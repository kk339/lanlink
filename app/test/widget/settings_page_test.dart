/// Widget tests for the shell's **设置 module** — the successor of the old
/// `SettingsPage` (spec §6 T04; PRD §4.4, A2-16 / A2-17; design §8.1).
///
/// Each test mounts `ShellPage(initialModule: ShellModule.settings)` (via
/// `pumpShell`) instead of the deleted `SettingsPage`; the three settings now
/// render in `SettingsBody` and run end to end against in-memory doubles: the
/// alias write-through to **both** ports (§4.6), the save-directory persistence,
/// the receive toggle's default and single source of truth, and a failed write
/// surfaced **in place** (never silently swallowed, §4.4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';
import 'package:lanlink_app/ui/widgets/error_banner.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

void main() {
  testWidgets(
    'renders exactly the three V1 settings and none of the dropped Flix items '
    '(A2-16)',
    (WidgetTester tester) async {
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);

      await pumpShell(
        tester,
        initialModule: ShellModule.settings,
        backend: backend,
        settle: true,
      );

      expect(find.text('本机名称'), findsOneWidget);
      expect(find.text('保存位置'), findsOneWidget);
      expect(find.text('接收模式'), findsOneWidget);

      // PRD §4.4 裁剪边界: these must never appear.
      expect(find.textContaining('集团码'), findsNothing);
      expect(find.textContaining('捐赠'), findsNothing);
      expect(find.textContaining('推荐'), findsNothing);
    },
  );

  testWidgets(
    'echoes the loaded settings and writes a new device name through both '
    'ports (§4.6 / P1-1)',
    (WidgetTester tester) async {
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);

      await pumpShell(
        tester,
        initialModule: ShellModule.settings,
        backend: backend,
        settle: true,
      );
      expect(find.text('This device'), findsOneWidget);

      await tester.enterText(find.byType(TextField).at(0), 'Alice Laptop');
      await tester.tap(find.text('保存名称'));
      await tester.pumpAndSettle();

      expect(backend.discovery.status.selfAlias, 'Alice Laptop');
      expect(backend.transfer.alias, 'Alice Laptop');
      expect(find.text('Alice Laptop'), findsOneWidget);
    },
  );

  testWidgets(
    'persists a changed save directory (§4.4)',
    (WidgetTester tester) async {
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);

      await pumpShell(
        tester,
        initialModule: ShellModule.settings,
        backend: backend,
        settle: true,
      );
      expect(find.text('/received'), findsOneWidget);

      await tester.enterText(find.byType(TextField).at(1), r'D:\Files');
      await tester.tap(find.text('更改位置'));
      await tester.pumpAndSettle();

      expect(
        (await backend.platform.loadSettings()).saveDirectory,
        r'D:\Files',
      );
      expect(find.text(r'D:\Files'), findsOneWidget);
    },
  );

  testWidgets(
    'the receive toggle starts ON (0.2.25 default), drives the single source of '
    'truth, and remembers being turned off (A2-17)',
    (WidgetTester tester) async {
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);

      await pumpShell(
        tester,
        initialModule: ShellModule.settings,
        backend: backend,
        settle: true,
      );

      // 0.2.25 — 「接收模式默认开着就行」. The assertion below used to be `isFalse`;
      // the new default is the product decision, so the expectation follows it
      // rather than the old behaviour being preserved for the test's sake.
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
      expect(backend.transfer.accepting, isTrue);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      // The direction that now matters: this is the only place receiving can be
      // turned off, and the choice must reach the receiver…
      expect(backend.transfer.accepting, isFalse);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      // …and be remembered as the default (P0-7).
      expect(
        (await backend.platform.loadSettings()).acceptByDefault,
        isFalse,
      );
    },
  );

  testWidgets(
    'a failed save is shown in place and can be dismissed — never silent '
    '(§4.4 / E10)',
    (WidgetTester tester) async {
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);
      backend.platform.failSaveWith('目录不可写');

      await pumpShell(
        tester,
        initialModule: ShellModule.settings,
        backend: backend,
        settle: true,
      );

      await tester.enterText(find.byType(TextField).at(1), '/nope');
      await tester.tap(find.text('更改位置'));
      await tester.pumpAndSettle();

      expect(find.byType(ErrorBanner), findsOneWidget);
      expect(find.textContaining('保存位置保存失败'), findsOneWidget);

      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.byType(ErrorBanner), findsNothing);
    },
  );
}
