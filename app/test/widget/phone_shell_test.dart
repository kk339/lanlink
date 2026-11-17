/// Widget tests for the narrow-window **phone shell** (M5 spec §3.1–§3.4).
///
/// These mount the real [ShellPage] at a phone width (`< 760`) via `pumpShell`,
/// so they exercise the whole shell: the top bar (title + rescan + receive
/// toggle), the **three-tab** bottom navigation, the 文件 tab's `最近文件 /
/// 已归档` segment and the detail-reset on a tab tap.
///
/// Behavioural assertions only: the widget under test is driven through the
/// public shell state and the assertions read what the user sees.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/app_info.dart';
import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/archived_list.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/shell/nav_rail.dart';
import 'package:lanlink_app/ui/shell/phone_tabs.dart';
import 'package:lanlink_app/ui/shell/list_pane.dart';
import 'package:lanlink_app/ui/widgets/accept_toggle.dart';
import 'package:lanlink_app/ui/widgets/device_row.dart';

import '../support/pump_app.dart';

/// A dialable peer for `initialPeer`.
PeerDevice _peer(String fingerprint,
        {required String alias, bool online = false}) =>
    PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: DeviceKind.desktop,
      isOnline: online,
      lastPort: 53317,
    );

/// The labels of a `NavigationBar`'s destinations, in order.
List<String> _destinationLabels(NavigationBar bar) => <String>[
      for (final Widget destination in bar.destinations)
        if (destination is NavigationDestination) destination.label,
    ];

void main() {
  testWidgets(
      'narrow: the bottom bar has exactly three destinations (设备/文件/设置) '
      'and the left rail is gone', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    final NavigationBar bar =
        tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.destinations.length, 3);
    expect(_destinationLabels(bar), <String>['设备', '文件', '设置']);

    // Default tab = 设备 → the conversations list is up.
    expect(bar.selectedIndex, PhoneTab.devices.index);
    expect(find.byType(DeviceRow), findsWidgets);

    // The collapsed (64px) rail is replaced by the bottom bar on a phone.
    expect(find.byType(NavRail), findsNothing);
  });

  testWidgets(
      'narrow: the bottom bar is ICON-ONLY — the labels are gone from the render '
      'tree, but survive as semantics (docs/18 §2.3)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    final NavigationBar bar =
        tester.widget<NavigationBar>(find.byType(NavigationBar));

    // 1) The bar is *told* to hide labels. (RED before the change: it is not.)
    expect(bar.labelBehavior, NavigationDestinationLabelBehavior.alwaysHide);

    // 2) Accessibility is not lost: the labels still exist as properties, so
    //    the semantics tree keeps naming each destination.
    expect(_destinationLabels(bar), <String>['设备', '文件', '设置']);

    // 3) The text is genuinely out of the render tree — scoped to the bar, since
    //    the app-bar title legitimately shows the same string for the current
    //    tab, so a bare `find.text('设备')` would match that instead.
    // 3) Not shown to the user. `alwaysHide` does **not** delete the label
    //    widget — it keeps it (for the semantics tree and for the show/hide
    //    animation) and fades it out. So the honest observable is the fade:
    //    asserting `findsNothing` here would assert something Flutter does not
    //    do, and would be a test that lies. (docs/18 §7.2's "0 text nodes" is
    //    marked optional for exactly this reason.)
    //
    //    Scoping matters: the app-bar title legitimately shows the same string
    //    for the current tab, so an unscoped `find.text('设备')` would match it.
    for (final String label in <String>['设备', '文件', '设置']) {
      final FadeTransition fade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.descendant(
                of: find.byType(NavigationBar),
                matching: find.text(label),
              ),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      expect(fade.opacity.value, 0, reason: '$label must be faded out');
    }

    // 4) …while the three icons (the only remaining affordance) are present.
    expect(find.byIcon(Icons.forum), findsOneWidget); // 设备
    expect(find.byIcon(Icons.history), findsOneWidget); // 文件
    expect(find.byIcon(Icons.settings), findsOneWidget); // 设置
    expect(bar.destinations.length, 3);
  });

  testWidgets(
      'narrow: the bottom bar is ONE bar — the receive status row above it is '
      'gone (docs/18, "照 Flix")', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    // 1) The row itself is gone — checked by its *copy*, since the widget type
    //    no longer exists at all. (RED before the change.)
    expect(find.text('接收已关闭'), findsNothing);
    expect(find.text('可被接收'), findsNothing);

    // 2) Nothing sits between the pane and the tabs: the pane's bottom edge **is**
    //    the nav bar's top edge. Asserting only "the nav bar still exists" would
    //    be green before the change too — this is the assertion that can actually
    //    tell the two trees apart.
    final Rect nav = tester.getRect(find.byType(NavigationBar));
    final Rect pane = tester.getRect(find.byType(ListPane));
    expect(pane.bottom, moreOrLessEquals(nav.top, epsilon: 0.5),
        reason: 'no second horizontal bar between the pane and the tabs');

    // 3) Still exactly three tabs — the fix must not take a tab with it.
    expect(
      tester
          .widget<NavigationBar>(find.byType(NavigationBar))
          .destinations
          .length,
      3,
    );
  });

  testWidgets(
      'narrow: the receive switch still has a home — the SETTINGS page — and it '
      'still toggles (it is the only place 接收模式 can be turned off)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    final Finder toggle = find.byType(AcceptToggle);
    expect(toggle, findsOneWidget,
        reason: 'removing the bottom row must not remove the only control');
    final bool before = tester.widget<AcceptToggle>(toggle).accepting;
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<AcceptToggle>(toggle).accepting, !before);
  });

  testWidgets(
      '2: the receive switch lives in 设置 (the bottom row is gone, docs/18) and '
      'still writes through the single settings entry (B8)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    // The shell no longer carries the receive row, so neither of its two copies
    // is painted here (docs/18 "照 Flix": one bottom bar).
    expect(find.text('接收已关闭'), findsNothing);
    expect(find.text('可被接收'), findsNothing);

    // The switch itself still writes through `SettingsController.setAccepting`
    // and persists — the B8 property this test has always guarded. Only its host
    // moved (bottom row → 设置), so the assertion is re-pointed, not dropped.
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    // 0.2.25: the receiver starts ON, so this taps it off — the direction the
    // settings page exists for.
    expect(backend.transfer.accepting, isTrue);
    await tester.tap(find.byType(AcceptToggle));
    await tester.pumpAndSettle();
    expect(backend.transfer.accepting, isFalse);
    expect((await backend.platform.loadSettings()).acceptByDefault, isFalse);
  });

  testWidgets(
      'narrow: a bottom-tab tap resets the detail flag (leaves the old detail '
      'and lands on the new module\'s list)', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('AAAA1111', alias: 'Alice Laptop', online: true),
    );

    // The detail is open on mount.
    expect(find.byType(ConversationThread), findsOneWidget);

    // Tap 设置 → the settings body shows; the conversation detail is gone.
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationThread), findsNothing);
    expect(find.text('接收模式'), findsOneWidget);

    // Back to 设备 → the conversation LIST (not the stale detail).
    await tester.tap(find.byIcon(Icons.forum));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceRow), findsWidgets);
    expect(find.byType(ConversationThread), findsNothing);
  });

  testWidgets(
      'narrow: the 文件 tab reaches 已归档 through its secondary segment, and '
      '已归档 is never a fourth bottom tab (Q8)', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    // e5 carries an archived (old) thread, so the archive list has content.
    final FakeBackend backend = Scenarios.e5PeerReinstalled();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    // Switch to the 文件 tab.
    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    expect(find.text('最近文件'), findsOneWidget); // the segment chip
    expect(find.text('已归档'), findsOneWidget); // the segment chip
    expect(find.byType(ArchivedList), findsNothing);

    // The 已归档 segment shows the read-only archive list.
    await tester.tap(find.text('已归档'));
    await tester.pumpAndSettle();
    expect(find.byType(ArchivedList), findsOneWidget);

    // Still exactly three tabs — 已归档 shares the 文件 highlight (Q8).
    final NavigationBar bar =
        tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.destinations.length, 3);
    expect(bar.selectedIndex, PhoneTab.files.index);
  });

  testWidgets(
      'narrow: the top-bar title is the peer alias while a conversation is '
      'open (W3)', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('AAAA1111', alias: 'Alice Laptop', online: true),
    );

    // The alias appears in the conversation header too, so assert the AppBar
    // title specifically.
    final AppBar appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect((appBar.title! as Text).data, 'Alice Laptop');

    // 0.2.9: and the detail bar carries **no brand mark** — the list bar does
    // (see the brand test below), the conversation bar must not, or the peer
    // looks like a child of the product. `home_brand_test.dart` guards the same
    // property from the brand side; this is the shell's own copy of the rule.
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(Image),
      ),
      findsNothing,
      reason: 'a conversation is not branded',
    );
  });

  testWidgets(
      '0.2.9: the conversation LIST bar title is the BRAND (mark + product '
      'name), not the tab label and not an empty bar',
      (WidgetTester tester) async {
    // The bar used to be textless on this page (the brand row under it carried
    // the name). The row is gone, so the bar must now carry the brand — the
    // assertion can tell the three states apart: empty (old), tab label 设备
    // (the generic rule), brand (correct).
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    final Finder bar = find.byType(AppBar);
    expect(
      find.descendant(of: bar, matching: find.text(kAppName)),
      findsOneWidget,
      reason: 'the product name is the list bar title',
    );
    expect(
      find.descendant(of: bar, matching: find.byType(Image)),
      findsOneWidget,
      reason: 'the brand mark sits beside it',
    );
    // The generic rule (module label) must NOT be what the bar says here — a bar
    // reading 设备 over a list of devices was the duplicate-title defect.
    expect(find.descendant(of: bar, matching: find.text('设备')), findsNothing);
  });

  testWidgets(
      '2/3: the conversations ⋮ exposes 筛选设备, 重新扫描 and 手动填写 IP 连接; the '
      'search field stays collapsed until revealed', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    // The search field is collapsed on a phone (M5c §3 — "usually 1–3 devices").
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    // 「筛选设备」, not 「搜索设备」 (0.2.56): the item only reveals a field that
    // filters the rows already listed. Sitting one row above 「重新扫描」, the old
    // wording made the *discovery* action the non-obvious one.
    expect(find.text('筛选设备'), findsOneWidget);
    expect(find.text('搜索设备'), findsNothing,
        reason: 'the ambiguous word must be gone, not merely re-described');
    expect(find.text('重新扫描'), findsOneWidget);
    // 0.2.56 — the third door to the manual address, for the (normal) case where
    // the device list is not empty.
    expect(find.text('手动填写 IP 连接'), findsOneWidget);

    // 筛选设备 reveals the field.
    await tester.tap(find.text('筛选设备'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    // Another module has no ⋮.
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.byTooltip('更多'), findsNothing);
  });

  testWidgets(
      'the phone home has NO ➕ — the ⋮ already offers 重新扫描 (docs/19 §9.9)',
      (WidgetTester tester) async {
    // The ➕ opened a **one-item** menu ("添加其他设备") that called
    // `home.rescan()`; the top bar's ⋮ offers 「重新扫描」 calling the same thing.
    // Two entries for one action, one of them behind an extra tap.
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    expect(find.byTooltip('添加其他设备'), findsNothing);
    expect(find.byIcon(Icons.add), findsNothing);
    // The remaining entry point is still there and still does both actions.
    expect(find.byTooltip('更多'), findsOneWidget);
  });

  testWidgets(
      'B: the phone conversation header is slim — no avatar, and the name is '
      'NOT repeated (only in the top bar)', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    // A real phone reports `isMobile == true`. Declaring it matters from
    // 2026-10-17: the **desktop** message bubble draws a round avatar outside an
    // incoming bubble (docs/19 §8-⑥) while the phone one does not — so a fixture
    // left at `false` would be asserting against the desktop tree, not a phone.
    backend.platform.setMobile(true);
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);
    await tester.tap(find.widgetWithText(DeviceRow, 'Alice Laptop'));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationThread), findsOneWidget);

    // The name appears exactly once — the top-bar title (the header no longer
    // repeats it), and the avatar block is gone.
    expect(find.text('Alice Laptop'), findsOneWidget);
    expect(find.byType(CircleAvatar), findsNothing);

    // ★ The conversation page is now ONE row (docs/18 §2.4): the status line is
    // gone entirely, so neither word is painted here.
    // (Intermediate state, on purpose: the 在线/离线 fact has no home on the
    // conversation page any more — it moves to the home device row in the next
    // stage (§5 / S6). This test therefore drops the old assertion rather than
    // moving it somewhere it does not exist yet; §7.5 lists this file as a
    // legitimate update for exactly this reason.)
    expect(find.text('在线'), findsNothing);
    expect(find.text('离线'), findsNothing);

    // The ⋮ survived the move into the bar: exactly one on this page (the list
    // page's ⋮ is hidden while a detail is open — one ⋮ per page).
    expect(find.byTooltip('更多'), findsOneWidget);

    // The bar itself is one row: ← + name + ⋮.
    final AppBar bar = tester.widget<AppBar>(find.byType(AppBar));
    expect(bar.leading, isNotNull);
    expect(bar.actions, isNotEmpty);
  });

  testWidgets(
      'B3: the conversation ⋮ in the top bar still offers 查看指纹 / 归档会话 '
      '(moved from the removed header, behaviour unchanged)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);
    await tester.tap(find.widgetWithText(DeviceRow, 'Alice Laptop'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('查看指纹'), findsOneWidget);
    expect(find.text('归档会话'), findsOneWidget);

    // 查看指纹 still reports the peer's fingerprint (as a snack bar).
    await tester.tap(find.text('查看指纹'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets(
      '0.2.10: archiving a conversation lands on the LIST — not on the detail\'s '
      'desktop placeholder — and the bar goes back to the brand',
      (WidgetTester tester) async {
    // The state this guards: `clearSelection()` nulls the selection but keeps
    // `detailVisible == true` (`ShellController`), so the phone stayed on the
    // detail branch with nothing selected — the body showed
    // `EmptyState.rightPlaceholder()` ("**左侧**选一台设备开始", which speaks about
    // a left pane a phone does not have) and the bar fell back to the module
    // label 「设备」. Archiving now closes the detail first.
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);
    await tester.tap(find.widgetWithText(DeviceRow, 'Alice Laptop'));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationThread), findsOneWidget);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('归档会话'));
    await tester.pumpAndSettle();

    // 1) The list is back (not the detail branch).
    expect(find.byType(ListPane), findsOneWidget,
        reason: 'archive returns to the conversation list');
    expect(find.byType(ConversationThread), findsNothing);

    // 2) The desktop placeholder never appears on a phone.
    expect(find.text('左侧选一台设备开始'), findsNothing,
        reason: 'that copy talks about a left pane the phone does not have');

    // 3) The bar is the brand again (not the module label 设备).
    final Finder brand = find.descendant(
      of: find.byType(AppBar),
      matching: find.text(kAppName),
    );
    expect(brand, findsOneWidget, reason: 'back to the brand title');
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('设备')),
        findsNothing,
        reason: 'the module label must not become a fallback title');
  });
}
