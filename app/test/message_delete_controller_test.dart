/// `ConversationController.deleteMessage` / `canDelete` (0.2.36).
///
/// The controller is the **only** place the three rules of the feature meet, so
/// this is where each of them is pinned:
///
/// * an in-flight send is refused ([ConversationController.canDelete]) — the
///   record must not vanish while the transfer keeps running;
/// * the visible list is updated **after** the store answered, so a bubble can
///   never disappear from a timeline that still holds the row;
/// * every outcome carries copy, including the two refusals.
///
/// The store write itself is the fake's; `store/test/message_delete_test.dart`
/// owns the real sub-tree delete and its durability.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/unsent_dismissal_store.dart';

import 'support/fakes.dart';

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'AAAA1111',
      alias: 'Alice',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

void main() {
  late FakeBackend backend;
  late TransferOrchestrator orchestrator;
  late ConversationController controller;
  late String conversationId;

  setUp(() {
    backend = FakeBackend(devices: <PeerDevice>[_peer()]);
    conversationId = backend.repo
        .addConversation(id: 'c-1', deviceFingerprint: 'AAAA1111')
        .id;
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
      conversationId: conversationId,
      // A private store per test: the shared one is process-wide and persisted,
      // and a dismissal written by another test must not silence this banner.
      dismissals: UnsentDismissalStore(),
    );
  });

  tearDown(() {
    controller.dispose();
    orchestrator.dispose();
    backend.dispose();
  });

  /// Seeds one text message and returns it.
  ChatMessage seed({
    required String id,
    MessageStatus status = MessageStatus.done,
    MessageDirection direction = MessageDirection.incoming,
    MessageKind kind = MessageKind.text,
    int minutes = 0,
  }) =>
      backend.repo.addMessage(
        id: id,
        conversationId: conversationId,
        direction: direction,
        status: status,
        kind: kind,
        textBody: kind == MessageKind.text ? 'body $id' : null,
        createdAt: fixedEpoch.add(Duration(minutes: minutes)),
        files: kind == MessageKind.file
            ? <FileAttachment>[
                FileAttachment(
                  id: 'f-$id',
                  messageId: id,
                  fileName: '$id.bin',
                  size: 5,
                  sha256: '00',
                  localPath: '/src/$id.bin',
                ),
              ]
            : const <FileAttachment>[],
      );

  group('canDelete', () {
    test('is false for the three in-flight statuses', () {
      for (final MessageStatus status in <MessageStatus>[
        MessageStatus.pending,
        MessageStatus.awaitingConfirm,
        MessageStatus.transferring,
      ]) {
        final ChatMessage message = seed(id: 'm-${status.wire}', status: status);
        expect(controller.canDelete(message), isFalse,
            reason: '${status.wire} is still sending — the record must stay');
      }
    });

    test('is true once the transfer is over', () {
      for (final MessageStatus status in <MessageStatus>[
        MessageStatus.done,
        MessageStatus.failed,
        MessageStatus.canceled,
        MessageStatus.rejected,
      ]) {
        final ChatMessage message =
            seed(id: 'm-${status.wire}', status: status);
        expect(controller.canDelete(message), isTrue,
            reason: '${status.wire} has no running transfer left');
      }
    });
  });

  group('deleteMessage', () {
    test('removes the bubble from the loaded list and from the repository', () async {
      seed(id: 'keep', minutes: 0);
      seed(id: 'gone', minutes: 1);
      await controller.load();
      expect(controller.messages.valueOrNull, hasLength(2));

      final ChatMessage target = controller.messages.valueOrNull!
          .firstWhere((ChatMessage m) => m.id == 'gone');
      final DeleteResult result = controller.deleteMessage(target);

      expect(result.wasDeleted, isTrue);
      expect(result.notice, '已删除');
      expect(
        controller.messages.valueOrNull!.map((ChatMessage m) => m.id),
        <String>['keep'],
        reason: 'the deleted bubble must leave the timeline immediately',
      );
      expect(
        backend.repo.history(conversationId).map((ChatMessage m) => m.id),
        <String>['keep'],
        reason: 'and it must be gone from the store, not only from the view',
      );
    });

    test('notifies its listeners exactly when the list changed', () async {
      seed(id: 'gone');
      await controller.load();

      int notified = 0;
      controller.addListener(() => notified++);
      controller.deleteMessage(
        controller.messages.valueOrNull!.single,
      );
      expect(notified, 1,
          reason: 'one repaint per delete — the bubble disappeared');

      // A second delete of the same row changes nothing on screen, so it must
      // not repaint (and must not claim success either).
      final DeleteResult again = controller.deleteMessage(
        ChatMessage(
          id: 'gone',
          conversationId: conversationId,
          direction: MessageDirection.incoming,
          kind: MessageKind.text,
          textBody: 'body gone',
          createdAt: fixedEpoch,
          updatedAt: fixedEpoch,
          status: MessageStatus.done,
        ),
      );
      expect(again.wasDeleted, isFalse);
      expect(again.notice, '这条消息已经不在了');
      expect(notified, 1, reason: 'nothing changed, so nothing is repainted');
    });

    test('refuses an in-flight message and leaves the row in place', () async {
      seed(id: 'sending', status: MessageStatus.transferring);
      await controller.load();

      final DeleteResult result = controller.deleteMessage(
        controller.messages.valueOrNull!.single,
      );

      expect(result.wasDeleted, isFalse);
      expect(result.notice, '这条消息正在发送，不能删除');
      expect(controller.messages.valueOrNull, hasLength(1));
      expect(backend.repo.history(conversationId), hasLength(1));
    });

    test('a deleted failed message stops counting in the 未发送成功 banner',
        () async {
      seed(
        id: 'f1',
        status: MessageStatus.failed,
        direction: MessageDirection.outgoing,
        kind: MessageKind.file,
        minutes: 0,
      );
      seed(
        id: 'f2',
        status: MessageStatus.failed,
        direction: MessageDirection.outgoing,
        kind: MessageKind.file,
        minutes: 1,
      );
      seed(
        id: 'f3',
        status: MessageStatus.failed,
        direction: MessageDirection.outgoing,
        kind: MessageKind.file,
        minutes: 2,
      );
      await controller.load();
      expect(controller.unsentMessages, hasLength(3));

      controller.deleteMessage(
        controller.messages.valueOrNull!
            .firstWhere((ChatMessage m) => m.id == 'f2'),
      );

      expect(controller.unsentMessages, hasLength(2),
          reason: 'the banner count is derived from the visible list');
      expect(
        controller.unsentMessages.map((ChatMessage m) => m.id),
        <String>['f1', 'f3'],
      );
    });

    test('works before the history has loaded', () {
      final ChatMessage message = seed(id: 'm1');
      // No `load()`: `_messages` is still `Loading`, so there is no list to
      // prune — but the store delete still has to happen.
      expect(controller.messages.valueOrNull, isNull);

      final DeleteResult result = controller.deleteMessage(message);

      expect(result.wasDeleted, isTrue);
      expect(backend.repo.history(conversationId), isEmpty);
    });
  });
}
