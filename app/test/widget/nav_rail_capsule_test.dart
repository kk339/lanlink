/// 飞书对照表 第 1 行 — 桌面左栏的**选中项是"内缩的圆角胶囊"**，不是"整条直角块"。
///
/// ★ 圆角值与内缩量都是**选定的，不是量到的** —— 详见 `kRadiusNavItem` 的注释：
/// 参考图实为 **1767×1068**（我先前写的"1080"是串了 Flix 手机那批图 ✗），而"±2px"
/// 是我对**缩略图**目测出来的，**从来不是误差棒** ✗。这条测试钉的是**我们的常量本身**
/// （防止它在无人注意时漂移），**它不代表"飞书实测值"**。
///
/// 颜色**不动**（对照表第 2 行已对齐），所以这里同时断言底色仍是 [kSelectionFill]
/// —— 只改形状、不改配色，是这次改动的边界。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/ui/shell/nav_rail.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';
import 'package:lanlink_app/ui/theme.dart';

import '../support/pump_app.dart';

/// The selected module's capsule: the nearest [AnimatedContainer] above its
/// label (label → Row → AnimatedContainer).
Finder capsuleOf(ShellModule module) => find
    .ancestor(
      of: find.text(module.label),
      matching: find.byType(AnimatedContainer),
    )
    .first;

void main() {
  testWidgets('宽屏左栏：选中项 = 内缩的圆角胶囊（不是整条直角块）', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1280, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    final Rect railRect = tester.getRect(find.byType(NavRail));
    // The default module is 会话 (ShellModule.values.first).
    final Finder capsule = capsuleOf(ShellModule.conversations);
    expect(capsule, findsOneWidget);

    final AnimatedContainer container =
        tester.widget<AnimatedContainer>(capsule);
    final BoxDecoration decoration = container.decoration! as BoxDecoration;

    // ① 颜色不变（对照表第 2 行已对齐 ⟹ 这次只改形状）。
    expect(decoration.color, kSelectionFill);
    // ② 形状变：圆角胶囊。
    expect(decoration.borderRadius, BorderRadius.circular(kRadiusNavItem));

    // ③ 内缩：不铺满整条 rail，两侧各留 kNavItemInset。
    final Rect r = tester.getRect(capsule);
    expect(r.width, lessThan(railRect.width));
    expect(r.left - railRect.left, closeTo(kNavItemInset, 0.6));
    expect(railRect.right - r.right, closeTo(kNavItemInset, 0.6));
  });

  testWidgets('未选中项仍然是透明的（形状改动不能顺带把别人也点亮）', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1280, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    final AnimatedContainer other =
        tester.widget<AnimatedContainer>(capsuleOf(ShellModule.settings));
    final BoxDecoration decoration = other.decoration! as BoxDecoration;
    expect(decoration.color, Colors.transparent);
  });
}
