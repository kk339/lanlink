/// 飞书对照表 第 3 / 4 / 7 行 —— 三件都落在模块中栏 `list_pane.dart`。
///
/// 每条都**写成"改之前就红"的形式**（"能拦 ≠ 拦住过"）：
/// ② 断言"那条 Divider **不存在**"；④ 断言字号**正好是 20**；⑦ 断言**无描边且填充**。
/// 如果写成"该处有留白 / 有填充"这类正向描述，改前改后都可能绿 —— 那就等于没拦。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/ui/shell/list_pane.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';
import 'package:lanlink_app/ui/theme.dart';

import '../support/pump_app.dart';

Future<void> pumpDesktop(WidgetTester tester) async {
  useSurfaceSize(tester, const Size(1280, 800));
  final FakeBackend backend = Scenarios.e14NarrowFold();
  addTearDown(backend.dispose);
  await pumpShell(tester, backend: backend, settle: true);
}

void main() {
  testWidgets('② 中栏模块标题下不再有 Divider（改用留白）', (WidgetTester tester) async {
    await pumpDesktop(tester);
    expect(
      find.descendant(
          of: find.byType(ListPane), matching: find.byType(Divider)),
      findsNothing,
      reason: '飞书几乎不用线；节与节靠留白（对照表第 3 行）',
    );
  });

  testWidgets('④ 中栏大标题字号 = 20（我们是 16）', (WidgetTester tester) async {
    await pumpDesktop(tester);
    // 该标签在导轨里也有一份 ⟹ 必须限定在 ListPane 内。
    final Text title = tester.widget<Text>(
      find.descendant(
        of: find.byType(ListPane),
        matching: find.text(ShellModule.conversations.label),
      ),
    );
    expect(title.style?.fontSize, 20,
        reason: '钉的是规格值（对照表第 4 行）：目标带 20–27（阈值扫描下标题墨迹'
            '稳定 23 图像 px，行名墨迹 12–16 有漂移 ⟹ 比值 1.44–1.92）；'
            '20 与 22 都在带内。本值是 CHOSEN，不是单点实测');
  });

  testWidgets('⑦ 搜索框：无描边 + 填充式', (WidgetTester tester) async {
    await pumpDesktop(tester);
    final TextField field = tester.widget<TextField>(
      find.descendant(
          of: find.byType(ListPane), matching: find.byType(TextField)),
    );
    final InputDecoration decoration = field.decoration!;

    final InputBorder border = decoration.border!;
    expect(border, isA<OutlineInputBorder>());
    expect((border as OutlineInputBorder).borderSide, BorderSide.none,
        reason: '飞书控件没有一圈描边，是填充式（对照表第 7 行）');
    expect(decoration.filled, isTrue);
    expect(decoration.fillColor, kSearchFill);
  });
}
