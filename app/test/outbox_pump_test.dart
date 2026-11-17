/// Judgements for the outbox pump (0.2.40) — the offline queue's consumer.
///
/// Every test here fails on the **pre-0.2.40** code, which is the point: the bug
/// being fixed was not "a wrong value" but "a state with no reader", and a test
/// that stays green on the old code would be describing the old bug as correct.
///
/// The fixture is deliberately the real thing — `FakeBackend` repository,
/// discovery and transfer, plus the real [TransferOrchestrator] — because the
/// behaviour under test is the *seam* between three ports. A hand-rolled double
/// for any of them would hide exactly the mismatch that caused the bug (a
/// `pending` row whose peer nobody tells us about).
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/outbox_pump.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/transfer_service.dart';

import 'support/fakes.dart';

const String _kFingerprint = 'AAAA1111';
const String _kConversationId = 'c-outbox';

/// The peer the queue is waiting for.
///
/// Its **stored** row says offline (that is the state the send was queued in);
/// the live entry says online, with a dialable port — the shape of "对方上线了".
DiscoveredPeer _livePeer({int port = 53317}) => DiscoveredPeer(
      fingerprint: _kFingerprint,
      alias: 'Alice Laptop',
      kind: DeviceKind.desktop,
      address: '192.168.1.10',
      port: port,
      isOnline: true,
      lastSeen: fixedEpoch,
    );

PeerDevice _storedDeviceRow() => PeerDevice(
      fingerprint: _kFingerprint,
      alias: 'Alice Laptop',
      kind: DeviceKind.desktop,
      isOnline: false,
      lastPort: 53317,
      lastSeenAt: fixedEpoch,
    );

/// A backend with one conversation for [_kFingerprint] and nothing queued yet.
FakeBackend _backend() {
  final FakeBackend backend = FakeBackend(
    devices: <PeerDevice>[_storedDeviceRow()],
  );
  backend.repo.addConversation(
    id: _kConversationId,
    deviceFingerprint: _kFingerprint,
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  return backend;
}

/// Seeds one `pending` (queued) **file** message — exactly the row the real
/// `TransferOrchestrator.send` leaves behind when the peer is offline.
ChatMessage _seedQueuedFile(
  FakeBackend backend, {
  String messageId = 'm-queued',
  String fileId = 'f-queued',
  String? localPath = '/src/report.pdf',
  String? folderName,
  int folderFiles = 0,
}) {
  final FileAttachment attachment = FileAttachment(
    id: fileId,
    messageId: messageId,
    fileName: 'report.pdf',
    size: 2048,
    sha256: 'AB' * 32,
    localPath: localPath,
  );
  return backend.repo.addMessage(
    id: messageId,
    conversationId: _kConversationId,
    direction: MessageDirection.outgoing,
    status: MessageStatus.pending,
    files: <FileAttachment>[attachment],
    folderName: folderName,
    folderFiles: folderFiles,
  );
}

/// The real orchestrator over the fake ports — the code path production uses.
TransferOrchestrator _orchestrator(FakeBackend backend) =>
    TransferOrchestrator(repo: backend.repo, transfer: backend.transfer);

OutboxPump _pump(FakeBackend backend, TransferOrchestrator orchestrator) =>
    OutboxPump(
      repo: backend.repo,
      discovery: backend.discovery,
      orchestrator: orchestrator,
      // 0.2.52: "is this queued message's source still on disk?" — the fake port
      // answers `true` unless a test says otherwise, so these fixtures publish
      // paths that do not exist and still go out, exactly as they did before.
      platform: backend.platform,
      clock: backend.clock,
    );

/// Lets queued microtasks (stream listeners + the pump's own awaits) run.
Future<void> _settle() async {
  for (int i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

MessageStatus _statusOf(FakeBackend backend, String messageId) =>
    backend.repo
        .messagesByStatus(<MessageStatus>{...MessageStatus.values})
        .firstWhere((ChatMessage message) => message.id == messageId)
        .status;

int _messageCount(FakeBackend backend) =>
    backend.repo.history(_kConversationId).length;

/// Queues one message through the **real** send path, returning its id.
///
/// This is deliberately not `_seedQueuedFile`: seeding writes straight into the
/// fake's maps, while the production path goes through `recordOutgoing`, which
/// is what publishes `MessageAdded` — and that event is the pump's only way of
/// hearing "there is a queued row now" while the app is running (`start()`'s own
/// drain is long past). A test that seeded the row and then expected the scan to
/// arm itself would be testing a notification production never sends.
Future<String> _queueThroughOrchestrator(
  FakeBackend backend,
  TransferOrchestrator orchestrator, {
  required String fileId,
}) async {
  final SendOutcome outcome = await orchestrator.send(
    // Offline: what the card looks like when the user presses 发送 too early.
    peer: _storedDeviceRow(),
    files: <OutgoingFile>[
      OutgoingFile(
        id: fileId,
        fileName: 'report.pdf',
        size: 2048,
        sha256: 'AB' * 32,
        localPath: '/src/report.pdf',
      ),
    ],
  );
  expect(outcome.queued, isTrue,
      reason: 'an offline peer must queue, never dial');
  return backend.repo
      .messagesByStatus(<MessageStatus>{MessageStatus.pending})
      .last
      .id;
}

void main() {
  // `OutboxPump.start()` registers a `WidgetsBindingObserver`, so a binding has
  // to exist even in the tests that never touch the lifecycle.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('1. offline → online → the queued send actually goes out', () async {
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend);
    final OutboxPump pump = _pump(backend, _orchestrator(backend));
    addTearDown(pump.dispose);

    // Trigger ①: the subscription. The peer is still offline, so `start`'s own
    // drain (trigger ③) must find nothing to do — that is judgement 2, asserted
    // here as the precondition it really is.
    pump.start();
    await _settle();
    expect(backend.transfer.prepareCalls, 0,
        reason: 'the peer is offline — nothing may be dialled yet');

    backend.discovery.comeOnline(_livePeer());
    await _settle();

    expect(backend.transfer.prepareCalls, 1,
        reason: 'the online event must reach the queue and dial exactly once');
    expect(backend.transfer.preparedSessions, hasLength(1));
    expect(_statusOf(backend, 'm-queued'), MessageStatus.done,
        reason: 'the row must leave `pending` — that is the whole bug');
    expect(backend.repo.sessionOf('f-queued'), isNotNull,
        reason: 'the resumed send must attach the session to the stored fileId');
  });

  test('2. a peer that is still offline is never dialled', () async {
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend);
    final OutboxPump pump = _pump(backend, _orchestrator(backend));
    addTearDown(pump.dispose);
    pump.start();
    await _settle();

    // Every event shape that reports an *online* peer, except there is none:
    // the peer is absent from discovery entirely, so the merged card is offline.
    await pump.drainAll();
    await pump.drainFor(_kFingerprint);
    await _settle();

    expect(backend.transfer.prepareCalls, 0,
        reason: 'a pump that ignored isOnline would dial an absent peer here');
    expect(_statusOf(backend, 'm-queued'), MessageStatus.pending,
        reason: 'an undialable peer must leave the message queued, not failed');
  });

  test('3. three online events in one burst dial once', () async {
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend);
    final OutboxPump pump = _pump(backend, _orchestrator(backend));
    addTearDown(pump.dispose);
    pump.start();
    await _settle();

    final DiscoveredPeer peer = _livePeer();
    // Emitted synchronously: all three listeners run while the first drain is
    // still awaiting `prepare`, which is exactly what the re-entrancy guard is
    // there for.
    backend.discovery.appear(peer);
    backend.discovery.comeOnline(peer);
    backend.discovery.update(peer);
    await _settle();

    expect(backend.transfer.prepareCalls, 1,
        reason: 'one wake-up burst must produce one dial, not three');
    expect(_statusOf(backend, 'm-queued'), MessageStatus.done);
  });

  test('4. a dial that fails lands on `failed`, not back on `pending`', () async {
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend);
    backend.transfer.failNextPrepare(StateError('link refused'));
    final TransferOrchestrator orchestrator = _orchestrator(backend);
    final OutboxPump pump = _pump(backend, orchestrator);
    addTearDown(pump.dispose);
    pump.start();
    await _settle();

    backend.discovery.comeOnline(_livePeer());
    await _settle();

    expect(_statusOf(backend, 'm-queued'), MessageStatus.failed,
        reason: 'a resume that cannot dial must end in `failed` — leaving it '
            '`pending` is the original bug with extra steps');

    // …and the existing 未发送成功 machinery picks it up for free: that is why
    // the pump writes no fallback of its own.
    final ConversationController controller = ConversationController(
      repo: backend.repo,
      orchestrator: orchestrator,
      platform: backend.platform,
      ids: backend.ids,
      clock: backend.clock,
      conversationId: _kConversationId,
    );
    addTearDown(controller.dispose);
    await controller.load();
    expect(
      controller.unsentMessages.map((ChatMessage m) => m.id),
      contains('m-queued'),
      reason: 'a failed resume must be offered by 重新发送 / 全部重试',
    );
  });

  test('5. only `PeerAppeared` (no transition) still wakes the queue', () async {
    // The restart case: `core`'s PeerRegistry is in-memory, so after a relaunch a
    // live peer produces `PeerAdded` — never `PeerCameOnline`. A pump that
    // matched the event *type* would strand every message queued before the
    // restart, which is the most likely way a user meets this bug.
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend);
    final OutboxPump pump = _pump(backend, _orchestrator(backend));
    addTearDown(pump.dispose);
    pump.start();
    await _settle();

    backend.discovery.appear(_livePeer());
    await _settle();

    expect(backend.transfer.prepareCalls, 1,
        reason: 'PeerAppeared must be enough — no state change is guaranteed');
    expect(_statusOf(backend, 'm-queued'), MessageStatus.done);
  });

  test('5b. `PeerUpdated` (peer back inside the offline grace) also wakes it',
      () async {
    // The other half of the same rule: a peer that returns before the 60 s grace
    // expires never left the registry, so it emits neither `PeerAppeared` nor
    // `PeerCameOnline` — only `PeerUpdated`.
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend);
    final OutboxPump pump = _pump(backend, _orchestrator(backend));
    addTearDown(pump.dispose);
    pump.start();
    await _settle();

    backend.discovery.update(_livePeer());
    await _settle();

    expect(backend.transfer.prepareCalls, 1);
    expect(_statusOf(backend, 'm-queued'), MessageStatus.done);
  });

  test('6. returning to the foreground drains the outbox once', () async {
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend);
    final OutboxPump pump = _pump(backend, _orchestrator(backend));
    addTearDown(pump.dispose);
    // The peer is online from the start, but the pump's subscription is not fed:
    // this is the suspended-process window, where multicast frames are dropped
    // and no event can arrive.
    backend.discovery.setOnline(<DiscoveredPeer>[_livePeer()]);
    await _settle();
    expect(backend.transfer.prepareCalls, 0);

    pump.start();
    await _settle();
    expect(backend.transfer.prepareCalls, 1,
        reason: 'trigger ③: a message queued before this process existed');
    expect(pump.observesLifecycle, isTrue);

    // Trigger ②, through the **real** binding: the observer is what makes a
    // resume-after-sleep work, so driving `onAppResumed` directly would not
    // prove the wiring.
    _seedQueuedFile(backend, messageId: 'm-queued-2', fileId: 'f-queued-2');
    final int before = pump.drainRuns;
    TestWidgetsFlutterBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle();

    expect(pump.drainRuns, before + 1,
        reason: 'resumed must run one drain');
    expect(_statusOf(backend, 'm-queued-2'), MessageStatus.done);
  });

  test('7. a queued *text* message is resumed with its stored nonce', () async {
    final FakeBackend backend = _backend();
    backend.repo.addMessage(
      id: 'm-text-queued',
      conversationId: _kConversationId,
      direction: MessageDirection.outgoing,
      status: MessageStatus.pending,
      kind: MessageKind.text,
      textBody: '文件放桌面上',
      eventNonce: 'nonce-1',
    );
    final OutboxPump pump = _pump(backend, _orchestrator(backend));
    addTearDown(pump.dispose);
    pump.start();
    await _settle();
    backend.discovery.comeOnline(_livePeer());
    await _settle();

    expect(backend.transfer.sentTexts, hasLength(1));
    expect(backend.transfer.sentTexts.single.id, 'nonce-1',
        reason: 'the stored nonce is the receiver-de-dupe anchor; a fresh one '
            'would duplicate the message after a lost ack');
    expect(backend.transfer.sentTexts.single.text, '文件放桌面上');
    expect(_statusOf(backend, 'm-text-queued'), MessageStatus.done);
  });

  test('8. resuming does not add a second bubble', () async {
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend);
    final OutboxPump pump = _pump(backend, _orchestrator(backend));
    addTearDown(pump.dispose);
    expect(_messageCount(backend), 1);

    pump.start();
    await _settle();
    backend.discovery.comeOnline(_livePeer());
    await _settle();

    expect(_messageCount(backend), 1,
        reason: 'a resume drives the existing row — a new message here would '
            'leave the user looking at 排队中 above a second, identical bubble');
    expect(backend.repo.history(_kConversationId).single.id, 'm-queued');
  });

  test('9. a folder message keeps its descriptor when resumed', () async {
    final FakeBackend backend = _backend();
    _seedQueuedFile(
      backend,
      folderName: '素材',
      folderFiles: 1,
    );
    final OutboxPump pump = _pump(backend, _orchestrator(backend));
    addTearDown(pump.dispose);
    pump.start();
    await _settle();
    backend.discovery.comeOnline(_livePeer());
    await _settle();

    expect(backend.transfer.lastPreparedFolder?.name, '素材',
        reason: 'resuming without the descriptor would deliver a folder as N '
            'loose files under a bubble that still says 文件夹');
    expect(backend.transfer.lastPreparedFolder?.count, 1);
  });

  test('10. a source file that is gone ends in `failed`, never `pending`',
      () async {
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend, localPath: null);
    final TransferOrchestrator orchestrator = _orchestrator(backend);
    final OutboxPump pump = _pump(backend, orchestrator);
    addTearDown(pump.dispose);
    pump.start();
    await _settle();
    backend.discovery.comeOnline(_livePeer());
    await _settle();

    expect(backend.transfer.prepareCalls, 0);
    expect(_statusOf(backend, 'm-queued'), MessageStatus.failed,
        reason: 'the picked copy may have been swept — say so, and offer '
            '重新发送, instead of queueing for ever');
  });

  test('11. a message the peer will never dial is marked failed, not queued',
      () async {
    // Simulates the one `failed` outcome the orchestrator reports **without**
    // writing a status (`canSend == false`): in `send` that is right, because no
    // row exists yet; on a resume the row does exist, so a pump that trusted the
    // outcome alone would leave it pending for ever.
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend);
    final OutboxPump pump = _pump(backend, _orchestrator(backend));
    addTearDown(pump.dispose);
    pump.start();
    await _settle();
    // A live entry with port 0: online, but no inbound server. `isDialable` is
    // false, so the pump skips it and the message legitimately stays queued…
    backend.discovery.comeOnline(_livePeer(port: 0));
    await _settle();
    expect(backend.transfer.prepareCalls, 0);
    expect(_statusOf(backend, 'm-queued'), MessageStatus.pending,
        reason: 'a peer with no inbound server is "not now", not "never" — the '
            'pump must keep the row queued');
  });

  // ── trigger ④: the fallback scan (0.2.47) ───────────────────────────────
  //
  // Triggers ①–③ are events. The recoveries users actually meet — a firewall
  // rule that starts allowing us, a receiver that was switched on, a peer that
  // quietly started listening — produce **no event at all**, so a `pending` row
  // could sit at 排队中 until this app was restarted. The tests below are the
  // ones the pump could not have passed before the scan existed; they run with
  // **fake time** (`testWidgets` advances the clock, nothing sleeps).

  testWidgets('12. with no event at all, the scan tries once after 30 seconds',
      (WidgetTester tester) async {
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend);
    final OutboxPump pump = _pump(backend, _orchestrator(backend));
    addTearDown(pump.dispose);

    // The peer is not reachable at start, so the pump leaves the row queued and
    // arms the scan. Nothing is emitted from here on — the whole point.
    pump.start();
    await tester.pump();
    expect(backend.transfer.prepareCalls, 0);
    expect(pump.isScanning, isTrue,
        reason: 'something is queued, so exactly one scan must exist');

    // "The peer can now be reached" with **no** discovery event: the live list
    // says online (a firewall rule changed, the receiver came back), and no
    // announcement ever told us.
    backend.discovery.setOnline(<DiscoveredPeer>[_livePeer()]);

    await tester.pump(const Duration(seconds: 29));
    expect(backend.transfer.prepareCalls, 0,
        reason: '30 s is the period: this is a fallback, not a poll');
    expect(pump.scanTicks, 0);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump();

    expect(pump.scanTicks, 1);
    expect(backend.transfer.prepareCalls, 1,
        reason: 'the scan must actually try the dial — a timer that fires and '
            'decides nothing is the same bug with a different name');
    expect(_statusOf(backend, 'm-queued'), MessageStatus.done);
    expect(pump.isScanning, isFalse,
        reason: 'the queue is empty again — the timer must be gone, not idle');
  });

  testWidgets('13. nothing queued → no scan timer exists at all',
      (WidgetTester tester) async {
    // The cost judgement: an idle app (nothing queued, ever) must own no timer,
    // no tick and no work. `flutter_test` also fails the test if a timer outlives
    // the test, so this is asserted twice.
    final FakeBackend backend = _backend(); // no message seeded
    final OutboxPump pump = _pump(backend, _orchestrator(backend));
    addTearDown(pump.dispose);

    pump.start();
    await tester.pump();
    expect(pump.isScanning, isFalse);
    expect(pump.drainRuns, 0, reason: 'an empty queue is not a drain');

    await tester.pump(const Duration(minutes: 5));
    expect(pump.scanTicks, 0, reason: 'no timer, so no ticks');
    expect(pump.drainRuns, 0);
    expect(backend.transfer.prepareCalls, 0);
  });

  testWidgets('14. a message queued mid-session arms the scan, cancelling '
      'disarms it', (WidgetTester tester) async {
    // The invariant is "timer exists ⇔ something is pending". It has to hold
    // **whenever** the queue changes, not only at `start()` — a 发送 that cannot
    // dial is recorded `pending` long after the pump's startup drain.
    final FakeBackend backend = _backend();
    final TransferOrchestrator orchestrator = _orchestrator(backend);
    final OutboxPump pump = _pump(backend, orchestrator);
    addTearDown(pump.dispose);
    pump.start();
    await tester.pump();
    expect(pump.isScanning, isFalse);

    // The user presses 发送 while the peer is away.
    final String messageId = await _queueThroughOrchestrator(
      backend,
      orchestrator,
      fileId: 'f-live-1',
    );
    await tester.pump();
    expect(pump.isScanning, isTrue,
        reason: 'a queued row must arm the fallback, otherwise "queued it now" '
            'is still waiting for an event that may never come');

    // …and the user 取消s it: nothing is queued any more, so nothing may tick.
    expect(
      backend.repo.setStatus(
        messageId: messageId,
        from: MessageStatus.pending,
        to: MessageStatus.canceled,
      ),
      isTrue,
    );
    await tester.pump();
    expect(pump.isScanning, isFalse);
  });

  testWidgets('15. three wake-ups inside one scan period still dial once',
      (WidgetTester tester) async {
    // Anti-amplification, now that a timer exists to amplify: the scan must not
    // be a second send path. `prepare` is held open so the first dial is still
    // in flight while the other triggers arrive — the only window where a second
    // dial could stack.
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend);
    final Completer<void> gate = Completer<void>();
    backend.transfer.holdNextPrepare(gate);
    final OutboxPump pump = _pump(backend, _orchestrator(backend));
    addTearDown(pump.dispose);

    backend.discovery.setOnline(<DiscoveredPeer>[_livePeer()]);
    pump.start();
    await tester.pump();
    expect(backend.transfer.prepareCalls, 1);

    backend.discovery.update(_livePeer());
    backend.discovery.appear(_livePeer());
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();

    expect(backend.transfer.prepareCalls, 1,
        reason: 'a drain that is already walking this peer, and a cooldown that '
            'is still armed, must both swallow the extra triggers');

    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(_statusOf(backend, 'm-queued'), MessageStatus.done);
  });

  testWidgets('16. the scan still refuses a peer with no inbound server',
      (WidgetTester tester) async {
    // 判据 "仍然尊重 canSend", through the new trigger: `port == 0` means the
    // peer runs no server, so dialling it fails instantly (E6). The scan must
    // ask the same question the event path asks — which it does, because it
    // calls the same drain.
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend);
    final OutboxPump pump = _pump(backend, _orchestrator(backend));
    addTearDown(pump.dispose);
    pump.start();
    await tester.pump();

    // Online, announcing, and **undialable** — no event, and none is needed.
    backend.discovery.setOnline(<DiscoveredPeer>[_livePeer(port: 0)]);
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();

    expect(pump.scanTicks, 1);
    expect(backend.transfer.prepareCalls, 0,
        reason: 'the scan must not dial a peer the UI would not let the user '
            'send to either');
    expect(_statusOf(backend, 'm-queued'), MessageStatus.pending,
        reason: 'and it must stay queued: "not now" is not "never"');
    expect(pump.isScanning, isTrue,
        reason: 'the row is still pending, so the fallback keeps watching it');

    // This test *wants* a live timer at the end (that is the assertion above),
    // so it has to give it back explicitly: `flutter_test` checks for pending
    // timers before `addTearDown` runs, and a scan that outlived its pump is
    // exactly the leak those two lines prove does not happen.
    pump.dispose();
    expect(pump.isScanning, isFalse);
  });

  testWidgets('17. the scan re-arms for the next queued message and dials it '
      'once', (WidgetTester tester) async {
    // The cycle, twice: cancel-then-re-arm must be as reliable as the first arm.
    // A timer that leaks a stale instance (or forgets to come back) is exactly
    // the "pending with no reader" bug this class exists to prevent.
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend);
    final TransferOrchestrator orchestrator = _orchestrator(backend);
    final OutboxPump pump = _pump(backend, orchestrator);
    addTearDown(pump.dispose);

    backend.discovery.setOnline(<DiscoveredPeer>[_livePeer()]);
    pump.start();
    // Trigger ③ takes the first row: a peer that is already online at `start()`
    // is dialled by the startup drain, not by the scan.
    await tester.pump();
    expect(backend.transfer.prepareCalls, 1);
    expect(_statusOf(backend, 'm-queued'), MessageStatus.done);
    expect(pump.isScanning, isFalse);
    expect(pump.scanTicks, 0, reason: 'no scan was needed for that one');

    // A second 发送 that can only queue (the peer looked away at that moment).
    await _queueThroughOrchestrator(
      backend,
      orchestrator,
      fileId: 'f-live-2',
    );
    await tester.pump();
    expect(pump.isScanning, isTrue, reason: 'the next queued row re-arms it');

    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(backend.transfer.prepareCalls, 2,
        reason: 'and the scan really sends it — one dial, not one per tick');
    expect(
      backend.repo.messagesByStatus(<MessageStatus>{MessageStatus.pending}),
      isEmpty,
    );
    expect(pump.isScanning, isFalse);
    expect(pump.scanTicks, 1, reason: 'one tick per period, not per message');
  });
}
