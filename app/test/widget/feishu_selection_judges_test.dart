/// docs/18d §6 —— 第二批（电脑端抄飞书「设置」页）的验收判据。
///
/// **本文件覆盖 §6 的第 1 / 2 / 3 / 5 / 6 条**；第 4 条（右栏去 9px 空档 → 1px 线）
/// 随 `docs/18d §3` 一起落地，届时在这里加。
///
/// **来源与口径（`docs/18b` / `docs/18d`）**：
/// * 飞书的中栏选中行是 **342 × 69 图像px**，落在 **360** 宽的内容列里 ⟹ **左右各内缩 9**
///   （`18b §2b` / `§6.2`）；**块不铺满该栏** —— 这是本条最核心的形状；
/// * 参考里**没有**我们那条 **2px 品牌条**（`18d §1`）；
/// * 填充 `#D2DEF5` 来自 `18b §2b`（`mode` 占 92%）；**它不是 alpha 叠得出来的**
///   （我们原有的 `selectionFill` 是 `kSeedColor@10%`，叠出来 `b−r ≈ 21`，
///   而 `#D2DEF5` 是 **35**）⟹ 因此**另开一个槽位**，而不是调 alpha（`18d §4`）。
///
/// **★ 两条互不相同的“没坏”断言**（`docs/18d §1` 那条硬红线的可查化）：
/// 手机卡分支（`carded`）**必须仍然有那条 2px 条、且填充仍是旧槽位** ——
/// 否则"共享件里只动了宽屏"就只是**一句话**，而不是一条能红的断言。
///
/// **判据 6 的写法说明**：它扫的是**源码文本**（`lib/ui/theme.dart`）。本仓已有先例
/// （`test/app_version_test.dart:15` 扫 `pubspec.yaml`）。它防的是"注释回退成谎话"，
/// 因为**下一个人是拿注释当事实读的**。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/ui/theme.dart';
import 'package:lanlink_app/ui/widgets/device_row.dart';

import '../support/pump_app.dart';

/// 宽/紧凑行里那块**内缩的圆角选中块** —— 返回它的矩形与装饰，找不到则 `null`。
///
/// 认它的方式：行内**唯一**带 `borderRadius` 的 `BoxDecoration` 的那个
/// `AnimatedContainer`。不写死颜色，所以亮/暗两套都能读（与 `phone_card_test.dart`
/// 读卡片用的是同一个路子）。
({Rect rect, BoxDecoration decoration})? selectionBlock(
  WidgetTester tester,
  Finder row,
) {
  for (final Element element in find
      .descendant(of: row, matching: find.byType(AnimatedContainer))
      .evaluate()) {
    final Decoration? decoration = (element.widget as AnimatedContainer).decoration;
    if (decoration is BoxDecoration && decoration.borderRadius != null) {
      final RenderBox box = element.renderObject! as RenderBox;
      return (rect: box.localToGlobal(Offset.zero) & box.size, decoration: decoration);
    }
  }
  return null;
}

/// 行里那条 **2px 品牌条**在不在。
///
/// 按**渲染宽度**认它，不按构造参数：`AnimatedContainer` 把 `width` 折进了
/// `constraints`，**没有公开的 `width` getter**（写 `w.width` 编译不过 —— 这处
/// 是本文件第一版的实际报错）。用渲染宽度还顺带说明"它真的被布局成了 2px"，
/// 而不只是"某个控件的参数里写了 2"。
///
/// 只看宽度、不看颜色：未选中时它的颜色是透明的，但**控件仍在树上** ——
/// 所以"有没有这条条"与"这一行选没选中"是两件事，断言前者不需要先选中。
bool hasBrandBar(WidgetTester tester, Finder row) {
  for (final Element element in find
      .descendant(of: row, matching: find.byType(AnimatedContainer))
      .evaluate()) {
    final RenderBox box = element.renderObject! as RenderBox;
    if (box.size.width == kSelectionBarWidth) {
      return true;
    }
  }
  return false;
}

/// 挂上宽屏（`≥1000` ⟹ 三栏 + 展开导轨）、选中第一行，然后返回那一行。
///
/// 用**点一下**来选中（而不是猜夹具的指纹）：`DeviceRow.onTap` 就是
/// `ShellController.selectPeer` 的接线，所以点一下和用户点一下走的是同一条路。
Future<Finder> pumpWideWithFirstRowSelected(WidgetTester tester) async {
  useSurfaceSize(tester, const Size(1200, 800));
  final FakeBackend backend = Scenarios.e14NarrowFold();
  addTearDown(backend.dispose);
  await pumpShell(tester, backend: backend, settle: true);

  final Finder rows = find.byType(DeviceRow);
  expect(rows, findsWidgets, reason: '夹具要至少有设备行，否则下面的断言无从谈起');
  await tester.tap(rows.first);
  await tester.pumpAndSettle();
  return rows;
}

void main() {
  // ── 判据 1 ──────────────────────────────────────────────────────────────
  testWidgets('① 宽屏：选中行的填充是**内缩的块**，左右各 8（不铺满该栏）(docs/18d §1)',
      (WidgetTester tester) async {
    final Finder rows = await pumpWideWithFirstRowSelected(tester);

    final Rect row = tester.getRect(rows.first);
    final ({Rect rect, BoxDecoration decoration})? block =
        selectionBlock(tester, rows.first);
    expect(block, isNotNull, reason: '选中行应当有一个圆角填充块（docs/18d §1）');

    // ★ 量的是**几何**，不是"代码里写了 EdgeInsets" ——
    //   飞书那块 342 落在 360 的列里 ⟹ 左右各 9 图像px ⟹ 我们 320 的栏取 8（由比例推得）。
    expect(
      block!.rect.left - row.left,
      kNavItemInset,
      reason: '左边内缩应为 kNavItemInset($kNavItemInset)：9 图像px / 360 内容宽 = 2.50%，'
          '套到我们 320 宽的栏 = 8.0（docs/18d §4）',
    );
    expect(
      row.right - block.rect.right,
      kNavItemInset,
      reason: '右边内缩应与左边相同 —— 飞书那块的左右内缩是对称的 9 / 9（18b §6.2）',
    );
    expect(
      block.rect.width,
      row.width - 2 * kNavItemInset,
      reason: '块宽 = 栏宽 − 左右内缩',
    );
  });

  // ── 判据 2 ──────────────────────────────────────────────────────────────
  testWidgets('② 宽屏：选中行**没有**那条 2px 品牌条（参考里没有它）(docs/18d §1)',
      (WidgetTester tester) async {
    final Finder rows = await pumpWideWithFirstRowSelected(tester);

    expect(
      hasBrandBar(tester, rows.first),
      isFalse,
      reason: '飞书的选中行是"内缩圆角块"，没有左边那条 2px 竖条 —— '
          '那条条是我们自己的做法（docs/18d §1）',
    );
  });

  // ── 判据 3 ──────────────────────────────────────────────────────────────
  testWidgets('③ 宽屏：选中块填充 = kSelectionFillList(#D2DEF5)，圆角 = kRadiusNavItem',
      (WidgetTester tester) async {
    final Finder rows = await pumpWideWithFirstRowSelected(tester);

    final ({Rect rect, BoxDecoration decoration})? block =
        selectionBlock(tester, rows.first);
    expect(block, isNotNull);
    expect(
      block!.decoration.color,
      kSelectionFillList,
      reason: '飞书中栏选中底 mode = #D2DEF5（占 92%，18b §2b）—— '
          '它是显式常量，不是 alpha 叠出来的（叠出来 b−r≈21，而它是 35）',
    );
    expect(
      block.decoration.borderRadius,
      BorderRadius.circular(kRadiusNavItem),
      reason: '圆角复用 kRadiusNavItem($kRadiusNavItem)：参考给的是一条带 8~10 图像px，'
          '÷ 尺度 1.13 ≈ 7.1~8.8，8 落在带内（18b §6.6）',
    );
  });

  // ── 判据 5 ──────────────────────────────────────────────────────────────
  test('⑤ 两个槽位是两个不同的值（一个槽位扮不了两个角色）(docs/18d §4)', () {
    expect(kSelectionFillList, const Color(0xFFD2DEF5));
    expect(
      selectionFillList(ThemeData.light()),
      isNot(selectionFill(ThemeData.light())),
      reason: '飞书两栏的选中是**两种写法**：中栏浅蓝 #D2DEF5(b−r=35)、'
          '导轨近白 #F8FAFD(b−r=5)（18b §6.3）—— 合成一个槽位就会丢掉其中一种',
    );
  });

  // ── 判据 6 ──────────────────────────────────────────────────────────────
  test('⑥ 两个常量的注释不再自称 CHOSEN，且写明由比值推得 (docs/18d §5)', () {
    final String source = File('lib/ui/theme.dart').readAsStringSync();

    expect(
      source.contains('CHOSEN, NOT MEASURED'),
      isFalse,
      reason: '2026-10-15 起 kRadiusNavItem / kNavItemInset 有了出处（由比值推得）—— '
          '旧标注会与新的算法段落互相打架（docs/18d §5）',
    );
    expect(
      source.toLowerCase().contains('derived by ratio'),
      isTrue,
      reason: '要写明它是**推出来的**（带 8~10 ÷ 尺度 1.13；两条比例都落 8），'
          '而不是"量到 8"',
    );
  });

  // ── 红线：手机卡不许被这处改动碰坏（docs/18d §1）────────────────────────
  testWidgets('★ 窄屏手机卡：那条 2px 条**仍在**，且填充仍是旧槽位（共享件的硬红线）',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    final Finder rows = find.byType(DeviceRow);
    expect(rows, findsWidgets);
    expect(
      hasBrandBar(tester, rows.first),
      isTrue,
      reason: 'device_row.dart 是宽窄共享件：宽屏去掉那条条时，'
          '**手机卡必须原样保留**（docs/18d §1 的硬红线）',
    );

    // 并且手机卡里**不该**出现内缩的选中块 —— 内缩只加在宽/紧凑那条壳上。
    expect(
      selectionBlock(tester, rows.first),
      isNull,
      reason: '手机卡有自己的白卡外壳（kCardHeight 67），不该再套一层内缩圆角块',
    );
  });
}
