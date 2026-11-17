/// **The 0.2.30 regression tests for desktop text selection** —
/// *"手机上倒是可以选择文字，电脑上反而不行"*.
///
/// 0.2.28 made a text body selectable by wrapping **each bubble** in a
/// `SelectionArea`, and the bubble lives **inside** the timeline's `ListView`.
/// That is the arrangement this file exists to keep out:
///
/// * a `SelectableRegion` only competes for a drag whose pointer came down
///   **inside its own box** — with a region per bubble that box is one paragraph
///   inside a scrollable, so
///   – a drag that started on the bubble's **padding** (not exactly on a glyph)
///     selected **nothing at all**, and
///   – a drag that ran past the bubble it started in could only ever select that
///     one bubble (see case C);
/// * a finger long-presses, which no sibling competes for, so the **phone** kept
///   working — the mirror image of the user's report.
///
/// The fix is structural: `ConversationThread` mounts **one** `SelectionArea`
/// above the `ListView`, and the bubbles pass `selectableText: false` so exactly
/// one region exists.
///
/// What each case proves, on the **real desktop path** (`ShellPage`, 1400×1000,
/// `isMobile: false`) and never on a bare bubble in a `Scaffold`:
/// * **A** — the gesture the user described (press, drag across the wrapped
///   paragraph, `Ctrl+C`) leaves **that substring** on the clipboard;
/// * **B** — the same in a **scrollable** timeline (30 rows, the newest visible):
///   the shape every real conversation has, and the one the old per-bubble region
///   could not see;
/// * **C** — the drag may **start on the card's padding** and still select, and it
///   may **run into the next bubble** and select across both. Both were
///   impossible with a region inside each bubble, and neither regresses the
///   phone (that is `message_selection_test.dart` case C, kept green);
/// * **D** — the desktop **right-click belongs to the selection layer**, not to
///   the bubble (0.2.31). 0.2.27–0.2.30 answered it with 「复制文字」 and had to
///   put that handler *inside* the region to win the arena, which is exactly why
///   the region could never offer 复制 for the dragged range. The clipboard half
///   of the new arrangement lives in `message_copy_test.dart`.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/domain/models.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

/// The body the drag runs over. Two wrapped lines at the desktop pane width —
/// on purpose: a multi-line paragraph is the case a user actually drags across.
const String _body =
    '这是一段刚好四十个字的中文用来做排版基线的断言一段话写在这里正好四十个字结束了哦';

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'CC01',
      alias: 'Eve',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// A backend whose conversation holds [count] incoming text messages, each
/// `_body` with a `#<index>` tail so an assertion can say **which** bubble a
/// copied range came from.
FakeBackend _seededBackend({int count = 1}) {
  final FakeBackend backend = FakeBackend();
  backend.repo.addConversation(
    id: 'c-sel',
    deviceFingerprint: 'CC01',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  for (int i = 0; i < count; i++) {
    backend.repo.addMessage(
      id: 'm-$i',
      conversationId: 'c-sel',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.text,
      textBody: '$_body#$i',
      createdAt: fixedEpoch.add(Duration(minutes: i)),
      updatedAt: fixedEpoch.add(Duration(minutes: i)),
    );
  }
  return backend;
}

/// Captures every `Clipboard.setData` payload while the test runs — the real
/// `Ctrl+C` path, not a call to the app's own menu.
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
/// `CopySelectionTextIntent` → the selection layer's copy action → clipboard).
Future<void> _controlC(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// Press at [from], move to [to] in three steps (like a real pointer stream, so
/// a recognizer that only gives up after its slop threshold gets the chance),
/// release, and settle.
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

/// The drag a human makes over a two-line paragraph: press near the start of the
/// first line, drag down-and-right across the wrap, release.
Future<void> _dragAcrossBody(WidgetTester tester, Rect box) => _mouseDrag(
      tester,
      box.topLeft + Offset(box.width * 0.06, box.height * 0.22),
      box.topLeft + Offset(box.width * 0.60, box.height * 0.78),
    );

/// Mounts the **real desktop path** — `ShellPage` with `CC01` open — at
/// 1400×1000 with `isMobile: false`.
Future<void> _pumpDesktopShell(
  WidgetTester tester,
  FakeBackend backend,
) async {
  useSurfaceSize(tester, const Size(1400, 1000));
  backend.platform.setMobile(false);
  await pumpShell(
    tester,
    backend: backend,
    settle: true,
    initialPeer: _peer(),
  );
}

/// A right-click (secondary tap) at [position].
Future<void> _rightClick(WidgetTester tester, Offset position) async {
  final TestGesture gesture = await tester.startGesture(
    position,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'A: desktop — drag across the wrapped body with the mouse, Ctrl+C, and '
      'the clipboard holds exactly the dragged range', (WidgetTester tester) async {
    final FakeBackend backend = _seededBackend();
    addTearDown(backend.dispose);
    final List<String> copied = _captureClipboard();
    await _pumpDesktopShell(tester, backend);

    final Finder body = find.text('$_body#0');
    expect(body, findsOneWidget, reason: 'the conversation must be on screen');

    final Rect box = tester.getRect(body);
    expect(box.height, greaterThan(20),
        reason: 'the baseline body must wrap onto two lines — a one-line body '
            'would make the vertical part of the drag meaningless');
    await _dragAcrossBody(tester, box);
    await _controlC(tester);

    expect(copied, hasLength(1),
        reason: 'Ctrl+C must reach the selection layer and copy the selection');
    final String selected = copied.single;
    expect(selected, isNotEmpty,
        reason: 'the drag over the body must have selected something — this is '
            "the exact assertion the user's 电脑上反而不行 fails");
    expect('$_body#0'.contains(selected), isTrue,
        reason: 'the copied text must be a slice of the message body, '
            'got "$selected"');
    expect(selected.length, lessThan(('$_body#0').length),
        reason: 'copying the **whole** body would mean the selection never '
            'happened and something copied the message for us');
  });

  testWidgets(
      'B: desktop — the same gesture works in a SCROLLABLE timeline (the shape '
      'every real conversation has)', (WidgetTester tester) async {
    final FakeBackend backend = _seededBackend(count: 30);
    addTearDown(backend.dispose);
    final List<String> copied = _captureClipboard();
    await _pumpDesktopShell(tester, backend);

    // The thread scrolls to the newest message on open, so 30 rows are more
    // content than the pane holds: this `ListView` really can scroll, which is
    // the condition the per-bubble region never had to survive in a test.
    final Finder newest = find.text('$_body#29');
    expect(newest, findsOneWidget);
    final Finder oldest = find.text('$_body#0');
    expect(oldest, findsNothing,
        reason: 'the oldest row must be off screen, or the list is not '
            'scrollable and this case proves nothing');

    final Rect box = tester.getRect(newest);
    await _dragAcrossBody(tester, box);
    await _controlC(tester);

    expect(copied, hasLength(1));
    final String selected = copied.single;
    expect(selected, isNotEmpty);
    expect('$_body#29'.contains(selected), isTrue,
        reason: 'the copied text must be a slice of the newest body, '
            'got "$selected"');
    expect(selected.length, lessThan(('$_body#29').length));
  });

  testWidgets(
      'C: desktop — the drag may start on the bubble\'s PADDING and run into the '
      'next bubble; both still select (one region above the list)',
      (WidgetTester tester) async {
    final FakeBackend backend = _seededBackend(count: 3);
    addTearDown(backend.dispose);
    final List<String> copied = _captureClipboard();
    await _pumpDesktopShell(tester, backend);

    final Rect second = tester.getRect(find.text('$_body#1'));
    final Rect third = tester.getRect(find.text('$_body#2'));
    final Finder secondCard =
        find.ancestor(of: find.text('$_body#1'), matching: find.byType(DecoratedBox)).first;
    final Rect cardBox = tester.getRect(secondCard);

    // **Start on the card's left padding**, 4px inside the rounded rect: six
    // pixels *outside* the paragraph's own box. With a `SelectionArea` per
    // bubble this drag began on nothing and copied nothing.
    final Offset from = Offset(cardBox.left + 4, second.top + second.height * 0.5);
    expect(from.dx, lessThan(second.left),
        reason: 'the start point must be outside the text box on purpose');
    // …and finish inside the **next** bubble.
    final Offset to = Offset(
      third.left + third.width * 0.5,
      third.top + third.height * 0.5,
    );
    await _mouseDrag(tester, from, to);
    await _controlC(tester);

    expect(copied, hasLength(1),
        reason: 'a drag that starts on the bubble and crosses into the next one '
            'must still produce a selection');
    final String selected = copied.single;
    expect(selected, contains('#1'),
        reason: 'the range must reach the end of the bubble it started in — '
            'got "$selected"');
    expect(selected, contains(_body.substring(0, 6)),
        reason: 'and it must reach into the next bubble, i.e. the selection '
            'crosses bubbles — got "$selected"');
  });

  testWidgets(
      'D: desktop — the selection layer, not the bubble, answers a right click '
      '(0.2.31 — and that is the whole point of the change)',
      (WidgetTester tester) async {
    final FakeBackend backend = _seededBackend();
    addTearDown(backend.dispose);
    await _pumpDesktopShell(tester, backend);

    await _rightClick(tester, tester.getCenter(find.text('$_body#0')));

    // What matters here is **ownership**: the right click is served by the one
    // `SelectionArea` above the list, through its `contextMenuBuilder` — never by
    // a gesture the bubble hung on the text (0.2.27–0.2.30 did that, and 0.2.28
    // shipped it with a silently dead right click because the inner recognizer
    // won the arena). Since 0.2.38 that builder shows the **message** menu when
    // there is no selection, so 「复制文字」 is expected here — coming from the
    // region, which is exactly the point. The full matrix (message menu / range
    // toolbar / file menu) is `text_bubble_menu_test.dart`.
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget,
        reason: 'the right click belongs to the one SelectionArea above the list');
    expect(find.text('复制文字'), findsOneWidget,
        reason: 'served by the region\'s builder, not by a bubble gesture');
    expect(
      find.descendant(
        of: find.byType(AdaptiveTextSelectionToolbar),
        matching: find.text('复制'),
      ),
      findsNothing,
      reason: 'no selection ⇒ no range item; the bubble\'s own 「复制」 button '
          'lives outside the toolbar and is not what this checks',
    );
  });
}
