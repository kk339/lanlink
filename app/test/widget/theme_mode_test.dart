/// Widget tests for **dark mode** (M5c §7).
///
/// The app follows the OS through `ThemeMode.system`: a light OS keeps the
/// original light rendering (byte-for-byte — the light theme still pins the old
/// surface/divider/hover constants), a dark OS gets the dark theme.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/app.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/ui/shell/shell_page.dart';
import 'package:lanlink_app/ui/theme.dart';

import '../support/pump_app.dart';

void main() {
  test(
      '7: the light theme is unchanged; the dark theme differs only by surfaces',
      () {
    final ThemeData light = buildLightTheme();
    final ThemeData dark = buildDarkTheme();

    expect(light.brightness, Brightness.light);
    expect(dark.brightness, Brightness.dark);

    // Light keeps the original constants exactly.
    expect(light.dividerColor, kDividerColor);
    expect(surfaceList(light), kSurfaceList);
    expect(surfaceRail(light), kSurfaceRail);
    expect(selectionFill(light), kSelectionFill);
    expect(hoverFill(light), kHoverFill);

    // Dark actually differs (otherwise "dark mode" would be a no-op).
    expect(dark.dividerColor, isNot(kDividerColor));
    expect(surfaceList(dark), isNot(kSurfaceList));
    expect(surfaceRail(dark), isNot(kSurfaceRail));
    expect(hoverFill(dark), isNot(kHoverFill));
  });

  testWidgets('7: ThemeMode.system picks the dark theme when the OS is dark',
      (WidgetTester tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    await tester.pumpWidget(LanlinkApp(deps: testDeps(backend)));
    // NOT `pumpAndSettle`: the shell shows a loading spinner (an unbounded
    // animation) until the fake resolves, so settling would never return.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final MaterialApp app =
        tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system);
    expect(app.darkTheme?.brightness, Brightness.dark);
    // The resolved theme at the shell is the dark one.
    expect(
      Theme.of(tester.element(find.byType(ShellPage))).brightness,
      Brightness.dark,
    );
  });
}
