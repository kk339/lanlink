/// **右键气泡 → 删除该条消息** (0.2.36) — *"感觉还是要支持消息气泡删除，就是右键气泡，
/// 加一个删除该气泡的功能"*.
///
/// The scope is deliberately local, and this file is where that is pinned:
///
/// * the bubble goes and the **store** row goes with it — a *second* controller
///   loading the same repository does not see it again (the "重启后它又回来了"
///   shape, which the real durable half of this is
///   `store/test/message_delete_test.dart`: it re-opens the database file);
/// * **a send that is still running cannot be deleted** — the menu row is not
///   even built for `transferring`, which is what "findsNothing" below means;
/// * the **未发送成功** count follows the deletion, because it is derived from the
///   visible list rather than stored anywhere;
/// * the deletion is reached through the **two menus that already exist** — the
///   selection layer's toolbar for a text bubble (0.2.31 made that button the
///   selection layer's, so a new `GestureDetector` would repeat the 0.2.28
///   failure) and the attachment menu for a file bubble.
library;

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/draft_store.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/unsent_dismissal_store.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

/// The body a selection is dragged over. Long enough to wrap at the default test
/// surface, which is what makes "right-click *inside* the range" meaningful.
const String _longBody =
    '这是一段刚好四十个字的中文用来做排版基线的断言一段话写在这里正好四十个字结束了哦';

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'CC01',
      alias: 'Eve',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// A right-click (secondary tap) at [position].
Future<void> _rightClickAt(WidgetTester tester, Offset position) async {
  final TestGesture gesture = await tester.startGesture(
    position,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

/// A left-button mouse drag from [from] to [to] in three steps.
Future<void> _mouseDrag(WidgetTester tester, Offset from, Offset to) async {
  final TestGesture gesture =
      await tester.startGesture(from, kind: PointerDeviceKind.mouse);
  await tester.pump();
  for (final double t in <double>[0.34, 0.67, 1.0]) {
    await gesture.moveTo(Offset.lerp(from, to, t)!);
    await tester.pump();
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 「删除消息」 inside the selection toolbar (the text-bubble path).
Finder _toolbarDelete() => find.descendant(
      of: find.byType(AdaptiveTextSelectionToolbar),
      matching: find.text('删除消息'),
    );

/// The 「删除」 row of the attachment menu (the file-bubble path). The menu is
/// `fast_menu.dart`'s custom route, so its rows are keyed rather than being
/// `PopupMenuItem`s.
Finder _menuDelete() => find.byKey(const ValueKey<String>('fast-menu-delete'));

void main() {
  late FakeBackend backend;
  late ConversationController controller;

  const String conversationId = 'c-delete';

  /// Releases everything, **inside** the test body as well as in `tearDown`.
  ///
  /// A conversation holding a file whose transfer is not finished — which
  /// includes a `failed` row, because the fake seeds its progress without an
  /// error — keeps the controller's 1 Hz progress ticker alive, and
  /// `flutter_test` fails a test that leaves a `Timer` pending at teardown
  /// (`progress_resume_test.dart` disposes for exactly this reason).
  bool disposed = false;
  void disposeAll() {
    if (disposed) {
      return;
    }
    disposed = true;
    controller.dispose();
    backend.dispose();
  }

  setUp(() {
    disposed = false;
    backend = FakeBackend();
    backend.repo.addConversation(
      id: conversationId,
      deviceFingerprint: 'CC01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    controller = ConversationController(
      repo: backend.repo,
      orchestrator: TransferOrchestrator(
        repo: backend.repo,
        transfer: backend.transfer,
      ),
      platform: backend.platform,
      ids: backend.ids,
      clock: backend.clock,
      conversationId: conversationId,
      drafts: ComposerDraftStore(),
      // Private per test: the shared store is process-wide and persisted.
      dismissals: UnsentDismissalStore(),
    );
  });

  tearDown(disposeAll);

  /// Seeds one text message.
  ChatMessage seedText({
    required String id,
    String body = _longBody,
    MessageDirection direction = MessageDirection.incoming,
    MessageStatus status = MessageStatus.done,
    int minutes = 0,
  }) =>
      backend.repo.addMessage(
        id: id,
        conversationId: conversationId,
        direction: direction,
        status: status,
        kind: MessageKind.text,
        textBody: body,
        createdAt: fixedEpoch.add(Duration(minutes: minutes)),
        updatedAt: fixedEpoch.add(Duration(minutes: minutes)),
      );

  /// Seeds one file message carrying a single attachment.
  ChatMessage seedFile({
    required String id,
    MessageDirection direction = MessageDirection.incoming,
    MessageStatus status = MessageStatus.done,
    int minutes = 0,
  }) =>
      backend.repo.addMessage(
        id: id,
        conversationId: conversationId,
        direction: direction,
        status: status,
        kind: MessageKind.file,
        createdAt: fixedEpoch.add(Duration(minutes: minutes)),
        updatedAt: fixedEpoch.add(Duration(minutes: minutes)),
        files: <FileAttachment>[
          FileAttachment(
            id: 'f-$id',
            messageId: id,
            fileName: '$id.bin',
            size: 128,
            sha256: '00',
            localPath: '/src/$id.bin',
          ),
        ],
      );

  /// Mounts the real thread over [repo]-backed [ctrl].
  Future<void> pumpThread(
    WidgetTester tester, {
    ConversationController? ctrl,
  }) async {
    final ConversationController target = ctrl ?? controller;
    // Read the history **before** mounting: a thread still in `Loading` paints
    // the indeterminate spinner, and `pumpAndSettle` would never settle.
    target.load();
    await pumpApp(
      tester,
      Scaffold(
        body: ConversationThread(controller: target, peer: _peer()),
      ),
      backend: backend,
      settle: true,
    );
  }

  testWidgets(
      'A: text bubble — a right click on a selection offers 复制 / 全选 / '
      '删除消息, and 删除消息 removes the bubble and the store row',
      (WidgetTester tester) async {
    seedText(id: 'm-text');
    await pumpThread(tester);

    final Finder body = find.text(_longBody);
    expect(body, findsOneWidget);

    // Drag a partial selection, then right-click **inside** it. (A right click
    // outside the range collapses the selection — Flutter then drops 复制 too,
    // and that case is asserted separately below.)
    final Rect box = tester.getRect(body);
    final Offset from =
        box.topLeft + Offset(box.width * 0.06, box.height * 0.25);
    final Offset to = box.topLeft + Offset(box.width * 0.60, box.height * 0.25);
    await _mouseDrag(tester, from, to);
    await _rightClickAt(tester, Offset.lerp(from, to, 0.5)!);

    // ★ The 0.2.31/0.2.35 toolbar is untouched: same widget, same Flutter
    // labels, same entries — 「删除消息」 is **appended**, not a new menu.
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AdaptiveTextSelectionToolbar),
        matching: find.text('复制'),
      ),
      findsOneWidget,
      reason: '复制 for the dragged range must survive (0.2.31)',
    );
    expect(
      find.descendant(
        of: find.byType(AdaptiveTextSelectionToolbar),
        matching: find.text('全选'),
      ),
      findsOneWidget,
      reason: 'and 全选 must still be Flutter\'s own row (0.2.35 labels)',
    );
    expect(_toolbarDelete(), findsOneWidget,
        reason: 'the new entry belongs in the selection toolbar');

    await tester.tap(_toolbarDelete());
    await tester.pumpAndSettle();

    expect(find.text(_longBody), findsNothing,
        reason: 'the bubble must disappear from the timeline');
    expect(
      backend.repo.history(conversationId),
      isEmpty,
      reason: 'and the row must be gone from the store, not only from the view',
    );
    expect(find.text('已删除'), findsOneWidget,
        reason: 'every action answers: the 0.2.36 floating notice says so');
  });

  testWidgets(
      'A2: the deletion survives a reload — a brand-new controller on the same '
      'repository does not see the message', (WidgetTester tester) async {
    seedText(id: 'm-gone', body: '要删掉的一条', minutes: 0);
    seedText(id: 'm-keep', body: '留下的一条', minutes: 1);
    await pumpThread(tester);

    // Delete via the toolbar, exactly as a user would.
    final Rect box = tester.getRect(find.text('要删掉的一条'));
    final Offset from =
        box.topLeft + Offset(box.width * 0.10, box.height * 0.5);
    final Offset to = box.topLeft + Offset(box.width * 0.70, box.height * 0.5);
    await _mouseDrag(tester, from, to);
    await _rightClickAt(tester, Offset.lerp(from, to, 0.5)!);
    expect(_toolbarDelete(), findsOneWidget);
    await tester.tap(_toolbarDelete());
    await tester.pumpAndSettle();

    expect(backend.repo.history(conversationId).map((m) => m.id), <String>[
      'm-keep',
    ]);

    // A fresh controller = "the thread, opened again". It reads the store, so a
    // deletion that only touched the view would bring the bubble straight back.
    final ConversationController reopened = ConversationController(
      repo: backend.repo,
      orchestrator: TransferOrchestrator(
        repo: backend.repo,
        transfer: backend.transfer,
      ),
      platform: backend.platform,
      ids: backend.ids,
      clock: backend.clock,
      conversationId: conversationId,
      drafts: ComposerDraftStore(),
      dismissals: UnsentDismissalStore(),
    );
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(
      reopened.messages.valueOrNull?.map((ChatMessage m) => m.id),
      <String>['m-keep'],
      reason: 're-opening the conversation must not resurrect the bubble',
    );
  });

  testWidgets(
      'B: file bubble — the attachment menu gains 删除, and choosing it removes '
      'the bubble and its row', (WidgetTester tester) async {
    seedFile(id: 'm-file');
    await pumpThread(tester);

    await _rightClickAt(tester, tester.getCenter(find.text('m-file.bin')));
    expect(_menuDelete(), findsOneWidget,
        reason: 'the file bubble\'s own menu is where a file message is deleted');

    await tester.tap(_menuDelete());
    await tester.pumpAndSettle();

    expect(find.text('m-file.bin'), findsNothing);
    expect(backend.repo.history(conversationId), isEmpty,
        reason: 'and the attachment/transfer rows go with it — the controller '
            'delegates the whole sub-tree to the store');
    expect(find.text('已删除'), findsOneWidget);
  });

  testWidgets(
      'C: a TRANSFERRING text bubble offers no 删除消息 at all',
      (WidgetTester tester) async {
    seedText(
      id: 'm-sending',
      direction: MessageDirection.outgoing,
      status: MessageStatus.transferring,
    );
    await pumpThread(tester);

    final Rect box = tester.getRect(find.text(_longBody));
    final Offset from =
        box.topLeft + Offset(box.width * 0.06, box.height * 0.25);
    final Offset to = box.topLeft + Offset(box.width * 0.60, box.height * 0.25);
    await _mouseDrag(tester, from, to);
    await _rightClickAt(tester, Offset.lerp(from, to, 0.5)!);

    // The toolbar itself is still there — the selection layer is unchanged.
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    expect(_toolbarDelete(), findsNothing,
        reason: '删除的是一条记录，但这条还在传：菜单里不能出现删除');
    expect(backend.repo.history(conversationId), hasLength(1),
        reason: 'and nothing may have been deleted');
  });

  testWidgets(
      'C2: a TRANSFERRING file bubble offers no 删除 in the attachment menu',
      (WidgetTester tester) async {
    seedFile(
      id: 'm-sending',
      direction: MessageDirection.outgoing,
      status: MessageStatus.transferring,
    );
    await pumpThread(tester);

    await _rightClickAt(tester, tester.getCenter(find.text('m-sending.bin')));

    // The menu opened (it is the attachment menu), and 删除 is simply one of the
    // rows that is **not built** — the menu's own rule for an action that cannot
    // run. The other entries are untouched.
    expect(find.byKey(const ValueKey<String>('fast-menu-open')), findsOneWidget);
    expect(_menuDelete(), findsNothing,
        reason: 'a message that is still transferring must not be deletable');

    // A live transfer keeps the controller's ticker running; release it inside
    // the body so `flutter_test`'s "no pending Timer" invariant holds.
    disposeAll();
  });

  testWidgets(
      'D: the 未发送成功 banner counts what is left — 3 → 2 → gone',
      (WidgetTester tester) async {
    for (int i = 0; i < 3; i++) {
      seedFile(
        id: 'f$i',
        direction: MessageDirection.outgoing,
        status: MessageStatus.failed,
        minutes: i,
      );
    }
    await pumpThread(tester);

    expect(find.text('3 条没有发送成功'), findsOneWidget);

    // Delete one failed bubble through its attachment menu.
    await _rightClickAt(tester, tester.getCenter(find.text('f2.bin')));
    await tester.tap(_menuDelete());
    await tester.pumpAndSettle();

    expect(find.text('2 条没有发送成功'), findsOneWidget,
        reason: 'the count is derived from the visible list, so a deletion must '
            'move it');

    // …and again, down to one: below two the row has nothing to batch, so it is
    // gone entirely (the 0.2.24 rule).
    await _rightClickAt(tester, tester.getCenter(find.text('f1.bin')));
    await tester.tap(_menuDelete());
    await tester.pumpAndSettle();

    expect(find.textContaining('没有发送成功'), findsNothing,
        reason: 'with a single failure left there is no batch to offer');
    expect(backend.repo.history(conversationId), hasLength(1));

    // A `failed` file row still keeps the ticker alive (the fake seeds its
    // progress with no error) — release it inside the body.
    disposeAll();
  });

  testWidgets(
      'E: a right click with NO selection is the MESSAGE menu, so 删除消息 is '
      'there (0.2.38 — the user no longer has to select text first)',
      (WidgetTester tester) async {
    seedText(id: 'm-text');
    await pumpThread(tester);

    await _rightClickAt(tester, tester.getCenter(find.text(_longBody)));

    // 0.2.36 gated 「删除消息」 on a selection, which on a desktop meant "select a
    // word, then right click" — *"右键删除这一块确实啊，文字有点不好说"*. A right
    // click with nothing selected is now the whole message's menu.
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    expect(_toolbarDelete(), findsOneWidget);
    // …and it is a menu, not an action: the row is still there until it is used.
    expect(backend.repo.history(conversationId), hasLength(1));
  });

  testWidgets(
      'F: nothing else moved — the 「复制」 button under the bubble, 重新发送 and '
      '取消 are untouched', (WidgetTester tester) async {
    seedText(
      id: 'm-failed',
      direction: MessageDirection.outgoing,
      status: MessageStatus.failed,
    );
    seedFile(
      id: 'm-file',
      direction: MessageDirection.outgoing,
      status: MessageStatus.failed,
      minutes: 1,
    );
    await pumpThread(tester);

    // 0.2.31's copy button is still there on the text bubble.
    expect(find.byKey(const ValueKey<String>('bubble-copy-text')), findsOneWidget);
    // 0.2.22's retry path is still there on the failed bubbles.
    expect(find.text('重新发送'), findsWidgets);
    // And the file bubble's menu still carries its existing rows.
    await _rightClickAt(tester, tester.getCenter(find.text('m-file.bin')));
    expect(find.byKey(const ValueKey<String>('fast-menu-open')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('fast-menu-copyName')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('fast-menu-details')),
      findsOneWidget,
    );
    expect(_menuDelete(), findsOneWidget);

    // Same ticker note as case D — this test holds two `failed` file rows.
    disposeAll();
  });
}
