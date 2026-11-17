/// The **desktop message menu** on a text bubble (0.2.38) — *"右键删除这一块确实啊，
/// 文字有点不好说"*.
///
/// 0.2.36 put 「删除消息」 inside `_selectionContextMenu`, which is only built when
/// there **is** a selection — so on a desktop, right-clicking a bubble without
/// selecting anything first offered nothing at all, and deleting a message meant
/// "drag a selection, then right-click". The reference app splits the two jobs:
///
/// * **the whole message** → right click (desktop) / long press (phone) → a menu
///   that owns 删除;
/// * **the selected text** → the selection toolbar → 复制 / 全选 (and, here, 删除
///   because the phone has no other door).
///
/// This file pins the split. **Criterion 1 must fail before the change** — that is
/// checked and quoted in the commit message, not assumed: this exact spot has a
/// history of "silently dead right click, tests green" (0.2.28).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/draft_store.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

const String _body = '这是一段可以直接右键的文字消息';
const String _conversationId = 'c-menu';

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'CC01',
      alias: '小甲',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// Mounts the thread with one message of [kind].
///
/// Every case runs on the **real desktop platform** (`TargetPlatform.windows`):
/// `SelectableRegion`'s right-click handling branches per platform, and the app
/// only ever ships this menu on Windows/macOS/Linux — a test on the default
/// (android) target would be proving the wrong branch.
Future<FakeBackend> _pump(
  WidgetTester tester, {
  Size size = const Size(1400, 1000),
  bool mobile = false,
  MessageKind kind = MessageKind.text,
  MessageStatus status = MessageStatus.done,
}) async {
  useSurfaceSize(tester, size);
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.repo.addConversation(
    id: _conversationId,
    deviceFingerprint: 'CC01',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.repo.addMessage(
    id: 'm-1',
    conversationId: _conversationId,
    direction: MessageDirection.incoming,
    status: status,
    kind: kind,
    textBody: kind == MessageKind.text ? _body : null,
    files: kind == MessageKind.file
        ? const <FileAttachment>[
            FileAttachment(
              id: 'f-1',
              messageId: 'm-1',
              fileName: 'notes.txt',
              size: 12,
              sha256: 'AA',
              localPath: r'C:\recv\notes.txt',
            ),
          ]
        : const <FileAttachment>[],
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
  );
  backend.platform.setMobile(mobile);
  final ConversationController controller = ConversationController(
    repo: backend.repo,
    orchestrator: TransferOrchestrator(
      repo: backend.repo,
      transfer: backend.transfer,
    ),
    platform: backend.platform,
    ids: backend.ids,
    clock: backend.clock,
    conversationId: _conversationId,
    drafts: ComposerDraftStore(),
  );
  addTearDown(controller.dispose);
  unawaited(controller.load());
  await pumpApp(
    tester,
    Scaffold(
      body: ConversationThread(controller: controller, peer: _peer()),
    ),
    backend: backend,
    settle: true,
  );
  return backend;
}

/// Runs [body] with the **desktop platform** selected, and puts it back before
/// the body returns.
///
/// `addTearDown` is not enough: the test binding verifies that no foundation
/// debug variable was left changed **at the end of the body**, before tear-downs
/// run — so the reset has to happen in a `finally` here, or every case fails with
/// "The value of a foundation debug variable was changed by the test" and hides
/// the real assertion.
Future<void> _onWindows(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// A right click (secondary button down + up) at [at].
Future<void> _rightClickAt(WidgetTester tester, Offset at) async {
  final TestGesture gesture = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

/// A left-button drag across the body — the "select some words" gesture.
Future<void> _selectSomeText(WidgetTester tester) async {
  final Rect box = tester.getRect(find.text(_body));
  final Offset from = box.topLeft + Offset(box.width * 0.05, box.height * 0.5);
  final Offset to = box.topLeft + Offset(box.width * 0.55, box.height * 0.5);
  final TestGesture gesture =
      await tester.startGesture(from, kind: PointerDeviceKind.mouse);
  await tester.pump();
  await gesture.moveTo(Offset.lerp(from, to, 0.5)!);
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      '★ criterion 1: desktop — right-clicking a text bubble with NOTHING selected '
      'opens the message menu, and 删除消息 really deletes it',
      (WidgetTester tester) async {
    await _onWindows(() async {
    final FakeBackend backend = await _pump(tester);

    await _rightClickAt(tester, tester.getCenter(find.text(_body)));

    // ★ Before 0.2.38 this was the failing line: with no selection the only
    // thing on screen was Flutter's 全选, which is the "文字有点不好说" the user
    // reported.
    expect(find.text('复制文字'), findsOneWidget,
        reason: 'the whole-message menu must exist without a selection');
    expect(find.text('删除消息'), findsOneWidget);

    await tester.tap(find.text('删除消息'));
    await tester.pumpAndSettle();

    expect(find.byType(MessageBubble), findsNothing,
        reason: 'the bubble must be gone from the timeline');
    expect(backend.repo.history(_conversationId), isEmpty,
        reason: 'and gone from the repository, or it would return on the next load');
    });
  });

  testWidgets(
      '★ criterion 2: desktop — with a selection, the SELECTION toolbar comes up '
      'and the message menu does NOT (one click, one menu)',
      (WidgetTester tester) async {
    await _onWindows(() async {
    await _pump(tester);
    await _selectSomeText(tester);

    final Rect box = tester.getRect(find.text(_body));
    // Right-click **inside** the selection (a click outside it would collapse the
    // range first, which is the "no selection" case above).
    await _rightClickAt(
      tester,
      Offset(box.left + box.width * 0.2, box.center.dy),
    );

    expect(
      find.descendant(
        of: find.byType(AdaptiveTextSelectionToolbar),
        matching: find.text('复制'),
      ),
      findsOneWidget,
      reason: 'the range toolbar — not the bubble\'s own 「复制」 button',
    );
    expect(find.text('全选'), findsOneWidget);
    expect(find.text('删除消息'), findsOneWidget,
        reason: '0.2.36 keeps 删除消息 in the toolbar — the phone deletes from '
            'here and has no other door');
    expect(find.text('复制文字'), findsNothing,
        reason: 'two menus for one right click is the bug this asserts against');
    });
  });

  testWidgets(
      '★ criterion 3: desktop — a FILE bubble still opens the attachment menu and '
      'never the text menu', (WidgetTester tester) async {
    await _onWindows(() async {
    await _pump(tester, kind: MessageKind.file);

    await _rightClickAt(tester, tester.getCenter(find.byType(FileTile)));

    expect(find.text('复制文件名'), findsOneWidget,
        reason: 'the file menu is unchanged');
    expect(find.text('复制文字'), findsNothing);
    expect(find.text('删除消息'), findsNothing);
    });
  });

  testWidgets(
      '★ criterion 4 (red line): phone — a long press still goes through selection '
      'and its toolbar still offers 删除消息', (WidgetTester tester) async {
    await _onWindows(() async {
    await _pump(tester, size: const Size(600, 1200), mobile: true);

    await tester.longPress(find.text(_body));
    await tester.pumpAndSettle();

    expect(find.text('删除消息'), findsOneWidget,
        reason: 'the phone deletes from the selection toolbar — this must not '
            'regress while the desktop gets a menu of its own');
    expect(find.text('复制文字'), findsNothing,
        reason: 'the desktop message menu is desktop-only');
    });
  });

  testWidgets(
      '★ criterion 5: an in-flight message — the menu opens, but 删除消息 is NOT '
      'built (the item that cannot work is not drawn)',
      (WidgetTester tester) async {
    await _onWindows(() async {
    await _pump(tester, status: MessageStatus.transferring);

    await _rightClickAt(tester, tester.getCenter(find.text(_body)));

    expect(find.text('复制文字'), findsOneWidget,
        reason: 'copying an in-flight message\'s text is still useful');
    expect(find.text('删除消息'), findsNothing,
        reason: 'a transferring send must not be deletable (canDelete)');
    });
  });

  testWidgets(
      '★ criterion 6: no fake entries — 置顶 / 翻译 / 引用 / 收藏 are not in the menu',
      (WidgetTester tester) async {
    await _onWindows(() async {
    await _pump(tester);

    await _rightClickAt(tester, tester.getCenter(find.text(_body)));

    // 转发 is **no longer** in this list (0.2.46): 「转发到…」 is a real
    // capability now, and `test/widget/forward_to_many_test.dart` pins it. What
    // stays here is the other half of the rule — the entries the app does not
    // have are still not drawn, and "转发到…" must not be a menu about nothing.
    for (final String invented in <String>['置顶', '翻译', '引用', '收藏']) {
      expect(find.text(invented), findsNothing,
          reason: '"$invented" is a capability this app does not have — the '
              'project rule is that a control that cannot work is not drawn');
    }
    expect(find.text('转发到…'), findsOneWidget,
        reason: '0.2.46: the whole-message menu owns the forward entry');
    });
  });

  testWidgets(
      '★ 0.2.48 criterion 5: right-clicking EMPTY space opens NO message menu — '
      'not even the last bubble\'s', (WidgetTester tester) async {
    await _onWindows(() async {
      await _pump(tester);

      // 1. Open the bubble's own menu once, so `_selectionMessageId` is armed
      //    with a real id (that is the stale value the defect reused).
      await _rightClickAt(tester, tester.getCenter(find.text(_body)));
      expect(find.text('复制文字'), findsOneWidget);

      // 2. Dismiss it and make sure it is really gone — otherwise step 3 would
      //    be asserting about a menu that never closed.
      final Offset empty = _emptyPoint(tester);
      await tester.tapAt(empty);
      await tester.pumpAndSettle();
      expect(find.text('复制文字'), findsNothing);
      expect(find.text('删除消息'), findsNothing);

      // 3. Right-click that empty space. Windows sends this to the app too (the
      //    `SelectableRegion` above the timeline hands every right click to our
      //    builder), and before this release the builder answered with the menu
      //    of the message last pressed — 「删除消息」 included, which deleted a
      //    message the user had not clicked on.
      await _rightClickAt(tester, empty);

      expect(find.text('复制文字'), findsNothing,
          reason: 'empty space has no message to be about');
      expect(find.text('删除消息'), findsNothing,
          reason: 'and it certainly must not offer to delete another message');
      expect(find.text('多选'), findsNothing);
      expect(find.text('转发到…'), findsNothing);
      expect(find.text('全选'), findsNothing,
          reason: 'no selection ⇒ nothing to select-all either');

      // 4. …and the bubble's own menu still works, i.e. the fix is not "never
      //    show a menu".
      await _rightClickAt(tester, tester.getCenter(find.text(_body)));
      expect(find.text('复制文字'), findsOneWidget);
      expect(find.text('删除消息'), findsOneWidget);
    });
  });
}

/// A point inside the timeline that is **not** over any message.
///
/// The timeline is the thread's `SelectionArea`; with one short message the list
/// stacks it at the top and everything below is the scrollable's empty space —
/// the place a user's right click used to conjure up another message's menu.
Offset _emptyPoint(WidgetTester tester) {
  final Rect area = tester.getRect(find.byType(SelectionArea));
  return Offset(area.center.dx, area.bottom - 20);
}
