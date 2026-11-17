/// 0.2.24 — the **desktop** path to the 关于 page.
///
/// **History, because it is the point.** Until 0.2.24 `AboutPage` was reachable
/// only from the phone body: `lib/ui/shell/list_pane.dart` mounts the same
/// `SettingsBody` for `ShellModule.settings` on every layout, but
/// `SettingsBody` branches on `context.deps.platform.isMobile`
/// (`settings_body.dart` → `_phoneBody` / `_desktopBody`) and the 关于 row lived
/// **only** in `_phoneBody`; `_desktopBody` rendered 名称 / 保存位置 / 接收模式 and
/// stopped. `AboutPage` had no second reference anywhere in `lib/`, and the
/// Windows runner registers no menu entry, so on a desktop build the page could
/// not be opened at all. That assumption ("the same body is mounted, therefore
/// the desktop has it") is exactly what this file was written to test — and it
/// was false.
///
/// **Since 0.2.24** `_desktopBody` ends with the phone's own `_navRow`
/// (「关于我们」 + `版本 …` + `›` → `AboutPage`). So direction 1 below is the
/// assertion reversed: the walk is still a real one — **launch → rail 「设置」 →
/// 「关于我们」 → AboutPage**, never `initialModule`, because taking that shortcut
/// is what would have hidden the missing entry in the first place.
///
/// Direction 2 keeps the phone honest at the same time: the same shell with a
/// phone platform still opens the page, so a desktop fix cannot quietly become a
/// phone regression.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/app_info.dart';
import 'package:lanlink_app/ui/about_page.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

void main() {
  testWidgets(
      '★ DESKTOP: launch → rail 「设置」 → 「关于我们」 really renders AboutPage',
      (WidgetTester tester) async {
    // Wide enough for `ShellLayout.wide`, so the rail draws its labels (a
    // collapsed rail has no 「设置」 text to tap).
    useSurfaceSize(tester, const Size(1400, 1000));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    // `mobile` stays false: this is the desktop build.

    // 1) Start where the app starts: the conversations module.
    await pumpShell(tester, backend: backend, settle: true);
    expect(find.byType(AboutPage), findsNothing);

    // 2) The rail lists every module; 「设置」 is one of them (NavRail iterates
    //    `ShellModule.values`).
    expect(find.text(ShellModule.settings.label), findsOneWidget,
        reason: 'the wide rail shows labels, so 设置 is a visible target');
    await tester.tap(find.text(ShellModule.settings.label));
    await tester.pumpAndSettle();

    // 3) The desktop settings pane is up …
    expect(find.text('本机名称'), findsOneWidget);
    expect(find.text('保存位置'), findsOneWidget);

    // 4) ★ …and it carries the About entry, with the version beside the `›`.
    final Finder aboutRow = find.text('关于我们');
    expect(aboutRow, findsOneWidget,
        reason: 'without this row the desktop cannot reach AboutPage at all');
    expect(find.text('版本 $kAppVersion'), findsOneWidget,
        reason: 'the version is `kAppVersion`, one constant, both layouts');
    final Finder aboutTile =
        find.ancestor(of: aboutRow, matching: find.byType(ListTile));
    expect(aboutTile, findsOneWidget, reason: 'it opens a page, so it is a tile');
    expect(
      find.descendant(of: aboutTile, matching: find.byIcon(Icons.chevron_right)),
      findsOneWidget,
      reason: 'a row that looks tappable must be tappable — and this one is',
    );

    // 5) …and it opens the real page (not a dialog, not a dead row).
    await tester.tap(aboutRow);
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
    // Two facts only the page itself can satisfy:
    expect(find.text('局域网直传 · 不过云 · 不要账号'), findsOneWidget);
    expect(find.text('© 2026 lanlink'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '★ the SAME shell with a phone platform still opens 关于我们 → AboutPage — '
      'the desktop entry did not change the phone',
      (WidgetTester tester) async {
    // A tall surface: `_phoneBody` is a Flix-style page and the About card is the
    // third group, below the fold of a default 800×600 window.
    useSurfaceSize(tester, const Size(600, 1200));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform.setMobile(true);

    await pumpShell(
      tester,
      initialModule: ShellModule.settings,
      backend: backend,
      settle: true,
    );

    final Finder aboutRow = find.text('关于我们');
    expect(aboutRow, findsOneWidget);
    expect(find.text('版本 $kAppVersion'), findsOneWidget);

    await tester.tap(aboutRow);
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
    expect(find.text('局域网直传 · 不过云 · 不要账号'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
