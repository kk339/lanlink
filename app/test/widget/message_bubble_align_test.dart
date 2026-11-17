/// Widget tests for a bubble's **left/right split** (PRD §4 / A1-1..A1-4) — and
/// the pane-width cap that keeps it visible on a phone (the #4 fix).
///
/// The alignment code was always correct (`out` → right, `in` → left); the bug
/// was the **cap** being a fraction of the *window* rather than of the *pane*,
/// which on a narrow pane grew to ~93% of it, so both sides filled the pane and
/// the split disappeared. These tests pin the split against a deliberately
/// **narrow** pane: before the fix both bubbles filled it (equal left edges →
/// red); after the fix the cap is 78% of the pane and the anchors differ (green).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';

import '../support/pump_app.dart';

/// A long text message, so the bubble is wider than the cap and the cap is what
/// actually determines its width (a short text would size to its content).
ChatMessage _message(MessageDirection direction, String body) => ChatMessage(
      id: 'm-$body',
      conversationId: 'c1',
      direction: direction,
      kind: MessageKind.text,
      textBody: body,
      createdAt: DateTime.utc(2026, 1, 7, 12),
      updatedAt: DateTime.utc(2026, 1, 7, 12),
      status: MessageStatus.done,
    );

/// The bubble's own box (the `ConstrainedBox`), whose rect carries the anchoring.
Rect _bubbleBox(WidgetTester tester, String body) => tester.getRect(
      find
          .descendant(
            of: find.widgetWithText(MessageBubble, body),
            matching: find.byType(ConstrainedBox),
          )
          .first,
    );

void main() {
  testWidgets(
      'A1-1 / A1-2 / A1-3: on a narrow pane the cap is a fraction of the PANE, so '
      'the out/in split survives (the #4 fix)', (WidgetTester tester) async {
    // The WINDOW is wide (800), but the pane is deliberately narrow (320) — the
    // exact mismatch that used to collapse the split.
    useSurfaceSize(tester, const Size(800, 800));
    const double paneWidth = 320;
    const String outBody =
        'outgoing message body that is definitely longer than the pane cap '
        'so it wraps and fills it entirely';
    const String inBody =
        'incoming message body that is also definitely longer than the pane '
        'cap so it wraps and fills it entirely too';

    await pumpApp(
      tester,
      Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: paneWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                MessageBubble(
                    message: _message(MessageDirection.outgoing, outBody)),
                MessageBubble(
                    message: _message(MessageDirection.incoming, inBody)),
              ],
            ),
          ),
        ),
      ),
      settle: true,
    );

    // The pane the bubbles were given (MessageBubble's root fills it).
    final Rect pane =
        tester.getRect(find.widgetWithText(MessageBubble, outBody));
    expect(pane.width, paneWidth);
    final Rect outBox = _bubbleBox(tester, outBody);
    final Rect inBox = _bubbleBox(tester, inBody);

    // A1-1: the outgoing bubble hugs the right edge of its pane (≤ 16px gap).
    expect(pane.right - outBox.right, lessThanOrEqualTo(16));
    // A1-2: the incoming bubble is mirrored to the left edge.
    expect(inBox.left - pane.left, lessThanOrEqualTo(16));
    // A1-3: and the two anchors differ — with the window-based cap both boxes
    // filled the 320px pane and this difference was 0 (the #4 report).
    expect(outBox.left - inBox.left, greaterThan(20));
  });
}
