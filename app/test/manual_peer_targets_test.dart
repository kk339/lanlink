/// 0.2.54 — **the live set of hand-typed addresses**: adding one, the capacity
/// limit, removing one, and the boot-time replay.
///
/// ## Why the set needs a life cycle at all
///
/// `manual_probe_test.dart` pins "one probe makes a peer sendable". That is not
/// enough to make the feature usable, for two reasons this file is about:
///
/// 1. **A probe expires.** `/hello` is the only request that refreshes a peer's
///    registry on both sides, and both sides drop a peer after 60 s. So the 25 s
///    heartbeat exists to re-dial the addresses the user typed — and the set it
///    dials is what these judgements are about.
/// 2. **A set that only grows kills the feature.** One heartbeat pass is
///    *serial* with a 3 s deadline per address, so nine permanently-unreachable
///    addresses take 27 s — longer than the 25 s period — and the pass then
///    overlaps or is dropped while the peers that *do* answer fall off the list.
///    Hence the cap ([kMaxManualPeers]) and hence a removal path that actually
///    reaches the dialling code.
///
/// Every judgement here runs the **real** `LanPeerDiscovery` over the **real**
/// `core.PeerRegistry`, with only the HTTP client doubled (the peers are, by
/// definition, not on this machine). A fake-only test would prove the fake works.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/data/real/lan_peer_discovery.dart';
import 'package:lanlink_app/domain/manual_targets.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/peer_discovery.dart';
import 'package:lanlink_core/lanlink_core.dart' as core;

import 'support/fakes.dart';

/// The port every fake peer in this file says its receiver listens on.
const int _kPort = 49494;

/// The fingerprint of the peer that "is there".
final String _kPeerFp = 'A1' * 32;

/// A `core.PeerClient` whose `/hello` round trip is decided by the harness: a
/// fingerprint means "this peer answers", `null` means the connection is refused.
class _FakeProbeClient extends core.PeerClient {
  _FakeProbeClient({
    required super.host,
    required super.port,
    this.peer,
    this.fingerprint,
  }) : super(allowUnknownCertificate: true);

  /// The frame the peer answers with, when it answers.
  final core.DeviceInfo? peer;

  /// What the TLS handshake measured. `null` models "nothing answered".
  final String? fingerprint;

  @override
  String? get observedFingerprint => fingerprint;

  @override
  Future<core.DeviceInfo> register({required core.DeviceInfo self}) {
    final core.DeviceInfo? reply = peer;
    if (reply == null) {
      return Future<core.DeviceInfo>.error(
        const SocketException('Connection refused'),
      );
    }
    return Future<core.DeviceInfo>.value(reply);
  }
}

/// A real adapter over a real registry, with the dialler doubled and a record of
/// every dial it made.
///
/// Not started: nothing here needs multicast, and a hand-typed address is
/// deliberately usable without `start()` (that is the situation it exists for).
class _Harness {
  _Harness(this.certificate) {
    discovery = LanPeerDiscovery(
      certificate: certificate,
      // 60 s, exactly as `bootstrap/create_deps_native.dart` configures it: the
      // deadline the heartbeat exists to beat.
      registry: registry,
      clock: FixedClock(fixedEpoch),
      selfPort: 53317,
      alias: 'self',
      registrations: const Stream<DiscoveredPeer>.empty(),
      onLog: logs.add,
      probeClient: _buildClient,
    );
  }

  final core.DeviceCertificate certificate;

  final core.PeerRegistry registry =
      core.PeerRegistry(offlineAfter: const Duration(seconds: 60));

  /// Every log line the adapter wrote — the only place a "silent" refusal would
  /// be invisible, so several judgements read it.
  final List<String> logs = <String>[];

  /// Every dial, in order, as `host:port`.
  final List<String> dials = <String>[];

  late final LanPeerDiscovery discovery;

  /// host → the fingerprint the peer there presents. An absent host refuses.
  final Map<String, String> answers = <String, String>{};

  core.PeerClient _buildClient({required String host, required int port}) {
    dials.add('$host:$port');
    final String? fingerprint = answers[host];
    if (fingerprint == null) {
      return _FakeProbeClient(host: host, port: port);
    }
    return _FakeProbeClient(
      host: host,
      port: port,
      fingerprint: fingerprint,
      peer: core.DeviceInfo(
        alias: 'peer@$host',
        fingerprint: fingerprint,
        port: _kPort,
        deviceType: core.DeviceType.desktop,
      ),
    );
  }

  Future<void> dispose() async {
    await discovery.dispose();
    await registry.dispose();
  }
}

void main() {
  late core.DeviceCertificate certificate;

  setUpAll(() {
    // One RSA keygen for the whole file (~a second, once).
    certificate =
        core.DeviceCertificate.generate(commonName: 'lanlink-manual-targets');
  });

  group('1. adding an address arms the heartbeat (0.2.54)', () {
    test('add is idempotent and keeps insertion order', () async {
      final _Harness h = _Harness(certificate);
      addTearDown(h.dispose);

      h.discovery.addManualTarget('192.168.1.30', _kPort);
      h.discovery.addManualTarget('192.168.1.10', _kPort);
      // The same address twice is one target — the heartbeat must not dial it
      // twice per pass.
      h.discovery.addManualTarget('192.168.1.30', _kPort);
      // A bracketed IPv6 literal is the same target as the bare one.
      h.discovery.addManualTarget('[fe80::1]', _kPort);
      h.discovery.addManualTarget('fe80::1', _kPort);

      expect(
        h.discovery.manualTargets,
        <({String host, int port})>[
          (host: '192.168.1.30', port: _kPort),
          (host: '192.168.1.10', port: _kPort),
          (host: 'fe80::1', port: _kPort),
        ],
        reason: 'insertion order is the dial order — the serial heartbeat logs '
            'and dials in it',
      );
      expect(h.discovery.manualTargetCount, 3);
      expect(h.discovery.hasManualHeartbeat, isTrue,
          reason: 'a target with no timer would be an address nobody re-dials');
    });

    test('an address that is not an address never becomes a target', () async {
      final _Harness h = _Harness(certificate);
      addTearDown(h.dispose);

      h.discovery.addManualTarget('mypc.local', _kPort); // hostname
      h.discovery.addManualTarget('192.168.1.300', _kPort); // not an IPv4 literal
      h.discovery.addManualTarget('', _kPort);
      h.discovery.addManualTarget('192.168.1.5', 0);
      h.discovery.addManualTarget('192.168.1.5', 65536);

      expect(h.discovery.manualTargets, isEmpty,
          reason: 'the same rule `probeHost` applies to a typed string applies '
              'here, or the seeded set could hold addresses nobody can dial');
      expect(h.discovery.hasManualHeartbeat, isFalse);
      expect(h.logs.where((String line) => line.contains('ignored')), hasLength(5),
          reason: 'each refusal is recorded — a silently dropped address is the '
              '"it just does not work" bug this feature exists to remove');
    });
  });

  group('2. the capacity limit (why the list cannot grow forever)', () {
    test('the ninth address is refused, and the refusal is visible', () async {
      final _Harness h = _Harness(certificate);
      addTearDown(h.dispose);

      for (int i = 1; i <= kMaxManualPeers; i += 1) {
        h.discovery.addManualTarget('192.168.1.$i', _kPort);
      }
      expect(h.discovery.manualTargets, hasLength(kMaxManualPeers),
          reason: 'nine permanently unreachable addresses would take 27 s a '
              'pass (serial, 3 s each) — longer than the 25 s period, which is '
              'the staleness the cap exists to prevent');
      expect(h.discovery.manualTargetsFull, isTrue);

      h.discovery.addManualTarget('192.168.1.99', _kPort);

      expect(h.discovery.manualTargets, hasLength(kMaxManualPeers),
          reason: 'the ninth must not be kept');
      expect(
        h.discovery.manualTargets.map((({String host, int port}) t) => t.host),
        isNot(contains('192.168.1.99')),
      );
      expect(
        h.logs.any((String line) => line.contains('refusing 192.168.1.99')),
        isTrue,
        reason: 'a silently dropped address is a bug report waiting to happen — '
            'the caller can also read manualTargetsFull and say so in the UI',
      );
      expect(h.discovery.hasManualHeartbeat, isTrue,
          reason: 'the eight already kept still have to be re-dialled');
    });

    test('a probe at capacity still connects once, but keeps no target',
        () async {
      final _Harness h = _Harness(certificate);
      addTearDown(h.dispose);
      for (int i = 1; i <= kMaxManualPeers; i += 1) {
        h.discovery.addManualTarget('192.168.1.$i', _kPort);
      }
      h.answers['10.0.0.7'] = _kPeerFp;

      final ManualProbeResult result = await h.discovery.probeHost('10.0.0.7');

      expect(result, isA<ManualProbeOk>(),
          reason: 'the user asked to connect *now*; a full list of saved '
              'addresses must not block a one-off connection');
      expect(h.dials, <String>['10.0.0.7:$_kPort']);
      expect(h.registry.length, 1,
          reason: 'the peer is usable for this session');
      expect(h.discovery.manualTargets, hasLength(kMaxManualPeers),
          reason: 'but it is not remembered, because it cannot be re-dialled '
              'within one heartbeat period');
    });
  });

  group('3. removing an address is not deleting a device', () {
    test('remove drops the target and cancels the timer when it empties',
        () async {
      final _Harness h = _Harness(certificate);
      addTearDown(h.dispose);
      h.discovery.addManualTarget('192.168.1.23', _kPort);
      h.discovery.addManualTarget('192.168.1.24', _kPort);

      h.discovery.removeManualTarget('192.168.1.23', _kPort);

      expect(h.discovery.manualTargets, <({String host, int port})>[
        (host: '192.168.1.24', port: _kPort),
      ]);
      expect(h.discovery.hasManualHeartbeat, isTrue);

      h.discovery.removeManualTarget('192.168.1.24', _kPort);

      expect(h.discovery.manualTargets, isEmpty);
      expect(h.discovery.hasManualHeartbeat, isFalse,
          reason: 'an empty set must leave no timer behind: a 25 s dialler with '
              'nothing to dial is a battery cost nobody can see');
      // Idempotent: removing what is already gone is not an error.
      h.discovery.removeManualTarget('192.168.1.24', _kPort);
      expect(h.discovery.manualTargets, isEmpty);
    });

    test('the device stays in the registry after its address is forgotten',
        () async {
      final _Harness h = _Harness(certificate);
      addTearDown(h.dispose);
      h.answers['192.168.1.23'] = _kPeerFp;
      // A probe is how the address *and* the device both arrive.
      await h.discovery.probeHost('192.168.1.23');
      expect(h.registry.byFingerprint(_kPeerFp), isNotNull);
      expect(h.discovery.manualTargets, hasLength(1));

      h.discovery.removeManualTarget('192.168.1.23', _kPort);

      expect(h.discovery.manualTargets, isEmpty);
      expect(h.registry.byFingerprint(_kPeerFp), isNotNull,
          reason: 'forgetting a dial address and deleting a device are two '
              'different user intentions; the peer must go grey on its own '
              'schedule (sweepOffline), exactly like a peer found by multicast');
      expect(h.registry.byFingerprint(_kPeerFp)!.isOnline, isTrue);
    });
  });

  group('4. this device is never its own target', () {
    test('probing ourselves leaves no target and no heartbeat', () async {
      final _Harness h = _Harness(certificate);
      addTearDown(h.dispose);
      // The address at the other end of the probe turns out to be *this* device
      // (a plausible typo, and the classic "which of these two am I?" mistake).
      h.answers['127.0.0.1'] = certificate.fingerprint;

      final ManualProbeResult result = await h.discovery.probeHost('127.0.0.1');

      expect(result, isA<ManualProbeOk>(),
          reason: 'the probe did reach a lanlink peer — that part is true');
      expect(h.discovery.manualTargets, isEmpty,
          reason: 'a target here would make this device dial itself every 25 s, '
              'forever');
      expect(h.discovery.hasManualHeartbeat, isFalse);
      expect(h.registry.length, 0);
    });

    test('the other targets survive a self-probe', () async {
      final _Harness h = _Harness(certificate);
      addTearDown(h.dispose);
      h.discovery.addManualTarget('192.168.1.23', _kPort);
      h.answers['127.0.0.1'] = certificate.fingerprint;

      await h.discovery.probeHost('127.0.0.1');

      expect(h.discovery.manualTargets, <({String host, int port})>[
        (host: '192.168.1.23', port: _kPort),
      ]);
      expect(h.discovery.hasManualHeartbeat, isTrue);
    });
  });

  group('5. a cold start replays what the user typed', () {
    test('the live address appears, the dead one is kept and says nothing',
        () async {
      final _Harness h = _Harness(certificate);
      addTearDown(h.dispose);
      h.answers['192.168.1.10'] = _kPeerFp;
      // 192.168.1.11 is absent from `answers`, so it refuses — the ordinary
      // "that phone is off / this IP now belongs to something else" case.

      // What `create_deps_native` does with a settings document: seed, then run
      // one pass in the background.
      h.discovery.seedManualTargets(const <ManualPeerTarget>[
        ManualPeerTarget(host: '192.168.1.10', port: _kPort),
        ManualPeerTarget(host: '192.168.1.11', port: _kPort),
      ]);
      expect(h.discovery.manualTargets, hasLength(2));
      expect(h.discovery.hasManualHeartbeat, isTrue,
          reason: 'seeding alone must arm the heartbeat — the boot pass is an '
              'optimisation, not the mechanism');

      await h.discovery.heartbeatOnce();

      expect(h.dials, <String>['192.168.1.10:$_kPort', '192.168.1.11:$_kPort']);
      expect(h.discovery.online.map((DiscoveredPeer p) => p.fingerprint),
          <String>[_kPeerFp],
          reason: 'the address that answers is a device again, with no user action');
      expect(
        h.discovery.online.single.address,
        '192.168.1.10',
        reason: 'the address that provably works is the one the card must show',
      );
      expect(h.discovery.manualTargets, hasLength(2),
          reason: 'the dead address is kept: "not answering right now" is the '
              'state the heartbeat exists to recover from');
      expect(h.discovery.status.phase, DiscoveryPhase.starting,
          reason: 'one unreachable stored address must not fail discovery, '
              'raise the E10 banner, or crash the launch');
      expect(
        h.logs.where((String line) =>
            line.contains('192.168.1.11') &&
            // Seeding one address is not news; a *failed* dial is what would be,
            // and there must be none: `quiet` is the heartbeat's mode and the
            // first health observation is silent by design.
            !line.contains('added by the caller')),
        isEmpty,
        reason: 'nothing to say: the peer is simply not there yet, and a log line '
            'per pass for an hour would bury the ones that matter',
      );
    });
  });
}
