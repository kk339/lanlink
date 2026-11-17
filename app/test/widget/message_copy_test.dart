/// Widget tests for **copying a text message** — *"我发文字出去电脑端貌似没办法复制
/// 文本"* (0.2.27) → *"选中右键就没法单独复制我选中的那部分了"* (0.2.31).
///
/// **The split this file pins down (0.2.31):** there are two copies, and they no
/// longer fight for one gesture.
///
/// * a **right click on a selection** belongs to the timeline's `SelectionArea`
///   — Flutter's own menu, which offers 「复制」 for **the range the user
///   dragged**. 0.2.27–0.2.30 could not do this: the bubble's own
///   `onSecondaryTapDown` had to sit *inside* the selection layer to win the
///   arena, so the layer never saw a right click at all and the user could only
///   ever get the whole message;
/// * **copy the whole message** is the 「复制」 **button** under a desktop bubble
///   (`bubble_copy_button_test.dart` owns that one).
///
/// What each case here proves:
/// * the desktop right click **no longer opens 「复制文字」** — it opens the
///   selection layer's menu, and that menu's 复制 puts the **dragged range** (a
///   strict part) on the clipboard;
/// * a **file** bubble keeps its own attachment menu and never grows either text
///   entry (it has no selection layer, so nothing competes there);
/// * a **phone** has no right button: a long press selects and the platform
///   toolbar copies — and there is no 「复制」 button under the bubble.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// The message body used everywhere below.
///
/// Deliberately **not** a single ASCII word: the assertions compare the clipboard
/// text to this string exactly, so leading/trailing punctuation and mixed
/// scripts would catch any "helpful" trimming or quoting on the way.
const String _body = '这是一段文字，带标点！and English.';

/// The key the 「复制」 button carries (`MessageBubble._copyButton`).
const ValueKey<String> _copyKey = ValueKey<String>('bubble-copy-text');

/// A long single-script body for the drag test: 40 characters, so a drag over
/// part of it must yield a **strict** substring.
const String _longBody =
    '这是一段刚好四十个字的中文用来做排版基线的断言一段话写在这里正好四十个字结束了哦';

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'CC01',
      alias: 'Eve',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// Captures every `Clipboard.setData` payload while the test runs.
List<String> _captureClipboard() {
  final List<String> copied = <String>[];
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform,
      (MethodCall call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map<Object?, Object?>)['text']! as String);
    }
    return null;
  });
  addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return copied;
}

/// A right-click (secondary tap) at [position] — the desktop gesture.
Future<void> _rightClickAt(WidgetTester tester, Offset position) async {
  final TestGesture gesture = await tester.startGesture(
    position,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

/// A right-click at the centre of [finder].
Future<void> _rightClick(WidgetTester tester, Finder finder) =>
    _rightClickAt(tester, tester.getCenter(finder));

/// Drags with the **left** mouse button from [from] to [to] in three steps.
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

/// The 「复制」 row **inside the selection toolbar** — not the bubble's button,
/// which carries the same word on purpose (`bubble_copy_button_test.dart`).
Finder _toolbarCopy() => find.descendant(
      of: find.byType(AdaptiveTextSelectionToolbar),
      matching: find.text('复制'),
    );

Future<void> _pumpThread(
  WidgetTester tester,
  FakeBackend backend,
  ConversationController controller,
) async {
  // Read the history **before** mounting: a thread still in `Loading` paints the
  // indeterminate spinner, and `pumpAndSettle` would never settle on it.
  unawaited(controller.load());
  await pumpApp(
    tester,
    Scaffold(
      body: ConversationThread(controller: controller, peer: _peer()),
    ),
    backend: backend,
    settle: true,
  );
}

void main() {
  late FakeBackend backend;
  late ConversationController controller;

  setUp(() {
    backend = FakeBackend();
    backend.repo.addConversation(
      id: 'c-copy',
      deviceFingerprint: 'CC01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-text',
      conversationId: 'c-copy',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.text,
      textBody: _body,
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
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
      conversationId: 'c-copy',
      drafts: ComposerDraftStore(),
    );
  });

  tearDown(() {
    controller.dispose();
    backend.dispose();
  });

  testWidgets(
      'desktop: right-click AFTER a drag belongs to the selection layer — its '
      '「复制」 puts the dragged range on the clipboard, not the whole message',
      (WidgetTester tester) async {
    backend.repo.addMessage(
      id: 'm-long',
      conversationId: 'c-copy',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.text,
      textBody: _longBody,
      createdAt: fixedEpoch.add(const Duration(minutes: 1)),
      updatedAt: fixedEpoch.add(const Duration(minutes: 1)),
    );
    final List<String> copied = _captureClipboard();
    await _pumpThread(tester, backend, controller);

    final Finder body = find.text(_longBody);
    final Rect box = tester.getRect(body);
    final Offset from =
        box.topLeft + Offset(box.width * 0.06, box.height * 0.25);
    final Offset to = box.topLeft + Offset(box.width * 0.60, box.height * 0.25);
    await _mouseDrag(tester, from, to);

    // ★ The whole point of 0.2.31: **the bubble's old menu is gone.** Until now
    // this code path opened 「复制文字」 and copied the entire body, so a user who
    // had just selected three words had no way to copy them.
    expect(find.text('复制文字'), findsNothing,
        reason: 'the bubble must no longer answer a text right-click itself; '
            '0.2.27–0.30 did, and that is what starved the selection layer');

    // Right-click **inside** the range just dragged. (The box centre would land
    // on the second line, which this drag never touched — Flutter then collapses
    // the selection and offers 全选 only, which is correct there and tested in
    // the "no selection" case below.)
    await _rightClickAt(tester, Offset.lerp(from, to, 0.5)!);
    expect(find.text('复制文字'), findsNothing);
    expect(_toolbarCopy(), findsOneWidget,
        reason: 'the selection layer\'s own menu must offer 复制 for the range; '
            'it comes from SelectableRegion, not from this app');
    expect(
      find.descendant(
        of: find.byType(AdaptiveTextSelectionToolbar),
        matching: find.text('全选'),
      ),
      findsOneWidget,
      reason: 'Flutter\'s menu is shown with Chinese labels (0.2.31) — the '
          'default ones are English and the rest of the app is not',
    );
    expect(copied, isEmpty,
        reason: 'opening the menu must not copy anything by itself');

    await tester.tap(_toolbarCopy());
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    final String selected = copied.single;
    expect(selected, isNotEmpty);
    expect(_longBody.contains(selected), isTrue,
        reason: 'the copied text must be a slice of the body, got "$selected"');
    expect(selected.length, lessThan(_longBody.length),
        reason: 'a right click after a drag must copy **the dragged range**; '
            'copying the whole body here means the bubble stole the gesture '
            'again');
  });

  testWidgets(
      'desktop: a right-click with NO selection offers the MESSAGE menu — and its '
      '「复制文字」 puts the whole body on the clipboard (0.2.38)',
      (WidgetTester tester) async {
    final List<String> copied = _captureClipboard();
    await _pumpThread(tester, backend, controller);

    await _rightClick(tester, find.text(_body));

    // Nothing is selected, so the range toolbar must not offer 复制…
    expect(_toolbarCopy(), findsNothing,
        reason: 'Flutter only offers 复制 for an uncollapsed selection');
    // …but the *message* menu does, and it means "the whole thing"
    // (`text_bubble_menu_test.dart` owns that matrix).
    expect(find.text('复制文字'), findsOneWidget);
    expect(copied, isEmpty, reason: 'opening a menu copies nothing by itself');

    await tester.tap(find.text('复制文字'));
    await tester.pumpAndSettle();

    expect(copied, <String>[_body],
        reason: 'the whole body, verbatim — the same rule the 0.2.27 menu had');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'phone: a long press belongs to text selection — no 复制文字 menu and no '
      '「复制」 button under the bubble', (WidgetTester tester) async {
    backend.platform.setMobile(true);
    final List<String> copied = _captureClipboard();
    await _pumpThread(tester, backend, controller);

    // The button is desktop-only, so it must not be mounted on a phone at all —
    // asserted **before** the long press, while no toolbar is covering it.
    expect(find.byKey(_copyKey), findsNothing,
        reason: 'on a phone a long press selects and the system toolbar copies; '
            'a second copy button under every bubble is noise');

    await tester.longPress(find.text(_body));
    await tester.pumpAndSettle();

    expect(find.text('复制文字'), findsNothing,
        reason: 'a finger long press is "select this word" now; two meanings for '
            'one gesture is what made selection unreachable');
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
    expect(copied, isEmpty,
        reason: 'merely selecting must not write the whole body to the clipboard');
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop: a FILE bubble opens its own menu and never 复制文字',
      (WidgetTester tester) async {
    backend.repo.addMessage(
      id: 'm-file',
      conversationId: 'c-copy',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.file,
      createdAt: fixedEpoch.add(const Duration(minutes: 1)),
      updatedAt: fixedEpoch.add(const Duration(minutes: 1)),
      files: <FileAttachment>[
        const FileAttachment(
          id: 'f-1',
          messageId: 'm-file',
          fileName: 'notes.txt',
          size: 12,
          sha256: 'AA',
          localPath: r'C:\recv\notes.txt',
        ),
      ],
    );
    await _pumpThread(tester, backend, controller);

    final Finder fileBubble = find.ancestor(
        of: find.byType(FileTile), matching: find.byType(MessageBubble));
    expect(
      find.descendant(of: fileBubble, matching: find.byKey(_copyKey)),
      findsNothing,
      reason: 'the 「复制」 button belongs to a **text** bubble only (the text '
          'message from setUp has one, so this must be scoped)',
    );

    await _rightClick(tester, find.byType(FileTile));

    // The file menu really opened (so the gesture was not simply swallowed)…
    expect(find.text('复制文件名'), findsOneWidget);
    // …and it has neither text-copy entry: no menu row, no button.
    expect(find.text('复制文字'), findsNothing);
    expect(find.byKey(const ValueKey<String>('fast-menu-copyText')),
        findsNothing);
  });

  testWidgets('phone: long-pressing a FILE bubble opens the file menu only',
      (WidgetTester tester) async {
    backend.platform.setMobile(true);
    backend.repo.addMessage(
      id: 'm-file',
      conversationId: 'c-copy',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.file,
      createdAt: fixedEpoch.add(const Duration(minutes: 1)),
      updatedAt: fixedEpoch.add(const Duration(minutes: 1)),
      files: <FileAttachment>[
        const FileAttachment(
          id: 'f-1',
          messageId: 'm-file',
          fileName: 'notes.txt',
          size: 12,
          sha256: 'AA',
          localPath: r'C:\recv\notes.txt',
        ),
      ],
    );
    await _pumpThread(tester, backend, controller);

    await tester.longPress(find.byType(FileTile));
    await tester.pumpAndSettle();

    expect(find.text('分享…'), findsOneWidget,
        reason: 'the phone file menu is the one with 分享…');
    expect(find.text('复制文字'), findsNothing);
    expect(find.byKey(_copyKey), findsNothing,
        reason: 'no text bubble has a button on a phone, so none may exist here '
            'either');
  });
}
