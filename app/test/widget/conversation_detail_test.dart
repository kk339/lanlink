/// Widget tests for a conversation shown in the shell's **right pane** — the
/// successor of the old `ConversationPage` (spec §8.8 / PRD §10 A2; design §8.1).
///
/// Each test mounts `ShellPage(initialPeer: …)` (via `pumpShell`) instead of the
/// deleted `ConversationPage`; the assertions are unchanged — the timeline and
/// its composer now live in `ConversationThread`.
///
/// Behavioural assertions only: they drive the fake backend and assert what the
/// user sees (timeline layout, copy, actions), never internal structure.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/format.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

/// A device for [fingerprint]; defaults to a dialable peer.
PeerDevice _peer(
  String fingerprint, {
  required String alias,
  bool online = false,
  int? lastPort = 53317,
  DeviceKind kind = DeviceKind.desktop,
}) =>
    PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: kind,
      isOnline: online,
      lastPort: lastPort,
    );

/// One attachment.
FileAttachment _file(
  String id,
  String messageId,
  String name,
  int size, {
  String? path,
}) =>
    FileAttachment(
      id: id,
      messageId: messageId,
      fileName: name,
      size: size,
      sha256: 'AA',
      localPath: path,
    );

void main() {
  testWidgets('no messages → conversation empty state (PRD §4.2)',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-1',
      deviceFingerprint: 'EE00',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('EE00', alias: 'Eve'),
    );

    expect(find.byType(ConversationThread), findsOneWidget);
    expect(find.text('还没有传输记录'), findsOneWidget);
  });

  testWidgets(
      'out bubbles sit right of in bubbles and a local-day separator '
      'is shown (A2-6)', (WidgetTester tester) async {
    // A *wide* and tall window: tall so every status bubble is laid out (the
    // timeline is a lazy `ListView` now — the old page used a
    // `SingleChildScrollView`), and wide so the right pane is broader than the
    // bubble cap (root cause B, below).
    useSurfaceSize(tester, const Size(1200, 1600));
    final FakeBackend backend = FakeBackend.allStatuses();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('DDDD4444', alias: 'Dave', online: true),
    );

    expect(
      find.byType(MessageBubble),
      findsNWidgets(MessageStatus.values.length),
    );
    // All seven statuses are seeded at `fixedEpoch` (plus a few minutes), which
    // is the injected clock's "now" → the separator reads 今天.
    expect(
      find.text(dateSeparatorText(fixedEpoch, fixedEpoch)),
      findsWidgets,
    );

    // 量内层。外层 `Align` 撑满整栏，量它会得到两个相同的中心 x —— 这个坑在这个项目里出现过三次。
    //
    // Concretely, the bubble is `Align(child: ConstrainedBox(child: Container))`.
    // The outer `Align` always fills the pane, so its centre is the pane centre
    // for BOTH directions — never a probe. The left/right placement lives on the
    // bubble's **inner** box, the `ConstrainedBox` (same probe as the old
    // `ConversationPage` test). That box only moves when the pane is **wider**
    // than the bubble cap (`kBubbleMaxWidthPx` = 460): at the compact width the
    // pane is ≈454, the cap does not bind, the box fills the pane too, and both
    // centres collapse to the same 573.0 — which is exactly the failure this
    // window size fixes. Measure the bubble's own box, never the outer `Align`.
    double bubbleCentreX(String fileName) => tester
        .getCenter(
          find
              .descendant(
                of: find.widgetWithText(MessageBubble, fileName),
                matching: find.byType(ConstrainedBox),
              )
              .first,
        )
        .dx;

    expect(
      bubbleCentreX('file-failed.bin'),
      greaterThan(bubbleCentreX('file-canceled.bin')),
    );
  });

  testWidgets(
      'the seven status labels render exactly, and never '
      'queued/sent/delivered/read (A2-7 / A2-8)', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(800, 1600));
    final FakeBackend backend = FakeBackend.allStatuses();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('DDDD4444', alias: 'Dave', online: true),
    );

    // Root cause C (A2-7), honestly: this is **not** a lazy-viewport miss. The
    // mount always runs the startup sweep (`HomeController.init` →
    // `failInterruptedMessages`, E2), which turns any *seeded* `awaiting_confirm`
    // / `transferring` into `failed` before the thread is first read — so those
    // two labels cannot be observed from a seeded state at all, and no surface
    // size can conjure a chip whose status no longer exists. (Cross-check: the
    // A2-6 test above asserts all `MessageStatus.values.length` bubbles are built
    // at this very surface, so the viewport is not the constraint.) Drive the two
    // messages back **live**, along the exact legal edges the orchestrator uses,
    // so all seven labels are observable at once.
    void walk(String messageId, List<MessageStatus> path) {
      for (int i = 0; i < path.length - 1; i++) {
        expect(
          backend.repo
              .setStatus(messageId: messageId, from: path[i], to: path[i + 1]),
          isTrue,
          reason: '${path[i].wire} -> ${path[i + 1].wire}',
        );
      }
    }

    walk('m-awaiting_confirm', <MessageStatus>[
      MessageStatus.failed, // the status the mount's sweep left it in
      MessageStatus.pending,
      MessageStatus.awaitingConfirm,
    ]);
    walk('m-transferring', <MessageStatus>[
      MessageStatus.failed, // the status the mount's sweep left it in
      MessageStatus.pending,
      MessageStatus.awaitingConfirm,
      MessageStatus.transferring,
    ]);
    await tester.pumpAndSettle();

    for (final MessageStatus status in MessageStatus.values) {
      if (status == MessageStatus.done) {
        // docs/19 §9-A (2026-10-17): a **delivered** message shows「已完成」only
        // on the thread's **newest** bubble, because six identical green dots
        // down one conversation said nothing the first one had not. This
        // fixture's delivered message is not the newest, so the label is
        // deliberately absent **here** — and that is now pinned:
        expect(find.text(statusText(status)), findsNothing,
            reason: '${status.wire}: not the newest ⟹ no chip');
        // Its wording is still pinned: `widgets_smoke_test.dart:90` asserts
        // 「已完成」on a **lone** bubble (a lone bubble is last by construction).
        // A2-7 / A2-8 require all seven labels to exist and read exactly; they
        // do not require one chip per delivered message in a list.
        continue;
      }
      expect(find.text(statusText(status)), findsWidgets, reason: status.wire);
    }
    for (final String forbidden in <String>[
      'queued',
      'sent',
      'delivered',
      'read',
    ]) {
      expect(find.text(forbidden), findsNothing, reason: forbidden);
    }
  });

  testWidgets('size == -1 renders 未知大小, never -1 or 0 B (A2-9)',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-neg',
      deviceFingerprint: 'AB12',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-neg',
      conversationId: 'c-neg',
      direction: MessageDirection.outgoing,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
      files: <FileAttachment>[_file('f-neg', 'm-neg', 'mystery.bin', -1)],
    );

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('AB12', alias: 'Neg'),
    );

    expect(find.text('未知大小'), findsOneWidget);
    expect(find.text('-1'), findsNothing);
    expect(find.text('0 B'), findsNothing);
  });

  testWidgets('a multi-file message renders every file with its size (A2-10)',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-multi',
      deviceFingerprint: 'CD12',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-multi',
      conversationId: 'c-multi',
      direction: MessageDirection.outgoing,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
      files: <FileAttachment>[
        _file('f-a', 'm-multi', 'a.bin', 1024),
        _file('f-b', 'm-multi', 'b.bin', 2048),
      ],
    );

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('CD12', alias: 'Multi'),
    );

    expect(find.text('a.bin'), findsOneWidget);
    expect(find.text('b.bin'), findsOneWidget);
    expect(find.text('1.0 KB'), findsWidgets);
    expect(find.text('2.0 KB'), findsWidgets);
  });

  testWidgets(
      'a failed message whose source is gone shows 源文件不可用 and '
      'disables resend (A2-18)', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform.setExists('/gone.bin', false);
    backend.repo.addConversation(
      id: 'c-g',
      deviceFingerprint: 'CD34',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-g',
      conversationId: 'c-g',
      direction: MessageDirection.outgoing,
      status: MessageStatus.failed,
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
      files: <FileAttachment>[
        _file('f-g', 'm-g', 'gone.bin', 10, path: '/gone.bin'),
      ],
    );

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('CD34', alias: 'Cee'),
    );

    expect(find.text('源文件不可用'), findsWidgets);
    expect(find.text('重新发送'), findsOneWidget);
    final TextButton resend =
        tester.widget<TextButton>(find.widgetWithText(TextButton, '重新发送'));
    expect(resend.onPressed, isNull);
  });

  testWidgets(
      'a queued (offline) message states the reason and cancels to '
      '已取消 (Q9 / A2-23)', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-p',
      deviceFingerprint: 'EF56',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-p',
      conversationId: 'c-p',
      direction: MessageDirection.outgoing,
      status: MessageStatus.pending,
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
      files: <FileAttachment>[_file('f-p', 'm-p', 'queued.bin', 4)],
    );

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('EF56', alias: 'Ef', online: false),
    );

    expect(find.text('排队中'), findsOneWidget);
    expect(find.textContaining('对方离线'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    // 0.2.22: two widgets now say 已取消 — the status chip (the durable record,
    // which is what this test has always pinned) and the snackbar (the tap is
    // now *answered*, not only applied). The state itself is what matters.
    expect(find.text('已取消'), findsWidgets);
    expect(find.text('排队中'), findsNothing);
  });

  testWidgets(
      'a lastPort == 0 peer cannot send; the composer is disabled '
      '(A2-15)', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend.lastPortZero();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('FFFF6666', alias: 'Frank', online: true, lastPort: 0),
    );

    // The note appears both on the list row and in the composer (the shell shows
    // the same peer on both sides), so the count is not fixed.
    expect(find.text('对方当前不可接收'), findsWidgets);
    final IconButton attach = tester
        .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.attach_file));
    expect(attach.onPressed, isNull);
  });

  testWidgets(
      'sending to an offline peer records a pending bubble immediately '
      '(PRD §4.2 / Q4)', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-s',
      deviceFingerprint: 'EF56',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.platform.setPickResult(FileKind.any, <String>['/tmp/photo.jpg']);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('EF56', alias: 'Ef', online: false),
    );

    // The single attachment entry (the old image/video/file trio was merged).
    // 0.2.33: that entry now opens a two-row menu — 「发送文件」 keeps the old
    // one-dialog pick, 「发送文件夹…」 is the new batch action — so picking a file
    // is one tap deeper than it was.
    await tester.tap(find.byTooltip('发送附件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发送文件'));
    await tester.pumpAndSettle();

    expect(find.text('photo.jpg'), findsOneWidget);
    expect(find.text('排队中'), findsOneWidget);
  });
}
