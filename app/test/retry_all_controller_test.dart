/// 0.2.24 — `ConversationController.resendUnsent`: what one 全部重试 run does.
///
/// The batch is a **controller** concern, not a widget one: it owns the serial
/// order, the "source file is gone" judgement (the same `canResend` the bubble's
/// own 重新发送 uses) and the three counters the UI turns into one sentence.
/// These tests pin exactly those four things, and nothing about pixels — the
/// visible half lives in `test/widget/retry_all_test.dart`.
///
/// Everything is driven by [FakeBackend] plus a real [TransferOrchestrator] over
/// the fake [TransferService], so a "send" here goes through the same status
/// machine a device does (`pending → awaitingConfirm → transferring → done`).
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/transfer_service.dart';
import 'package:lanlink_app/domain/unsent_dismissal_store.dart';

const String _fingerprint = 'RR24';
const String _conversationId = 'c-retry-all';

PeerDevice _peer() => const PeerDevice(
      fingerprint: _fingerprint,
      alias: 'Rita',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

DiscoveredPeer _live() => DiscoveredPeer(
      fingerprint: _fingerprint,
      alias: 'Rita',
      kind: DeviceKind.desktop,
      address: '192.168.1.24',
      port: 53317,
      isOnline: true,
      lastSeen: fixedEpoch,
    );

FakeBackend _backend() {
  final FakeBackend backend = FakeBackend(
    devices: <PeerDevice>[_peer()],
    online: <DiscoveredPeer>[_live()],
  );
  backend.repo.addConversation(
    id: _conversationId,
    deviceFingerprint: _fingerprint,
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  return backend;
}

/// Seeds one outgoing **file** message in [status] whose source is [path].
void _seed(
  FakeBackend backend, {
  required String messageId,
  required MessageStatus status,
  String path = '/src/one.bin',
}) {
  backend.repo.addMessage(
    id: messageId,
    conversationId: _conversationId,
    direction: MessageDirection.outgoing,
    status: status,
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
    files: <FileAttachment>[
      FileAttachment(
        id: 'f-$messageId',
        messageId: messageId,
        fileName: 'one.bin',
        size: 5,
        sha256: '00',
        localPath: path,
      ),
    ],
  );
}

void main() {
  late FakeBackend backend;
  late TransferOrchestrator orchestrator;
  late ConversationController controller;

  setUp(() {
    backend = _backend();
    orchestrator = TransferOrchestrator(
      repo: backend.repo,
      transfer: backend.transfer,
    );
    controller = ConversationController(
      repo: backend.repo,
      orchestrator: orchestrator,
      platform: backend.platform,
      ids: backend.ids,
      clock: backend.clock,
      conversationId: _conversationId,
      // 0.2.30: dismissals moved to a **process-wide** store (that is the fix for
      // "退出会话再进来 忽略就没了"). A fresh instance per test keeps these cases
      // isolated from each other — they reuse the same conversation id and the
      // same message ids on purpose, so a shared store would let one test's 忽略
      // silently pre-ignore the next test's seed (a false green).
      dismissals: UnsentDismissalStore(),
    );
  });

  tearDown(() {
    controller.dispose();
    orchestrator.dispose();
    backend.dispose();
  });

  List<ChatMessage> history() => backend.repo.history(_conversationId);

  test('unsentMessages counts failed AND canceled file messages, nothing else',
      () async {
    _seed(backend, messageId: 'm-failed-1', status: MessageStatus.failed);
    _seed(backend, messageId: 'm-failed-2', status: MessageStatus.failed);
    _seed(
      backend,
      messageId: 'm-canceled',
      status: MessageStatus.canceled,
      path: '/src/two.bin',
    );
    _seed(backend, messageId: 'm-done', status: MessageStatus.done);
    _seed(backend, messageId: 'm-pending', status: MessageStatus.pending);
    // A failed *text* message: there is no re-send path for text, so it must
    // never inflate the count the button promises to retry.
    backend.repo.addMessage(
      id: 'm-text',
      conversationId: _conversationId,
      direction: MessageDirection.outgoing,
      status: MessageStatus.failed,
      kind: MessageKind.text,
      textBody: 'hi',
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
    );
    await controller.load();

    expect(
      controller.unsentMessages.map((ChatMessage m) => m.id),
      // Order is not the point here (all these rows share one `createdAt`, so
      // the timeline tie-breaks by id) — the *membership* is.
      unorderedEquals(<String>['m-failed-1', 'm-failed-2', 'm-canceled']),
      reason: 'failed + canceled file messages, nothing else — a done, a queued '
          'and a text message are not "没有发送成功" for this button',
    );
  });

  test('3 failed → 3 new messages, the old rows untouched, and the list empties',
      () async {
    _seed(backend, messageId: 'm-1', status: MessageStatus.failed);
    _seed(backend, messageId: 'm-2', status: MessageStatus.failed);
    _seed(backend, messageId: 'm-3', status: MessageStatus.failed);
    await controller.load();

    final BulkResendResult result =
        await controller.resendUnsent(peer: _peer());

    expect(result.refused, isFalse);
    expect(result.sent, 3);
    expect(result.skipped, 0);
    expect(result.failed, 0);
    expect(result.notice, '已重新发送 3 条');

    final List<ChatMessage> after = history();
    expect(after.length, 6, reason: 'each re-send is a NEW message (Q3)');
    expect(
      after.where((ChatMessage m) => m.status == MessageStatus.failed).length,
      3,
      reason: 'the three original rows must keep their `failed` status — '
          're-sending never rewrites history',
    );
    expect(
      after.where((ChatMessage m) => m.status == MessageStatus.done).length,
      3,
      reason: 'the fake link delivers, so the three new messages are done',
    );
    expect(
      controller.unsentMessages,
      isEmpty,
      reason: 'the banner must stop counting what the run just re-sent',
    );
  });

  test('the run is SERIAL: message 2 is not even probed until message 1 is over',
      () async {
    _seed(backend, messageId: 'm-1', status: MessageStatus.failed);
    _seed(
      backend,
      messageId: 'm-2',
      status: MessageStatus.failed,
      path: '/src/two.bin',
    );
    _seed(
      backend,
      messageId: 'm-3',
      status: MessageStatus.failed,
      path: '/src/three.bin',
    );
    await controller.load();

    // Park the FIRST upload. A concurrent implementation would already be
    // preparing the second and third session; a serial one has exactly one.
    final Completer<void> hold = Completer<void>();
    backend.transfer.holdNextUpload(hold);

    final Future<BulkResendResult> running =
        controller.resendUnsent(peer: _peer());
    // Let every microtask the loop can reach run.
    await pumpEventQueue();

    expect(
      backend.transfer.preparedSessions.length,
      1,
      reason: 'a serial run has one upload in flight, never three at once — a '
          'concurrent burst on a just-recovered link stalls the first one',
    );
    expect(
      history().length,
      4,
      reason: 'only the first re-send exists so far',
    );
    expect(
      controller.bulkResending,
      isTrue,
      reason: 'the UI disables 全部重试 off this flag',
    );

    hold.complete();
    final BulkResendResult result = await running;

    expect(result.sent, 3);
    expect(history().length, 6);
    expect(controller.bulkResending, isFalse);
  });

  test('a gone source file is skipped and counted, not sent and not failed',
      () async {
    _seed(backend, messageId: 'm-here', status: MessageStatus.failed);
    _seed(
      backend,
      messageId: 'm-gone',
      status: MessageStatus.failed,
      path: '/src/gone.bin',
    );
    backend.platform.setExists('/src/gone.bin', false);
    await controller.load();

    final BulkResendResult result =
        await controller.resendUnsent(peer: _peer());

    expect(result.sent, 1);
    expect(result.skipped, 1);
    expect(result.failed, 0);
    expect(result.notice, contains('跳过 1 条'));
    expect(history().length, 3, reason: 'the skipped message sent nothing');
    expect(
      backend.transfer.preparedSessions.length,
      1,
      reason: 'a skip never dials the peer',
    );
  });

  test('a second call while a run is live is refused — the count cannot double',
      () async {
    _seed(backend, messageId: 'm-1', status: MessageStatus.failed);
    _seed(
      backend,
      messageId: 'm-2',
      status: MessageStatus.failed,
      path: '/src/two.bin',
    );
    await controller.load();

    final Completer<void> hold = Completer<void>();
    backend.transfer.holdNextUpload(hold);

    final Future<BulkResendResult> first =
        controller.resendUnsent(peer: _peer());
    await pumpEventQueue();
    final BulkResendResult second =
        await controller.resendUnsent(peer: _peer());

    expect(
      second.refused,
      isTrue,
      reason: 'the double-tap guard has to hold in the controller too — the '
          'disabled button only lands one frame later',
    );
    expect(second.notice, isNotEmpty);

    hold.complete();
    final BulkResendResult result = await first;
    expect(result.sent, 2);
    expect(
      history().length,
      4,
      reason: '2 old + 2 new. A 6 here would be the doubled-message defect',
    );
  });

  test('a retry that still fails is counted, stays outstanding and does not '
      'abort the rest of the run', () async {
    _seed(backend, messageId: 'm-1', status: MessageStatus.failed);
    _seed(
      backend,
      messageId: 'm-2',
      status: MessageStatus.failed,
      path: '/src/two.bin',
    );
    await controller.load();

    // The first re-send dies in `prepare`; the second must still go out.
    backend.transfer.failNextPrepare(StateError('link reset'));
    final BulkResendResult result =
        await controller.resendUnsent(peer: _peer());

    expect(result.sent, 1);
    expect(result.failed, 1);
    expect(result.notice, contains('仍失败'));
    expect(
      history().where((ChatMessage m) => m.status == MessageStatus.done).length,
      1,
      reason: 'one send died, one delivered — the loop kept going',
    );
    expect(
      controller.unsentMessages.length,
      2,
      reason: 'the failed one is still outstanding for a further attempt (and '
          'its own new row is failed too, so it is offered as well) — two, not '
          'zero: a failed retry must not be silently dropped from the count',
    );
  });

  test('hasActiveSend ignores `pending` (a queued message is not a live send)',
      () async {
    _seed(backend, messageId: 'm-pending', status: MessageStatus.pending);
    await controller.load();
    expect(controller.hasActiveSend, isFalse);

    _seed(backend, messageId: 'm-live', status: MessageStatus.transferring);
    await controller.load();
    expect(controller.hasActiveSend, isTrue);
  });

  // ── 0.2.26: dismissing the batch ───────────────────────────────────────

  test('dismissUnsent() drops the batch from the count and touches no message',
      () async {
    _seed(backend, messageId: 'm-1', status: MessageStatus.failed);
    _seed(
      backend,
      messageId: 'm-2',
      status: MessageStatus.failed,
      path: '/src/two.bin',
    );
    _seed(
      backend,
      messageId: 'm-3',
      status: MessageStatus.failed,
      path: '/src/three.bin',
    );
    await controller.load();
    expect(controller.unsentMessages.length, 3);

    expect(controller.dismissUnsent(), 3);

    expect(
      controller.unsentMessages,
      isEmpty,
      reason: 'the dismissed batch is neither counted nor re-sendable',
    );
    // Re-reading the history (what a thread refocus does) must not resurrect the
    // batch: the dismissal lives in the process-wide store, never in the message
    // rows. (0.2.30 — it used to live on *this object*, which is precisely why
    // "退出会话再进来" brought the banner back; that path needs a SECOND
    // controller and is covered in `unsent_dismissal_store_test.dart` and
    // `test/widget/retry_all_reenter_test.dart`.)
    await controller.load();
    expect(
      controller.unsentMessages,
      isEmpty,
      reason: '重新读取历史不会让已忽略的这一批复活 — nothing wrote it back into '
          'the message rows',
    );
    final List<ChatMessage> after = history();
    expect(
      after.length,
      3,
      reason: '忽略 ≠ 删除: the three messages are still in the timeline',
    );
    expect(
      after.every((ChatMessage m) => m.status == MessageStatus.failed),
      isTrue,
      reason: 'and their status is untouched — nothing was retried either',
    );
    expect(
      controller.dismissUnsent(),
      0,
      reason: 'a second dismissal has nothing left to hide (idempotent)',
    );
  });

  test('a dismissal covers THIS batch only: a later failure counts again',
      () async {
    _seed(backend, messageId: 'm-1', status: MessageStatus.failed);
    _seed(
      backend,
      messageId: 'm-2',
      status: MessageStatus.failed,
      path: '/src/two.bin',
    );
    await controller.load();
    controller.dismissUnsent();
    expect(controller.unsentMessages, isEmpty);

    await _newFailedSend(backend, controller, path: '/src/after-1.bin');
    expect(
      controller.unsentMessages.length,
      1,
      reason: 'the new id was never dismissed, so it counts — one is below the '
          'banner threshold, which is the caller’s rule, not this one',
    );

    await _newFailedSend(backend, controller, path: '/src/after-2.bin');
    expect(
      controller.unsentMessages.length,
      2,
      reason: 'two fresh failures: the banner is worth showing again even '
          'though three older ones were dismissed',
    );
  });

  test('after a dismissal 全部重试 sends only the un-dismissed messages',
      () async {
    _seed(backend, messageId: 'm-old-1', status: MessageStatus.failed);
    _seed(
      backend,
      messageId: 'm-old-2',
      status: MessageStatus.failed,
      path: '/src/old-2.bin',
    );
    _seed(
      backend,
      messageId: 'm-old-3',
      status: MessageStatus.failed,
      path: '/src/old-3.bin',
    );
    await controller.load();
    controller.dismissUnsent();

    await _newFailedSend(backend, controller, path: '/src/new-1.bin');
    await _newFailedSend(backend, controller, path: '/src/new-2.bin');
    final int before = history().length;

    final BulkResendResult result =
        await controller.resendUnsent(peer: _peer());

    expect(result.sent, 2, reason: 'only the two un-dismissed ones go out');
    expect(
      history().length,
      before + 2,
      reason: 'the three dismissed messages must NOT be re-sent — dismissed '
          'means "leave these alone", not just "stop counting them"',
    );
  });
}

/// Makes one **real** failed send land in the thread (0.2.26 tests).
///
/// Goes through `sendPaths` + a failing `prepare`, so the failure arrives the way
/// a device's would — a `MessageAdded` then a `MessageStatusUpdated` — instead of
/// being seeded into the repository behind the controller's back.
///
/// The trailing `pumpEventQueue()` is not decoration: the repository's event
/// stream is a plain (async) broadcast controller, so the last `add` is delivered
/// in a **later microtask**. Without it the controller would still be showing the
/// pre-send list when the caller asserts, and a real bug ("the new failure never
/// got counted") would be masked by a test-fixture artefact.
Future<void> _newFailedSend(
  FakeBackend backend,
  ConversationController controller, {
  required String path,
}) async {
  backend.transfer.failNextPrepare(StateError('link reset'));
  await controller.sendPaths(peer: _peer(), paths: <String>[path]);
  await pumpEventQueue();
}
