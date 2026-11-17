/// Widget tests for **selectable** text in a message bubble (0.2.28) —
/// *"你这个复制只能右键复制文字，不能是我选择文字进行复制的那种吗"*.
///
/// 0.2.27 gave a text bubble "copy the whole message" on right-click / long
/// press. That is the wrong *unit* when the user wants three words out of a
/// paragraph, so 0.2.28 makes the body real selectable text.
///
/// What each test actually proves:
/// * **A** — a text body sits inside a `SelectionArea` (a file bubble does not),
///   and its **geometry is unchanged to the pixel** against the 0.2.27 baseline:
///   selection must not re-flow the paragraph or resize the bubble;
/// * **B** — the desktop gesture the user asked for works end to end: **drag with
///   the mouse → `Ctrl+C` → the clipboard holds exactly the dragged range**, a
///   strict part of the message, not the whole thing;
/// * **C** — on a phone a long press now **selects** (handles + the copy toolbar
///   appear) and no longer opens the bubble's 复制文字 menu: one gesture, one
///   meaning;
/// * **D** — a **file** bubble is untouched: no `SelectionArea` anywhere in it,
///   and its own attachment menu still answers right-click / long press.
///
/// **0.2.30 moved the selection layer, and these cases still hold.** The
/// `SelectionArea` is **one** region above the timeline's `ListView`
/// (`ConversationThread`), not one per bubble — so every case here that mounts a
/// **thread** exercises the region from above the list, and case **A** (which
/// mounts a lone bubble) exercises the bubble's own default. What the move
/// bought, and the two drags a per-bubble region could never see, is pinned in
/// `desktop_mouse_selection_test.dart`.
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

import '../support/pump_app.dart';

/// **The layout baseline body: exactly 40 Chinese characters**, asserted to be 40
/// by the test itself so a later "tidy up" of this string cannot quietly change
/// what the recorded numbers below belong to.
const String _body40 =
    '这是一段刚好四十个字的中文用来做排版基线的断言一段话写在这里正好四十个字结束了哦';

/// A short mixed-script body for the gesture tests (spaces included, so a phone
/// long press selects a **word** rather than a whole CJK run).
const String _bodyMixed = '这是一段文字，带标点！and English.';

/// The **0.2.27 baseline**, measured by pumping this exact bubble *before* the
/// selection change and printing `tester.getSize` / `tester.getRect`:
///
/// ```
/// BODY_LEN=40 TEXT=Size(230.8, 60.0) TEXT_RECT=Rect.fromLTRB(38.0, 360.0, 268.8, 420.0)
///             CARD=Size(254.8, 84.0) CARD_RECT=Rect.fromLTRB(26.0, 348.0, 280.8, 432.0)
/// ```
///
/// (pane 360 dp → bubble cap min(360 × 0.78, 460) = 280.8; two wrapped lines of
/// 30 dp each; card = text + 12 dp padding on every side.) Any change to the way
/// the body is measured — a different renderer, a different `strutStyle`, a
/// caret margin, an extra `Padding` — moves at least one of these numbers, which
/// is exactly what these assertions are here to catch.
const Size _baselineText = Size(230.8, 60.0);
const Rect _baselineTextRect = Rect.fromLTRB(38.0, 360.0, 268.8, 420.0);
const Size _baselineCard = Size(254.8, 84.0);
const Rect _baselineCardRect = Rect.fromLTRB(26.0, 348.0, 280.8, 432.0);

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'CC01',
      alias: 'Eve',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

ChatMessage _textMessage(String body) => ChatMessage(
      id: 'm-text',
      conversationId: 'c-sel',
      direction: MessageDirection.incoming,
      kind: MessageKind.text,
      textBody: body,
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
      status: MessageStatus.done,
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

/// `Ctrl+C` through the real shortcut stack (`DefaultTextEditingShortcuts` →
/// `CopySelectionTextIntent` → the selection layer's copy action → the
/// clipboard), i.e. not a call to the app's own menu.
Future<void> _controlC(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// A right-click (secondary tap) at the centre of [finder].
Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  final TestGesture gesture = await tester.startGesture(
    tester.getCenter(finder),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Drags with the **left** mouse button from the top-left area of [finder]'s box
/// to its bottom-right area — the gesture the user described ("选择文字").
Future<void> _mouseDrag(WidgetTester tester, Rect box) async {
  final Offset start = box.topLeft + Offset(box.width * 0.08, box.height * 0.25);
  final Offset end = box.topLeft + Offset(box.width * 0.55, box.height * 0.75);
  final TestGesture gesture =
      await tester.startGesture(start, kind: PointerDeviceKind.mouse);
  await tester.pump();
  await gesture.moveTo(end);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _pumpThread(
  WidgetTester tester,
  FakeBackend backend,
  ConversationController controller,
) async {
  unawaited(controller.load());
  await pumpApp(
    tester,
    Scaffold(body: ConversationThread(controller: controller, peer: _peer())),
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
      id: 'c-sel',
      deviceFingerprint: 'CC01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-text',
      conversationId: 'c-sel',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.text,
      textBody: _bodyMixed,
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
      conversationId: 'c-sel',
      drafts: ComposerDraftStore(),
    );
  });

  tearDown(() {
    controller.dispose();
    backend.dispose();
  });

  testWidgets(
      'A: the body of a text bubble is selectable, and its geometry is the '
      '0.2.27 baseline — to the pixel', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(800, 800));
    final FakeBackend fresh = await pumpApp(
      tester,
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 360,
            child: MessageBubble(message: _textMessage(_body40)),
          ),
        ),
      ),
    );
    addTearDown(fresh.dispose);

    // 1. There really is a selectable-text component around the body. Note this
    //    bubble is built with **no** `onShowTextMenu` at all: selection is the
    //    platform's behaviour and must not depend on a caller wiring a menu.
    //    (`selectableText` defaults to `true`: a bubble on its own is selectable
    //    without a timeline. Inside a thread the timeline owns the one region and
    //    passes `false` — 0.2.30.)
    expect(find.byType(SelectionArea), findsOneWidget,
        reason: 'the desktop body must be selectable text');
    expect(
      find.descendant(
        of: find.byType(SelectionArea),
        matching: find.text(_body40),
      ),
      findsOneWidget,
      reason: 'the SelectionArea must wrap the message body itself',
    );
    expect(_body40.length, 40, reason: 'the baseline below is for 40 chars');

    // 2. The layout did not move. Same string, same pane width, same numbers.
    final Finder card = find
        .ancestor(of: find.text(_body40), matching: find.byType(DecoratedBox))
        .first;
    expect(tester.getSize(find.text(_body40)), _baselineText,
        reason: 'the body text must be measured exactly as it was before '
            'selection was added (no caret margin, no strut change)');
    expect(tester.getRect(find.text(_body40)), _baselineTextRect,
        reason: 'same width, same wrap, same position inside the card');
    expect(tester.getSize(card), _baselineCard,
        reason: 'the bubble shrink-wraps its body, so its size follows the text');
    expect(tester.getRect(card), _baselineCardRect);
  });

  testWidgets(
      'B: desktop — drag with the mouse, Ctrl+C, and the clipboard holds '
      'exactly the dragged range (a part, not the whole message)',
      (WidgetTester tester) async {
    backend.repo.addMessage(
      id: 'm-long',
      conversationId: 'c-sel',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.text,
      textBody: _body40,
      createdAt: fixedEpoch.add(const Duration(minutes: 1)),
      updatedAt: fixedEpoch.add(const Duration(minutes: 1)),
    );
    final List<String> copied = _captureClipboard();
    await _pumpThread(tester, backend, controller);

    final Rect box = tester.getRect(find.text(_body40));
    await _mouseDrag(tester, box);
    await _controlC(tester);

    expect(copied, hasLength(1),
        reason: 'Ctrl+C must reach the selection layer and copy it');
    final String selected = copied.single;
    expect(selected, isNotEmpty, reason: 'the drag must have selected something');
    expect(_body40.contains(selected), isTrue,
        reason: 'the copied text must be a slice of the body, not decoration: '
            '"$selected"');
    expect(selected.length, lessThan(_body40.length),
        reason: 'a drag over part of the paragraph must copy a *part* — copying '
            'the whole body here would mean selection is not really working');
  });

  testWidgets(
      'C: phone — a long press selects (handles + copy toolbar) and does NOT '
      'open the 复制文字 menu', (WidgetTester tester) async {
    backend.platform.setMobile(true);
    final List<String> copied = _captureClipboard();
    await _pumpThread(tester, backend, controller);

    await tester.longPress(find.text(_bodyMixed));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'a long press must not throw (the menu gesture and the '
            'selection gesture used to be in the same arena)');
    expect(find.text('复制文字'), findsNothing,
        reason: 'a finger long press is now "select this word"; the bubble menu '
            'must not appear on top of it');
    expect(find.byKey(const ValueKey<String>('fast-menu-copyText')), findsNothing);
    // The selection really happened: the platform toolbar is up…
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget,
        reason: 'the copy toolbar is how a phone user copies the selection');
    // …and the selection is copyable through the standard shortcut.
    await _controlC(tester);
    expect(copied, hasLength(1));
    expect(copied.single, isNotEmpty);
    expect(_bodyMixed.contains(copied.single), isTrue,
        reason: 'copied "${copied.single}" must come from the message body');
  });

  testWidgets(
      'D: a FILE bubble has no selectable text and keeps its own attachment '
      'menu on both surfaces', (WidgetTester tester) async {
    backend.repo.addMessage(
      id: 'm-file',
      conversationId: 'c-sel',
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

    // Nothing in **this bubble** is selectable — only a text body is. (Scoped to
    // the file bubble on purpose: the thread also holds the text message from
    // `setUp`, and *it* is of course selectable.)
    final Finder fileBubble =
        find.ancestor(of: find.byType(FileTile), matching: find.byType(MessageBubble));
    expect(
      find.descendant(of: fileBubble, matching: find.byType(SelectionArea)),
      findsNothing,
      reason: 'a file bubble must not grow a selectable text layer',
    );

    await _rightClick(tester, find.byType(FileTile));
    expect(find.text('复制文件名'), findsOneWidget,
        reason: 'the desktop file menu still answers a right-click');
    expect(find.text('复制文字'), findsNothing);
  });

  testWidgets('D2: phone — a file bubble keeps its long-press file menu',
      (WidgetTester tester) async {
    backend.platform.setMobile(true);
    backend.repo.addMessage(
      id: 'm-file',
      conversationId: 'c-sel',
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
        reason: 'the phone file menu is the one with 分享… — untouched by 0.2.28');
    expect(find.text('复制文字'), findsNothing);
    expect(
      find.descendant(
        of: find.ancestor(
            of: find.byType(FileTile), matching: find.byType(MessageBubble)),
        matching: find.byType(SelectionArea),
      ),
      findsNothing,
    );
  });
}
