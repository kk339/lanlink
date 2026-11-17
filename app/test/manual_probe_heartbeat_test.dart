/// 0.2.54 — **the manual probe's heartbeat**: what makes a hand-typed device
/// stay a device for longer than a minute.
///
/// ## The time scale that forced this file (read this before touching it)
///
/// `POST /api/lanlink/v1/hello` is the **only** request that refreshes the
/// *receiving* side's registry (`core/peer_server.dart`'s `onPeerSeen`);
/// `/prepare`, `/put` and `/text` do not. And both sides time a peer out after
/// **60 s** — production passes `offlineAfter: const Duration(seconds: 60)` in
/// `bootstrap/create_deps_native.dart`.
///
/// A one-shot probe therefore buys 60 seconds, and the failure is **one-way**:
/// once the peer's card goes grey here there is nothing dialable left (so we
/// cannot send), and on the peer's side our card goes grey too (so what it
/// sends us is queued, not delivered). Typing the address again every minute is
/// not a feature. A heartbeat is: re-probe the same address every 25 s
/// (`_kManualHeartbeat`), which is roughly two attempts per deadline.
///
/// ## What each judgement is *for*
///
/// 1. the timer exists **iff** there is a target — no target, no 25 s wake-up on
///    a phone that has never used the feature;
/// 2. the heartbeat is what keeps the peer online across the 60 s deadline (this
///    is the whole point of the step, and its control case — no heartbeat, peer
///    offline — is the first test below);
/// 3. a failed heartbeat keeps the target, so a peer that comes back is found
///    without the user typing anything again ("self-healing");
/// 4. the pass is serial: never two dials in flight at once;
/// 5. `stop()` stops dialling — a stopped adapter must not keep opening TLS
///    connections from a timer nobody can see;
/// 6. one pass = one dial per target (not zero, not n²).
///
/// ## Why the interval is shortened instead of waiting
///
/// The adapter takes its period as a parameter (`manualHeartbeatInterval`,
/// defaulting to [_kManualHeartbeat] — the same shape as `announceInterval`),
/// so a test can watch real ticks in ~20 ms and a real absence of ticks in the
/// same window. The **production** value is asserted separately, from the class
/// under test only: a test that burns 75 s of wall clock to prove "no dial after
/// stop()" would be a flaky test, not a stricter one.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/data/real/lan_peer_discovery.dart';
import 'package:lanlink_app/domain/clock.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/peer_discovery.dart';
import 'package:lanlink_core/lanlink_core.dart' as core;

/// The instant every judgement starts from.
final DateTime _kEpoch = DateTime.utc(2026, 1, 1, 12);

/// The port the fake peers answer on (what they *say* their receiver listens on).
const int _kPeerPort = 49494;

/// Two addresses, so "serial" and "one dial per target" have something to say.
const String _kHostA = '192.168.1.23';
const String _kHostB = '192.168.1.24';

/// The two peers' real identities — what their certificates hash to.
final String _kFpA = 'A1' * 32;
final String _kFpB = 'B2' * 32;

/// What one fake peer does when it is dialled.
enum _Answer {
  /// A lanlink peer answers `/hello` properly.
  answers,

  /// Nothing is listening: the connect is refused.
  refused,
}

/// One fake peer: its identity, and how it answers.
class _Peer {
  _Peer({required this.fingerprint, this.alias = 'Alice Phone',
      this.answer = _Answer.answers});

  final String fingerprint;
  final String alias;

  /// Mutable so a test can make a peer that answered stop answering — the
  /// "went away, should come back" case the heartbeat exists for.
  _Answer answer;
}

/// Records how many probes are in flight at once, and in what order they were
/// dialled.
///
/// **This is how "serial" is observed.** The concurrency of one pass is not
/// visible from the outside: `heartbeatOnce()` returns one future no matter how
/// many dials it made. Counting entries into [core.PeerClient.register] and
/// taking the maximum is the only honest measurement — `Future.wait` over two
/// targets would push this peak to 2 even though the pass still "awaited".
class _Gauge {
  int _inFlight = 0;

  /// The highest number of simultaneous `/hello` calls ever observed.
  int peak = 0;

  /// Dial order, as `host:port`.
  final List<String> order = <String>[];

  void enter(String target) {
    _inFlight += 1;
    order.add(target);
    if (_inFlight > peak) {
      peak = _inFlight;
    }
  }

  void leave() => _inFlight -= 1;
}

/// A `core.PeerClient` whose `/hello` outcome the test decides.
///
/// A double rather than a socket for the same reason `manual_probe_test.dart`
/// uses one: the peers these tests are about are *not on this machine*, and the
/// suite must stay hermetic (no ports bound, no real handshakes). Unlike that
/// file's double this one **takes time to answer** ([hold]), which is what makes
/// overlap observable at all.
class _FakeProbeClient extends core.PeerClient {
  _FakeProbeClient({
    required super.host,
    required super.port,
    required this.peer,
    required this.gauge,
    required this.hold,
  }) : super(allowUnknownCertificate: true);

  final _Peer peer;
  final _Gauge gauge;
  final Duration hold;

  @override
  String? get observedFingerprint => peer.fingerprint;

  @override
  Future<core.DeviceInfo> register({required core.DeviceInfo self}) async {
    gauge.enter('$host:$port');
    try {
      await Future<void>.delayed(hold);
      if (peer.answer == _Answer.refused) {
        throw const SocketException('Connection refused');
      }
      return core.DeviceInfo(
        alias: peer.alias,
        fingerprint: peer.fingerprint,
        port: _kPeerPort,
        deviceType: core.DeviceType.mobile,
      );
    } finally {
      gauge.leave();
    }
  }
}

/// A real `LanPeerDiscovery` over a real `core.PeerRegistry` (60 s, exactly as
/// production configures it), with the probe's client replaced by
/// [_FakeProbeClient] and a clock the test moves by hand.
///
/// The adapter is **not started**: nothing here needs multicast, and a manual
/// probe is deliberately usable without `start()` (that is the situation it
/// exists for — discovery failed and the user typed an address). The registry's
/// 1 s sweeper is not installed either, so every sweep below is an explicit call
/// with an explicit `now` — which is what makes the 60 s deadline testable at
/// all.
class _Harness {
  _Harness(this.certificate, {this.interval = const Duration(seconds: 25)}) {
    discovery = LanPeerDiscovery(
      certificate: certificate,
      registry: registry,
      clock: clock,
      selfPort: 53317,
      alias: 'self',
      registrations: const Stream<DiscoveredPeer>.empty(),
      onLog: logs.add,
      probeClient: _buildClient,
      manualHeartbeatInterval: interval,
    );
  }

  final core.DeviceCertificate certificate;

  /// The heartbeat period this harness injects (production: 25 s).
  final Duration interval;

  /// 60 s, the value `bootstrap/create_deps_native.dart` passes — the deadline
  /// these tests are about.
  final core.PeerRegistry registry =
      core.PeerRegistry(offlineAfter: const Duration(seconds: 60));

  final FixedClock clock = FixedClock(_kEpoch);
  final List<String> logs = <String>[];
  final _Gauge gauge = _Gauge();

  /// Every dial the adapter made, as `host:port`.
  List<String> get dials => gauge.order;

  late final LanPeerDiscovery discovery;

  /// What each address answers. Absent address = refused (nothing there).
  final Map<String, _Peer> peers = <String, _Peer>{};

  /// How long one `/hello` takes. Long enough that two overlapping dials would
  /// be seen by [_Gauge.peak].
  Duration hold = const Duration(milliseconds: 5);

  core.PeerClient _buildClient({required String host, required int port}) {
    // An address nobody registered answers like an empty address does: refused.
    final _Peer peer = peers[host] ??
        _Peer(fingerprint: 'FF' * 32, answer: _Answer.refused);
    return _FakeProbeClient(
      host: host,
      port: port,
      peer: peer,
      gauge: gauge,
      hold: hold,
    );
  }

  /// The peer's live registry entry, if any.
  core.Peer? peer(String fingerprint) => registry.byFingerprint(fingerprint);

  /// Whether the registry currently considers [fingerprint] online.
  bool isOnline(String fingerprint) =>
      registry.byFingerprint(fingerprint)?.isOnline ?? false;

  /// One registry sweep at the current clock — what the adapter's 1 s sweeper
  /// does in production (`registry.sweepOffline(clock.nowUtc())`).
  void sweep() => registry.sweepOffline(clock.nowUtc());

  Future<void> dispose() async {
    await discovery.dispose();
    await registry.dispose();
  }
}

/// A harness whose heartbeat ticks fast enough to observe, without changing the
/// behaviour under test (the period is the only thing shortened).
_Harness _fast(core.DeviceCertificate certificate) => _Harness(
      certificate,
      interval: const Duration(milliseconds: 20),
    );

/// Waits for [ticks] heartbeat periods plus slack, so "a tick happened" is not
/// a race against the scheduler.
Future<void> _waitTicks(Duration interval, int ticks) =>
    Future<void>.delayed(interval * ticks + const Duration(milliseconds: 40));

void main() {
  late core.DeviceCertificate certificate;

  setUpAll(() {
    // One RSA keygen for the whole file (~a second, once) — the same trick
    // `manual_probe_test.dart` uses.
    certificate =
        core.DeviceCertificate.generate(commonName: 'lanlink-heartbeat-test');
  });

  group('1. the timer exists iff there is a manual target', () {
    test('a fresh adapter has no target and no heartbeat', () async {
      final _Harness h = _fast(certificate);
      addTearDown(h.dispose);

      expect(h.discovery.manualProbeTargets, isEmpty);
      expect(h.discovery.hasManualHeartbeat, isFalse);

      // Nothing was ever typed, so nothing may wake up: wait out several
      // periods and require silence. A phone that never used the feature must
      // not carry a 25 s timer for the whole session.
      await _waitTicks(h.interval, 3);
      expect(h.dials, isEmpty,
          reason: 'no target means no probe — not even a "just checking" one');
    });

    test('a parsed target arms it; a malformed input does not', () async {
      final _Harness h = _fast(certificate);
      addTearDown(h.dispose);
      h.peers[_kHostA] = _Peer(fingerprint: _kFpA);

      // `badInput` is the one outcome that must **not** become a target: there
      // is nothing to keep dialling.
      final ManualProbeResult rejected = await h.discovery.probeHost('abc');
      expect((rejected as ManualProbeError).reason,
          ManualProbeFailure.badInput);
      expect(h.discovery.manualProbeTargets, isEmpty);
      expect(h.discovery.hasManualHeartbeat, isFalse,
          reason: 'a typo must not arm a background dialler');

      await h.discovery.probeHost(_kHostA);
      expect(h.discovery.manualProbeTargets, <String>{'$_kHostA:$_kPeerPort'});
      expect(h.discovery.hasManualHeartbeat, isTrue);

      // …and it really ticks: the probe itself dialled once, the heartbeat
      // dials again without anyone asking.
      final int afterProbe = h.dials.length;
      await _waitTicks(h.interval, 2);
      expect(h.dials.length, greaterThan(afterProbe),
          reason: 'an armed heartbeat must actually dial');
    });

    test('the production period is 25 s: two attempts per 60 s deadline', () {
      // The number matters (60 s / 25 s > 2), and it is judged as a number:
      // sleeping 25 s to observe it would be a slow test, not a stricter one.
      // This harness keeps the **default** period — no injection.
      final _Harness h = _Harness(certificate);
      addTearDown(h.dispose);
      h.peers[_kHostA] = _Peer(fingerprint: _kFpA);

      expect(h.discovery.manualHeartbeatPeriod, const Duration(seconds: 25),
          reason: 'a heartbeat longer than the 60 s deadline would leave the '
              'peer offline between two of them');
      expect(h.discovery.manualHeartbeatPeriod,
          lessThan(const Duration(seconds: 60)));
    });
  });

  group('2. the heartbeat is what keeps the peer online across 60 s', () {
    test('control: with no heartbeat the peer is offline 61 s after one probe',
        () async {
      // This is the state 0.2.54 shipped in, and it is why the step exists. It
      // is kept green as the control that makes the next test non-vacuous: the
      // 60 s deadline really does kill a one-shot probe.
      final _Harness h = _fast(certificate);
      addTearDown(h.dispose);
      h.peers[_kHostA] = _Peer(fingerprint: _kFpA);

      await h.discovery.probeHost(_kHostA);
      expect(h.isOnline(_kFpA), isTrue);

      // Never a heartbeat: cancel the timer the probe armed, which is exactly
      // the pre-0.2.54 world.
      await h.discovery.stop();

      h.clock.advance(const Duration(seconds: 61));
      h.sweep();

      expect(h.isOnline(_kFpA), isFalse,
          reason: 'one /hello buys 60 s; nothing refreshed it');
      expect(h.discovery.online, isEmpty,
          reason: 'and the device card goes grey — the user can no longer send');
    });

    test('a heartbeat before the deadline keeps it online past the deadline',
        () async {
      final _Harness h = _fast(certificate);
      addTearDown(h.dispose);
      h.peers[_kHostA] = _Peer(fingerprint: _kFpA);

      // t=0: the user types the address; the probe files the peer.
      await h.discovery.probeHost(_kHostA);
      final DateTime probedAt = h.peer(_kFpA)!.lastSeen;
      expect(h.isOnline(_kFpA), isTrue);

      // t=50s: still inside the 60 s window, so a sweep agrees.
      h.clock.advance(const Duration(seconds: 50));
      h.sweep();
      expect(h.isOnline(_kFpA), isTrue,
          reason: '50 s < 60 s, so this assertion cannot carry the judgement');

      // One heartbeat pass, at t=50s.
      await h.discovery.heartbeatOnce();
      expect(h.peer(_kFpA)!.lastSeen, h.clock.nowUtc(),
          reason: 'the heartbeat must actually re-register, i.e. move '
              'lastSeen — not just "succeed"');

      // t=61s: past the deadline that killed the control case above.
      h.clock.advance(const Duration(seconds: 11));
      h.sweep();

      expect(h.isOnline(_kFpA), isTrue,
          reason: 'this is the whole point of the step: /hello at t=50s makes '
              'the peer fresh again, so t=61s is 11 s since the last sighting');
      expect(h.discovery.online.single.fingerprint, _kFpA);
      expect(probedAt.isBefore(h.peer(_kFpA)!.lastSeen), isTrue);
    });
  });

  group('3. a failed heartbeat keeps the target (self-healing)', () {
    test('a peer that stops answering stays a target and is retried', () async {
      final _Harness h = _fast(certificate);
      addTearDown(h.dispose);
      h.peers[_kHostA] = _Peer(fingerprint: _kFpA);

      await h.discovery.probeHost(_kHostA);
      expect(h.isOnline(_kFpA), isTrue);

      // The peer goes away (receiver off, reboot, Wi-Fi hop).
      h.peers[_kHostA]!.answer = _Answer.refused;
      final int dialsBefore = h.dials.length;
      await h.discovery.heartbeatOnce();

      expect(h.dials.length, dialsBefore + 1, reason: 'it did try');
      expect(h.discovery.manualProbeTargets, contains('$_kHostA:$_kPeerPort'),
          reason: 'a probe failure is not a user decision: the address stays, '
              'so the peer is found again by itself');
      expect(h.discovery.hasManualHeartbeat, isTrue);

      // …and the retry is what finds it when it comes back.
      h.peers[_kHostA]!.answer = _Answer.answers;
      h.clock.advance(const Duration(seconds: 30));
      await h.discovery.heartbeatOnce();
      h.sweep();

      expect(h.isOnline(_kFpA), isTrue,
          reason: 'the peer returned and nobody had to type the address again');
      expect(h.peer(_kFpA)!.lastSeen, h.clock.nowUtc());
    });

    test('an unreachable probe is still a target (the "not on yet" case)',
        () async {
      final _Harness h = _fast(certificate);
      addTearDown(h.dispose);
      // Nothing answers at this address yet — the user typed it before turning
      // the other machine's receiver on.
      final ManualProbeResult result = await h.discovery.probeHost(_kHostB);

      expect((result as ManualProbeError).reason,
          ManualProbeFailure.unreachable);
      expect(h.discovery.manualProbeTargets, <String>{'$_kHostB:$_kPeerPort'},
          reason: '"unreachable" must still be remembered: the peer may simply '
              'not be listening yet');

      // It comes up later; the heartbeat finds it with no further input.
      h.peers[_kHostB] = _Peer(fingerprint: _kFpB, alias: 'Bob Box');
      await h.discovery.heartbeatOnce();

      expect(h.isOnline(_kFpB), isTrue);
      expect(h.peer(_kFpB)!.address, _kHostB);
    });
  });

  group('4. one pass is serial', () {
    test('never two dials in flight at once, and each target dialled once',
        () async {
      final _Harness h = _fast(certificate);
      addTearDown(h.dispose);
      // Two targets, and each `/hello` takes long enough (5 ms, see
      // [_Harness.hold]) that an overlapping dial would be counted.
      h.peers[_kHostA] = _Peer(fingerprint: _kFpA);
      h.peers[_kHostB] = _Peer(fingerprint: _kFpB, alias: 'Bob Box');
      await h.discovery.probeHost(_kHostA);
      await h.discovery.probeHost(_kHostB);

      h.gauge.peak = 0;
      final int before = h.dials.length;

      await h.discovery.heartbeatOnce();

      expect(h.gauge.peak, 1,
          reason: 'a serial pass never has two handshakes open — `Future.wait` '
              'over the targets would push this to 2');
      expect(h.dials.length - before, 2,
          reason: 'one dial per target: not 0 (a pass that skips targets) and '
              'not 4 (a pass that dials each twice)');
      expect(h.dials.sublist(before), <String>[
        '$_kHostA:$_kPeerPort',
        '$_kHostB:$_kPeerPort',
      ], reason: 'insertion order, so a log is readable in dial order');
    });
  });

  group('5. stop() stops the dialling', () {
    test('no probe after stop(), and the timer is gone', () async {
      final _Harness h = _fast(certificate);
      addTearDown(h.dispose);
      h.peers[_kHostA] = _Peer(fingerprint: _kFpA);

      await h.discovery.probeHost(_kHostA);
      await _waitTicks(h.interval, 2);
      expect(h.dials.length, greaterThan(1),
          reason: 'the heartbeat must have been ticking, or the judgement below '
              'would pass on an adapter that never ticked at all');

      await h.discovery.stop();
      expect(h.discovery.hasManualHeartbeat, isFalse,
          reason: 'a stopped adapter must not own a timer');

      // Three periods' worth of waiting: zero further dials.
      final int dialsAtStop = h.dials.length;
      await _waitTicks(h.interval, 3);
      expect(h.dials, hasLength(dialsAtStop),
          reason: 'stop() is the user/tests turning discovery off; a timer '
              'still opening TLS connections after it is a leak');
    });

    test('a stop() in the middle of a pass drops the rest of the targets',
        () async {
      // The pass is serial, so a `stop()` that arrives while target #1 is being
      // dialled can still see target #2 ahead of it. It must not dial it: after
      // `stop()` the adapter owns no timer, and an in-flight loop is the one
      // remaining way a stopped adapter could open a connection.
      final _Harness h = _Harness(certificate); // 25 s: the timer never ticks
      addTearDown(h.dispose);
      h.peers[_kHostA] = _Peer(fingerprint: _kFpA);
      h.peers[_kHostB] = _Peer(fingerprint: _kFpB, alias: 'Bob Box');
      h.hold = const Duration(milliseconds: 60);
      await h.discovery.probeHost(_kHostA);
      await h.discovery.probeHost(_kHostB);

      final int before = h.dials.length;
      final Future<void> pass = h.discovery.heartbeatOnce();
      // Let the first dial start, then stop while it is in flight.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await h.discovery.stop();
      await pass;

      expect(h.dials.length - before, 1,
          reason: 'only the dial already in flight; target #2 must be dropped');
    });

    test('dispose() also stops it (no pending timer at the end of a test)',
        () async {
      final _Harness h = _fast(certificate);
      h.peers[_kHostA] = _Peer(fingerprint: _kFpA);
      await h.discovery.probeHost(_kHostA);
      expect(h.discovery.hasManualHeartbeat, isTrue);

      await h.dispose();

      expect(h.discovery.hasManualHeartbeat, isFalse);
      final int dialsAtDispose = h.dials.length;
      await _waitTicks(h.interval, 2);
      expect(h.dials, hasLength(dialsAtDispose));
    });
  });

  group('6. connection to the rest of the adapter', () {
    test('a heartbeat keeps the peer dialable, not just "online"', () async {
      final _Harness h = _fast(certificate);
      addTearDown(h.dispose);
      h.peers[_kHostA] = _Peer(fingerprint: _kFpA);

      await h.discovery.probeHost(_kHostA);
      h.clock.advance(const Duration(seconds: 40));
      await h.discovery.heartbeatOnce();

      // The same accessors the UI's merge uses (`selectors.mergeDeviceCards`
      // copies a live peer's address/port onto the card).
      final DiscoveredPeer peer = h.discovery.online.single;
      expect(peer.fingerprint, _kFpA);
      expect(peer.address, _kHostA);
      expect(peer.port, _kPeerPort);
    });

    test('the log reports a change once, not every period', () async {
      final _Harness h = _fast(certificate);
      addTearDown(h.dispose);
      h.peers[_kHostA] = _Peer(fingerprint: _kFpA);
      await h.discovery.probeHost(_kHostA);

      // Three passes on a peer that keeps answering: no repetition.
      final int logsBefore = h.logs.length;
      await h.discovery.heartbeatOnce();
      await h.discovery.heartbeatOnce();
      await h.discovery.heartbeatOnce();
      expect(h.logs, hasLength(logsBefore),
          reason: 'a pass that finds nothing new is silent; 25 s × N targets of '
              '"still there" is what hides the one line that matters');

      // The peer goes away: exactly one line, and it says the target is kept.
      h.peers[_kHostA]!.answer = _Answer.refused;
      await h.discovery.heartbeatOnce();
      final List<String> afterLoss = h.logs.sublist(logsBefore);
      expect(afterLoss, hasLength(1),
          reason: 'one transition, not one line per dial');
      expect(afterLoss.single, contains('does not answer'));
      expect(afterLoss.single, contains('keeping it as a target'));

      // …and one more pass changes nothing, so it stays quiet.
      await h.discovery.heartbeatOnce();
      expect(h.logs.where((String line) => line.contains('does not answer')),
          hasLength(1));

      // Back again: one line for the recovery.
      h.peers[_kHostA]!.answer = _Answer.answers;
      await h.discovery.heartbeatOnce();
      expect(
          h.logs.where((String line) => line.contains('answers again')),
          hasLength(1));
    });
  });
}
