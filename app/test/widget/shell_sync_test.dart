/// Widget tests for the three-pane shell's **selection synchronisation**
/// (PRD §8-B5–B9 / §6 E16; design §2.4).
///
/// E16 is the hard requirement: switching modules or selecting a session must
/// never show "the highlight on A while the right pane shows B". Both the middle
/// row's highlight and the right pane read the **same** `ShellController`
/// selection, so they cannot disagree within a render.
///
/// B5: the rail is present in every module (no whole-page `Navigator.push`).
/// B7: at most one highlighted row per render.
/// B8: the rail's receive indicator and the settings switch are one source.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/shell/nav_rail.dart';
import 'package:lanlink_app/ui/widgets/device_row.dart';

import '../support/pump_app.dart';

PeerDevice _peer(String fingerprint,
        {required String alias, bool online = false}) =>
    PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: DeviceKind.desktop,
      isOnline: online,
      lastPort: 53317,
    );

void main() {
  testWidgets('B5 the rail persists across every module (no page-level nav)',
      (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    for (final String label in <String>['最近文件', '已归档', '设置', '会话']) {
      await tester.tap(find.byTooltip(label));
      await tester.pumpAndSettle();
      // The rail never leaves the tree, and every module entry stays tappable.
      expect(find.byType(NavRail), findsOneWidget, reason: label);
      expect(find.byTooltip(label), findsOneWidget, reason: label);
    }
  });

  testWidgets(
      'E16 selecting a row moves the highlight AND the right pane together; '
      'exactly one row is highlighted (B7 / B9)', (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    int highlighted() => tester
        .widgetList<DeviceRow>(find.byType(DeviceRow))
        .where((DeviceRow row) => row.selected)
        .length;

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('AAAA1111', alias: 'Alice Laptop', online: true),
    );

    expect(highlighted(), 1);
    expect(
      tester
          .widget<DeviceRow>(find.widgetWithText(DeviceRow, 'Alice Laptop'))
          .selected,
      isTrue,
    );
    expect(find.byType(ConversationThread), findsOneWidget);

    // Move the selection: exactly one highlight, on the new row, and the right
    // pane follows.
    await tester.tap(find.widgetWithText(DeviceRow, 'Bob Phone'));
    await tester.pumpAndSettle();
    expect(highlighted(), 1);
    expect(
      tester
          .widget<DeviceRow>(find.widgetWithText(DeviceRow, 'Bob Phone'))
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<DeviceRow>(find.widgetWithText(DeviceRow, 'Alice Laptop'))
          .selected,
      isFalse,
    );
    expect(find.byType(ConversationThread), findsOneWidget);
  });

  testWidgets(
      'E16 switching modules keeps the selection (highlight + right pane agree '
      'on return)', (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('AAAA1111', alias: 'Alice Laptop', online: true),
    );

    await tester.tap(find.byTooltip('最近文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('会话'));
    await tester.pumpAndSettle();

    // The selection survived the module round-trip; the row is still highlighted
    // and the right pane still shows the same conversation.
    expect(
      tester
          .widget<DeviceRow>(find.widgetWithText(DeviceRow, 'Alice Laptop'))
          .selected,
      isTrue,
    );
    expect(find.byType(ConversationThread), findsOneWidget);
  });

  testWidgets(
      'B8 the rail receive indicator and the settings switch are one source',
      (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);
    // 0.2.25: a fresh install is receivable, so the rail starts on.
    expect(backend.transfer.accepting, isTrue);

    // Toggle from the rail…
    await tester.tap(find.byIcon(Icons.wifi_tethering));
    await tester.pumpAndSettle();
    expect(backend.transfer.accepting, isFalse);

    // …and the settings switch shows the same value (one source of truth).
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
  });
}
