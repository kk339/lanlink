/// Widget tests for the **「复制」button under a desktop text bubble** (0.2.31).
///
/// It exists because the right click had to be given back. 0.2.27 put "copy the
/// whole message" on the bubble's right-click; 0.2.30 made the body really
/// selectable; and the two then fought for one button — the bubble's handler had
/// to sit *inside* the selection layer to win, which is exactly why that layer
/// never got a right click and the user could not copy the range he had just
/// dragged (*"选中右键就没法单独复制我选中的那部分了"*). So:
///
/// * **right click → the selection layer** (`message_copy_test.dart` owns that);
/// * **whole message → this button**, which competes with no gesture at all.
///
/// What each case proves:
/// * **A** — the button is *inside the bubble*, in the **meta row below the
///   card**, on the same line as the status chip, and its geometry is **pinned**
///   (with the 0.2.30 numbers next to it, because adding the row is the one
///   layout change this task allowed);
/// * **B** — tapping it puts the body on the clipboard **verbatim** and shows
///   「已复制」 — the same two rules 0.2.27's menu followed;
/// * **C** — a **middle** message (no status chip to show) still gets the button:
///   it is the only way left to copy a whole message, so it may not depend on
///   being the newest bubble;
/// * **D** — an **outgoing** bubble gets it too, flush with the right edge of its
///   meta row (outgoing takes a different branch of the bubble, so "it exists"
///   has to be proved on both sides).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';
import 'package:lanlink_app/ui/widgets/status_chip.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

/// The 40-character baseline body (the same string `message_selection_test.dart`
/// pins its TEXT/CARD numbers with, so the two files measure the same paragraph).
const String _body =
    '这是一段刚好四十个字的中文用来做排版基线的断言一段话写在这里正好四十个字结束了哦';

/// The key the button carries, so a test can tell it apart from the selection
/// toolbar's own 复制 (which is a `Text` too).
const ValueKey<String> _copyKey = ValueKey<String>('bubble-copy-text');

/// **The one layout change of 0.2.31**, measured at 1400×1000 on the real
/// desktop path, one incoming text message (the case that also draws the
/// 「已完成」chip):
///
/// | | 0.2.30 | 0.2.31 |
/// |---|---|---|
/// | the card (bubble body) | `434.0 × 64.0` | `434.0 × 64.0` — **unchanged** |
/// | the body text | `554,201 → 964,241` | **unchanged** |
/// | the status chip | `542,257 → 593.5,273` | `542,259 → 593.5,275` (+2: it is centred in a 20 dp row instead of a 16 dp one) |
/// | the whole bubble | `872.0 × 84.0` | `872.0 × 88.0` (+4 = the row grew from 16 to 20) |
/// | the 「复制」button | — | `36.8 × 20.0` at `601.5,257 → 638.3,277` |
///
/// The two numbers that must **not** move are the card and the paragraph: the
/// button lives *below* the card, so nothing inside it can re-flow. (0.2.28's
/// four-value baseline in `message_selection_test.dart` is a bare bubble with no
/// button wired, which is why it is still green to the pixel.)
const Size _baselineCard = Size(434.0, 64.0);
const Rect _baselineText = Rect.fromLTRB(554.0, 201.0, 964.0, 241.0);
const Size _baselineBubble = Size(872.0, 88.0);

/// The button's **height** is ours (`minimumSize` + `VisualDensity.compact`), so
/// it is pinned exactly; its width follows two glyphs of `bodySmall` plus 12 dp
/// of padding, which lands on 36.8 — pinned to a hundredth, which still fails on
/// any real change to the label or the padding.
const double _baselineButtonHeight = 20.0;
const double _baselineButtonWidth = 36.8;

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'CC01',
      alias: 'Eve',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// A backend whose conversation holds [count] incoming text messages, each
/// `_body` with a `#<index>` tail.
FakeBackend _seededBackend({int count = 1}) {
  final FakeBackend backend = FakeBackend();
  backend.repo.addConversation(
    id: 'c-copy',
    deviceFingerprint: 'CC01',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  for (int i = 0; i < count; i++) {
    backend.repo.addMessage(
      id: 'm-$i',
      conversationId: 'c-copy',
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
/// `Clipboard.setData` call, not a mock of the app's own helper.
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

/// Pumps the **real desktop path** — `ShellPage` with `CC01` open — at 1400×1000
/// with `isMobile: false`.
Future<void> _pumpDesktop(WidgetTester tester, FakeBackend backend) async {
  useSurfaceSize(tester, const Size(1400, 1000));
  backend.platform.setMobile(false);
  await pumpShell(tester, backend: backend, settle: true, initialPeer: _peer());
}

void main() {
  testWidgets(
      'A: desktop — 「复制」sits in the meta row under the card, on the same '
      'line as the status chip; the card and the paragraph do not move',
      (WidgetTester tester) async {
    final FakeBackend backend = _seededBackend();
    addTearDown(backend.dispose);
    await _pumpDesktop(tester, backend);

    final Finder button = find.byKey(_copyKey);
    expect(button, findsOneWidget,
        reason: 'copying a whole text message must stay reachable now that the '
            'right click belongs to the selection layer');

    // 1. Geometry: the two numbers that may not move…
    final Finder text = find.text('$_body#0');
    final Finder card =
        find.ancestor(of: text, matching: find.byType(DecoratedBox)).first;
    expect(tester.getSize(text), _baselineText.size);
    expect(tester.getRect(text), _baselineText,
        reason: 'the button is below the card, so the paragraph must be '
            'measured exactly as before');
    expect(tester.getSize(card), _baselineCard);
    // …and the two that the new row legitimately moves.
    expect(tester.getSize(find.byType(MessageBubble)), _baselineBubble);
    expect(tester.getSize(button).height, _baselineButtonHeight);
    expect(tester.getSize(button).width, closeTo(_baselineButtonWidth, 0.01));

    // 2. It really is *below* the card and *on the chip's line* — not floating
    //    somewhere else in the bubble.
    final Rect cardRect = tester.getRect(card);
    final Rect buttonRect = tester.getRect(button);
    final Rect chipRect = tester.getRect(find.byType(StatusChip));
    expect(buttonRect.top, greaterThan(cardRect.bottom),
        reason: 'the button belongs under the bubble, not inside it');
    expect(buttonRect.center.dy, closeTo(chipRect.center.dy, 0.5),
        reason: 'the button and the status chip share **one line**: both are '
            'centred in the same meta row (the button is 4 dp taller, which is '
            'why the row is 20 dp and not 16)');
    expect(buttonRect.left, greaterThan(chipRect.right),
        reason: 'reads "已完成 复制" left→right, the way the row is written');
  });

  testWidgets(
      'B: desktop — tapping 「复制」 puts the whole body on the clipboard, '
      'verbatim, and shows 已复制', (WidgetTester tester) async {
    final FakeBackend backend = _seededBackend();
    addTearDown(backend.dispose);
    final List<String> copied = _captureClipboard();
    await _pumpDesktop(tester, backend);

    await tester.tap(find.byKey(_copyKey));
    await tester.pumpAndSettle();

    expect(copied, <String>['$_body#0'],
        reason: 'the clipboard must receive the message body character for '
            'character — no time, no status, no added quotes');
    expect(find.text('已复制'), findsOneWidget,
        reason: 'the confirmation follows the write, never precedes it');
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing,
        reason: 'pressing the button is not a selection gesture — the layer '
            'above the list must not raise its copy toolbar over a click');
  });

  testWidgets(
      'C: desktop — a middle message (nothing to report but its text) still '
      'carries the button', (WidgetTester tester) async {
    final FakeBackend backend = _seededBackend(count: 3);
    addTearDown(backend.dispose);
    await _pumpDesktop(tester, backend);

    // Only the newest bubble draws the status chip (docs/19 §9-A), so the first
    // two have no meta row for any other reason — the button must be enough.
    expect(find.byType(StatusChip), findsOneWidget,
        reason: 'sanity: the older bubbles really have no status to show');
    expect(find.byKey(_copyKey), findsNWidgets(3),
        reason: 'every text bubble must offer "copy the whole message" — it is '
            'the only way left to get one out');
  });

  testWidgets(
      'D: desktop — an OUTGOING bubble gets the same button, right-aligned like '
      'the rest of its meta row, and it copies that body', (WidgetTester tester) async {
    // Outgoing bubbles take a different branch of the bubble (`Align` to the
    // right, no avatar row), so "the button exists" has to be proved on both.
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-copy',
      deviceFingerprint: 'CC01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-out',
      conversationId: 'c-copy',
      direction: MessageDirection.outgoing,
      status: MessageStatus.done,
      kind: MessageKind.text,
      textBody: '$_body#out',
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
    );
    final List<String> copied = _captureClipboard();
    await _pumpDesktop(tester, backend);

    final Finder button = find.byKey(_copyKey);
    expect(button, findsOneWidget);
    final Rect cardRect = tester.getRect(find
        .ancestor(of: find.text('$_body#out'), matching: find.byType(DecoratedBox))
        .first);
    final Rect buttonRect = tester.getRect(button);
    expect(buttonRect.right, cardRect.right,
        reason: 'an outgoing bubble meta row is flush with its right edge');
    expect(buttonRect.top, greaterThan(cardRect.bottom));

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(copied, <String>['$_body#out']);
  });
}
