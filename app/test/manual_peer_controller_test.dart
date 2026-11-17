/// 0.2.54 — `HomeController.addManualPeer` / `removeManualPeer`: what the user
/// typed, what the app says, and what it remembers.
///
/// ## What is judged here, and why at this level
///
/// The sentences. A failed manual probe is the one place in this app where the
/// user is *stuck* — discovery found nothing, they typed an address by hand, and
/// it did not work. The four failure classes exist precisely because they imply
/// four different next actions (fix the typing / check the network / check the
/// identity / check the port), so the copy is asserted **verbatim** here, as a
/// requirement rather than as a reference to a constant: a test that compares
/// `kManualPeerUnreachable` with itself would stay green through any rewording.
///
/// The persistence is judged too — an address that works once and is gone after a
/// restart is the "why do I have to type this every time" report waiting to
/// happen.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/home_controller.dart';
import 'package:lanlink_app/domain/manual_targets.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/peer_discovery.dart';

import 'support/fakes.dart';

/// The peer the probes in this file reach.
const String _kFp = 'A1A1A1A1';

/// The address the user types.
const String _kHost = '192.168.1.23';

/// Its port.
const int _kPort = 49494;

/// The four sentences, **as shipped copy** (0.2.54 wording ruling).
///
/// Deliberately literal: see this file's header.
const Map<ManualProbeFailure, String> _kExpectedCopy =
    <ManualProbeFailure, String>{
  ManualProbeFailure.badInput: '地址格式不对。填 `192.168.1.23` 或 `192.168.1.23:49494`。',
  ManualProbeFailure.unreachable: '连不上。确认对方开着 lanlink、两台在同一 Wi-Fi，且没开『AP 隔离』。',
  ManualProbeFailure.certificateMismatch: '这个地址上的设备身份对不上。可能对方重装过，或这个 IP 分给了别的机器。',
  ManualProbeFailure.notLanlink: '这个地址上不是 lanlink。确认端口是 49494。',
};

/// A successful probe outcome for the address above.
const ManualProbeOk _kOk = ManualProbeOk(
  fingerprint: _kFp,
  alias: 'Alice Phone',
  port: _kPort,
  host: _kHost,
);

void main() {
  late FakeBackend backend;
  late HomeController home;

  setUp(() {
    backend = FakeBackend();
    home = HomeController(
      repo: backend.repo,
      discovery: backend.discovery,
      transfer: backend.transfer,
      // The settings document's only owner: remembering an address is an edit of
      // `AppSettings.manualPeers`.
      platform: backend.platform,
    );
  });

  tearDown(() {
    home.dispose();
    backend.dispose();
  });

  group('1. success is silent and the device simply appears', () {
    test('the card turns online at the typed address, and the address is kept',
        () async {
      await home.init();
      expect(home.cards.valueOrNull, isEmpty, reason: 'nothing found yet');
      backend.discovery.setManualProbeOutcome(_kOk);

      final String? problem = await home.addManualPeer('$_kHost:$_kPort');

      expect(problem, isNull,
          reason: 'success has no sentence: the device appearing IS the answer, '
              'and a "连接成功" dialog on top of it would be a second confirmation '
              'of something already visible');
      expect(backend.discovery.probeHostCalls, <String>['$_kHost:$_kPort'],
          reason: 'the controller must hand over exactly what the user typed — '
              'parsing is the discovery layer\'s job, not this one\'s');

      final PeerDevice card = home.cards.valueOrNull!.single;
      expect(card.fingerprint, _kFp);
      expect(card.isOnline, isTrue);
      expect(card.lastIp, _kHost,
          reason: 'the card is what the send path reads its destination from');
      expect(card.lastPort, _kPort);
      expect(card.canSend, isTrue);

      expect(
        backend.platform.presetSettings.manualPeers,
        <ManualPeerTarget>[const ManualPeerTarget(host: _kHost, port: _kPort)],
        reason: 'a typed address has to survive a restart, or the user re-types '
            'it every time the network stays broken',
      );
    });

    test('typing the same address twice does not duplicate it', () async {
      await home.init();
      backend.discovery.setManualProbeOutcome(_kOk);
      await home.addManualPeer('$_kHost:$_kPort');
      await home.addManualPeer('$_kHost:$_kPort');

      expect(backend.platform.presetSettings.manualPeers, hasLength(1),
          reason: '`ManualPeerTarget` equality is the dedupe rule — one address, '
              'however many times it is probed');
    });
  });

  group('2. each failure gets the sentence its class needs', () {
    test('the four classes map to the four shipped sentences, verbatim',
        () async {
      for (final MapEntry<ManualProbeFailure, String> expected
          in _kExpectedCopy.entries) {
        backend.discovery
            .setManualProbeOutcome(ManualProbeError(expected.key));

        final String? problem = await home.addManualPeer('192.168.1.23');

        expect(problem, expected.value,
            reason: 'failure class ${expected.key.name}');
      }
    });

    test('a bad input reaches the discovery layer and changes nothing else',
        () async {
      await home.init();
      backend.discovery
          .setManualProbeOutcome(const ManualProbeError(ManualProbeFailure.badInput));

      final String? problem = await home.addManualPeer('abc');

      expect(problem, _kExpectedCopy[ManualProbeFailure.badInput]);
      expect(backend.discovery.probeHostCalls, <String>['abc'],
          reason: 'the controller passes the text on; `badInput` is decided where '
              'the address parser lives, and it dials nothing there');
      expect(backend.platform.presetSettings.manualPeers, isEmpty,
          reason: 'a typo must never be remembered');
      expect(backend.discovery.manualTargets, isEmpty);
    });

    test('a failure leaves the device list exactly as it was', () async {
      await home.init();
      backend.discovery
          .setManualProbeOutcome(const ManualProbeError(ManualProbeFailure.unreachable));

      await home.addManualPeer(_kHost);

      expect(home.cards.valueOrNull, isEmpty);
    });
  });

  group('3. the capacity limit reaches the user', () {
    test('the ninth address is refused with a sentence that says what to do',
        () async {
      final List<ManualPeerTarget> full = <ManualPeerTarget>[
        for (int i = 1; i <= kMaxManualPeers; i += 1)
          ManualPeerTarget(host: '192.168.1.$i', port: _kPort),
      ];
      backend.dispose();
      backend = FakeBackend(
        settings: AppSettings(
          alias: 'Me',
          saveDirectory: '/received',
          manualPeers: full,
        ),
      );
      home.dispose();
      home = HomeController(
        repo: backend.repo,
        discovery: backend.discovery,
        transfer: backend.transfer,
        platform: backend.platform,
      );
      await home.init();
      // The adapter keeps the live set too, so a 9th probe would put a target in
      // it that the document refuses.
      for (final ManualPeerTarget target in full) {
        backend.discovery.addManualTarget(target.host, target.port);
      }
      expect(backend.discovery.manualTargetsFull, isTrue);
      backend.discovery.setManualProbeOutcome(
        const ManualProbeOk(
          fingerprint: _kFp,
          alias: 'Alice Phone',
          port: _kPort,
          host: '10.0.0.7',
        ),
      );

      final String? problem = await home.addManualPeer('10.0.0.7');

      expect(problem, isNotNull,
          reason: 'a silent refusal would leave the user retyping an address the '
              'app quietly refuses to keep');
      expect(problem, contains('8'),
          reason: 'the sentence must name the number, or "已满" is unexplainable');
      expect(problem, contains('删'),
          reason: 'and the way out of it');
      expect(backend.platform.presetSettings.manualPeers, hasLength(kMaxManualPeers),
          reason: 'the ninth address must not be stored');
      expect(
        backend.discovery.manualTargets,
        hasLength(kMaxManualPeers),
        reason: 'and it must not be dialled either: "not remembered" has to mean '
            '"not re-dialled", or the app works on something the user cannot see',
      );
    });
  });

  group('4. removing an address stops the dialling, not the device', () {
    test('the row goes, the heartbeat stops, the peer stays', () async {
      const ManualPeerTarget kept =
          ManualPeerTarget(host: '192.168.1.24', port: _kPort);
      const ManualPeerTarget removed =
          ManualPeerTarget(host: _kHost, port: _kPort);
      backend.dispose();
      backend = FakeBackend(
        settings: const AppSettings(
          alias: 'Me',
          saveDirectory: '/received',
          manualPeers: <ManualPeerTarget>[removed, kept],
        ),
        online: <DiscoveredPeer>[
          DiscoveredPeer(
            fingerprint: _kFp,
            alias: 'Alice Phone',
            kind: DeviceKind.mobile,
            address: _kHost,
            port: _kPort,
            isOnline: true,
            lastSeen: fixedEpoch,
          ),
        ],
      );
      home.dispose();
      home = HomeController(
        repo: backend.repo,
        discovery: backend.discovery,
        transfer: backend.transfer,
        platform: backend.platform,
      );
      await home.init();
      backend.discovery.addManualTarget(removed.host, removed.port);
      backend.discovery.addManualTarget(kept.host, kept.port);

      final String? problem = await home.removeManualPeer(removed);

      expect(problem, isNull);
      expect(backend.platform.presetSettings.manualPeers,
          <ManualPeerTarget>[kept]);
      expect(backend.discovery.manualTargets, <ManualPeerTarget>[kept],
          reason: 'the address stops being re-dialled — that is the instant '
              'effect the user asked for');
      expect(backend.discovery.removedManualTargets, <ManualPeerTarget>[removed]);
      expect(backend.discovery.online, hasLength(1),
          reason: 'the device is NOT deleted: it goes grey on the registry\'s own '
              'schedule, like any peer that stopped answering');
      expect(home.cards.valueOrNull, hasLength(1));
    });

    test('removing an address that is already gone is a no-op', () async {
      await home.init();

      final String? problem = await home
          .removeManualPeer(const ManualPeerTarget(host: '10.9.9.9', port: 1));

      expect(problem, isNull);
      expect(backend.platform.presetSettings.manualPeers, isEmpty);
    });
  });
}
