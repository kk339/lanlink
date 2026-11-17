/// The lanlink M4 entry point (spec §3.4 / §8.6).
///
/// It builds the platform [AppDeps] through the conditional seam
/// ([createAppDeps] — native vs. Web, chosen at compile time) and runs
/// [LanlinkApp].
///
/// Any failure while building deps is caught so the app shows an error surface
/// instead of a blank window — the code never fails silently (spec §8.5).
library;

import 'package:flutter/material.dart';

import 'app.dart';
import 'bootstrap/app_deps.dart';
import 'bootstrap/create_deps.dart';
import 'ui/fonts.dart';
import 'ui/localization.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final AppDeps deps = await createAppDeps();
    runApp(LanlinkApp(deps: deps));
  } catch (error, stackTrace) {
    runApp(StartupErrorApp(error: error, stackTrace: stackTrace));
  }
}

/// Shown when [createAppDeps] throws at launch.
///
/// A bare `Text` with no Material ancestor renders black-on-black — on a phone
/// that is literally a blank screen. This gives an **opaque, scrollable,
/// selectable** surface carrying both the failure reason and its stack, so the
/// failing step is readable on-device (and copyable into a bug report).
///
/// **Why it is public (0.2.35):** it is the app's *second* `MaterialApp`, and a
/// second `MaterialApp` is a second place the localization wiring can be
/// forgotten. Keeping it private made that unfalsifiable — no test could mount
/// the crash surface at all, so "the crash screen speaks Chinese too" would have
/// been an assertion by inspection. Public so
/// `test/widget/localization_chinese_test.dart` can pump it and read
/// `MaterialLocalizations.of` out of the real tree.
class StartupErrorApp extends StatelessWidget {
  /// Creates the crash surface around [error] and [stackTrace].
  const StartupErrorApp({
    super.key,
    required this.error,
    required this.stackTrace,
  });

  /// The startup error to surface.
  final Object error;

  /// Where the error was raised — names the failing step.
  final StackTrace stackTrace;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // 0.2.35: the same localization wiring as [LanlinkApp]. This surface is a
      // *second* `MaterialApp` (it is built when `createAppDeps` throws, so it
      // cannot be the app root), and it carries a `SelectableText` — whose
      // long-press / right-click menu is `MaterialLocalizations` too. Without
      // these three lines a user whose app failed to start would get an English
      // "Copy / Select all" over an otherwise Chinese crash report; that is
      // exactly the bug 0.2.35 fixes, so it must not survive in the one screen a
      // user only ever sees when something is already wrong.
      localizationsDelegates: kLanlinkLocalizationsDelegates,
      supportedLocales: kLanlinkSupportedLocales,
      locale: kLanlinkLocale,
      // 0.2.36: the second `MaterialApp` needs the CJK fallback too, for the same
      // reason it needed the localization wiring — a user who only ever sees this
      // screen must not see Japanese glyphs on top of a Chinese error message.
      theme: buildDarkTheme(),
      home: Scaffold(
        backgroundColor: const Color(0xFF101418),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              'lanlink 启动失败 / failed to start\n\n'
              '原因 / reason:\n$error\n\n'
              '调用栈 / stack:\n$stackTrace',
              // ★ `fontFamilyFallback` **here**, not only on the theme: this style
              // is written out in full (a monospace face for the stack trace), so
              // it never merges the theme's text theme — the theme alone would
              // leave the Chinese in this very Text to Skia's default choice.
              style: const TextStyle(
                color: Color(0xFFE6E6E6),
                fontSize: 13,
                height: 1.4,
                fontFamily: 'monospace',
                fontFamilyFallback: kCjkFallback,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
