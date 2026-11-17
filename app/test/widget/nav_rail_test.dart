/// Widget test for the [NavRail] receiver toggle (P0-7).
///
/// **The bug this pins (red before the fix, green after):** the rail's toggle
/// used to call a write path that only rebuilt the receiver and never persisted
/// the choice, so the rail toggle silently reverted to "off" on the next launch.
/// The fix routes it through `SettingsController.setAccepting` — the single
/// receive-mode write entry — so the rail persists the choice exactly like the
/// settings switch already did.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/home_controller.dart';
import 'package:lanlink_app/controllers/settings_controller.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/ui/shell/nav_rail.dart';
import 'package:lanlink_app/ui/shell/shell_controller.dart';

import '../support/pump_app.dart';

void main() {
  testWidgets('the rail receive switch persists the choice (P0-7)',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend.threeDevices();
    addTearDown(backend.dispose);
    final ShellController shell = ShellController(repo: backend.repo);
    final HomeController home = HomeController(
      repo: backend.repo,
      discovery: backend.discovery,
      transfer: backend.transfer,
    );
    final SettingsController settings = SettingsController(
      platform: backend.platform,
      discovery: backend.discovery,
      transfer: backend.transfer,
    );
    addTearDown(shell.dispose);
    addTearDown(home.dispose);
    addTearDown(settings.dispose);
    await settings.load(); // the rail's write path reads the persisted settings

    await pumpApp(
      tester,
      NavRail(controller: shell, home: home, settings: settings),
      backend: backend,
      settle: true,
    );

    // 0.2.25: a fresh install starts receivable, so the rail shows the
    // tethering icon. The direction of the write under test is unchanged — this
    // still asserts that the rail **persists** what it sends to the receiver —
    // it is only the starting state that moved.
    expect(find.byIcon(Icons.wifi_tethering), findsOneWidget);

    await tester.tap(find.byIcon(Icons.wifi_tethering));
    await tester.pumpAndSettle();

    // The receiver is off AND the choice was persisted. Before the fix the second
    // assertion was false (the rail never wrote the setting) — that is the "red".
    expect(backend.transfer.accepting, isFalse);
    expect((await backend.platform.loadSettings()).acceptByDefault, isFalse);
    expect(find.byIcon(Icons.wifi_tethering_off), findsOneWidget);
  });
}
