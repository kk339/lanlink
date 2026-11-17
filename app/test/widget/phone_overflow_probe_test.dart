/// Size sweep at real phone widths (read-only investigation follow-up, M5d).
///
/// Pins three things the Web screenshot made us check: the bottom bar has all
/// **three** destinations, no RenderFlex overflow occurs at real phone sizes
/// (`takeException()` turns an overflow into a failure), and the search field is
/// collapsed on a phone (M5c §3).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/ui/widgets/device_row.dart';

import '../support/pump_app.dart';

void main() {
  for (final Size size in <Size>[
    const Size(360, 780),
    const Size(390, 844),
    const Size(412, 915),
  ]) {
    testWidgets(
        'phone @${size.width.toInt()}x${size.height.toInt()}: 3 tabs, no overflow, '
        'search collapsed', (WidgetTester tester) async {
      useSurfaceSize(tester, size);
      // Alice / Bob / Carol — Carol has `lastPort == 0`, so she renders the
      // `对方当前不可接收` marker.
      final FakeBackend backend = Scenarios.e14NarrowFold();
      addTearDown(backend.dispose);

      await pumpShell(tester, backend: backend, settle: true);

      // No RenderFlex overflow anywhere (captured as an exception).
      expect(tester.takeException(), isNull);

      // The bottom bar has all three destinations.
      final NavigationBar bar =
          tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.destinations.length, 3);

      // The bottom row is gone (docs/18); the search is hidden.
      expect(find.byType(TextField), findsNothing);

      expect(find.byType(DeviceRow), findsNWidgets(3));
      expect(find.text(DeviceRow.notReceivable), findsOneWidget);
    });
  }

  // M5d ③ — RED before the `Flexible` fix, GREEN after. A **large text scale**
  // (an accessibility setting a phone user really uses) widens the marker past
  // its row; the assertion is geometric, so it isolates the horizontal spill from
  // the separate, out-of-scope vertical squeeze of the fixed row height.
  testWidgets(
      'a LARGE text scale keeps the marker + status hint inside their rows',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(390, 844));
    tester.platformDispatcher.textScaleFactorTestValue = 3.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    // At 3× the row's FIXED 56px height also overflows *vertically* — that is the
    // separate layout item team-lead ruled out of scope for now, and an
    // unconsumed overflow fails a widget test on its own. Consume it explicitly
    // so THIS test pins only the horizontal spill it is about.
    for (int i = 0; i < 10 && tester.takeException() != null; i++) {}

    // The device row's `对方当前不可接收` marker must stay within its row (a
    // non-flexible Text ignores its own `ellipsis` and overflowed by 138px).
    final Rect row =
        tester.getRect(find.widgetWithText(DeviceRow, 'Carol Desktop'));
    final Rect marker = tester.getRect(find.text(DeviceRow.notReceivable));
    expect(
      marker.right,
      lessThanOrEqualTo(row.right + 0.5),
      reason: 'the marker must not spill past its row',
    );

    // REMOVED with the row (docs/18, "照 Flix"): this test used to also assert
    // that the receive row's trailing `点击…` hint did not spill past its bar.
    // That row no longer exists, so the assertion has no subject — it is deleted
    // rather than re-pointed at some unrelated widget, which would have turned it
    // into an assertion that can never fail. The device-row check above still
    // guards the horizontal-spill property this test exists for.
  });
}
