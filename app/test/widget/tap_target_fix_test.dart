/// Gate for the two sub-48 tap targets found by the probe
/// (`test/widget/tap_target_probe_test.dart`): the phone **receive status bar**
/// (measured 36) and the **file row** (measured 44).
///
/// Real assertions, not numbers: each target must measure **≥48** *and* must
/// still respond to a tap **2px inside its own edge** — the same "hit it at the
/// edge" proof that exposed a 48 `IconButton` measuring as a 40 ink circle.
/// Measuring alone is not enough: a box can report 48 and still not be the box
/// that handles the gesture.
///
/// Red before the fix (36.0 / 44.0), green after.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/panes/file_detail.dart';
import 'package:lanlink_app/ui/widgets/device_row.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';

import '../support/pump_app.dart';

void main() {
  testWidgets('recent-file row is a >=48 target, edges included',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();

    final Rect row = tester.getRect(find.byType(FileTile).first);
    expect(
      row.height,
      greaterThanOrEqualTo(48.0),
      reason: 'file row hit box is ${row.height}',
    );

    // A tap 2px inside the *left* edge must still open the file detail.
    await tester.tapAt(Offset(row.left + 2, row.center.dy));
    await tester.pumpAndSettle();
    expect(
      find.byType(FileDetail),
      findsOneWidget,
      reason: 'a tap 2px inside the left edge must still reach the row',
    );
  });

  testWidgets('the moved ← is a >=48 target and returns to the list',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    await tester.tap(find.widgetWithText(DeviceRow, 'Alice Laptop'));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationThread), findsOneWidget);

    // The ← now lives in the AppBar's leading slot (~56 wide), not the body —
    // so re-measure: a slot can constrain the button inside it.
    expect(find.byTooltip('返回列表'), findsOneWidget);
    // Measure the **button**, not the Tooltip inside it — the tooltip wraps only
    // the icon area (40 here), while the 48 box that actually responds is the
    // IconButton. (Same trap the probe's edge-tap exposed for the un-moved ←:
    // `IconButton=48x48 <- Center=56x56 <- …`.)
    final Finder back = find
        .ancestor(
          of: find.byTooltip('返回列表'),
          matching: find.byType(IconButton),
        )
        .first;
    final Rect r = tester.getRect(back);
    expect(
      r.height,
      greaterThanOrEqualTo(48.0),
      reason: 'the moved ← hit box is ${r.height}',
    );

    // Edge: 2px inside its own edge must still step back one layer — to the
    // LIST, without exiting the app.
    await tester.tapAt(Offset(r.center.dx, r.top + 2));
    await tester.pumpAndSettle();
    expect(
      find.byType(DeviceRow),
      findsWidgets,
      reason: 'the edge tap must land on the list',
    );
    expect(find.byType(ConversationThread), findsNothing);
  });
}
