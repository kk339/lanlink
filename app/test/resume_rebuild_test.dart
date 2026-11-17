/// Resume must **rebuild** discovery, not re-announce on the sockets that were
/// open before the phone slept (0.2.40 — "手机只能重新打开软件才会变成在线").
///
/// The bug, in one line: `rejoin()` re-joined the multicast group and
/// re-announced on the **pre-sleep** sockets; after an Android screen lock those
/// sockets keep reporting success while the datagrams go nowhere, and
/// `prepareBroadcast()` keys its sockets by **address**, so reconnecting to the
/// same AP with the same IP looked like "nothing changed". Only a full
/// `start()` (a fresh bind) cured it — which is why restarting the app worked.
///
/// What these pin (each criterion is written so it can fail):
///
///  1. the resume path **closes the old sockets and binds new ones** — asserted
///     as "the layer built before the resume was `stop()`ped and a *new* layer
///     was `start()`ed", and explicitly as "the old layer was **not**
///     `rejoin()`ed" (the exact old behaviour);
///  2. `AndroidForegroundService.ensureRunning()` is called on resume **and it
///     re-starts a service that died even though `start()` already succeeded**
///     (the `_started` latch that made a dead keep-alive unrecoverable);
///  3. the rebuild is retried after 3s, and a success on the second attempt
///     stops there (no third attempt) — asserted through an injected delay, so
///     the suite does not sleep;
///  4. the TCP `/register` fan-out happens **even when multicast is completely
///     dead** (`_multicast` never comes up), ≤3 dials at a time, and never
///     throws;
///  5. overlapping resumes cannot run two rebuilds at once.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/data/real/android_foreground_service.dart';
import 'package:lanlink_app/data/real/lan_peer_discovery.dart';
import 'package:lanlink_app/domain/clock.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/peer_discovery.dart';
import 'package:lanlink_core/lanlink_core.dart' as core;

const String _foregroundChannel = 'lanlink/foreground_service';

/// Stands in for the real [core.MulticastDiscovery].
///
/// `start()` **is** "bind the sockets" and `stop()` **is** "close the sockets":
/// that is exactly what the real class does inside those two methods
/// (`RawDatagramSocket.bind` / `.close`), so counting them here is the honest
/// way to assert a rebuild without racing a real NIC.
class _FakeMulticast extends core.MulticastDiscovery {
  _FakeMulticast({this.failStart = false})
      : super(
          deviceInfo: core.DeviceInfo(
            alias: 'self',
            fingerprint: 'AA' * 32,
            port: 53317,
          ),
        );

  /// When `true`, `start()` throws — a network that is not back yet.
  bool failStart;

  /// When set, `start()` blocks on it — used to hold a rebuild open so a second
  /// resume can be attempted while the first is still in flight.
  Completer<void>? startGate;

  int startCalls = 0;
  int stopCalls = 0;
  int rejoinCalls = 0;
  int announceCalls = 0;

  @override
  Future<void> start() async {
    startCalls++;
    final Completer<void>? gate = startGate;
    if (gate != null) {
      await gate.future;
    }
    if (failStart) {
      throw const SocketException('network is not back yet');
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<bool> rejoin() async {
    rejoinCalls++;
    return true;
  }

  @override
  void announce() {
    announceCalls++;
  }
}

/// Records the keep-alive calls the resume path makes.
class _FakeKeepAlive extends AndroidForegroundService {
  _FakeKeepAlive() : super(enabled: true);

  int ensureRunningCalls = 0;
  int startCalls = 0;

  @override
  Future<void> ensureRunning() async {
    ensureRunningCalls++;
  }

  @override
  Future<void> start() async {
    startCalls++;
  }
}

void _mockChannel(
  String name,
  Future<Object?> Function(MethodCall call) handler,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(MethodChannel(name), handler);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late core.DeviceCertificate certificate;

  setUpAll(() {
    // One RSA keygen for the whole file: ~a second, once.
    certificate = core.DeviceCertificate.generate(commonName: 'lanlink-test');
  });

  tearDown(() {
    _mockChannel(_foregroundChannel, (MethodCall call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(_foregroundChannel),
      null,
    );
  });

  /// A harness: one discovery wired to fakes, with its layers/logs recorded.
  _Harness harness({
    core.PeerRegistry? registry,
    AndroidForegroundService? keepAlive,
    RegisterBack? registerBack,
    List<bool>? startScript,
  }) {
    return _Harness(
      certificate: certificate,
      registry: registry ?? core.PeerRegistry(),
      keepAlive: keepAlive,
      registerBack: registerBack,
      startScript: startScript,
    );
  }

  group('1) resume rebuilds the sockets', () {
    test('the pre-resume layer is stop()ped and a NEW layer is start()ed '
        '(and the old one is never rejoin()ed)', () async {
      final _Harness h = harness();
      addTearDown(h.dispose);

      await h.discovery.start();
      expect(h.layers, hasLength(1), reason: 'launch builds one layer');
      expect(h.layers.single.startCalls, 1);

      await h.discovery.rejoin();

      expect(h.layers, hasLength(2), reason: 'a resume must build a NEW layer');
      expect(
        h.layers[0].stopCalls,
        1,
        reason: 'the pre-sleep sockets must be closed',
      );
      expect(
        h.layers[1].startCalls,
        1,
        reason: 'fresh sockets must be bound',
      );
      expect(
        h.layers[0].rejoinCalls,
        0,
        reason: 'the old socket must NOT be re-joined — that is the 0.2.39 bug',
      );
      expect(
        h.layers[1].rejoinCalls,
        0,
        reason: 'a freshly built layer needs no re-join either',
      );
    });

    test('a resume that succeeds leaves the phase running', () async {
      final _Harness h = harness();
      addTearDown(h.dispose);

      await h.discovery.start();
      await h.discovery.rejoin();

      expect(h.discovery.status.phase, DiscoveryPhase.running);
    });
  });

  group('2) the platform keep-alives are re-asserted', () {
    test('resume calls ensureRunning() on the keep-alive, after start() has '
        'already run', () async {
      final _FakeKeepAlive keepAlive = _FakeKeepAlive();
      final _Harness h = harness(keepAlive: keepAlive);
      addTearDown(h.dispose);

      await h.discovery.start();
      expect(keepAlive.startCalls, 1, reason: 'launch starts it once');

      await h.discovery.rejoin();

      expect(
        keepAlive.ensureRunningCalls,
        1,
        reason: 'the resume must re-assert the keep-alive (it may have died)',
      );
    });

    test('ensureRunning() re-starts the service although start() already '
        'succeeded once — the `_started` latch must not swallow it', () async {
      int starts = 0;
      bool running = false;
      _mockChannel(_foregroundChannel, (MethodCall call) async {
        switch (call.method) {
          case 'start':
            starts++;
            running = true;
            return <String, Object?>{'started': true};
          case 'status':
            return <String, Object?>{'running': running};
          case 'notificationPermission':
            return true;
          case 'requestNotificationPermission':
            return true;
        }
        return null;
      });

      final AndroidForegroundService service =
          AndroidForegroundService(enabled: true);
      await service.start();
      expect(starts, 1);

      // Android killed the service while the app was cached. `_started` is
      // still true here — that is the state that used to be unrecoverable.
      running = false;
      await service.ensureRunning();

      expect(
        starts,
        2,
        reason: 'ensureRunning must ask the platform, not trust its own latch',
      );
    });

    test('ensureRunning() does nothing when the platform says it is up', () async {
      int starts = 0;
      _mockChannel(_foregroundChannel, (MethodCall call) async {
        switch (call.method) {
          case 'start':
            starts++;
            return <String, Object?>{'started': true};
          case 'status':
            return <String, Object?>{'running': true};
          case 'notificationPermission':
            return true;
        }
        return null;
      });

      final AndroidForegroundService service =
          AndroidForegroundService(enabled: true);
      await service.ensureRunning();

      expect(starts, 0, reason: 'a healthy service must not be started twice');
    });
  });

  group('3) the rebuild is retried with a backoff', () {
    test('fails once → waits 3s → succeeds → no third attempt', () async {
      // Layer #1 (launch) ok, layer #2 (first resume attempt) fails,
      // layer #3 (retry) ok.
      final _Harness h = harness(startScript: <bool>[true, false, true]);
      addTearDown(h.dispose);

      await h.discovery.start();
      await h.discovery.rejoin();

      expect(h.layers, hasLength(3), reason: 'one retry, then success');
      expect(
        h.delays,
        <Duration>[const Duration(seconds: 3)],
        reason: 'the retry is spaced by one 3s backoff',
      );
      expect(h.layers[1].startCalls, 1, reason: 'attempt #1 really was tried');
      expect(h.layers[2].startCalls, 1, reason: 'attempt #2 came up');
      expect(h.discovery.status.phase, DiscoveryPhase.running);
    });

    test('every attempt failing → 3s then 6s, then phase failed + a visible '
        'event (the E10 banner)', () async {
      final _Harness h = harness(startScript: <bool>[true, false, false, false]);
      addTearDown(h.dispose);

      await h.discovery.start();
      h.events.clear();
      await h.discovery.rejoin();

      expect(h.delays, <Duration>[
        const Duration(seconds: 3),
        const Duration(seconds: 6),
      ]);
      expect(h.layers, hasLength(4), reason: 'launch + 3 attempts, no more');
      expect(h.discovery.status.phase, DiscoveryPhase.failed);
      // The event stream is a `StreamController`, so delivery is a microtask
      // behind the emit; drain it before asserting on it.
      await pumpEventQueue();
      expect(
        h.events.whereType<DiscoveryFailed>(),
        hasLength(1),
        reason: 'a failed resume must reach the UI, not just the log',
      );
      expect(
        h.logs.any((String line) => line.contains('rebuild failed after 3')),
        isTrue,
      );
    });
  });

  group('4) the TCP /register fan-out does not need multicast', () {
    test('dials every known peer even when the multicast layer can never come '
        'up, ≤3 at a time, and never throws', () async {
      final core.PeerRegistry registry = core.PeerRegistry();
      final FixedClock clock = FixedClock(DateTime.utc(2026, 1, 1));
      for (var i = 0; i < 5; i++) {
        registry.touch(
          core.DeviceInfo(
            alias: 'peer$i',
            fingerprint: '0$i' * 32,
            port: 53317 + i,
          ),
          address: '192.168.1.1$i',
          source: core.PeerSource.multicast,
          now: clock.nowUtc(),
        );
      }
      // The peers are known but currently offline — exactly the state the
      // registry is in after the phone slept through its own timeout.
      registry.sweepOffline(clock.nowUtc().add(const Duration(minutes: 5)));

      final List<String> dialled = <String>[];
      int inFlight = 0;
      int peak = 0;
      // The fan-out is fire-and-forget by design, so the test waits for the
      // last dial instead of guessing how many microtasks it takes.
      final Completer<void> allDialled = Completer<void>();

      final _Harness h = harness(
        registry: registry,
        // Every build fails: the multicast leg is 100% dead for this test.
        startScript: <bool>[false, false, false, false],
        registerBack: (core.DeviceInfo peer, String address) async {
          dialled.add('$address:${peer.port}');
          inFlight++;
          peak = inFlight > peak ? inFlight : peak;
          await Future<void>.delayed(Duration.zero);
          inFlight--;
          if (dialled.length == 5 && !allDialled.isCompleted) {
            allDialled.complete();
          }
        },
      );
      addTearDown(h.dispose);

      // Never started: `_multicast` is null from the outset, like a phone whose
      // discovery never came back after the lock.
      await h.discovery.rejoin();
      await allDialled.future;

      expect(
        dialled,
        hasLength(5),
        reason: 'every known peer is dialled over TCP, multicast or not',
      );
      expect(dialled, contains('192.168.1.10:53317'));
      expect(peak, lessThanOrEqualTo(3), reason: 'the fan-out is capped at 3');
      expect(
        peak,
        3,
        reason: 'with 5 peers the cap must actually be reached, not bypassed',
      );
      expect(
        h.logs.any((String line) => line.contains('over TCP')),
        isTrue,
      );
    });

    test('a failing /register is swallowed (one dead peer is not an error)',
        () async {
      final core.PeerRegistry registry = core.PeerRegistry();
      final FixedClock clock = FixedClock(DateTime.utc(2026, 1, 1));
      registry.touch(
        core.DeviceInfo(alias: 'gone', fingerprint: 'AB' * 32, port: 53317),
        address: '192.168.1.99',
        source: core.PeerSource.multicast,
        now: clock.nowUtc(),
      );

      final Completer<void> tried = Completer<void>();
      final _Harness h = harness(
        registry: registry,
        registerBack: (core.DeviceInfo peer, String address) async {
          if (!tried.isCompleted) {
            tried.complete();
          }
          throw const SocketException('connection refused');
        },
      );
      addTearDown(h.dispose);

      await h.discovery.start();
      await expectLater(h.discovery.rejoin(), completes);
      await tried.future;
      // One turn for the caught failure to reach the log.
      await Future<void>.delayed(Duration.zero);

      expect(
        h.logs.any((String line) => line.contains('register 192.168.1.99')),
        isTrue,
        reason: 'the failure is logged, not raised',
      );
    });
  });

  group('5) overlapping resumes cannot double-rebuild', () {
    test('a resume that arrives during a rebuild is dropped', () async {
      final _Harness h = harness();
      addTearDown(h.dispose);

      await h.discovery.start();

      final Completer<void> gate = Completer<void>();
      // The layer index is not known before it is built, so gate lazily.
      h.onBuild = (int index, _FakeMulticast layer) {
        if (index == 1) {
          layer.startGate = gate;
        }
      };

      final Future<void> first = h.discovery.rejoin();
      // Let the first resume reach the gated `start()`.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      await h.discovery.rejoin();

      expect(
        h.layers,
        hasLength(2),
        reason: 'the second resume must not build a second layer',
      );
      expect(
        h.logs.any((String line) => line.contains('already running')),
        isTrue,
        reason: 'the dropped resume is logged, never silent',
      );

      gate.complete();
      await first;

      expect(h.layers, hasLength(2), reason: 'still exactly one rebuild');
      expect(h.discovery.status.phase, DiscoveryPhase.running);
    });
  });
}

/// Everything one `LanPeerDiscovery` is wired to, plus the records the criteria
/// read.
class _Harness {
  _Harness({
    required this.certificate,
    required core.PeerRegistry registry,
    AndroidForegroundService? keepAlive,
    RegisterBack? registerBack,
    List<bool>? startScript,
  }) : _startScript = startScript {
    discovery = LanPeerDiscovery(
      certificate: certificate,
      registry: registry,
      clock: FixedClock(DateTime.utc(2026, 1, 1)),
      selfPort: 53317,
      alias: 'phone',
      registrations: const Stream<DiscoveredPeer>.empty(),
      onLog: logs.add,
      keepAlive: keepAlive,
      registerBack: registerBack,
      delay: (Duration duration) async {
        delays.add(duration);
      },
      multicastBuilder: () {
        final int index = layers.length;
        final _FakeMulticast layer = _FakeMulticast(
          // `startScript[i] == true` means "this build comes up".
          failStart: _startScript == null
              ? false
              : (index >= _startScript.length ? false : !_startScript[index]),
        );
        layers.add(layer);
        onBuild?.call(index, layer);
        return layer;
      },
    );
    discovery.events.listen(events.add);
  }

  final core.DeviceCertificate certificate;
  final List<bool>? _startScript;

  /// Every layer built, in order (`layers[0]` is the launch one).
  final List<_FakeMulticast> layers = <_FakeMulticast>[];
  final List<String> logs = <String>[];
  final List<Duration> delays = <Duration>[];
  final List<DiscoveryEvent> events = <DiscoveryEvent>[];

  /// Called with each newly built layer, for tests that gate a specific one.
  void Function(int index, _FakeMulticast layer)? onBuild;

  late final LanPeerDiscovery discovery;

  Future<void> dispose() => discovery.dispose();
}
