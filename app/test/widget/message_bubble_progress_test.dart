/// Widget tests for the transfer **progress** display (M5 spec §3.6 / PRD §6,
/// A4-1…A4-7).
///
/// The percentage is now on the **shared** `_ProgressBar` label (the W1 ruling:
/// both ends show it, a pure addition), so the first test also pins that a
/// **desktop (wide)** window shows it — the guardrail the shared component
/// requires. The remaining tests pin the downgrades that must not regress:
/// `total <= 0` shows no bar and no `%` (A4-2), `awaiting_confirm` shows no bar
/// (A4-3), a fresh `0/total` progress reads `0%` (A4-6), a text message never
/// shows a bar (A4-7) and the offline note is not a bubble (A4-5).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

/// A file message (the shape progress attaches to).
ChatMessage _message({
  MessageStatus status = MessageStatus.transferring,
  MessageDirection direction = MessageDirection.outgoing,
  MessageKind kind = MessageKind.file,
  String? textBody,
}) =>
    ChatMessage(
      id: 'm1',
      conversationId: 'c1',
      direction: direction,
      kind: kind,
      textBody: textBody,
      createdAt: DateTime.utc(2026, 1, 7, 12),
      updatedAt: DateTime.utc(2026, 1, 7, 12),
      status: status,
    );

/// One attachment.
FileAttachment _file(String name, int size) => FileAttachment(
      id: 'f-$name',
      messageId: 'm1',
      fileName: name,
      size: size,
      sha256: '00',
      localPath: '/src/$name',
    );

/// Mounts [bubble] inside a `Scaffold` (Material host) at [size].
Future<void> _pumpBubble(
  WidgetTester tester,
  MessageBubble bubble, {
  Size size = const Size(600, 800),
}) async {
  useSurfaceSize(tester, size);
  await pumpApp(tester, Scaffold(body: bubble), settle: true);
}

void main() {
  testWidgets(
      'A4-1 (+ the W1 guardrail): transferring + known total shows the bar, the '
      'bytes AND the percentage — including on a DESKTOP (wide) window',
      (WidgetTester tester) async {
    // A wide window: the desktop form. The percentage must appear here too — the
    // shared label changed for both ends (W1), not just the phone.
    await _pumpBubble(
      tester,
      MessageBubble(
        message: _message(),
        files: <FileAttachment>[_file('big.bin', 1024)],
        progress: const TransferProgress(
          fileId: 'f-big.bin',
          bytesDone: 512,
          bytesTotal: 1024,
        ),
      ),
      size: const Size(1200, 1000),
    );

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('512 B / 1.0 KB · 50%'), findsOneWidget);
  });

  testWidgets(
      'A4-2: an unknown total (-1) draws no bar, no percentage, no "-1 B"',
      (WidgetTester tester) async {
    await _pumpBubble(
      tester,
      MessageBubble(
        message: _message(),
        files: <FileAttachment>[_file('mystery.bin', -1)],
        progress: const TransferProgress(
          fileId: 'f-mystery.bin',
          bytesDone: 300,
          bytesTotal: -1,
        ),
      ),
    );

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('%'), findsNothing);
    expect(find.textContaining('-1'), findsNothing);
    // The downgrade keeps the "already-sent bytes only" label.
    expect(find.text('300 B'), findsOneWidget);
  });

  testWidgets(
      'A4-3: awaiting_confirm draws no progress bar (nothing is transferring yet)',
      (WidgetTester tester) async {
    await _pumpBubble(
      tester,
      MessageBubble(
        message: _message(status: MessageStatus.awaitingConfirm),
        files: <FileAttachment>[_file('big.bin', 1024)],
        progress: const TransferProgress(
          fileId: 'f-big.bin',
          bytesDone: 0,
          bytesTotal: 1024,
        ),
      ),
    );

    expect(find.text('等待对方确认'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets(
      'A4-6: a fresh 0/total progress reads 0% — the bubble keeps no stale ratio',
      (WidgetTester tester) async {
    await _pumpBubble(
      tester,
      MessageBubble(
        message: _message(),
        files: <FileAttachment>[_file('again.bin', 1024)],
        progress: const TransferProgress(
          fileId: 'f-again.bin',
          bytesDone: 0,
          bytesTotal: 1024,
        ),
      ),
    );

    expect(find.text('0 B / 1.0 KB · 0%'), findsOneWidget);
  });

  testWidgets(
      'A4-7: a text message never contributes a progress bar, while a sibling '
      'transferring file does (exactly one bar)', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    final PeerDevice peer = PeerDevice(
      fingerprint: 'E1100011',
      alias: 'Eve Laptop',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );
    backend.repo.addConversation(
      id: 'c-a47',
      deviceFingerprint: 'E1100011',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    // A text message: it has no files, so `ConversationThread` wires no progress
    // for it (conversation_thread.dart: `files.isEmpty ? null : …`).
    backend.repo.addMessage(
      id: 'm-a47-text',
      conversationId: 'c-a47',
      direction: MessageDirection.outgoing,
      status: MessageStatus.done,
      kind: MessageKind.text,
      textBody: '你好',
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
    );

    useSurfaceSize(tester, const Size(600, 800));
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: peer,
    );

    // Drive a *file* message live to `transferring` (the mount sweep would reset
    // a seeded one, so it is recorded after mount along the legal edges).
    final live = backend.repo.recordOutgoing(
      peer: peer,
      files: <OutgoingFile>[
        OutgoingFile(
          id: 'f-a47',
          fileName: 'a.bin',
          size: 400,
          sha256: 'AA',
          localPath: '/src/a.bin',
        ),
      ],
    );
    for (final (MessageStatus, MessageStatus) edge
        in const <(MessageStatus, MessageStatus)>[
      (MessageStatus.pending, MessageStatus.awaitingConfirm),
      (MessageStatus.awaitingConfirm, MessageStatus.transferring),
    ]) {
      expect(
        backend.repo
            .setStatus(messageId: live.messageId, from: edge.$1, to: edge.$2),
        isTrue,
        reason: '${edge.$1.wire} -> ${edge.$2.wire}',
      );
    }
    await tester.pumpAndSettle();

    expect(find.text('你好'), findsOneWidget);
    // The bubble's OWN status reads 传输中. Scoped to the bubble on purpose: the
    // detail header *also* shows 传输中 here — its "第三态" reads 传输中 (not 离线)
    // when the peer is judged offline but the conversation has an in-flight
    // outgoing transfer (`detail_pane._statusLine`) — so an unscoped
    // `find.text('传输中')` legitimately matches two independent sources.
    expect(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.text('传输中'),
      ),
      findsOneWidget,
    );
    // Exactly ONE progress bar — the file's. The text bubble contributes none.
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('A4-5: the "对方离线" note is drawn OUTSIDE the message bubble',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    final PeerDevice peer = PeerDevice(
      fingerprint: 'EF56',
      alias: 'Ef',
      kind: DeviceKind.desktop,
      isOnline: false,
      lastPort: 53317,
    );
    backend.repo.addConversation(
      id: 'c-a45',
      deviceFingerprint: 'EF56',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-a45',
      conversationId: 'c-a45',
      direction: MessageDirection.outgoing,
      status: MessageStatus.pending,
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
      files: <FileAttachment>[_file('queued.bin', 4)],
    );

    useSurfaceSize(tester, const Size(600, 800));
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: peer,
    );

    expect(find.textContaining('对方离线'), findsOneWidget);
    // It must not read as "who sent this": the note is a sibling of the bubble,
    // never inside one (A4-5).
    expect(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.textContaining('对方离线'),
      ),
      findsNothing,
    );
  });
}
