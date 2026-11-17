/// 0.2.24 — 「在下载里查看」 in the attachment menu.
///
/// The user's complaint behind this feature: since 0.2.19 a received file is
/// published to `/storage/emulated/0/Download/lanlink`, but reaching it meant
/// opening a file manager and walking there by hand. The desktop has had
/// 「打开所在位置」 for a while; Android had no equivalent action at all.
///
/// **What these tests pin**, in the order the task states them:
///  1. a file **inside** `Download/lanlink` gets the row (and it opens the
///     folder), while a file still in `/data/user/0/…/received` does **not** —
///     both directions, because only the pair proves the predicate is doing
///     anything;
///  2. a platform without the action (desktop / Web / iOS) never builds the row,
///     even when the path would qualify — no button that taps into nothing;
///  3. when the native side answers "no app can open a folder", the user gets
///     the sentence and the path is **really** on the clipboard, in that order
///     (asserted on the platform channel, which is where `Clipboard.setData`
///     actually goes).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/platform_ports.dart'
    show ViewInDownloadsOutcome;
import 'package:lanlink_app/ui/widgets/attachment_menu.dart';

import '../support/pump_app.dart';

/// A received file as 0.2.19 records it: the **published** public path.
const String _publishedPath = '/storage/emulated/0/Download/lanlink/clip.mp4';

/// A received file as 0.2.18 and earlier recorded it: the private directory.
const String _privatePath =
    '/data/user/0/io.github.kk339.lanlink/files/lanlink/received/clip.mp4';

/// The exact wording of the "no folder app" fallback (task §3).
const String _noAppMessage = '这个系统没有能打开文件夹的应用，路径已复制到剪贴板';

FileAttachment _video(String path) => FileAttachment(
      id: 'f-clip',
      messageId: 'm1',
      fileName: 'clip.mp4',
      size: 2048,
      mime: 'video/mp4',
      sha256: '00',
      localPath: path,
    );

/// Every `Clipboard.setData` that reached the platform channel, in order.
final List<String> _clipboardWrites = <String>[];

/// One ordered log across the fake **port** and the mocked platform channel, so
/// "the copy happened after the platform refused" is asserted, not assumed.
final List<String> _events = <String>[];

/// The menu row's enabled state (rows are keyed `fast-menu-<value>`).
bool _rowEnabled(WidgetTester tester, String value) {
  final Finder finder = find.byKey(ValueKey<String>('fast-menu-$value'));
  expect(finder, findsOneWidget, reason: 'row $value must be built');
  return tester.widget<InkWell>(finder).onTap != null;
}

/// The menu row for [value], or `null` when it was not built at all.
Finder _row(String value) => find.byKey(ValueKey<String>('fast-menu-$value'));

/// Mounts a one-button page that opens the attachment menu for [path].
Future<FakeBackend> _pumpMenu(
  WidgetTester tester, {
  required String path,
  required bool mobile,
  required bool supportsViewInDownloads,
  ViewInDownloadsOutcome outcome = ViewInDownloadsOutcome.opened,
}) async {
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.platform.setMobile(mobile);
  backend.platform.setSupportsViewInDownloads(supportsViewInDownloads);
  backend.platform.viewInDownloadsOutcome = outcome;
  backend.platform.onViewInDownloads = (String requested) =>
      _events.add('port:viewInDownloads:$requested');

  final FileAttachment file = _video(path);
  await pumpApp(
    tester,
    Scaffold(
      // A Scaffold, because a `SnackBar` is only *rendered* by one — the
      // fallback message has to be findable here, not just queued.
      body: Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () => showAttachmentMenu(context,
              file: file, position: const Offset(120, 120)),
          child: const Text('menu'),
        ),
      ),
    ),
    backend: backend,
  );
  await tester.tap(find.text('menu'));
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
        final Object? text =
            arguments is Map ? arguments['text'] : null;
        _clipboardWrites.add(text is String ? text : '<not a string>');
        _events.add('clipboard');
      }
      // Everything else (`SystemChrome`, haptics, …) is answered with null,
      // exactly as the real platform does for a no-op.
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
      '★ direction 1: a file published into Download/lanlink gets '
      '「在下载里查看」, and it asks the platform to open the folder',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpMenu(
      tester,
      path: _publishedPath,
      mobile: true,
      supportsViewInDownloads: true,
    );

    expect(_row('viewInDownloads'), findsOneWidget,
        reason: 'this file really is in 下载/lanlink');
    expect(find.text('在下载里查看'), findsOneWidget);
    expect(_rowEnabled(tester, 'viewInDownloads'), isTrue,
        reason: 'the action is available, so the row must be live');

    await tester.tap(find.text('在下载里查看'));
    await tester.pumpAndSettle();

    expect(backend.platform.viewInDownloadsRequests, <String>[_publishedPath],
        reason: 'the file the user is looking at is what travels down');
    // Success is silent: the folder itself is the feedback.
    expect(_clipboardWrites, isEmpty);
    expect(find.text(_noAppMessage), findsNothing);
  });

  testWidgets(
      '★ direction 2: a file still in the PRIVATE directory gets no such row — '
      'no button that opens a folder the file is not in',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpMenu(
      tester,
      path: _privatePath,
      mobile: true,
      supportsViewInDownloads: true,
    );

    expect(_row('viewInDownloads'), findsNothing,
        reason: 'a pre-0.2.19 row points at /data/user/0/…/received');
    expect(find.text('在下载里查看'), findsNothing);
    // The rest of the menu is untouched: this is a missing row, not a broken
    // menu.
    expect(_rowEnabled(tester, 'open'), isTrue);
    expect(backend.platform.viewInDownloadsRequests, isEmpty);
  });

  testWidgets(
      '★ a platform without the action (desktop / Web / iOS) never builds the '
      'row — even for a path that would otherwise qualify',
      (WidgetTester tester) async {
    // Path qualifies, platform does not: the row is still absent. That is the
    // assertion the desktop case needs (the desktop already has 打开所在位置).
    await _pumpMenu(
      tester,
      path: _publishedPath,
      mobile: false,
      supportsViewInDownloads: false,
    );

    expect(_row('viewInDownloads'), findsNothing);
    expect(find.text('在下载里查看'), findsNothing);
    // …and the desktop keeps its own row, so nothing was lost by adding this.
    expect(_rowEnabled(tester, 'reveal'), isTrue);
  });

  testWidgets(
      '★ a phone that is not Android-shaped (isMobile but no action) also gets '
      'no row',
      (WidgetTester tester) async {
    await _pumpMenu(
      tester,
      path: _publishedPath,
      mobile: true,
      supportsViewInDownloads: false,
    );

    expect(_row('viewInDownloads'), findsNothing,
        reason: 'isMobile is Android OR iOS; only Android has this action');
  });

  testWidgets(
      '★ no app can open a folder: the sentence appears, the path is really on '
      'the clipboard, and the copy happens AFTER the platform refused',
      (WidgetTester tester) async {
    await _pumpMenu(
      tester,
      path: _publishedPath,
      mobile: true,
      supportsViewInDownloads: true,
      outcome: ViewInDownloadsOutcome.noApp,
    );

    await tester.tap(find.text('在下载里查看'));
    await tester.pumpAndSettle();

    expect(find.text(_noAppMessage), findsOneWidget);
    expect(_clipboardWrites, <String>[_publishedPath],
        reason: 'the user must be able to paste the path somewhere useful');
    // Order: the platform was asked first, the clipboard was written second.
    // A toast claiming "路径已复制" before the write would be a lie a paste
    // exposes.
    expect(_events, <String>[
      'port:viewInDownloads:$_publishedPath',
      'clipboard',
    ]);
  });

  testWidgets(
      'a folder that does not exist yet (nothing received since 0.2.19) takes '
      'the same honest fallback',
      (WidgetTester tester) async {
    await _pumpMenu(
      tester,
      path: _publishedPath,
      mobile: true,
      supportsViewInDownloads: true,
      outcome: ViewInDownloadsOutcome.noDirectory,
    );

    await tester.tap(find.text('在下载里查看'));
    await tester.pumpAndSettle();

    expect(find.text(_noAppMessage), findsOneWidget);
    expect(_clipboardWrites, <String>[_publishedPath]);
  });

  testWidgets(
      'a broken bridge is reported as a failure, not as a success — and still '
      'leaves the path usable',
      (WidgetTester tester) async {
    await _pumpMenu(
      tester,
      path: _publishedPath,
      mobile: true,
      supportsViewInDownloads: true,
      outcome: ViewInDownloadsOutcome.failed,
    );

    await tester.tap(find.text('在下载里查看'));
    await tester.pumpAndSettle();

    expect(find.text('打开文件夹失败，路径已复制到剪贴板'), findsOneWidget);
    expect(_clipboardWrites, <String>[_publishedPath]);
  });

  testWidgets(
      'the row is not gated on the file still being there — the FOLDER is what '
      'opens, so it still helps when the file was deleted',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpMenu(
      tester,
      path: _publishedPath,
      mobile: true,
      supportsViewInDownloads: true,
    );
    // The published copy is gone (renamed / deleted in 下载), while the row the
    // user is looking at is still in the conversation.
    backend.platform.setExists(_publishedPath, false);

    await tester.tapAt(const Offset(4, 4)); // dismiss the menu from _pumpMenu
    await tester.pumpAndSettle();
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();

    expect(_row('open'), findsOneWidget);
    expect(_rowEnabled(tester, 'open'), isFalse,
        reason: 'the file itself is gone, so 打开 is greyed out');
    expect(_rowEnabled(tester, 'viewInDownloads'), isTrue,
        reason: 'the folder is still the right place to go looking');
  });
}
