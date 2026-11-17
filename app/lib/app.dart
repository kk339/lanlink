/// The root widget (spec §2): `AppScope → MaterialApp → ShellPage`.
///
/// **T05 (final wiring):** [AppScope] wraps [MaterialApp] from the **outside**,
/// so every screen can read the wired [AppDeps] through `context.deps` —
/// including pages pushed by `Navigator` (which are siblings of [MaterialApp]'s
/// `home`, not descendants of it). Placing the scope *inside* `home` would
/// strand those pushed routes and fail `AppScope.of`'s assertion — the exact
/// bug `test/support/pump_app.dart` caught.
///
/// The theme is `ui/theme.dart::buildLightTheme` (the single source), and the
/// home screen is now the three-pane [ShellPage] (M4 UI 改版, design §1.1) — the
/// old page stack (`ui/pages/**`) is superseded by the rail / list / detail
/// shell.
library;

import 'package:flutter/material.dart';

import 'bootstrap/app_deps.dart';
import 'ui/localization.dart';
import 'ui/scope.dart';
import 'ui/shell/shell_page.dart';
import 'ui/theme.dart';

/// The lanlink application root.
class LanlinkApp extends StatelessWidget {
  /// Creates the app around the wired [deps].
  const LanlinkApp({super.key, required this.deps});

  /// The wired ports and configuration.
  final AppDeps deps;

  @override
  Widget build(BuildContext context) {
    // AppScope must wrap MaterialApp — NOT sit inside `home`. Navigator-pushed
    // routes are siblings of `home`, so a scope inside `home` would leave them
    // without deps and crash `AppScope.of` (see the library doc).
    return AppScope(
      deps: deps,
      child: MaterialApp(
        title: 'lanlink',
        debugShowCheckedModeBanner: false,
        // 0.2.35: Flutter's own strings (the selection toolbar, the composer's
        // long-press menu, tooltips, date/time pickers) come from
        // `MaterialLocalizations`, not from this app's hard-coded Chinese. With
        // no delegates declared, Flutter used `DefaultMaterialLocalizations` —
        // English — so those menus read "Paste / Select all / Copy" on an
        // all-Chinese screen. `lib/ui/localization.dart` is the single place the
        // locale is declared; the widget tests' mount helper uses the same
        // constants so a test tree matches production.
        localizationsDelegates: kLanlinkLocalizationsDelegates,
        supportedLocales: kLanlinkSupportedLocales,
        // Pinned, not followed from the OS: the app has one language, and
        // following the system would give English framework strings beside
        // Chinese app strings (see the library doc in localization.dart).
        locale: kLanlinkLocale,
        // Light stays the app's default look; a dark OS gets the dark theme
        // (M5c §7 — "睡前在床上传视频刺眼"). The light appearance is unchanged.
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.system,
        home: const ShellPage(),
      ),
    );
  }
}
