/// Unit tests for the process-wide 未发送成功 dismissal store (0.2.30).
///
/// The bug these pin down: *"如果退出这个会话界面重新进来，还是会显示全部重试"*.
/// 0.2.26 kept the ignored ids in a `Set` **field of `ConversationController`**,
/// and `DetailPane` builds a new controller for every conversation selection — so
/// leaving the thread threw the dismissals away with the object that held them.
///
/// Two layers are tested here:
/// 1. the store itself — the `conversationId → {messageId}` contract, blank cases,
///    unmodifiable snapshots, idempotence;
/// 2. `ConversationController` — **two separate controllers** (which is what
///    "exit and come back" really is) agreeing on the same dismissal, and one
///    conversation's dismissal not silencing another's.
///
/// The visible half (the banner really stays hidden after a re-mount) lives in
/// `test/widget/retry_all_reenter_test.dart`.
///
/// **0.2.33:** the store now also persists, so a dismissal survives a *restart*
/// as well as a conversation switch — that half is in
/// `test/unsent_dismissal_persistence_test.dart` and
/// `test/widget/retry_all_restart_test.dart`. The contract pinned here (per
/// conversation, idempotent, unmodifiable snapshots) is unchanged; the stores
/// created in this file simply have no persistence wired (the pre-0.2.33 shape,
/// which is also what the Web build gets).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/unsent_dismissal_store.dart';

const String _fingerprint = 'UD30';

/// Seeds one outgoing **failed file** message (the only kind the banner counts).
void _seed(
  FakeBackend backend, {
  required String conversationId,
  required String messageId,
}) {
  backend.repo.addMessage(
    id: messageId,
    conversationId: conversationId,
    direction: MessageDirection.outgoing,
    status: MessageStatus.failed,
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
    files: <FileAttachment>[
      FileAttachment(
        id: 'f-$messageId',
        messageId: messageId,
        fileName: 'one.bin',
        size: 5,
        sha256: '00',
        localPath: '/src/$messageId.bin',
      ),
    ],
  );
}

void main() {
  group('UnsentDismissalStore', () {
    test('a dismissal is remembered per conversation, and nowhere else', () {
      final UnsentDismissalStore store = UnsentDismissalStore();

      store.dismiss(conversationId: 'A', messageIds: <String>['m-1', 'm-2']);

      expect(store.isDismissed(conversationId: 'A', messageId: 'm-1'), isTrue);
      expect(store.isDismissed(conversationId: 'A', messageId: 'm-9'), isFalse);
      // Same id, other conversation: not dismissed — the key is the pair.
      expect(store.isDismissed(conversationId: 'B', messageId: 'm-1'), isFalse);
      expect(store.countFor('A'), 2);
      expect(store.countFor('B'), 0);
      expect(store.length, 1);
    });

    test('dismiss returns how many were NEW, and is idempotent', () {
      final UnsentDismissalStore store = UnsentDismissalStore();

      expect(
        store.dismiss(conversationId: 'A', messageIds: <String>['m-1', 'm-2']),
        2,
      );
      expect(
        store.dismiss(conversationId: 'A', messageIds: <String>['m-2', 'm-3']),
        1,
        reason: 'm-2 was already there — a stale frame tapping twice must not '
            'inflate anything',
      );
      expect(store.countFor('A'), 3);
    });

    test('dismissedFor is an unmodifiable snapshot', () {
      final UnsentDismissalStore store = UnsentDismissalStore()
        ..dismiss(conversationId: 'A', messageIds: <String>['m-1']);

      final Set<String> snapshot = store.dismissedFor('A');
      expect(snapshot, <String>{'m-1'});
      expect(
        () => snapshot.add('m-2'),
        throwsUnsupportedError,
        reason: 'the store must not be mutable through a getter',
      );
      // An unknown conversation answers with an empty set, never null.
      expect(store.dismissedFor('nobody'), isEmpty);
    });

    test('forgetConversation and clearAll undo dismissals', () {
      final UnsentDismissalStore store = UnsentDismissalStore()
        ..dismiss(conversationId: 'A', messageIds: <String>['m-1'])
        ..dismiss(conversationId: 'B', messageIds: <String>['m-2']);

      expect(store.forgetConversation('A'), isTrue);
      expect(store.forgetConversation('A'), isFalse);
      expect(store.isDismissed(conversationId: 'A', messageId: 'm-1'), isFalse);
      expect(store.isDismissed(conversationId: 'B', messageId: 'm-2'), isTrue);

      store.clearAll();
      expect(store.length, 0);
    });
  });

  group('ConversationController ↔ store', () {
    late FakeBackend backend;
    late UnsentDismissalStore store;

    setUp(() {
      backend = FakeBackend();
      backend.repo.addConversation(
        id: 'c-a',
        deviceFingerprint: _fingerprint,
        createdAt: fixedEpoch,
        lastMessageAt: fixedEpoch,
      );
      backend.repo.addConversation(
        id: 'c-b',
        deviceFingerprint: _fingerprint,
        createdAt: fixedEpoch,
        lastMessageAt: fixedEpoch,
      );
      store = UnsentDismissalStore();
    });

    tearDown(() => backend.dispose());

    ConversationController build(String conversationId) =>
        ConversationController(
          repo: backend.repo,
          orchestrator: TransferOrchestrator(
            repo: backend.repo,
            transfer: backend.transfer,
          ),
          platform: backend.platform,
          ids: backend.ids,
          clock: backend.clock,
          conversationId: conversationId,
          dismissals: store,
        );

    test('a NEW controller for the same conversation still ignores the batch '
        '(this is "退出会话再进来")', () async {
      _seed(backend, conversationId: 'c-a', messageId: 'm-1');
      _seed(backend, conversationId: 'c-a', messageId: 'm-2');
      _seed(backend, conversationId: 'c-a', messageId: 'm-3');

      final ConversationController first = build('c-a');
      await first.load();
      expect(first.unsentMessages.length, 3);
      expect(first.dismissUnsent(), 3);
      expect(first.unsentMessages, isEmpty);
      // Leaving the conversation: the pane disposes the controller.
      first.dispose();

      final ConversationController second = build('c-a');
      addTearDown(second.dispose);
      await second.load();

      expect(
        second.unsentMessages,
        isEmpty,
        reason: '退出会话再进来 —— 忽略必须仍然生效，否则提示条会回来（这次报的 bug）',
      );
      // 忽略 ≠ 删除 / ≠ 重试: the three rows are untouched.
      final List<ChatMessage> after = backend.repo.history('c-a');
      expect(after.length, 3);
      expect(
        after.every((ChatMessage m) => m.status == MessageStatus.failed),
        isTrue,
      );
    });

    test('a dismissal in one conversation does not silence another', () async {
      _seed(backend, conversationId: 'c-a', messageId: 'm-a1');
      _seed(backend, conversationId: 'c-a', messageId: 'm-a2');
      // The same message ids in the other conversation, on purpose: only the
      // conversation id may decide.
      _seed(backend, conversationId: 'c-b', messageId: 'm-a1');
      _seed(backend, conversationId: 'c-b', messageId: 'm-a2');

      final ConversationController a = build('c-a');
      await a.load();
      a.dismissUnsent();
      a.dispose();

      final ConversationController b = build('c-b');
      addTearDown(b.dispose);
      await b.load();

      expect(
        b.unsentMessages.length,
        2,
        reason: 'the other device’s two failures are still the user’s to act on',
      );
    });

    test('a failure that arrives after the dismissal counts again', () async {
      _seed(backend, conversationId: 'c-a', messageId: 'm-1');
      _seed(backend, conversationId: 'c-a', messageId: 'm-2');

      final ConversationController first = build('c-a');
      await first.load();
      first.dismissUnsent();
      first.dispose();

      // A new drop, landing while the user is away.
      _seed(backend, conversationId: 'c-a', messageId: 'm-after-1');
      _seed(backend, conversationId: 'c-a', messageId: 'm-after-2');

      final ConversationController second = build('c-a');
      addTearDown(second.dispose);
      await second.load();

      expect(
        second.unsentMessages.map((ChatMessage m) => m.id),
        <String>['m-after-1', 'm-after-2'],
        reason: '只忽略那一批：新 id 要重新计数，否则「别提醒我」会变成永久的',
      );
    });
  });
}
