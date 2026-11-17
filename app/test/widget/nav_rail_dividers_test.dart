/// 飞书对照表 第 3 行 —— **"几乎不用线"**：节与节靠**留白**，不靠 1px 分隔线。
///
/// 抄的是：**图1 左栏**（身份块 → 模块项 → 接收开关，之间只有留白，没有横线）。
///
/// 这一条**单变量**：只动导轨里的 [Divider]，别的一概不碰（形状/分栏/分页签都不在其中）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/ui/shell/nav_rail.dart';

import '../support/pump_app.dart';

void main() {
  testWidgets('宽屏导轨：节与节靠留白，导轨内没有 Divider',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1280, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    final Finder rail = find.byType(NavRail);
    expect(rail, findsOneWidget);

    // ① 不再用线。
    expect(
      find.descendant(of: rail, matching: find.byType(Divider)),
      findsNothing,
      reason: '飞书几乎不用线；节与节靠留白（对照表第 3 行）',
    );

    // ② 结构没被拆掉：身份块与接收开关都还在（改分隔方式不等于删内容）。
    expect(find.byType(CircleAvatar), findsWidgets);
    expect(find.textContaining('接收已'), findsWidgets);
  });
}
