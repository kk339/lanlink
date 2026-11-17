/// The phone home's 「接收已关闭」 marker (0.2.42).
///
/// **The defect.** `接收已开启 / 接收已关闭` was visible in exactly one place —
/// the desktop rail (`nav_rail.dart::_receiveMode`). A phone never mounts that
/// rail, so a user whose receiver was off saw files simply never arrive and had
/// nothing on screen to explain it: the two conclusions available to them are
/// "the network is bad" and "the other side's app is broken", and both are wrong.
///
/// What these tests hold down, each picking a different way to be wrong:
///
/// 1. receiver **off** → the marker is on the home list, and its sentence says
///    what a bare `接收已关闭` label does not: **别人现在发不进来** (plus where to
///    fix it) — a *reason*, not a setting;
/// 2. receiver **on** → not merely invisible: **absent**. The geometry is asserted
///    against the position the list holds when the marker has never existed
///    (`ListPane` flush at the app bar's bottom edge), because a `SizedBox`, an
///    `Opacity(0)` or a `Visibility(maintainSize: true)` would all pass a
///    text-only test while still shoving the whole home list down;
/// 3. it is **not a switch**: no `Switch` / `AcceptToggle` on the home — the one
///    write entry stays 设置 (or the desktop rail);
/// 4. it follows the state **without a tab switch** (the shell listens to
///    `settings`), and comes back to the exact same pixel when re-enabled;
/// 5. the desktop is untouched: at a wide width there is no phone shell, no
///    marker, and the rail still says 接收已关闭.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/home_controller.dart';
import 'package:lanlink_app/controllers/recent_files_controller.dart';
import 'package:lanlink_app/controllers/settings_controller.dart';
import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/ui/shell/list_pane.dart';
import 'package:lanlink_app/ui/shell/nav_rail.dart';
import 'package:lanlink_app/ui/shell/phone_shell.dart';
import 'package:lanlink_app/ui/shell/shell_controller.dart';
import 'package:lanlink_app/ui/widgets/accept_toggle.dart';
import 'package:lanlink_app/ui/widgets/notice_banner.dart';

import '../support/pump_app.dart';

/// The sentence fragment that makes the marker a **reason** rather than a label.
const String _reason = '别人现在发不进来';

/// Mounts the real shell (via `ShellPage`) at a phone width, with the receiver
/// [accepting] or not.
///
/// The state is set on the **transfer service** — the single place it lives, and
/// the one `SettingsController.accepting` forwards to — before the tree mounts,
/// i.e. "the app came up with 接收 off", which is the reported situation.
Future<FakeBackend> _pumpPhone(
  WidgetTester tester, {
  required bool accepting,
}) async {
  useSurfaceSize(tester, const Size(600, 800));
  final FakeBackend backend = Scenarios.e16SelectionSync();
  addTearDown(backend.dispose);
  if (!accepting) {
    await backend.transfer.setAccepting(false);
  }
  await pumpShell(tester, backend: backend, settle: true);
  return backend;
}

/// The marker's strip. `NoticeBanner` is used for exactly this one thing here,
/// so its type is the unambiguous finder (a text finder could match the rail's
/// tooltip or the settings page's caption).
Finder _marker() => find.byType(NoticeBanner);

void main() {
  testWidgets(
      '★ criterion 1: receiver OFF → the home list carries a read-only sentence '
      'that says 别人现在发不进来', (WidgetTester tester) async {
    await _pumpPhone(tester, accepting: false);

    // The home list is up (this is the 设备 tab, not a detail page).
    expect(find.byType(ListPane), findsOneWidget);
    expect(_marker(), findsOneWidget);
    expect(find.textContaining(_reason), findsOneWidget,
        reason: 'a bare 「已关闭」 is a setting, not a reason — say what it costs');
    // …the consequence the user would otherwise never learn: the peer is
    // refused outright, so its own screen says 「被拒绝」.
    expect(find.textContaining('拒绝'), findsOneWidget,
        reason: 'the peer is refused outright: that is what the sender sees');
    // …and the way out. A read-only marker that names no exit is a dead end.
    expect(find.textContaining('「设置」'), findsOneWidget);
  });

  testWidgets(
      '★ criterion 3: it is NOT a switch — no Switch / AcceptToggle on the home',
      (WidgetTester tester) async {
    await _pumpPhone(tester, accepting: false);

    expect(_marker(), findsOneWidget, reason: 'precondition: the marker is up');
    expect(find.byType(Switch), findsNothing,
        reason: 'a second control would be a second place one boolean is written');
    expect(find.byType(AcceptToggle), findsNothing);
  });

  testWidgets(
      '★ criterion 2: receiver ON → no marker, and the list sits flush under the '
      'app bar (no leftover row, no reserved gap)',
      (WidgetTester tester) async {
    await _pumpPhone(tester, accepting: true);

    expect(find.textContaining(_reason), findsNothing);
    expect(_marker(), findsNothing);

    // ★ The geometry half. "Nothing is drawn" is not the same as "nothing takes
    // up space": a zero-height `SizedBox`, an `Opacity(0)` banner or a
    // `Visibility(maintainSize: true)` would all keep the list pushed down while
    // every text assertion above still passed. The baseline "the marker never
    // existed" is the app bar's own bottom edge — the top of the body.
    final Rect appBar = tester.getRect(find.byType(AppBar));
    final Rect list = tester.getRect(find.byType(ListPane));
    expect(list.top, appBar.bottom,
        reason: 'with receiving on the home list starts exactly where the body '
            'starts — same pixels as before 0.2.42');
  });

  testWidgets(
      'the marker is a strip directly above the list — the list starts at its '
      'bottom edge, with no extra space between them',
      (WidgetTester tester) async {
    await _pumpPhone(tester, accepting: false);

    final Rect banner = tester.getRect(_marker());
    final Rect list = tester.getRect(find.byType(ListPane));
    expect(banner.height, greaterThan(0));
    expect(list.top, banner.bottom,
        reason: 'the banner and the list are adjacent; any gap would be an '
            'unexplained blank line under the sentence');
  });

  testWidgets(
      '★ criterion 4: flipping the receiver moves the list and puts it back to the '
      'SAME pixel — no tab switch needed to notice',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    // `PhoneShell` is mounted directly (with the real controllers, stub panes)
    // so this test can drive the one write entry — `SettingsController` — while
    // staying on the home: no tab switch, no selection change. That is what makes
    // it a test of the shell **listening** to `settings` rather than of a rebuild
    // that some other interaction would have caused anyway.
    final ShellController shell = ShellController(repo: backend.repo);
    final HomeController home = HomeController(
      repo: backend.repo,
      discovery: backend.discovery,
      transfer: backend.transfer,
    );
    final RecentFilesController recentFiles = RecentFilesController(
      repo: backend.repo,
      platform: backend.platform,
    );
    final SettingsController settings = SettingsController(
      platform: backend.platform,
      discovery: backend.discovery,
      transfer: backend.transfer,
    );
    addTearDown(shell.dispose);
    addTearDown(home.dispose);
    addTearDown(recentFiles.dispose);
    addTearDown(settings.dispose);
    await settings.load();
    expect(settings.ready, isTrue, reason: 'precondition: a write is allowed');
    expect(settings.accepting, isTrue, reason: 'precondition: 接收 starts on');

    // A probe stands in for the list pane: it fills whatever the shell gives it,
    // so its top edge is the body's content top.
    const Key probe = ValueKey<String>('list-probe');
    await pumpApp(
      tester,
      PhoneShell(
        shell: shell,
        home: home,
        recentFiles: recentFiles,
        settings: settings,
        listPane: const SizedBox.expand(key: probe),
        detailPane: const SizedBox.shrink(),
      ),
      backend: backend,
    );

    final double baseline = tester.getRect(find.byKey(probe)).top;
    expect(find.textContaining(_reason), findsNothing);

    // 接收 off — through the real write entry, while the user is looking at the
    // home list.
    await settings.setAccepting(false);
    await tester.pumpAndSettle();

    expect(_marker(), findsOneWidget,
        reason: 'the shell listens to `settings`, so this needs no tab switch');
    final Rect banner = tester.getRect(_marker());
    expect(tester.getRect(find.byKey(probe)).top, banner.bottom);
    expect(banner.bottom, greaterThan(baseline));

    // …and back on: the marker must leave nothing behind.
    await settings.setAccepting(true);
    await tester.pumpAndSettle();

    expect(_marker(), findsNothing);
    expect(find.textContaining(_reason), findsNothing);
    expect(tester.getRect(find.byKey(probe)).top, baseline,
        reason: 'the home returns to the exact pixel it had before the marker '
            'ever existed — no residual row, padding or spacer');
  });

  testWidgets(
      '★ criterion 5 (regression): the desktop is untouched — the rail still says '
      '接收已关闭, and the phone marker does not exist there',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1400, 900));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await backend.transfer.setAccepting(false);
    await pumpShell(tester, backend: backend, settle: true);

    // Wide layout: the rail, never the phone shell.
    expect(find.byType(NavRail), findsOneWidget);
    expect(find.byType(PhoneShell), findsNothing);
    expect(find.text('接收已关闭'), findsOneWidget,
        reason: 'the rail keeps its own label, unchanged');
    // The phone's sentence is a phone-only string; it must not leak into the
    // desktop layout (the rail's caption lives in a Tooltip instead).
    expect(find.textContaining(_reason), findsNothing);
  });
}
