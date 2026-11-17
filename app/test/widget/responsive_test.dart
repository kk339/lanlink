/// Widget tests for the shell's **responsive degradation** (PRD §8-A1–A3 /
/// design §6.1; E14).
///
/// The three breakpoints are driven by the window width, so each test sizes
/// `tester.view` (`useSurfaceSize`) and asserts the resolved `ShellLayout`:
///
/// * `≥ 1000px` — three panes, full-width rail (168px);
/// * `760–1000px` — three panes, rail collapses to icons (64px);
/// * `< 760px` — two levels (list ⇄ detail) with a back affordance (E14).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/shell/detail_pane.dart';
import 'package:lanlink_app/ui/shell/list_pane.dart';
import 'package:lanlink_app/ui/shell/nav_rail.dart';
import 'package:lanlink_app/ui/shell/phone_shell.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';
import 'package:lanlink_app/ui/theme.dart';
import 'package:lanlink_app/ui/widgets/device_row.dart';

import '../support/pump_app.dart';

// ─────────────────────────────────────────────────────────────────────────────
// docs/18 §7.1 — the "宽屏一个像素都没变" CONTRACT.
//
// These numbers were MEASURED on the pre-P0 tree at `Size(1280, 800)` (before
// the white-card / bottom-nav / top-bar rework), then reviewed one by one (see
// each doc line) — not lifted from a rendering and declared correct. They are a
// contract, so the test asserts them as constants instead of printing them
// (a print scrolls away; a constant does not).
//
// DISCIPLINE (§7.1 item 4): to change a value here you must first name WHICH
// line changed, WHY, and WHO approved it — a blanket re-record is forbidden.
// The one registered exception is the `message_bubble` attachment routing
// (user-approved 2026-10-14, owned by software-engineer-2); it is deliberately
// NOT part of this baseline (its own assertions live with its own work).
// ─────────────────────────────────────────────────────────────────────────────

/// The expanded rail's width at a wide window: 168 logical px.
///
/// An integer grade, not a fractional clamp, and equal to the production
/// `kRailWidth` — so this line also catches a silent edit to that constant.
const double kWideBaselineRailWidth = 168;

/// The middle (list) column's width when wide; equals production `kListWidth`.
const double kWideBaselineListWidth = 320;

/// One device row's height — the same at every breakpoint, so a row that grows
/// or shrinks is a regression rather than "the new design".
const double kWideBaselineDeviceRowHeight = 56;

/// The `CircleAvatar` fill inside a device row: the scheme's light surface tone
/// `#E6E0E9`. Pinned by value because the white-card rework is exactly the kind
/// of change that would tint it without anyone noticing.
const Color kWideBaselineDeviceRowAvatar = Color(0xFFE6E0E9);

/// Tappable entries inside `NavRail` at a wide window: the four module
/// destinations (`ShellModule.values.length`) plus the device identity and the
/// receive toggle.
const int kWideBaselineNavRailItems = 6;

/// The vertical separators between the three columns (one after each of the
/// first two).
/// The number of **seams** between the three columns on a wide screen.
///
/// §7.1 item 4 (name the line, the reason and the approver before touching a
/// baseline value): this was `kWideBaselineVerticalDividers = 2` — "two 1px
/// `VerticalDivider`s". The reference separates its panes with a **~9 image px
/// band** (`#EDF1FC`) instead of a rule (`docs/19 §6.1` / `§8-②`), and the user
/// approved the 改前/改后 sketch on 2026-10-17. **The count is unchanged (2); the
/// thing being counted changed** — so the name changed with it, and the
/// assertion below measures the *gap* rather than counting a widget type.
///
/// Every other baseline line (rail width, list width, row height, avatar fill,
/// nav item count) is **untouched and still exact**.
const int kWideBaselinePaneSeams = 2;

void main() {
  testWidgets('wide (≥ 1000): rail expanded, list + detail both visible (A1)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1200, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    // The expanded rail draws its caption (only shown when expanded).
    expect(tester.getSize(find.byType(NavRail)).width, kRailWidth);
    // 0.2.25: the caption's *word* follows the receive state, and a fresh
    // install now starts receivable — so this is 「接收已开启」. What is being
    // measured is unchanged: the caption is painted because the rail is
    // expanded (the compact case below asserts it is not).
    expect(find.text('接收已开启'), findsOneWidget);
    expect(find.text('会话'), findsWidgets); // the rail label is drawn

    // The middle pane keeps its wide width, and the detail pane is present.
    expect(tester.getSize(find.byType(DeviceRow).first).width, kListWidth);
    expect(find.text('左侧选一台设备开始'), findsOneWidget);
  });

  testWidgets(
      'compact (760–1000): rail collapses to icons, three panes stay '
      '(A2)', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(800, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    // Rail is icons-only: 64px, and the caption is hidden (tooltip only).
    expect(tester.getSize(find.byType(NavRail)).width, kRailCollapsedWidth);
    expect(find.text('接收已开启'), findsNothing);

    // Three panes still visible; the middle pane is now the compact width.
    expect(find.byType(DeviceRow), findsNWidgets(3));
    expect(
      tester.getSize(find.byType(DeviceRow).first).width,
      kListWidthCompact,
    );
    expect(find.text('左侧选一台设备开始'), findsOneWidget);
  });

  testWidgets(
      'narrow (< 760): two levels, and back returns to the list '
      '(A3 / E14)', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    // Only the list is shown (one pane at a time).
    expect(find.byType(DeviceRow), findsNWidgets(3));
    expect(find.text('左侧选一台设备开始'), findsNothing);

    // Opening a conversation shows the detail with a back affordance.
    await tester.tap(find.widgetWithText(DeviceRow, 'Alice Laptop'));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceRow), findsNothing);
    expect(find.byType(ConversationThread), findsOneWidget);
    expect(find.byTooltip('返回列表'), findsOneWidget);

    // Back → the list returns (the selection is kept, so the row is highlighted).
    await tester.tap(find.byTooltip('返回列表'));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceRow), findsNWidgets(3));
    expect(find.byType(ConversationThread), findsNothing);
  });

  testWidgets(
      'narrow (< 760): the collapsed rail is replaced by a three-tab bottom '
      'navigation bar (M5 §3.1)', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    // The phone form: a bottom bar with exactly three destinations.
    final NavigationBar bar =
        tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.destinations.length, 3);

    // The old left rail (64px) is gone on a phone — the bottom bar replaces it.
    expect(find.byType(NavRail), findsNothing);

    // The list itself is unchanged: the merged device rows are still there.
    expect(find.byType(DeviceRow), findsNWidgets(3));
  });

  // ── docs/18 §7.1: the wide-screen baseline contract ────────────────────────

  testWidgets(
      'wide (1280): every baseline line still holds — the P0 rework may not '
      'move the wide screen by a pixel (docs/18 §7.1)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1280, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    // 1. Exactly one rail, at the pinned width, with the pinned item count.
    expect(find.byType(NavRail), findsOneWidget);
    expect(tester.getSize(find.byType(NavRail)).width, kWideBaselineRailWidth);
    expect(
      find.descendant(
        of: find.byType(NavRail),
        matching: find.byType(InkWell),
      ),
      findsNWidgets(kWideBaselineNavRailItems),
    );

    // 2. Three columns, cut apart by a **seam**, not by a rule (docs/19 §8-②).
    //    Measured as a **gap**, because a gap is what the reference has.
    expect(find.byType(ListPane), findsOneWidget);
    expect(find.byType(DetailPane), findsOneWidget);
    expect(
      find.byType(VerticalDivider),
      findsNothing,
      reason: 'docs/19 §8-②: the 1px rule was replaced by the pane seam',
    );
    final Rect railRect = tester.getRect(find.byType(NavRail));
    final Rect listRect = tester.getRect(find.byType(ListPane));
    final Rect detailRect = tester.getRect(find.byType(DetailPane));
    final List<double> seams = <double>[
      listRect.left - railRect.right,
      detailRect.left - listRect.right,
    ];
    expect(seams.length, kWideBaselinePaneSeams);
    for (final double seam in seams) {
      expect(seam, kPaneSeam, reason: 'every seam is kPaneSeam wide');
    }

    // 3. A device row's own geometry — width from the list column, height fixed.
    final Size rowSize = tester.getSize(find.byType(DeviceRow).first);
    expect(rowSize.width, kWideBaselineListWidth);
    expect(rowSize.height, kWideBaselineDeviceRowHeight);

    // 4. …and its avatar fill, the value the white-card rework would tint.
    final CircleAvatar avatar = tester.widget<CircleAvatar>(
      find.descendant(
        of: find.byType(DeviceRow).first,
        matching: find.byType(CircleAvatar),
      ),
    );
    expect(avatar.backgroundColor, kWideBaselineDeviceRowAvatar);

    // 5. The narrow-screen shell and the back-interceptor are NOT mounted here.
    expect(find.byType(PhoneShell), findsNothing);
    expect(find.byType(PopScope), findsNothing);
  });

  testWidgets('the wide baseline values still match production',
      (WidgetTester tester) async {
    // Guards the contract from the other side: if a production constant drifts,
    // this fails even before any rendering does.
    expect(kWideBaselineRailWidth, kRailWidth);
    expect(kWideBaselineListWidth, kListWidth);
    expect(ShellModule.values.length, 4);
  });
}
