/// 0.2.22 — what the user **sees** around 取消 and a dead link.
///
/// The defect was partly invisible from the controller side: `cancel()` returned
/// a `bool` and the thread dropped it, so a tap the controller refused produced
/// no feedback whatsoever. These tests pin the two visible halves: 取消 always
/// answers, and a send that died of "no byte progress" says why on the bubble
/// instead of leaving 失败 unadorned.
///
/// The thread is mounted **directly** (not through `ShellPage`) for a reason:
/// mounting the shell runs the E2 startup sweep
/// (`SessionRepository.failInterruptedMessages`), which turns every leftover
/// `transferring` message into `failed` — so a `transferring` row cannot be
/// seeded, it has to be *produced* by a real send. That is what test 1 does, and
/// it is the honest path anyway: the held upload is the exact window the user
/// taps 取消 in.
library;

import 'dart:async';

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

const String _fingerprint = 'EE09';
const String _conversationId = 'c-cancel';

PeerDevice _peer() => const PeerDevice(
      fingerprint: _fingerprint,
      alias: 'Eve',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

FileAttachment _file(String messageId, {int size = 1000}) => FileAttachment(
      id: 'f-$messageId',
      messageId: messageId,
      fileName: 'big.mov',
      size: size,
      sha256: '00',
      localPath: '/src/big.mov',
    );

FakeBackend _newBackend() {
  final FakeBackend backend = FakeBackend(
    devices: <PeerDevice>[_peer()],
    online: <DiscoveredPeer>[
      DiscoveredPeer(
        fingerprint: _fingerprint,
        alias: 'Eve',
        kind: DeviceKind.desktop,
        address: '192.168.1.20',
        port: 53317,
        isOnline: true,
        lastSeen: fixedEpoch,
      ),
    ],
  );
  backend.repo.addConversation(
    id: _conversationId,
    deviceFingerprint: _fingerprint,
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  return backend;
}

/// Seeds one outgoing file message with [status] (and [progress], if any).
void _seed(
  FakeBackend backend, {
  required String messageId,
  required MessageStatus status,
  TransferProgress? progress,
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
  if (progress != null) {
    backend.repo.addTransfer(progress);
  }
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

  /// Mounts the real thread under the fake scope.
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
    '1: tapping 取消 on a 传输中 bubble really cancels — the bubble reads 已取消 '
    'and the user is told, instead of a button that does nothing',
    (WidgetTester tester) async {
      backend.platform.setPickResult(FileKind.any, const <String>['/src/big.mov']);
      backend.platform.setLength('/src/big.mov', 1000);
      backend.platform.setSha256('/src/big.mov', '00');
      final Completer<void> hold = Completer<void>();
      backend.transfer.holdNextUpload(hold);

      await controller.load();
      await mount(tester);

      // The send the composer's 附件 entry performs, parked in the upload so the
      // bubble is on screen in 传输中 when the user taps.
      final Future<SendOutcome?> sending =
          controller.pickAndSend(peer: _peer(), kind: FileKind.any);
      for (int i = 0; i < 5; i++) {
        await tester.pump();
      }

      expect(
        find.text('传输中'),
        findsWidgets,
        reason: 'the upload is held, so the bubble must be sitting in 传输中 — '
            'this is the exact frame the user taps 取消 in',
      );
      expect(find.text('取消'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text('已取消'),
        findsWidgets,
        reason: 'the bubble must leave 传输中 — an in-flight cancel that leaves '
            'the bubble spinning is the whole bug report',
      );
      expect(find.text('传输中'), findsNothing);
      expect(
        find.byType(SnackBar),
        findsOneWidget,
        reason: 'every cancel outcome must answer the tap (the old code dropped '
            'the result entirely)',
      );
      // The store agrees, so the state survives a remount.
      expect(backend.repo.history(_conversationId).single.status,
          MessageStatus.canceled);

      await sending;
      await tester.pump();
    },
  );

  testWidgets(
    '2: a cancelled bubble offers 重新发送 (0.2.22 widened canResend past '
    'failed)',
    (WidgetTester tester) async {
      _seed(backend, messageId: 'm-canceled', status: MessageStatus.canceled);
      await controller.load();
      await mount(tester);

      expect(find.text('已取消'), findsWidgets);
      expect(
        find.text('重新发送'),
        findsOneWidget,
        reason: '"I cancelled it — now send it again" must be possible',
      );
      expect(find.text('取消'), findsNothing);
    },
  );

  testWidgets(
    '3: a send that died of "no byte progress" says 连接中断 on the bubble, so '
    '失败 is not the only thing the user learns',
    (WidgetTester tester) async {
      _seed(
        backend,
        messageId: 'm-stalled',
        status: MessageStatus.failed,
        progress: const TransferProgress(
          fileId: 'f-m-stalled',
          bytesDone: 400,
          bytesTotal: 1000,
          error: kStalledError,
        ),
      );
      await controller.load();
      await mount(tester);

      expect(find.text('失败（可重新发送）'), findsWidgets);
      expect(
        find.textContaining('连接中断'),
        findsOneWidget,
        reason: 'the reason is the actionable half: nothing is wrong with the '
            'file, the link went away',
      );
    },
  );

  testWidgets(
    '4: a plain network failure shows no invented reason — a raw exception '
    'string is a diagnostic, not an answer',
    (WidgetTester tester) async {
      _seed(
        backend,
        messageId: 'm-failed',
        status: MessageStatus.failed,
        progress: const TransferProgress(
          fileId: 'f-m-failed',
          bytesDone: 0,
          bytesTotal: 1000,
          error: 'SocketException: Connection reset by peer',
        ),
      );
      await controller.load();
      await mount(tester);

      expect(find.text('失败（可重新发送）'), findsWidgets);
      expect(find.textContaining('SocketException'), findsNothing);
      expect(
        tester.widget<MessageBubble>(find.byType(MessageBubble)).failureNote,
        isNull,
      );
    },
  );
}
