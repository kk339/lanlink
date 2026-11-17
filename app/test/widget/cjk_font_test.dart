/// **0.2.36 — Chinese is drawn with a Chinese face.**
///
/// The user: *"中文显示的不是正常中文黑体……我都怀疑你是不是找的临近汉语文化国家用的汉字"*.
/// He was right, and it was not a display bug: nothing in the app ever named a
/// font, so on Windows the Latin text used `Segoe UI` and every CJK run fell
/// through to **Skia's own fallback**, which picks a **Japanese** face (Yu Gothic
/// UI) — same code points, wrong regional glyphs.
///
/// The fix is a `fontFamilyFallback` chain (`ui/fonts.dart`), attached in the two
/// theme builders so there is one answer for the whole app, and explicitly on the
/// crash surface's monospace style (which never merges the theme).
///
/// **What these tests can and cannot prove.** They cannot measure glyph shapes —
/// a widget test draws with the test font. What they *can* prove is that the
/// chain reaches the layer that paints: the assertions below read the
/// `TextStyle` off the **`RenderParagraph`** that will be handed to the engine,
/// which is the last thing this side of the boundary can be checked.
/// That the engine then resolves `Microsoft YaHei UI` to Hanzi rather than kana is
/// a property of the installed font (`C:\Windows\Fonts\msyh.ttc` publishes both
/// `Microsoft YaHei` and `Microsoft YaHei UI`) — verified on the machine, and
/// finally by eye on the real window.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/app.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/main.dart';
import 'package:lanlink_app/ui/fonts.dart';
import 'package:lanlink_app/ui/theme.dart';

import '../support/pump_app.dart';

/// The style a `Text` **actually paints with**, read off its render object.
TextStyle _paintedStyle(WidgetTester tester, Finder finder) {
  final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(finder);
  return (paragraph.text as TextSpan).style!;
}

void main() {
  test('A: the chain itself — Windows first, then the other platforms', () {
    // Pinned by hand: this list is the product decision, and a reordering is
    // exactly what would silently put a Japanese face back in front.
    expect(kCjkFallback.first, 'Microsoft YaHei UI');
    expect(kCjkFallback.take(3),
        <String>['Microsoft YaHei UI', 'Microsoft YaHei', 'PingFang SC']);
    expect(kCjkFallback, contains('PingFang SC'));
    expect(kCjkFallback, contains('Noto Sans SC'));
    expect(kCjkFallback.last, 'sans-serif');
  });

  test(
      'B: BOTH theme builders carry it — the app picks one by OS brightness, so '
      'a dark-mode user needs it just as much', () {
    for (final ThemeData theme in <ThemeData>[
      buildLightTheme(),
      buildDarkTheme(),
    ]) {
      expect(theme.textTheme.bodyMedium?.fontFamilyFallback, kCjkFallback,
          reason: '${theme.brightness} textTheme');
      expect(theme.textTheme.titleLarge?.fontFamilyFallback, kCjkFallback);
      expect(theme.primaryTextTheme.titleLarge?.fontFamilyFallback, kCjkFallback,
          reason: 'app-bar titles are drawn from primaryTextTheme');
    }
  });

  testWidgets(
      'C: the real app root — the theme in the tree carries the fallback, and so '
      'does the style that paints a Chinese label', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    await tester.pumpWidget(LanlinkApp(deps: testDeps(backend)));
    await tester.pumpAndSettle();

    // 1. `Theme.of` from inside the real tree (criterion: not just the config).
    final BuildContext anyContext = tester.element(find.byType(Scaffold).first);
    final ThemeData theme = Theme.of(anyContext);
    expect(theme.textTheme.bodyMedium?.fontFamilyFallback, kCjkFallback);
    expect(theme.textTheme.titleMedium?.fontFamilyFallback, kCjkFallback,
        reason: 'every style in the text theme is mapped, not just the body one');
    expect(theme.primaryTextTheme.titleLarge?.fontFamilyFallback, kCjkFallback,
        reason: 'an AppBar title is drawn from primaryTextTheme');

    // 2. …and the label that is actually on screen paints with it. This is the
    //    assertion that would fail if the theme were built but never reached the
    //    paragraph — e.g. a Text with a hard-coded style would show it.
    final Finder chinese = find.text('会话').first;
    expect(_paintedStyle(tester, chinese).fontFamilyFallback, kCjkFallback,
        reason: 'the RenderParagraph that will be handed to the engine must '
            'carry the chain, or the CJK run goes back to Skia\'s fallback');
  });

  testWidgets(
      'D: the crash surface (the second MaterialApp) has it too — theme AND the '
      'monospace style, which never merges a theme', (WidgetTester tester) async {
    await tester.pumpWidget(StartupErrorApp(
      error: 'boom',
      stackTrace: StackTrace.current,
    ));
    await tester.pumpAndSettle();

    expect(
      Theme.of(tester.element(find.byType(Scaffold).first))
          .textTheme
          .bodyMedium
          ?.fontFamilyFallback,
      kCjkFallback,
      reason: 'the second MaterialApp must carry the same theme',
    );

    // The crash report's own style is written out in full (`monospace`), so the
    // theme cannot reach it: the fallback has to be on that style itself, or the
    // one screen a user sees when everything else failed would speak Japanese.
    // (A `SelectableText` renders through `EditableText`, so there is no
    // `RenderParagraph` to read here — the requested style is the honest
    // assertion, and case B already proves the chain reaches a paragraph.)
    final SelectableText report = tester.widget<SelectableText>(
      find.byType(SelectableText),
    );
    expect(report.style?.fontFamily, 'monospace');
    expect(report.style?.fontFamilyFallback, kCjkFallback);
  });
}
