/// Widget walkthrough of the PRD §6 edge cases, E1–E13 (+ E15), re-anchored on
/// the three-pane shell (design §8.1 / §8.2).
///
/// One focused test per edge case, each announced by its `E<n>` tag. Every
/// fixture comes from `data/fake/scenarios.dart` (one line per case); the
/// assertions are behavioural — what the user sees — never internal structure.
///
/// **Mount contract (design §8.1):** E1/E2/E5/E6/E10/E13 mount the conversations
/// or archived module (`pumpShell`); E3/E4/E7/E9/E11/E12 mount
/// `ShellPage(initialPeer: …)`; E8 mounts `ShellPage(initialModule: recentFiles)`.
///
/// **E9 change (design §8.2):** the old "thumbnail is always NULL ⇒ always a
/// type icon, never an `Image`" is **retired** (the M4 rework does real
/// thumbnails). E9 now asserts the image path reads the port and falls back to a
/// type icon only when the read yields nothing.
///
/// | Test | Edge case |
/// | --- | --- |
/// | peer goes offline | E1 |
/// | restart sweeps a mid-flight transfer | E2 |
/// | receiver renamed a same-named file | E3 |
/// | several messages at the same instant | E4 |
/// | peer reinstalled (fingerprint changed) | E5 |
/// | `last_port == 0` (not receivable) | E6 |
/// | `size == -1` (unknown size) | E7 |
/// | `mime == null` (extension fallback) | E8 |
/// | thumbnails are real, read the port, fall back on a null read | E9 (rewritten) |
/// | discovery failed to start | E10 |
/// | multi-file message (+ a live in-flight one) | E11 |
/// | long CJK / emoji file name | E12 |
/// | first run / no history DB | E13 |
/// | thumbnail failed / source gone | E15 |
/// | right pane never collapses to an empty state | F26 |
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/panes/file_detail.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';
import 'package:lanlink_app/ui/widgets/device_row.dart';
import 'package:lanlink_app/ui/widgets/error_banner.dart';
import 'package:lanlink_app/ui/widgets/file_thumbnail.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';
import 'package:lanlink_app/ui/widgets/type_icon.dart';

import '../support/pump_app.dart';

/// The peer handed straight to `ShellPage(initialPeer: …)` (dialable by default).
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

void main() {
  // ── E1 ─────────────────────────────────────────────────────────────────
  testWidgets('E1 对端下线：右栏状态转离线，会话历史照常显示（本地历史价值兑现点）',
      (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e1PeerWentOffline();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('E1000001', alias: 'Eve Laptop', online: true),
    );
    // The right pane's conversation header is where the online marker lives.
    expect(find.text('在线'), findsOneWidget);

    // The peer goes offline (PeerRegistry.sweepOffline drives this in the app).
    backend.discovery.wentOffline(backend.discovery.online.single);
    await tester.pumpAndSettle();
    expect(find.text('离线'), findsOneWidget);

    // History is never lost. Per PRD §6 E1 the in-flight message becomes
    // `failed` — the startup cleanup sweeps `transferring` the moment the app
    // starts, so "传输中" can never survive an app start (that is E2's design).
    expect(find.byType(MessageBubble), findsNWidgets(2));
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('失败（可重新发送）'), findsOneWidget);
    expect(find.text('传输中'), findsNothing);
  });

  // ── E2 ─────────────────────────────────────────────────────────────────
  testWidgets('E2 传输中关闭 App：启动僵尸清理把非终态转 failed，排队中的 pending 保留',
      (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e2InterruptedTransfer();
    addTearDown(backend.dispose);

    // Mounting the shell runs the startup (`HomeController.init` → sweep).
    await pumpShell(tester, backend: backend, settle: true);

    expect(
      backend.repo.messagesByStatus(const <MessageStatus>{
        MessageStatus.transferring,
        MessageStatus.awaitingConfirm
      }),
      isEmpty,
    );
    expect(
        backend.repo.messagesByStatus(
            const <MessageStatus>{MessageStatus.failed}).length,
        2);
    expect(
        backend.repo.messagesByStatus(
            const <MessageStatus>{MessageStatus.pending}).length,
        1);

    await tester.tap(find.widgetWithText(DeviceRow, 'Eve Laptop'));
    await tester.pumpAndSettle();
    // Nothing is left stuck "in flight"; the two are shown as failed.
    expect(find.text('失败（可重新发送）'), findsNWidgets(2));
    expect(find.text('排队中'), findsOneWidget);
    expect(find.text('传输中'), findsNothing);
    expect(find.text('等待对方确认'), findsNothing);
  });

  // ── E3 ─────────────────────────────────────────────────────────────────
  testWidgets('E3 接收端同名文件被改名：界面显示实际落盘名（可见被改名）', (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e3RenamedOnReceive();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('E3000003', alias: 'Eve Laptop', online: true),
    );

    expect(find.text('photo (1).jpg'), findsOneWidget);
  });

  // ── E4 ─────────────────────────────────────────────────────────────────
  testWidgets('E4 同一时刻多条消息：按 id 去重、不合并，三条都显示', (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e4SameInstantMessages();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('E4000004', alias: 'Eve Laptop', online: true),
    );

    expect(find.byType(MessageBubble), findsNWidgets(3));
    expect(find.text('part-0.bin'), findsOneWidget);
    expect(find.text('part-1.bin'), findsOneWidget);
    expect(find.text('part-2.bin'), findsOneWidget);
  });

  // ── E5 ─────────────────────────────────────────────────────────────────
  testWidgets('E5 对方重装：旧会话归档后首页不可见、归档入口可见，且出现新设备行',
      (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e5PeerReinstalled();
    addTearDown(backend.dispose);

    // Conversations module: the new device is present; the old thread's history
    // (its `old.pdf` preview) is not shown.
    await pumpShell(tester, backend: backend, settle: true);
    expect(find.byType(DeviceRow), findsWidgets);
    expect(find.text('Eve New Phone'), findsOneWidget);
    expect(find.textContaining('old.pdf'), findsNothing);

    // The archived module keeps the old history reachable (Q8 / U11).
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpShell(
      tester,
      initialModule: ShellModule.archived,
      backend: backend,
      settle: true,
    );
    expect(find.text('Eve (old)'), findsOneWidget);
    expect(find.textContaining('old.pdf'), findsOneWidget);
  });

  // ── E6 ─────────────────────────────────────────────────────────────────
  testWidgets('E6 last_port = 0：行标注"对方当前不可接收"，不可发送',
      (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e6NotReceivable();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    expect(find.text(DeviceRow.notReceivable), findsOneWidget);
  });

  // ── E7 ─────────────────────────────────────────────────────────────────
  testWidgets('E7 size = -1：显示"未知大小"，不显示 0 B / -1 B',
      (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e7UnknownSize();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('E7000007', alias: 'Eve Laptop', online: true),
    );

    expect(find.text('未知大小'), findsOneWidget);
    expect(find.text('-1'), findsNothing);
    expect(find.text('0 B'), findsNothing);
  });

  // ── E8 ─────────────────────────────────────────────────────────────────
  testWidgets('E8 mime = null：按扩展名回落分类，仍在"全部"且进入"图片"tab',
      (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e8NullMime();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      initialModule: ShellModule.recentFiles,
      backend: backend,
      settle: true,
    );
    expect(find.text('photo.png'), findsOneWidget); // 全部

    await tester.tap(find.text('图片'));
    await tester.pumpAndSettle();
    expect(find.text('photo.png'), findsOneWidget); // extension fallback → 图片
  });

  // ── E9 (rewritten — design §8.2) ───────────────────────────────────────
  // The old assertion ("thumbnail 恒 NULL ⇒ 一律类型图标，绝无 Image") is retired:
  // the rework does real thumbnails. An image now takes the thumbnail path and
  // reads the port once; with no bytes preset the read yields null and the slot
  // falls back to the type icon (no broken image, no error).
  testWidgets('E9 图片走真缩略图路径：读端口一次，取不到字节则回落类型图标（旧 E9 作废）',
      (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e9ThumbnailNull();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('E9000009', alias: 'Eve Laptop', online: true),
    );

    expect(find.byType(FileThumbnail), findsWidgets); // the image slot exists
    expect(find.byType(TypeIcon), findsWidgets); // no bytes → icon fallback
    expect(find.byType(Image), findsNothing);
    expect(backend.platform.readRequests, contains('/received/pic.png'));
    expect(tester.takeException(), isNull);
  });

  // ── E10 ────────────────────────────────────────────────────────────────
  testWidgets('E10 发现层启动失败：常驻错误条 + 人话原因 + 重试，不静默', (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e10DiscoveryFailed();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);
    expect(find.byType(ErrorBanner), findsNothing);

    // Injected after start: `FakePeerDiscovery.start()` resets a seeded phase.
    backend.discovery.fail(Scenarios.e10ErrorMessage);
    await tester.pumpAndSettle();

    expect(find.byType(ErrorBanner), findsOneWidget);
    expect(find.text(Scenarios.e10ErrorMessage), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  // ── E11 ────────────────────────────────────────────────────────────────
  // ⚠️ Unlike the old page, mounting the shell **always** runs the startup sweep
  // (`HomeController.init` → `failInterruptedMessages`), so a seeded
  // `transferring` message can never survive an app start (E1/E2's design). The
  // in-flight case is therefore driven **live**: the message is recorded through
  // `recordOutgoing` after the mount — which, unlike the *seeding* `addMessage`,
  // emits a `MessageAdded` the running controller actually sees — exactly as the
  // orchestrator would add it while the app is running.
  testWidgets('E11 多文件消息：列出全部文件名；挂载后到达的在途消息显示进度', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(800, 1600));
    final FakeBackend backend = Scenarios.e11MultiFile();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('E1100011', alias: 'Eve Laptop', online: true),
    );

    // The done message (3 files) renders every name; the seeded `transferring`
    // message was swept to `failed` (so no "传输中" yet) but still lists its files.
    for (final String name in <String>[
      'one.txt',
      'two.png',
      'three.zip',
      'four.bin',
      'five.bin',
    ]) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    expect(find.text('传输中'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    // A live in-flight message. Root cause C (E11), honestly: the miss was
    // **not** a lazy viewport. `repo.addMessage` is a *seeding* helper — it
    // mutates the maps without emitting a `MessageAdded`, so the already-listening
    // `ConversationController` never learns of it and the bubble does not exist at
    // any window size. Record it the way the app does (`recordOutgoing` emits
    // `MessageAdded`), then walk the status along the legal edges up to
    // `transferring`.
    final SendHandle live = backend.repo.recordOutgoing(
      peer: _peer('E1100011', alias: 'Eve Laptop', online: true),
      files: <OutgoingFile>[
        OutgoingFile(
          id: 'f-e11-live-1',
          fileName: 'live-one.bin',
          size: 400,
          sha256: 'AA',
          localPath: '/src/live-one.bin',
        ),
        OutgoingFile(
          id: 'f-e11-live-2',
          fileName: 'live-two.bin',
          size: 500,
          sha256: 'AA',
          localPath: '/src/live-two.bin',
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

    expect(find.text('live-one.bin'), findsOneWidget);
    expect(find.text('live-two.bin'), findsOneWidget);
    expect(find.text('传输中'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  // ── E12 ────────────────────────────────────────────────────────────────
  testWidgets('E12 中文 / 表情 / 超长文件名：单行截断、不溢出崩版', (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e12LongName();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('E1200012', alias: 'Eve Laptop', online: true),
    );

    // A layout overflow would surface as an exception here.
    expect(tester.takeException(), isNull);
    expect(find.text(Scenarios.e12LongFileName), findsOneWidget);
  });

  // ── E13 ────────────────────────────────────────────────────────────────
  testWidgets('E13 首次运行 / 库不存在：各模块走空态，不弹错误', (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e13FreshInstall();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);
    expect(find.text('还没有发现设备'), findsOneWidget);
    expect(find.byType(ErrorBanner), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpShell(
      tester,
      initialModule: ShellModule.recentFiles,
      backend: backend,
      settle: true,
    );
    expect(find.text('还没有文件记录'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('E1300013', alias: 'Eve', online: false),
    );
    expect(find.text('还没有传输记录'), findsOneWidget);
  });

  // ── E15 (new — design §8.3) ────────────────────────────────────────────
  testWidgets('E15 源文件已不在：不发起读取（端口未被调用），回落类型图标', (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e15ThumbnailFallback();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      initialModule: ShellModule.recentFiles,
      backend: backend,
      settle: true,
    );

    expect(find.text('文件已不在原位置'), findsOneWidget); // the gone image
    expect(find.byType(TypeIcon), findsWidgets);
    expect(find.byType(Image), findsNothing);
    // The gone source is never read (PRD §8-G30).
    expect(backend.platform.readRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  // ── F26 (new — design §8.3) ────────────────────────────────────────────
  testWidgets('右栏文件详情不塌成空态：选中文件后切 tab / 输不匹配搜索词，右栏仍显示该文件',
      (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      initialModule: ShellModule.recentFiles,
      backend: backend,
      settle: true,
    );

    await tester.tap(find.widgetWithText(FileTile, 'photo.png'));
    await tester.pumpAndSettle();
    expect(find.byType(FileDetail), findsOneWidget);

    // Switch to a tab that filters the file out of the middle pane — the right
    // pane must still show the selected file (it reads the **unfiltered** `all`).
    await tester.tap(find.text('视频'));
    await tester.pumpAndSettle();
    expect(find.byType(FileDetail), findsOneWidget);

    // A non-matching query must not collapse it either.
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的文件'), findsOneWidget); // the middle pane is empty
    expect(find.byType(FileDetail), findsOneWidget); // the right pane is not
  });

  // ── conversation thread smoke (E1/E2 above cover the timeline) ──────────
  testWidgets('the right pane binds the selected conversation (design §1.4)',
      (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('AAAA1111', alias: 'Alice Laptop', online: true),
    );

    expect(find.byType(ConversationThread), findsOneWidget);
  });
}
