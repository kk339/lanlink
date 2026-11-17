/// docs/18 §5 / §7.4 — the two status layers, and the device row's 灰→彩.
///
/// The network layer (this device) and the device layer (one peer) must be
/// **independent**: a failed local network must not grey out an online peer, and
/// vice versa. Both read data that already exists — `DiscoveryStatus.phase` and
/// `PeerDevice.isOnline` — so nothing here invents a state source.
///
/// §7.5's half-promise lives here too: S3 removed the conversation page's
/// "在线/离线" line, so the *fact* has to stay visible on the home page. Deleting
/// an assertion without building another one is how a fact stops being guarded.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/theme.dart';
import 'package:lanlink_app/ui/widgets/device_row.dart';

import '../support/pump_app.dart';

/// The leading icon's colour for the [index]-th [DeviceRow].
Color iconColorAt(WidgetTester tester, int index) => tester
    .widget<Icon>(
      find.descendant(
        of: find.byType(DeviceRow).at(index),
        matching: find.byType(Icon),
      ),
    )
    .color!;

/// A stored-but-offline peer, so an offline row can be rendered at all.
void seedOffline(FakeBackend backend, String fingerprint) {
  backend.repo.addDevice(
    PeerDevice(
      fingerprint: fingerprint,
      alias: 'Offline $fingerprint',
      kind: DeviceKind.desktop,
      isOnline: false,
      lastPort: 53317,
    ),
  );
}

void main() {
  testWidgets('§7.4 网络层独立于设备层：本机网络失败，设备行仍是彩', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    // The local network goes down; the peer is still online.
    backend.discovery.fail('测试：本机网络失败');
    await tester.pumpAndSettle();

    // Network layer: its own line, in its failure state.
    expect(find.text('未连接'), findsOneWidget);
    // Device layer: untouched by the network's failure.
    expect(iconColorAt(tester, 0), statusDeviceOn);
  });

  testWidgets('§7.4 连上→彩：在线行绿、离线行灰（同一 DeviceRow 类型）',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    seedOffline(backend, 'OFFLINE01');
    await tester.pumpAndSettle();

    final int rows = find.byType(DeviceRow).evaluate().length;
    expect(rows, greaterThanOrEqualTo(2));

    // The scenario's peers are online; the seeded one is not.
    final Color online = iconColorAt(tester, 0);
    final Color offline = iconColorAt(tester, rows - 1);
    expect(online, statusDeviceOn);
    expect(offline, isNot(statusDeviceOn));
  });

  testWidgets('§7.4 只在窄屏：宽屏既无状态行，图标色也不随 isOnline 变',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1280, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    // No status line off the phone, and the row colour is the pre-existing grey
    // — the wide-screen baseline (§7.1) asserts the same value independently.
    expect(find.text('已连接'), findsNothing);
    expect(find.text('未连接'), findsNothing);
    expect(iconColorAt(tester, 0), isNot(statusDeviceOn));
  });

  testWidgets('§7.5 兑现：首页设备行把"在线"这件事显出来了', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    final int online = find.byType(DeviceRow).evaluate().length;
    expect(online, greaterThanOrEqualTo(1));
    // The fact S3 removed from the conversation page is visible here, on the
    // home page's device rows (and the network line sits under the title).
    expect(iconColorAt(tester, 0), statusDeviceOn);
    expect(find.text('正在连接…'), findsNothing);
  });
}
