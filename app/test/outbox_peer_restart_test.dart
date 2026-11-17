/// The queue must move when the peer **restarts lanlink** (0.2.47).
///
/// ## The bug this pins
///
/// A peer that restarts lanlink comes back on a different TCP port. It keeps the
/// same fingerprint, keeps the same alias, and — crucially — **never goes
/// offline**: it is announcing every 5 s before the restart and every 5 s after
/// it. So the registry sees three shapes and only two of them were events:
///
/// * the alias is unchanged → no `PeerUpdated`;
/// * `isOnline` is `true` before and after → no `PeerCameOnline`, no
///   `PeerWentOffline`;
/// * the **port** changed → nothing at all, because `PeerRegistry.touch` only
///   compared aliases.
///
/// `OutboxPump` is woken by exactly those events (plus an app resume), so a
/// message queued for that peer stayed 排队中 for ever — the same "a state with
/// a writer and no reader" bug the pump was built to fix, narrowed to the one
/// recovery that emits no event.
///
/// ## Why this test is wired with the **real** registry and the **real** adapter
///
/// `FakePeerDiscovery` lets a test *say* "emit a `PeerUpdated`", which would make
/// this file a test of the fake. The defect lived in the seam between
/// `core.PeerRegistry`, `LanPeerDiscovery` and `OutboxPump`, so the fixture is
/// that seam: a real `core.PeerRegistry`, the real `LanPeerDiscovery` over it,
/// the real `TransferOrchestrator`, and a fake repository / transfer underneath
/// (the only two things that would otherwise touch a disk and a socket).
///
/// The peer enters the registry through `registrations` — the adapter's
/// documented second liveness source (an inbound `/register`), which is the
/// honest way to model "this peer just talked to us" without a NIC.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/outbox_pump.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/real/lan_peer_discovery.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/peer_discovery.dart';
import 'package:lanlink_core/lanlink_core.dart' as core;

import 'support/fakes.dart';

const String _kFingerprint = 'AAAA1111';
const String _kConversationId = 'c-restart';

/// Stands in for the real [core.MulticastDiscovery] so nothing opens a socket.
///
/// This file never announces and never listens: the peer arrives through
/// `registrations`. The layer exists only because `LanPeerDiscovery.start()` is
/// what installs the registry subscription.
class _NoopMulticast extends core.MulticastDiscovery {
  _NoopMulticast()
      : super(
          deviceInfo: core.DeviceInfo(
            alias: 'self',
            fingerprint: 'BB' * 32,
            port: 53317,
          ),
        );

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  void announce() {}
}

/// A backend with one conversation for [_kFingerprint] and nothing queued.
FakeBackend _backend() {
  final FakeBackend backend = FakeBackend(
    devices: <PeerDevice>[
      PeerDevice(
        fingerprint: _kFingerprint,
        alias: 'Alice Laptop',
        kind: DeviceKind.desktop,
        isOnline: false,
        lastPort: 53317,
        lastSeenAt: fixedEpoch,
      ),
    ],
  );
  backend.repo.addConversation(
    id: _kConversationId,
    deviceFingerprint: _kFingerprint,
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  return backend;
}

/// Seeds one `pending` (queued) file message — the row a send leaves behind
/// when the peer is not dialable at that moment.
void _seedQueuedFile(
  FakeBackend backend, {
  required String messageId,
  required String fileId,
}) {
  backend.repo.addMessage(
    id: messageId,
    conversationId: _kConversationId,
    direction: MessageDirection.outgoing,
    status: MessageStatus.pending,
    files: <FileAttachment>[
      FileAttachment(
        id: fileId,
        messageId: messageId,
        fileName: 'report.pdf',
        size: 2048,
        sha256: 'AB' * 32,
        localPath: '/src/report.pdf',
      ),
    ],
  );
}

MessageStatus _statusOf(FakeBackend backend, String messageId) => backend.repo
    .messagesByStatus(<MessageStatus>{...MessageStatus.values})
    .firstWhere((ChatMessage message) => message.id == messageId)
    .status;

/// Lets queued microtasks (stream listeners + the pump's own awaits) run.
Future<void> _settle() async {
  for (int i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// One real `LanPeerDiscovery` over a real `core.PeerRegistry`, plus the
/// `registrations` stream a test pushes peer contacts into.
class _Seam {
  _Seam(core.DeviceCertificate certificate) {
    discovery = LanPeerDiscovery(
      certificate: certificate,
      registry: registry,
      clock: FixedClock(fixedEpoch),
      selfPort: 53317,
      alias: 'self',
      registrations: _registrations.stream,
      onLog: logs.add,
      multicastBuilder: _NoopMulticast.new,
    );
    _sub = discovery.events.listen(events.add);
  }

  final core.PeerRegistry registry = core.PeerRegistry();
  final List<DiscoveryEvent> events = <DiscoveryEvent>[];
  final List<String> logs = <String>[];
  final StreamController<DiscoveredPeer> _registrations =
      StreamController<DiscoveredPeer>.broadcast();

  late final LanPeerDiscovery discovery;
  late final StreamSubscription<DiscoveryEvent> _sub;

  /// How the registry learns about a peer over TCP (`/register`, `/prepare`, …).
  ///
  /// Called twice for the same fingerprint with two different [port]s, this is
  /// byte-for-byte the "对端重启 lanlink" shape: same device, new listening port.
  void register({required int port}) {
    _registrations.add(
      DiscoveredPeer(
        fingerprint: _kFingerprint,
        alias: 'Alice Laptop',
        kind: DeviceKind.desktop,
        address: '192.168.1.10',
        port: port,
        isOnline: true,
        lastSeen: fixedEpoch,
      ),
    );
  }

  Future<void> dispose() async {
    await _sub.cancel();
    await discovery.dispose();
    await _registrations.close();
    await registry.dispose();
  }
}

void main() {
  // `OutboxPump.start()` registers a `WidgetsBindingObserver`.
  TestWidgetsFlutterBinding.ensureInitialized();

  late core.DeviceCertificate certificate;

  setUpAll(() {
    // One RSA keygen for the whole file (~a second, once).
    certificate =
        core.DeviceCertificate.generate(commonName: 'lanlink-restart-test');
  });

  test('1. a peer that restarts with a new port wakes the queue', () async {
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend, messageId: 'm-queued', fileId: 'f-queued');
    final _Seam seam = _Seam(certificate);
    addTearDown(seam.dispose);
    final OutboxPump pump = OutboxPump(
      repo: backend.repo,
      discovery: seam.discovery,
      orchestrator: TransferOrchestrator(
        repo: backend.repo,
        transfer: backend.transfer,
      ),
      // 0.2.52: the pump asks the platform port whether a queued message's
      // source is still on disk before it dials.
      platform: backend.platform,
      clock: backend.clock,
    );
    addTearDown(pump.dispose);

    await seam.discovery.start();
    pump.start();
    await _settle();
    expect(backend.transfer.prepareCalls, 0,
        reason: 'no peer is known yet — nothing may be dialled');

    // First contact at 53317: the ordinary "peer is here" case, which already
    // worked (it is a `PeerAppeared`).
    seam.register(port: 53317);
    await _settle();
    expect(backend.transfer.prepareCalls, 1,
        reason: 'sanity: the seam really does reach the pump');
    expect(_statusOf(backend, 'm-queued'), MessageStatus.done);

    // A second message is queued, and the peer restarts lanlink.
    _seedQueuedFile(backend, messageId: 'm-restart', fileId: 'f-restart');
    seam.events.clear();

    seam.register(port: 53318);
    await _settle();

    // Precondition of the judgement: this recovery is silent by construction.
    expect(seam.events.whereType<PeerWentOffline>(), isEmpty,
        reason: 'the peer never stopped announcing — no offline event exists '
            'to wake the pump with');
    expect(seam.events.whereType<PeerCameOnline>(), isEmpty,
        reason: 'and it never came back online either: `isOnline` was true the '
            'whole time');

    expect(backend.transfer.prepareCalls, 2,
        reason: 'the new port is the only observable change, so it must be '
            'announced — otherwise the queued message waits for a restart of '
            'this app (the exact bug the pump exists to fix)');
    expect(_statusOf(backend, 'm-restart'), MessageStatus.done);
    // The registry is the single source of "where do I dial": it must hold the
    // port the peer is on now, otherwise the wake-up would dial a dead one.
    expect(seam.registry.byFingerprint(_kFingerprint)?.info.port, 53318);
  });

  test('2. a peer that opens its receiver (port 0 → real) wakes the queue',
      () async {
    // The same defect in its most user-visible form: the peer was online with
    // no inbound server (`port == 0`, so the app must not dial it), then it
    // opened 接收 and started advertising a port.
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend, messageId: 'm-queued', fileId: 'f-queued');
    final _Seam seam = _Seam(certificate);
    addTearDown(seam.dispose);
    final OutboxPump pump = OutboxPump(
      repo: backend.repo,
      discovery: seam.discovery,
      orchestrator: TransferOrchestrator(
        repo: backend.repo,
        transfer: backend.transfer,
      ),
      // 0.2.52: the pump asks the platform port whether a queued message's
      // source is still on disk before it dials.
      platform: backend.platform,
      clock: backend.clock,
    );
    addTearDown(pump.dispose);

    await seam.discovery.start();
    pump.start();
    await _settle();

    seam.register(port: 0);
    await _settle();
    expect(backend.transfer.prepareCalls, 0,
        reason: 'port 0 means "no inbound server": dialling it would fail '
            'instantly (E6)');
    expect(_statusOf(backend, 'm-queued'), MessageStatus.pending);

    seam.events.clear();
    seam.register(port: 53317);
    await _settle();

    expect(seam.events.whereType<PeerWentOffline>(), isEmpty);
    expect(backend.transfer.prepareCalls, 1,
        reason: 'not dialable → dialable must wake the queue');
    expect(_statusOf(backend, 'm-queued'), MessageStatus.done);
  });
}
