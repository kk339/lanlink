import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/app_info.dart';
import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';
import 'package:lanlink_app/ui/theme.dart';
import 'package:lanlink_app/ui/widgets/accept_toggle.dart';

import '../support/pump_app.dart';

/// The phone software-settings page, aligned with Flix (docs/18 §3.5).
///
/// Judgements only — no probing of private widgets: everything here reads the
/// rendered tree, which is what the user sees.
void main() {
  Future<void> pumpPhoneSettings(WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    backend.platform.setMobile(true);
    await pumpShell(
      tester,
      initialModule: ShellModule.settings,
      backend: backend,
      settle: true,
    );
  }

  testWidgets('grouped cards: 1px lines inside a group, air between groups',
      (WidgetTester tester) async {
    await pumpPhoneSettings(tester);

    // Inside a group the rows are divided by hairlines (docs/18 §2.1/§3.5).
    final Iterable<Divider> dividers = tester
        .widgetList<Divider>(find.byType(Divider))
        .where((Divider d) => d.thickness == 1);
    expect(dividers.length, greaterThanOrEqualTo(2),
        reason: 'the settings card is divided by 1px lines');

    // Between groups it is air, not a line: 本机名称 and 关于我们 sit in different
    // cards, so the gap between them is at least the card gap.
    final Rect first = tester.getRect(find.text('本机名称'));
    final Rect second = tester.getRect(find.text('关于我们'));
    expect(second.top - first.bottom, greaterThanOrEqualTo(kCardGap));
  });

  testWidgets(
      '「退出软件」 is its own card: centred red from the dangerAction SLOT, and '
      'no arrow (it performs, it does not navigate)',
      (WidgetTester tester) async {
    await pumpPhoneSettings(tester);

    final Text exit = tester.widget<Text>(find.text('退出软件'));
    expect(exit.style?.color, dangerAction,
        reason: 'the colour must come from the slot, never a hex written here');
    expect(exit.textAlign, TextAlign.center);

    // No chevron in that row: a › would promise navigation it does not do.
    final Finder exitRow = find
        .ancestor(of: find.text('退出软件'), matching: find.byType(ListTile))
        .first;
    expect(
      find.descendant(of: exitRow, matching: find.byIcon(Icons.chevron_right)),
      findsNothing,
    );
  });

  testWidgets(
      'the version rides on 「关于我们」, and there is NO 「检查更新」 row — a '
      'check we cannot perform must not get a look-tappable entry',
      (WidgetTester tester) async {
    await pumpPhoneSettings(tester);

    expect(find.text('关于我们'), findsOneWidget);
    expect(find.text('版本 $kAppVersion'), findsOneWidget);

    final Finder aboutRow = find
        .ancestor(of: find.text('关于我们'), matching: find.byType(ListTile))
        .first;
    final ListTile about = tester.widget<ListTile>(aboutRow);
    expect(about.onTap, isNotNull, reason: 'this row really opens a page');
    expect(
      find.descendant(of: aboutRow, matching: find.text('版本 $kAppVersion')),
      findsOneWidget,
      reason: 'the version is this row\'s value, not a separate entry',
    );

    expect(find.text('检查更新'), findsNothing,
        reason: 'no update server: that row could only ever be decorative');
  });

  testWidgets(
      '★ the receive switch is HERE and still switches — after the bottom row '
      'was removed this is the only place 接收模式 can be turned off',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    backend.platform.setMobile(true);
    await pumpShell(
      tester,
      initialModule: ShellModule.settings,
      backend: backend,
      settle: true,
    );

    expect(find.byType(AcceptToggle), findsOneWidget);
    expect(find.text('接收模式'), findsOneWidget,
        reason: 'our name, not Flix\'s 自动接收 — different semantics');

    // 0.2.25: the app now starts receivable, so the first tap is the one that
    // turns receiving **off** — which is exactly the direction this test was
    // written for ("this is the only place 接收模式 can be turned off"). The
    // second tap proves it can be turned back on, so a switch stuck in one
    // position still fails here.
    expect(backend.transfer.accepting, isTrue);
    await tester.tap(find.byType(AcceptToggle));
    await tester.pumpAndSettle();
    expect(backend.transfer.accepting, isFalse,
        reason: 'if this stops working, receiving can never be turned off');

    await tester.tap(find.byType(AcceptToggle));
    await tester.pumpAndSettle();
    expect(backend.transfer.accepting, isTrue);
  });

  testWidgets(
      '④b (0.2.23 → 0.2.26): 文件保存位置 states where the files really go and '
      'now OPENS that folder — it still does not open an editor',
      (WidgetTester tester) async {
    // ─────────────────────────────────────────────────────────────────────────
    // ★ HISTORY — why this test exists at all, and why its assertions changed
    //   twice.
    //
    // It was written to catch "灰字有路径，只是点开空白": `SettingsController.load()`
    // runs from `shell_page.dart` when the shell starts, and on a phone the
    // initial module is the CONVERSATION list — so by the time 设置 is opened the
    // load has already been delivered, and `addListener` never replays it. The
    // field controllers therefore opened on `''` while the row above showed the
    // real path. Starting where the app starts (list), letting the load settle,
    // and only then tapping 设置 is the ordering in which that defect appears —
    // so that ordering is kept.
    //
    // **0.2.23** deleted the editor that bug lived in: on Android
    // `settings.saveDirectory` is only the receiver's temporary landing spot
    // (`/data/user/0/<pkg>/files/lanlink/received`) and the file is published to
    // `Download/lanlink` and deleted from it, so 「更改位置」 promised something the
    // app never did. The row became a plain statement.
    //
    // **0.2.26** made that statement tappable again — not as an editor, but as
    // "open the folder". The user's report («点了没反应，是故意为之还是bug呢»)
    // is the reason: a read-only row that *looks* like a destination reads as a
    // bug. So the assertions below changed from "nothing may happen" to "exactly
    // one thing happens: the folder opens", and the "no editor" half is kept.
    // ─────────────────────────────────────────────────────────────────────────
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    backend.platform.setMobile(true);
    // This page's row opens a folder, so the platform must offer the action (the
    // fake defaults to "this platform has none").
    backend.platform.setSupportsViewInDownloads(true);

    // Start on the app's real initial module (conversations), not on settings.
    await pumpShell(tester, backend: backend, settle: true);
    // Let the settings load finish *before* the page exists — the phone's order.
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    // ④a (the user's report: "最上面有一个设置，下面又是软件设置"): this page carries
    // its own large 「软件设置」 title, so the bar above it must contribute **no**
    // text — otherwise the same screen announces itself twice.
    final Widget? barTitle = tester.widget<AppBar>(find.byType(AppBar)).title;
    expect(
      barTitle is Text ? (barTitle).data : barTitle,
      '',
      reason: 'a page with its own large title keeps the bar textless '
          '(the same rule the conversation list already follows)',
    );

    // The honest statement — the place the user can actually find — and the hint
    // that says what a tap will do.
    expect(find.text('文件保存位置'), findsOneWidget);
    expect(find.text('下载 / lanlink'), findsOneWidget);
    expect(find.text('点一下选择文件夹'), findsOneWidget);

    // No app-private path anywhere.
    final String current =
        (await backend.platform.loadSettings()).saveDirectory;
    expect(current, isNotEmpty, reason: 'the fixture has a real path');
    expect(find.textContaining('/data/user/0'), findsNothing);
    expect(find.text(current), findsNothing,
        reason: 'the private landing path is not the user destination');

    // ★ The tap: the folder is opened, and **no editor** appears (0.2.23's
    // decision stands — the directory cannot be changed on a phone).
    await tester.tap(find.text('文件保存位置'));
    await tester.pumpAndSettle();
    // 0.2.29: the row opens a small menu; opening the folder is one tap inside it.
    await tester.tap(find.text('打开文件夹'));
    await tester.pumpAndSettle();
    expect(backend.platform.openDownloadsFolderCalls, 1,
        reason: 'the tap must reach the platform — silence was the complaint');
    expect(find.byType(TextField), findsNothing,
        reason: 'the row is not an editor — nothing may open for editing');
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
      'the items we decided NOT to build are absent — not present-but-dead '
      '(docs/18 §8.2)', (WidgetTester tester) async {
    await pumpPhoneSettings(tester);

    for (final String label in <String>[
      '通用',
      '传输',
      '扩展功能',
      '捐赠',
      '推荐给朋友',
      '应用声明',
    ]) {
      expect(find.text(label), findsNothing,
          reason: '$label is deliberately not built; a dead row is worse');
    }
  });
}
