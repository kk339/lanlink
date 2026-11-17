/// Widget tests for the phone (narrow) **back stack** (M5 spec §3.4 / PRD §5).
///
/// The narrow shell mounts a `PopScope` so the system back steps back one layer
/// (detail → list) instead of leaving the app, and draws an in-app ← (tooltip
/// `返回列表`) that means the same thing. The system *key* itself is a real-device
/// concern (A2-1/A2-2, `[真机]`); here the pop callback is exercised the way the
/// spec sanctions — by invoking the `PopScope` callback directly — plus the
/// wide-window guard (A5-1: no `PhoneShell`, hence no `PopScope`).
///
/// The `PopScope` probes are scoped to the `ShellPage` subtree: the shell's own
/// `PopScope` lives *inside* `PhoneShell` (hence inside `ShellPage`), while any
/// framework-pop scope (were there one) would be an ancestor of the route — so
/// the scoped finder isolates exactly the shell's own interception.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/panes/file_detail.dart';
import 'package:lanlink_app/ui/shell/nav_rail.dart';
import 'package:lanlink_app/ui/shell/phone_shell.dart';
import 'package:lanlink_app/ui/shell/shell_page.dart';
import 'package:lanlink_app/ui/widgets/device_row.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';

import '../support/pump_app.dart';

/// Matches any `PopScope`, whatever its (generic) type argument.
///
/// **`find.byType(PopScope)` does NOT work here**: `PopScope<T>` is generic, so a
/// bare `Type` literal is `PopScope<dynamic>`, while the `PopScope` this shell
/// builds is inferred as a *different* instantiation (`PopScope<Object>`) — a
/// plain `runtimeType ==` is therefore false and `find.byType(PopScope)` matches
/// **nothing** (verified empirically with this project's SDK). `w is PopScope`
/// uses the covariant subtype check and does match the instance.
Finder _anyPopScope() => find.byWidgetPredicate(
      (Widget widget) => widget is PopScope,
      description: 'PopScope (any type argument)',
    );

/// The shell's own `PopScope` (descendant of [ShellPage]), assuming exactly one.
PopScope _shellPopScope(WidgetTester tester) => tester.widget<PopScope>(
      find.descendant(of: find.byType(ShellPage), matching: _anyPopScope()),
    );

void main() {
  testWidgets(
      'A2-3 / A2-4 (device entry): the in-app ← steps back exactly one layer to '
      'the list', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    // Enter the conversation by tapping a device row.
    await tester.tap(find.widgetWithText(DeviceRow, 'Alice Laptop'));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationThread), findsOneWidget);
    expect(find.byTooltip('返回列表'), findsOneWidget);

    // One step back → the list; the app is not exited (the shell is still up).
    await tester.tap(find.byTooltip('返回列表'));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceRow), findsWidgets);
    expect(find.byType(ConversationThread), findsNothing);
  });

  testWidgets(
      'A2-4 (recent-file entry): the file detail also draws the ← and returns to '
      'the list (the S3 fix — `_fileModule` used to have no back bar)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    // Open the 文件 tab and tap a file row.
    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FileTile, 'photo.png'));
    await tester.pumpAndSettle();

    expect(find.byType(FileDetail), findsOneWidget);
    expect(find.byTooltip('返回列表'), findsOneWidget);

    await tester.tap(find.byTooltip('返回列表'));
    await tester.pumpAndSettle();
    expect(find.byType(FileTile), findsWidgets);
    expect(find.byType(FileDetail), findsNothing);
  });

  testWidgets(
      'A2-1: the detail page swallows the back (PopScope.canPop false) and the '
      'callback steps back one layer; the list lets it through (canPop true)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    // List page: the system back is allowed (it may exit the app — the stack
    // bottom, A2-2).
    expect(_shellPopScope(tester).canPop, isTrue);

    // Detail page: the system back is intercepted.
    await tester.tap(find.widgetWithText(DeviceRow, 'Alice Laptop'));
    await tester.pumpAndSettle();
    final PopScope detailScope = _shellPopScope(tester);
    expect(detailScope.canPop, isFalse);

    // Invoking the pop callback (as the system would, `didPop == false`) steps
    // back exactly one layer — the list returns, the app does not exit.
    detailScope.onPopInvokedWithResult?.call(false, null);
    await tester.pumpAndSettle();
    expect(find.byType(DeviceRow), findsWidgets);
    expect(find.byType(ConversationThread), findsNothing);
  });

  testWidgets(
      'A5-1: a wide window has no PhoneShell and no shell-owned PopScope — the '
      'desktop back behaviour is unchanged (no new interception)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1200, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    expect(find.byType(PhoneShell), findsNothing);
    expect(
      find.descendant(of: find.byType(ShellPage), matching: _anyPopScope()),
      findsNothing,
    );
    // The desktop rail is still the wide layout's navigation.
    expect(find.byType(NavRail), findsOneWidget);
  });
}
