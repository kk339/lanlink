/// Widget tests for the **conversations module** of the three-pane shell — the
/// successor of the old `HomePage` (spec §8.8 / PRD §10 A2; design §8.1).
///
/// Every test mounts `ShellPage` (via `pumpShell`) instead of the deleted
/// `HomePage`. The assertions are the same behaviours, re-anchored on the new
/// widgets: the merged device list is now the middle pane's `DeviceRow`s, the
/// device identity header moved to the left `NavRail`, and the home "more" menu
/// became four rail modules.
///
/// Behavioural assertions only: they drive the fake backend and assert what the
/// user sees (states, copy, navigation), never internal structure (M1 §8).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/peer_discovery.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/shell/shell_page.dart';
import 'package:lanlink_app/ui/widgets/device_row.dart';
import 'package:lanlink_app/ui/widgets/error_banner.dart';
import 'package:lanlink_app/ui/widgets/loading_state.dart';
import 'package:lanlink_app/ui/widgets/troubleshoot_hints.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

/// A stored device row — the merged card's baseline shape (identity + history).
PeerDevice _device(
  String fingerprint,
  String alias,
  DeviceKind kind, {
  bool online = false,
  int? lastPort,
  String? preview,
}) =>
    PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: kind,
      isOnline: online,
      lastPort: lastPort,
      lastPreview: preview,
      lastActivityAt: preview == null ? null : fixedEpoch,
    );

/// A live discovery entry for an online peer.
DiscoveredPeer _online(
  String fingerprint,
  String alias,
  DeviceKind kind, {
  int port = 53317,
}) =>
    DiscoveredPeer(
      fingerprint: fingerprint,
      alias: alias,
      kind: kind,
      address: '192.168.1.10',
      port: port,
      isOnline: true,
      lastSeen: fixedEpoch,
    );

void main() {
  testWidgets('no devices → empty state + the four hints (A2-1)',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    // The conversations body's empty state (the right pane shows its own global
    // placeholder — that is the *new* structure, not a regression).
    expect(find.text('还没有发现设备'), findsOneWidget);
    expect(find.byType(TroubleshootHints), findsOneWidget);
    for (final String hint in kTroubleshootHints) {
      expect(find.text(hint), findsOneWidget, reason: hint);
    }
  });

  testWidgets('loading is a distinct state, not the empty one (A2-2)',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    // Mount without settling: the first frame is still loading. (The shell
    // creates its controllers in `didChangeDependencies`, so the very first
    // build already renders the three panes.)
    await tester.pumpWidget(
      appWithScope(child: const ShellPage(), deps: testDeps(backend)),
    );
    expect(find.byType(LoadingState), findsOneWidget);
    expect(find.text('还没有发现设备'), findsNothing);

    // Once discovery has produced a result, loading gives way to the empty state
    // (an empty list is "found nothing", not "still looking").
    await tester.pumpAndSettle();
    expect(find.byType(LoadingState), findsNothing);
    expect(find.text('还没有发现设备'), findsOneWidget);
  });

  testWidgets(
      'one row per merged device, online-first, with never-transferred and '
      'not-receivable hints (A2-3 / A2-4 / A2-15)',
      (WidgetTester tester) async {
    // Built explicitly (not via `FakeBackend.threeDevices()`): the
    // not-receivable case is an **online** peer that advertises no inbound port.
    // `mergeDeviceCards` (§4.2) lets a live discovery entry override the stored
    // `lastPort`, so the *live* entry — not the stored row — is what must carry
    // `port: 0`; a live entry with the default port would make the peer dialable
    // again and hide the hint.
    final FakeBackend backend = FakeBackend(
      devices: <PeerDevice>[
        _device('AAAA1111', 'Alice Laptop', DeviceKind.desktop,
            online: true, lastPort: 53317, preview: 'report.pdf'),
        _device('BBBB2222', 'Bob Phone', DeviceKind.mobile,
            online: false, lastPort: 53317, preview: 'notes.txt'),
        _device('CCCC3333', 'Carol Desktop', DeviceKind.desktop,
            online: true, lastPort: 0),
      ],
      online: <DiscoveredPeer>[
        _online('AAAA1111', 'Alice Laptop', DeviceKind.desktop),
        // The live entry is the source of truth for `lastPort` while online.
        _online('CCCC3333', 'Carol Desktop', DeviceKind.desktop, port: 0),
      ],
    );
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    expect(find.byType(DeviceRow), findsNWidgets(3));
    expect(find.text('Alice Laptop'), findsOneWidget);
    expect(find.text('Bob Phone'), findsOneWidget);
    expect(find.text('Carol Desktop'), findsOneWidget);
    // Carol is online but advertises no inbound server (`port == 0`).
    expect(find.text(DeviceRow.notReceivable), findsOneWidget);
    // Carol also has no history → "尚未传输过".
    expect(find.text(DeviceRow.neverTransferred), findsWidgets);

    // Online-first order (design §4.2 — the UI must not re-sort): the offline
    // row (Bob) sorts last.
    final List<DeviceRow> rows =
        tester.widgetList<DeviceRow>(find.byType(DeviceRow)).toList();
    expect(
        rows.map((DeviceRow r) => r.device.alias).toList().last, 'Bob Phone');
    expect(rows.first.device.isOnline, isTrue);
  });

  testWidgets(
      'discovery failure shows a persistent banner + the rail error dot, and '
      'retry clears both (A2-14)', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);
    expect(find.byType(ErrorBanner), findsNothing);

    backend.discovery.fail('端口 53317 被占用');
    await tester.pumpAndSettle();
    expect(find.byType(ErrorBanner), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // New in the shell: the left rail also marks a discovery error, so it is
    // visible from *any* module (design §2.4). The rail marker is a tooltip.
    expect(find.byTooltip('端口 53317 被占用'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.byType(ErrorBanner), findsNothing);
    expect(find.byTooltip('端口 53317 被占用'), findsNothing);
  });

  testWidgets('the conversations module offers a manual rescan action (Q10)',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend.threeDevices();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);
    // 0.2.56 — the header's action is a ⋮ holding **two** items (重新扫描 and
    // 手动填写 IP 连接), not a bare refresh icon. The absent tooltip is the
    // assertion that pins the change: it fails if the one-icon header returns.
    expect(find.byTooltip('重新扫描'), findsNothing,
        reason: 'the rescan moved into the ⋮; an icon tooltip would mean the old '
            'shape came back (and that the second action lost its home)');
    // ★ 0.2.57 — and it must **call** rescan, not merely close the menu.
    //
    // The previous version of this test tapped the item and asserted 「3 个
    // DeviceRow 还在」 — but the fixture *is* three devices, so deleting the
    // `home.rescan()` call left the test green. `rescanCount` on the fake is the
    // only observable that makes "tapped" and "called" different things (the
    // phone has had exactly this assertion since 0.2.8; the desktop lost it when
    // the icon became a menu).
    final FakePeerDiscovery discovery = backend.discovery;
    expect(discovery.rescanCount, 0, reason: 'nothing rescanned yet');

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('手动填写 IP 连接'), findsOneWidget,
        reason: 'both actions live in the same menu — that is the whole point of '
            'not putting two icons side by side');

    await tester.tap(find.text('重新扫描'));
    await tester.pumpAndSettle();
    expect(discovery.rescanCount, 1,
        reason: 'the item must reach HomeController.rescan — a menu that only '
            'closes is the "tappable but inert" shape (docs/18 §8.2)');
    expect(find.byType(DeviceRow), findsNWidgets(3));
  });

  testWidgets(
      'the rail receive toggle starts ON (0.2.25 default) and flips the '
      'transfer service (A2-17)', (WidgetTester tester) async {
    // The home status-bar switch moved into the left rail (the settings module
    // keeps a synced `SwitchListTile`); either way the write goes through the
    // one entry, `SettingsController.setAccepting`.
    //
    // The starting value used to be `off` (the P0-7 default). 0.2.25 flipped it:
    // 「接收模式默认开着就行」. The direction of the first tap changed with it —
    // off→on became on→off — so the assertion that matters most now is the
    // **off** one: on a fresh install this is the only way to stop receiving,
    // and a toggle that no longer switches off would be a worse bug than the
    // one this test was written for.
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);
    expect(backend.transfer.accepting, isTrue);
    expect(find.byIcon(Icons.wifi_tethering), findsOneWidget);

    await tester.tap(find.byIcon(Icons.wifi_tethering));
    await tester.pumpAndSettle();
    expect(backend.transfer.accepting, isFalse);
    expect(find.byIcon(Icons.wifi_tethering_off), findsOneWidget);

    // …and back on, so neither direction can break unnoticed.
    await tester.tap(find.byIcon(Icons.wifi_tethering_off));
    await tester.pumpAndSettle();
    expect(backend.transfer.accepting, isTrue);
    expect(find.byIcon(Icons.wifi_tethering), findsOneWidget);
  });

  testWidgets('tapping a row selects it and shows its conversation (PRD §4.1)',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend.threeDevices();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    await tester.tap(find.widgetWithText(DeviceRow, 'Alice Laptop'));
    await tester.pumpAndSettle();

    // The right pane now shows the bound conversation (the old `ConversationPage`).
    expect(find.byType(ConversationThread), findsOneWidget);
  });

  testWidgets(
      'the device identity (alias + short fingerprint) lives in the rail '
      '(PRD §4.1)', (WidgetTester tester) async {
    // A wide window keeps the rail expanded, where the identity text is drawn.
    useSurfaceSize(tester, const Size(1200, 800));
    final FakeBackend backend = FakeBackend(
      status: const DiscoveryStatus(
        phase: DiscoveryPhase.running,
        selfAlias: 'Alex PC',
        selfFingerprint: 'ab:cd:ef:12:34:56:78:90',
        selfPort: 53317,
      ),
    );
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    expect(find.text('Alex PC'), findsOneWidget);
    // First 8 normalised hex chars, upper-cased: ab:cd:ef:12:… → ABCDEF12.
    expect(find.text('ABCDEF12'), findsOneWidget);
  });

  testWidgets(
      'the rail reaches the four modules, each rendering its own body '
      '(PRD §4.1)', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    await pumpShell(tester, backend: backend, settle: true);

    // The old header "more" menu (最近文件 / 设置 / 已归档) became rail modules;
    // at the compact width the rail is collapsed, so each entry is reached by
    // its tooltip. Each module renders a body unique to it.
    await tester.tap(find.byTooltip('最近文件'));
    await tester.pumpAndSettle();
    expect(find.text('还没有文件记录'), findsOneWidget);

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('本机名称'), findsOneWidget);

    await tester.tap(find.byTooltip('已归档'));
    await tester.pumpAndSettle();
    expect(find.text('还没有归档的会话'), findsOneWidget);
  });
}
