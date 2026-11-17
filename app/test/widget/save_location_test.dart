/// Widget tests for the 保存位置 row (0.2.23, extended in 0.2.26).
///
/// **The defect these pin down.** On Android the settings page offered an
/// editable 文件保存位置 holding `/data/user/0/<pkg>/files/lanlink/received` —
/// a path the user can neither open nor change, and one that is only a
/// **temporary landing spot** since 0.2.19 (the file is published to
/// `Download/lanlink` and then deleted from it). Editing it could not change
/// anything, so the control lied twice: about where the files go, and about being
/// able to change it.
///
/// **0.2.26 added the other half.** The row must not go back to being inert
/// either: a read-only statement that *looks* like a destination answered the
/// user's tap with silence, and they reported it as a bug (「点了没反应，是故意为之
/// 还是bug呢」). So the position stays fixed, and the tap now opens the folder.
/// This file checks the *statement* (what the row says, and that no editor came
/// back); `settings_save_folder_test.dart` checks the *action* (one platform
/// call, the two fallbacks, the clipboard, 320dp).
///
/// Desktop keeps the editable field — there the directory really is the
/// destination — and it now takes effect immediately (pinned in
/// `settings_controller_test.dart`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/downloads_folder.dart' show kLanlinkDownloadsLabel;
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';

import '../support/pump_app.dart';

/// The path that used to leak into the UI on Android.
const String kPrivatePath =
    '/data/user/0/io.github.kk339.lanlink/files/lanlink/received';

/// The 0.2.23 sentence the phone used to show. **Gone in 0.2.26** — the value and
/// the hint now sit on two short lines instead of one long sentence. It is kept
/// here as a constant the assertions can name, so its return would be noticed.
const String kOldPhoneNote = '收到的文件保存在「下载 / lanlink」，可在文件管理器里找到';

FakeBackend backendWith({required bool mobile}) {
  final FakeBackend backend = FakeBackend(
    // Deliberately seeded with the private path: the point is that it must NOT
    // reach the phone's settings page any more.
    settings: const AppSettings(alias: '我的手机', saveDirectory: kPrivatePath),
  );
  if (mobile) {
    backend.platform.setMobile(true);
    // A phone offers 「打开文件夹」; without this the page would take its
    // "unsupported platform" branch and pop a fallback message.
    backend.platform.setSupportsViewInDownloads(true);
  }
  return backend;
}

void main() {
  testWidgets('phone: the save location states where the files go, and is not '
      'an editor', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1200, 900));
    final FakeBackend backend = backendWith(mobile: true);
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialModule: ShellModule.settings,
    );

    expect(find.text('文件保存位置'), findsOneWidget);
    // The value names the real destination, in words a person uses.
    expect(find.text(kLanlinkDownloadsLabel), findsOneWidget);
    // …and the row says what a tap will do (0.2.26).
    expect(find.text('点一下选择文件夹'), findsOneWidget);
    // The long 0.2.23 sentence is replaced, not stacked on top of.
    expect(find.text(kOldPhoneNote), findsNothing);

    // No app-private path anywhere on the page…
    expect(find.textContaining('/data/user/0'), findsNothing);
    // …and no editor: neither the inline field nor the 更改位置 dialog button.
    expect(find.text('更改位置'), findsNothing);
    expect(
      find.widgetWithText(TextField, kPrivatePath),
      findsNothing,
      reason: 'the phone must not show the private path as an editable value',
    );
  });

  testWidgets(
      'phone: tapping the row opens the FOLDER and still no editor — the 0.2.26 '
      'fix for 「点了没反应」', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1200, 900));
    final FakeBackend backend = backendWith(mobile: true);
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialModule: ShellModule.settings,
    );

    await tester.tap(find.text('文件保存位置'));
    await tester.pumpAndSettle();
    // 0.2.29: the tap opens a small menu; 打开文件夹 is the 0.2.26 behaviour.
    await tester.tap(find.text('打开文件夹'));
    await tester.pumpAndSettle();

    // Before 0.2.26 this assertion read `openDownloadsFolderCalls == 0` — the row
    // was inert, and the user reported exactly that as a possible bug.
    expect(backend.platform.openDownloadsFolderCalls, 1,
        reason: 'a tap the user reads as "show me" must reach the platform');
    // An `AlertDialog` with a text field is what used to appear. Still nothing.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(TextField), findsNothing);
    // Success is silent, and nothing was copied.
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('desktop: the save location stays editable, and says it is instant',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1200, 900));
    final FakeBackend backend = backendWith(mobile: false);
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialModule: ShellModule.settings,
    );

    expect(find.text('保存位置'), findsOneWidget);
    expect(find.text('接收到的文件会保存到这个目录，改完立即生效'), findsOneWidget);
    expect(find.text('更改位置'), findsOneWidget);
    // Desktop shows the real path — it is the destination there, so naming it is
    // information, not a leak.
    expect(find.text(kPrivatePath), findsOneWidget);
    // The phone's row — its old sentence, its new value and its hint — must never
    // appear on a desktop, where the directory is genuinely editable.
    expect(find.text(kOldPhoneNote), findsNothing);
    expect(find.text(kLanlinkDownloadsLabel), findsNothing);
    expect(find.text('点一下选择文件夹'), findsNothing);
    expect(find.text('文件保存位置'), findsNothing);
  });
}
