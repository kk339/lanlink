/// What the **bubble says** when a send died because its source file is gone
/// (0.2.52).
///
/// The pump writes a reason (`kSourceMissingError`) — but a reason nobody draws
/// is the same nothing the user reported: *「只说失败，不说为什么」*. This file
/// pins the reading half, and it pins both routes the reason can arrive by:
///
/// * the **stored** `transfers.error` — what `SessionRepository.markSendFailed`
///   writes, available whenever the message already had a transfer row;
/// * the **disk** — for a queued message that never started there is no transfer
///   row to write into, so the timeline's own shared judgement
///   (`SourceAvailability`, the same one that draws the red icon) is the only
///   witness. Without it that case would stay blank, which is exactly the defect.
///
/// One negative case is here too: a raw exception string must still be **shown
/// as nothing** — 0.2.22's rule, and the reason the new copy had to be a named
/// constant rather than "print `message.error`".
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/transfer_service.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';

import '../support/pump_app.dart';

const String _fingerprint = 'BB07';
const String _conversationId = 'c-source-note';
const String _sourcePath = '/cache/lanlink-picked/uuid-9/report.pdf';

PeerDevice _peer() => const PeerDevice(
      fingerprint: _fingerprint,
      alias: 'Bob',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

FileAttachment _file(String messageId) => FileAttachment(
      id: 'f-$messageId',
      messageId: messageId,
      fileName: 'report.pdf',
      size: 2048,
      sha256: '00',
      localPath: _sourcePath,
    );

FakeBackend _newBackend() {
  final FakeBackend backend = FakeBackend(
    devices: <PeerDevice>[_peer()],
  );
  backend.repo.addConversation(
    id: _conversationId,
    deviceFingerprint: _fingerprint,
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  return backend;
}

void main() {
  late FakeBackend backend;
  late TransferOrchestrator orchestrator;
  late ConversationController controller;

  setUp(() {
    backend = _newBackend();
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
    );
  });

  tearDown(() {
    controller.dispose();
    orchestrator.dispose();
    backend.dispose();
  });

  /// Seeds one outgoing file message in [status], optionally with a recorded
  /// transfer [error].
  void seed(
    String messageId, {
    required MessageStatus status,
    String? error,
    bool sourceOnDisk = true,
  }) {
    backend.repo.addMessage(
      id: messageId,
      conversationId: _conversationId,
      direction: MessageDirection.outgoing,
      status: status,
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
      files: <FileAttachment>[_file(messageId)],
    );
    if (error != null) {
      backend.repo.addTransfer(
        TransferProgress(
          fileId: 'f-$messageId',
          bytesDone: 0,
          bytesTotal: 2048,
          error: error,
        ),
      );
    }
    backend.platform.setExists(_sourcePath, sourceOnDisk);
  }

  Future<void> mount(WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1200, 900));
    await pumpApp(
      tester,
      Scaffold(
        body: ConversationThread(controller: controller, peer: _peer()),
      ),
      backend: backend,
      settle: true,
    );
  }

  testWidgets(
    '1: a failed send whose source was cleaned up says so — and says 重新发送',
    (WidgetTester tester) async {
      backend.platform.setExists(_sourcePath, false);
      seed('m-gone', status: MessageStatus.failed, error: kSourceMissingError);
      await controller.load();
      await mount(tester);

      expect(find.text('失败（可重新发送）'), findsWidgets);
      // ★ The green light. Before 0.2.52 this sentence did not exist anywhere:
      // the pump wrote 「源文件已不在」 into a transfer row the timeline did not
      // consult, and the bubble showed 失败 alone.
      expect(
        find.textContaining('重新发送'),
        findsWidgets,
        reason: 'the reason must name the action the row offers',
      );
      final String? note = tester
          .widget<MessageBubble>(find.byType(MessageBubble).last)
          .failureNote;
      expect(note, isNotNull,
          reason: 'a failed message with a known cause must never be blank');
      expect(note, contains('已被清理'));
    },
  );

  testWidgets(
    '2: the disk is the witness — a stored reason we cannot print still leaves '
    'the missing file said out loud',
    (WidgetTester tester) async {
      // The row carries the *other* kind of error: a raw exception string, which
      // this file has always refused to print (0.2.22). The file is gone
      // nonetheless, and the bubble must say the one thing that helps instead of
      // falling back to a bare 失败.
      seed('m-gone',
          status: MessageStatus.failed,
          error: 'FileSystemException: Cannot open file',
          sourceOnDisk: false);
      await controller.load();
      await mount(tester);

      final String? note = tester
          .widget<MessageBubble>(find.byType(MessageBubble).last)
          .failureNote;
      expect(note, isNotNull,
          reason: 'the stored reason is unprintable, but the disk answer is not '
              '— a blank bubble is the defect this closes');
      expect(note, contains('重新发送'));
      expect(find.textContaining('FileSystemException'), findsNothing);

      // …and the disk verdict also marks the row as missing, so the icon and the
      // sentence tell the same story.
      final MessageBubble bubble =
          tester.widget<MessageBubble>(find.byType(MessageBubble).last);
      expect(bubble.sourceUnavailable, isTrue,
          reason: 'the shared disk judgement flagged the file — the note is '
              'drawn from the same fact');
      expect(bubble.sourceCleanedByUs, isFalse,
          reason: 'we did not watch ourselves delete this one; it simply is not '
              'there, and the 重新发送 the user is offered cannot read it');
    },
  );

  testWidgets(
    '3: an unnamed failure stays unnamed — a raw exception is not UI copy',
    (WidgetTester tester) async {
      seed('m-raw',
          status: MessageStatus.failed,
          error: 'SocketException: Connection reset by peer');
      await controller.load();
      await mount(tester);

      expect(
        tester
            .widget<MessageBubble>(find.byType(MessageBubble).last)
            .failureNote,
        isNull,
        reason: '0.2.22 rule, unchanged: only a cause this app can name is drawn',
      );
      expect(find.textContaining('SocketException'), findsNothing);
    },
  );

  testWidgets(
    '4: a DELIVERED message whose copy we deleted is silent (no accusation)',
    (WidgetTester tester) async {
      // The post-send cleanup (`_discardPickedCopies`) removes the copy on
      // Android; 0.2.49's rule is that a successful send must not be accused of
      // losing its own file. The new note must not resurrect that complaint.
      seed('m-done', status: MessageStatus.done, sourceOnDisk: false);
      await controller.load();
      await mount(tester);

      expect(
        tester
            .widget<MessageBubble>(find.byType(MessageBubble).last)
            .failureNote,
        isNull,
        reason: 'only `failed` messages get a failure note — a delivered one has '
            'nothing to apologise for',
      );
    },
  );
}
