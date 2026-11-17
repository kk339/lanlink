/// 0.2.29 — the phone's 「文件保存位置」 row became **choosable**: a folder inside
/// `Download`, picked through `ACTION_OPEN_DOCUMENT_TREE`, stored, and used by the
/// publish step from then on.
///
/// **What the user asked for and what was refused.** "能改" — but a truly free
/// directory (an arbitrary SAF tree) would change what a received file *is*: its
/// identity would become a `content://` URI, and six platform capabilities
/// (`exists` / `openFile` / `shareFile` / thumbnails / byte reads /
/// 「在下载里查看」) plus three string-only uses (copy path, details, the
/// pre-resend probe) all assume an absolute path a `File()` can open. They would
/// not fail loudly — they would quietly behave as "the files are gone". So the
/// folder is choosable **inside `Download`**, the write still goes through
/// `MediaStore` with a derived `RELATIVE_PATH`, and the database keeps storing
/// real paths.
///
/// These tests cover the **UI contract**: three states on the row, a small menu
/// rather than a leap, and the three outcomes that must change nothing
/// (cancelled / invalid / unsupported). The persistence and native sides have
/// their own files (`settings_document_migration_test.dart`,
/// `android_folder_picker_test.dart`).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/downloads_folder.dart'
    show downloadsFolderLabel, downloadsFolderPath;
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/platform_ports.dart'
    show DownloadsFolderChoice, PickDownloadsFolderOutcome, ViewInDownloadsOutcome;
import '../support/pump_app.dart';

/// The hint under the title (0.2.29 wording — it used to say
/// 「点一下在文件管理器里打开」, which stopped being true once a tap asks a question).
const String _hint = '点一下选择文件夹';

/// The default folder, as the row shows it.
const String _defaultLabel = '下载 / lanlink';

/// Mounts the phone settings page.
///
/// Starts where the app starts (the conversation list) and taps 设置, i.e. the
/// ordering a user takes — the settings load has already been delivered by the
/// time the page opens, which is the ordering the 0.2.23 defect needed.
Future<FakeBackend> _pumpPhoneSettings(
  WidgetTester tester, {
  String? receivedSubdirectory,
  Size size = const Size(600, 900),
}) async {
  useSurfaceSize(tester, size);
  final FakeBackend backend = FakeBackend(
    settings: AppSettings(
      alias: '我的手机',
      saveDirectory: '/data/user/0/io.github.kk339.lanlink/files/lanlink/received',
      receivedSubdirectory: receivedSubdirectory ?? 'lanlink',
    ),
  );
  addTearDown(backend.dispose);
  backend.platform.setMobile(true);
  backend.platform.setSupportsViewInDownloads(true);

  await pumpShell(tester, backend: backend, settle: true);
  await tester.tap(find.byIcon(Icons.settings));
  await tester.pumpAndSettle();
  return backend;
}

/// Opens the row's sheet.
Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('文件保存位置'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      '★ state 1 — a fresh install says 下载 / lanlink and offers two ways out, '
      'not three: 「恢复默认」 is absent while we are already the default',
      (WidgetTester tester) async {
    await _pumpPhoneSettings(tester);

    expect(find.text('文件保存位置'), findsOneWidget);
    expect(find.text(_defaultLabel), findsOneWidget);
    expect(find.text(_hint), findsOneWidget);

    await _openSheet(tester);

    expect(find.text('打开文件夹'), findsOneWidget,
        reason: 'the 0.2.26 action stays one tap away — dropping it would '
            're-break 「点了没反应」');
    expect(find.text('选择文件夹'), findsOneWidget);
    expect(find.text('恢复默认'), findsNothing,
        reason: 'a row must never offer a no-op: we are already the default');
  });

  testWidgets('★ state 2 — a chosen folder shows up in the value, and then '
      '「恢复默认」 appears', (WidgetTester tester) async {
    await _pumpPhoneSettings(tester, receivedSubdirectory: '素材');

    expect(find.text(downloadsFolderLabel('素材')), findsOneWidget);
    expect(find.text(_defaultLabel), findsNothing);

    await _openSheet(tester);
    expect(find.text('恢复默认'), findsOneWidget);
  });

  testWidgets(
      '★ picking a folder stores it AND moves the live publish folder — the '
      'value, the setting and the port all agree',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpPhoneSettings(tester);
    backend.platform.pickDownloadsFolderReply = const DownloadsFolderChoice(
      PickDownloadsFolderOutcome.picked,
      subdirectory: '素材',
    );

    await _openSheet(tester);
    await tester.tap(find.text('选择文件夹'));
    await tester.pumpAndSettle();

    expect(backend.platform.pickDownloadsFolderCalls, 1);
    // The row now says where files will go …
    expect(find.text(downloadsFolderLabel('素材')), findsOneWidget);
    // … the document says the same …
    expect(
      (await backend.platform.loadSettings()).receivedSubdirectory,
      '素材',
      reason: 'a pick that is not persisted is a pick that disappears on restart',
    );
    // … and so does the value the publish step reads, which is what decides where
    // the *next* received file lands (0.2.29's whole point).
    expect(backend.platform.receivedSubdirectory, '素材');
  });

  testWidgets(
      '★ an out-of-bounds pick says what is allowed and changes NOTHING — the '
      'stored folder, the live folder and the row all stay put',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpPhoneSettings(tester);
    backend.platform.pickDownloadsFolderReply = const DownloadsFolderChoice(
      PickDownloadsFolderOutcome.invalid,
      reason: '只能选择「下载」里的文件夹',
    );

    await _openSheet(tester);
    await tester.tap(find.text('选择文件夹'));
    await tester.pumpAndSettle();

    expect(find.text('请选择「下载」里的文件夹'), findsOneWidget);
    expect(find.text(_defaultLabel), findsOneWidget);
    expect(
      (await backend.platform.loadSettings()).receivedSubdirectory,
      'lanlink',
    );
    expect(backend.platform.receivedSubdirectory, 'lanlink',
        reason: 'a refused pick must not move where the next file lands');
  });

  testWidgets('★ backing out of the chooser is silence — not an error toast',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpPhoneSettings(tester);
    // The fake's default answer is `cancelled`.
    await _openSheet(tester);
    await tester.tap(find.text('选择文件夹'));
    await tester.pumpAndSettle();

    expect(backend.platform.pickDownloadsFolderCalls, 1);
    expect(find.byType(SnackBar), findsNothing,
        reason: '「你改主意了」 is not something to announce');
    expect((await backend.platform.loadSettings()).receivedSubdirectory,
        'lanlink');
  });

  testWidgets('★ a chooser that cannot run says so and changes nothing',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpPhoneSettings(tester);
    backend.platform.pickDownloadsFolderReply = const DownloadsFolderChoice(
      PickDownloadsFolderOutcome.unsupported,
    );

    await _openSheet(tester);
    await tester.tap(find.text('选择文件夹'));
    await tester.pumpAndSettle();

    expect(find.text('这个系统不能选择保存文件夹'), findsOneWidget);
    expect(backend.platform.receivedSubdirectory, 'lanlink');
  });

  testWidgets('★ 「恢复默认」 brings back 下载 / lanlink', (WidgetTester tester) async {
    final FakeBackend backend =
        await _pumpPhoneSettings(tester, receivedSubdirectory: '素材');

    await _openSheet(tester);
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();

    expect(find.text(_defaultLabel), findsOneWidget);
    expect((await backend.platform.loadSettings()).receivedSubdirectory,
        'lanlink');
    expect(backend.platform.receivedSubdirectory, 'lanlink');
  });

  testWidgets(
      '★ 「打开文件夹」 opens the folder the user CHOSE, not the default one',
      (WidgetTester tester) async {
    final FakeBackend backend =
        await _pumpPhoneSettings(tester, receivedSubdirectory: '素材');
    backend.platform.viewInDownloadsOutcome = ViewInDownloadsOutcome.opened;

    await _openSheet(tester);
    await tester.tap(find.text('打开文件夹'));
    await tester.pumpAndSettle();

    expect(backend.platform.openDownloadsFolderCalls, 1);
    expect(backend.platform.openDownloadsFolderSubdirectories.single, '素材',
        reason: 'opening 下载/lanlink after choosing 素材 would be a lie');
  });

  testWidgets('★ the folder path the clipboard gets is the current one',
      (WidgetTester tester) async {
    // `noDirectory` is the "nothing received since the folder was chosen" case —
    // the fallback must hand out the *chosen* path, not the built-in default.
    final FakeBackend backend =
        await _pumpPhoneSettings(tester, receivedSubdirectory: '素材');
    backend.platform.viewInDownloadsOutcome = ViewInDownloadsOutcome.noDirectory;

    final List<String> copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          final Object? arguments = call.arguments;
          if (arguments is Map && arguments['text'] is String) {
            copied.add(arguments['text'] as String);
          }
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await _openSheet(tester);
    await tester.tap(find.text('打开文件夹'));
    await tester.pumpAndSettle();

    expect(find.text('这个系统没有能打开文件夹的应用，路径已复制到剪贴板'),
        findsOneWidget);
    expect(copied, <String>[downloadsFolderPath('素材')]);
    expect(copied.single, 'Download/素材');
  });

  testWidgets('★ 320dp still holds: the longer value (下载 / 素材) does not push '
      'the title out', (WidgetTester tester) async {
    await _pumpPhoneSettings(
      tester,
      receivedSubdirectory: '素材',
      size: const Size(320, 800),
    );

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.text('文件保存位置')).width, greaterThan(0));
    expect(find.text(downloadsFolderLabel('素材')), findsOneWidget);
    expect(find.text(_hint), findsOneWidget);
  });
}
