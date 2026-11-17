/// 0.2.26 — the phone's 「文件保存位置」 row is **tappable, and tapping it opens
/// the folder**.
///
/// The user's report: 「手机上设置界面，文件保存位置现在是改不了的，因为点了没反应，
/// 是故意为之还是bug呢」. Both halves of that are addressed here:
///
///  * the **position is still not editable** — on Android `saveDirectory` is a
///    temporary landing spot whose contents are published to `Download/lanlink`
///    and then deleted (0.2.23 removed the fake 「更改位置」 editor), so this file
///    asserts that no editor came back;
///  * but the tap now **does** something real — it opens that folder through
///    `PlatformPorts.openDownloadsFolder` (the no-file form of the 0.2.24
///    `viewInDownloads`). A row that looks like a destination and answers a tap
///    with silence is indistinguishable from a bug, which is exactly what the
///    user concluded.
///
/// The desktop is checked in the other direction on purpose: there the directory
/// **is** editable and takes effect immediately, so its 「更改位置」 must survive
/// and the phone's 「点一下选择文件夹」 hint must not leak into it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/downloads_folder.dart'
    show kLanlinkDownloadsLabel, kLanlinkDownloadsPath;
import 'package:lanlink_app/domain/platform_ports.dart'
    show ViewInDownloadsOutcome;
import 'package:lanlink_app/ui/shell/shell_module.dart';

import '../support/pump_app.dart';

/// The exact wording of the "no folder app" fallback.
const String _noAppMessage = '这个系统没有能打开文件夹的应用，路径已复制到剪贴板';

/// The other fallback (bridge broken / unsupported).
const String _failedMessage = '打开文件夹失败，路径已复制到剪贴板';

/// The subtitle that names the action.
/// The hint under the title. **0.2.29 re-worded it**: the tap no longer jumps to
/// the file manager (0.2.26) but opens a small menu, so the row says
/// 「点一下选择文件夹」 and the open action lives inside that menu.
const String _hint = '点一下选择文件夹';

/// Every `Clipboard.setData` that reached the platform channel, in order.
final List<String> _clipboardWrites = <String>[];

/// One ordered log across the fake **port** and the mocked platform channel.
final List<String> _events = <String>[];

/// Mounts the phone settings page (600×800 unless [size] says otherwise).
///
/// Starts where the app starts (the conversations list) and then taps 设置, i.e.
/// the ordering a user takes — the same ordering the 0.2.23 test used, because
/// the settings load has already been delivered by the time the page opens.
Future<FakeBackend> _pumpPhoneSettings(
  WidgetTester tester, {
  bool supportsFolderAction = true,
  ViewInDownloadsOutcome outcome = ViewInDownloadsOutcome.opened,
  Size size = const Size(600, 800),
}) async {
  useSurfaceSize(tester, size);
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.platform.setMobile(true);
  backend.platform.setSupportsViewInDownloads(supportsFolderAction);
  backend.platform.viewInDownloadsOutcome = outcome;
  backend.platform.onOpenDownloadsFolder = () => _events.add('port:openFolder');

  await pumpShell(tester, backend: backend, settle: true);
  await tester.tap(find.byIcon(Icons.settings));
  await tester.pumpAndSettle();
  return backend;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _clipboardWrites.clear();
    _events.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform,
            (MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        final Object? arguments = call.arguments;
        final Object? text = arguments is Map ? arguments['text'] : null;
        _clipboardWrites.add(text is String ? text : '<not a string>');
        _events.add('clipboard');
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
      '★ the row states WHERE and advertises THAT IT DOES SOMETHING: value '
      '「下载 / lanlink」, a ›, and the hint naming the action',
      (WidgetTester tester) async {
    await _pumpPhoneSettings(tester);

    expect(find.text('文件保存位置'), findsOneWidget);
    expect(find.text(kLanlinkDownloadsLabel), findsOneWidget,
        reason: 'the value is the folder, said the way a person says it');
    expect(find.text(_hint), findsOneWidget);

    final Finder row =
        find.ancestor(of: find.text('文件保存位置'), matching: find.byType(ListTile));
    expect(row, findsOneWidget);
    expect(tester.widget<ListTile>(row).onTap, isNotNull,
        reason: 'a row the user reads as a destination must answer a tap');
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.chevron_right)),
      findsOneWidget,
      reason: 'the › is backed by the real action below, never decoration',
    );
  });

  testWidgets(
      '★ tapping it asks the platform ONCE to open the folder, and a success '
      'says nothing at all',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpPhoneSettings(tester);

    await tester.tap(find.text('文件保存位置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开文件夹'));
    await tester.pumpAndSettle();

    expect(backend.platform.openDownloadsFolderCalls, 1,
        reason: 'one tap, one platform call');
    // Nothing else was asked: this is not the file-scoped action.
    expect(backend.platform.viewInDownloadsRequests, isEmpty);
    // Success is silent — the folder itself is the answer.
    expect(find.byType(SnackBar), findsNothing);
    expect(_clipboardWrites, isEmpty);
    // And it is not an editor: nothing opened.
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
      '★ no app can open a folder: the sentence appears, the folder path is '
      'really on the clipboard, and the copy happens AFTER the platform refused',
      (WidgetTester tester) async {
    await _pumpPhoneSettings(
      tester,
      outcome: ViewInDownloadsOutcome.noApp,
    );

    await tester.tap(find.text('文件保存位置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开文件夹'));
    await tester.pumpAndSettle();

    expect(find.text(_noAppMessage), findsOneWidget);
    expect(_clipboardWrites, <String>[kLanlinkDownloadsPath],
        reason: 'the readable path, never a content:// URI the user cannot use');
    expect(_clipboardWrites.single, 'Download/lanlink',
        reason: 'exactly what a file manager search box wants');
    expect(_events, <String>['port:openFolder', 'clipboard'],
        reason: 'a toast claiming 已复制 before the write would be a lie');
  });

  testWidgets('★ no folder yet (nothing received since 0.2.19) takes the same '
      'honest fallback', (WidgetTester tester) async {
    await _pumpPhoneSettings(
      tester,
      outcome: ViewInDownloadsOutcome.noDirectory,
    );

    await tester.tap(find.text('文件保存位置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开文件夹'));
    await tester.pumpAndSettle();

    expect(find.text(_noAppMessage), findsOneWidget);
    expect(_clipboardWrites, <String>[kLanlinkDownloadsPath]);
  });

  testWidgets('a broken bridge is reported as a failure — and still leaves the '
      'path usable', (WidgetTester tester) async {
    await _pumpPhoneSettings(
      tester,
      outcome: ViewInDownloadsOutcome.failed,
    );

    await tester.tap(find.text('文件保存位置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开文件夹'));
    await tester.pumpAndSettle();

    expect(find.text(_failedMessage), findsOneWidget);
    expect(_clipboardWrites, <String>[kLanlinkDownloadsPath]);
  });

  testWidgets(
      '★ the row is still NOT an editor: no 更改位置, no app-private path, and the '
      'receive switch is untouched right below it',
      (WidgetTester tester) async {
    await _pumpPhoneSettings(tester);

    // 0.2.23 removed the editor because it could not change anything; 0.2.26 did
    // not bring it back — only the tap's *destination* changed.
    expect(find.text('更改位置'), findsNothing,
        reason: 'on a phone the directory cannot be changed; do not offer it');
    expect(find.text('保存位置'), findsNothing,
        reason: 'the desktop field label must not appear on the phone page');

    // The private landing path is not the user's destination and must not show.
    expect(find.textContaining('/data/user/0'), findsNothing);
    expect(find.textContaining('/files/lanlink/received'), findsNothing);

    // …and nothing was deleted on the way: the switch and the About row stay.
    expect(find.text('接收模式'), findsOneWidget);
    expect(find.text('关于我们'), findsOneWidget);
  });

  testWidgets(
      '★ DESKTOP: 保存位置 stays editable and never shows the phone hint',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1400, 1000));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    // `mobile` stays false → desktop, where the directory really is editable.

    await pumpShell(
      tester,
      initialModule: ShellModule.settings,
      backend: backend,
      settle: true,
    );

    expect(find.text('保存位置'), findsOneWidget);
    expect(find.text('更改位置'), findsOneWidget,
        reason: 'the desktop can change it, and the change takes effect');
    expect(find.text(kLanlinkDownloadsLabel), findsNothing,
        reason: 'the fixed Downloads destination is a phone fact');
    expect(find.text(_hint), findsNothing,
        reason: 'the phone hint must not leak into the desktop page');
    expect(find.text('文件保存位置'), findsNothing);
  });

  testWidgets(
      '★ 320dp: nothing is squeezed out and nothing overflows — the title keeps '
      'its width and the folder value stays whole',
      (WidgetTester tester) async {
    // 320 is the narrowest phone the layout host resolves to, and the test font
    // makes every glyph a full em (so widths here are the *worst* case, ~1.4-1.8×
    // a real phone font). Two failure modes were measured while building this row:
    //  * the folder value in the `›`-side slot: title 「文件保存位置」 came out
    //    **0 dp wide, 144 dp tall** (six one-character lines) — the row's name
    //    disappeared;
    //  * the value in the title line: `RenderFlex overflowed by 9.0 pixels`.
    // Hence the value lives under the title. This test locks all three properties
    // that made that necessary.
    await _pumpPhoneSettings(tester, size: const Size(320, 800));

    expect(tester.takeException(), isNull);
    expect(find.text('文件保存位置'), findsOneWidget);
    expect(tester.getSize(find.text('文件保存位置')).width, greaterThan(0),
        reason: 'the title still occupies width instead of being squeezed away');
    // The value and the hint are both whole, at the row's full width.
    expect(find.text(kLanlinkDownloadsLabel), findsOneWidget);
    expect(find.text(_hint), findsOneWidget);
    // The row still works at this size.
    await tester.tap(find.text('文件保存位置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开文件夹'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(_noAppMessage), findsNothing);
  });
}
