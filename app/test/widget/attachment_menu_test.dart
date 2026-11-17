/// docs/19 §9.6 — the attachment context menu and "click to open".
///
/// These replace a user report: **"我没法点开视频，也没法右键看到'打开所在位置'"**.
/// Both capabilities already existed on `PlatformPorts`; nothing was wired to the
/// cards. The tests below pin the wiring **and the grey state**, because a menu
/// entry that looks clickable and does nothing is the failure we keep fixing.
library;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/widgets/attachment_menu.dart';
import 'package:lanlink_app/ui/widgets/file_thumbnail.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';

import '../support/pump_app.dart';

ChatMessage _message() => ChatMessage(
      id: 'm1',
      conversationId: 'c1',
      direction: MessageDirection.incoming,
      kind: MessageKind.file,
      createdAt: DateTime.utc(2026, 1, 7, 12),
      updatedAt: DateTime.utc(2026, 1, 7, 12),
      status: MessageStatus.done,
    );

FileAttachment _video({String? path = '/src/clip.mp4'}) => FileAttachment(
      id: 'f-clip',
      messageId: 'm1',
      fileName: 'clip.mp4',
      size: 2048,
      mime: 'video/mp4',
      sha256: '00',
      localPath: path,
    );

/// Whether the row for [value] is actionable.
///
/// The menu is drawn by `fast_menu.dart` (a custom route with a 150 ms Fluent
/// entrance), so its rows are keyed `fast-menu-<value>` rather than being
/// `PopupMenuItem`s. `onTap == null` is exactly "greyed out and inert".
bool _rowEnabled(WidgetTester tester, String value) {
  final Finder finder = find.byKey(ValueKey<String>('fast-menu-$value'));
  expect(finder, findsOneWidget, reason: 'row $value must be built');
  return tester.widget<InkWell>(finder).onTap != null;
}

double _rowHeight(WidgetTester tester, String value) =>
    tester.getSize(find.byKey(ValueKey<String>('fast-menu-$value'))).height;

/// The open menu's row values **in build order**.
///
/// The point of reading every row rather than poking at the ones a test happens
/// to care about: the 0.2.46 change **adds a row**, and "add an entry, loosen the
/// assertion" is exactly how a menu silently grows fake entries later. An exact
/// list fails on a lost row *and* on an uninvited one.
List<String> _menuValues(WidgetTester tester) => <String>[
      for (final Element element in tester
          .elementList(
            find.byWidgetPredicate(
              (Widget w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith('fast-menu-'),
            ),
          )
          .toList())
        ((element.widget.key! as ValueKey<String>).value)
            .substring('fast-menu-'.length),
    ];

/// Opens the menu for [file] from a throwaway button, so a case can assert on the
/// rows without mounting a whole bubble.
Future<void> _openMenu(
  WidgetTester tester, {
  required FileAttachment file,
  FakeBackend? backend,
  VoidCallback? onDelete,
  VoidCallback? onForward,
  bool mobile = false,
}) async {
  final FakeBackend resolved = backend ?? FakeBackend();
  if (backend == null) {
    addTearDown(resolved.dispose);
  }
  resolved.platform.setMobile(mobile);
  await pumpApp(
    tester,
    Builder(
      builder: (BuildContext context) => TextButton(
        onPressed: () => showAttachmentMenu(
          context,
          file: file,
          position: const Offset(120, 120),
          onDelete: onDelete,
          onForward: onForward,
        ),
        child: const Text('menu'),
      ),
    ),
    backend: resolved,
  );
  await tester.tap(find.text('menu'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a DESKTOP tap on a media card opens the file (the "点不开视频" fix)',
      (WidgetTester tester) async {
    final List<FileAttachment> opened = <FileAttachment>[];
    // `isMobile` stays false: this is the desktop case that used to be inert.
    await pumpApp(
      tester,
      Scaffold(
        body: Center(
          child: MessageBubble(
            message: _message(),
            files: <FileAttachment>[_video()],
            onOpenFile: opened.add,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(FileThumbnail));
    await tester.pumpAndSettle();

    expect(opened, hasLength(1), reason: 'a media card must be tappable here');
    expect(opened.single.fileName, 'clip.mp4');
  });

  testWidgets(
      'a right-click on a card asks for the context menu, with the file',
      (WidgetTester tester) async {
    final List<(String, Offset)> asked = <(String, Offset)>[];
    await pumpApp(
      tester,
      Scaffold(
        body: Center(
          child: MessageBubble(
            message: _message(),
            files: <FileAttachment>[_video()],
            onShowAttachmentMenu: (FileAttachment file, Offset position) =>
                asked.add((file.fileName, position)),
          ),
        ),
      ),
    );

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(FileThumbnail)),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(asked, hasLength(1));
    expect(asked.single.$1, 'clip.mp4');
  });

  testWidgets('the menu opens the file when it is on disk',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    final FileAttachment file = _video();

    await pumpApp(
      tester,
      Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () => showAttachmentMenu(context,
              file: file, position: const Offset(120, 120)),
          child: const Text('menu'),
        ),
      ),
      backend: backend,
    );
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();

    expect(_rowEnabled(tester, 'open'), isTrue,
        reason: 'the file is on disk, so 打开 must be actionable');

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(backend.platform.opened, <String>['/src/clip.mp4']);
  });

  testWidgets(
      'the menu GREYS OUT 打开 when the file is gone — never a silent no-op',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    final FileAttachment file = _video();
    backend.platform.setExists('/src/clip.mp4', false);

    await pumpApp(
      tester,
      Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () => showAttachmentMenu(context,
              file: file, position: const Offset(120, 120)),
          child: const Text('menu'),
        ),
      ),
      backend: backend,
    );
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();

    expect(_rowEnabled(tester, 'open'), isFalse,
        reason: 'a missing file must read as unavailable, not as a dead click');
    // Copying the **name** still works — it does not depend on the file.
    expect(_rowEnabled(tester, 'copyName'), isTrue);
  });

  testWidgets('the menu hugs its widest label, not a fixed 280 (docs/19 §9.9)',
      (WidgetTester tester) async {
    // Measured before the fix: 280x198 (desktop) and 280x258 (phone) -- a
    // `minWidth 156 / maxWidth 280` box around a `stretch` Column always takes
    // the max, so on a 375-wide phone the menu covered 75% of the screen.
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    await pumpApp(
      tester,
      Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () => showAttachmentMenu(context,
              file: _video(), position: const Offset(120, 120)),
          child: const Text('menu'),
        ),
      ),
      backend: backend,
    );
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();

    final Size box = tester.getSize(
      find.ancestor(of: find.text('打开'), matching: find.byType(Material)).first,
    );
    expect(box.width, lessThan(200),
        reason: 'a menu wider than 200 is more than half a 375-wide phone; '
            'the box measured ${box.width}');
  });

  testWidgets(
      'the menu is 36 per row with a mouse and 48 with a finger — '
      'a mouse menu is not a touch menu', (WidgetTester tester) async {
    // The user's report was "右键拉出来的是不是有点太长了": five rows at Material's
    // default 48 (the *finger* floor) read as a long airy strip. Desktop menus
    // are 28-36 everywhere else; the ≥48 rule is a **touch** rule and only binds
    // the phone. This pins both sides so neither drifts back.
    for (final bool mobile in <bool>[false, true]) {
      final FakeBackend backend = FakeBackend();
      backend.platform.setMobile(mobile);
      await pumpApp(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showAttachmentMenu(context,
                file: _video(), position: const Offset(120, 120)),
            child: Text('menu-$mobile'),
          ),
        ),
        backend: backend,
      );
      await tester.tap(find.text('menu-$mobile'));
      await tester.pumpAndSettle();

      expect(_rowHeight(tester, 'open'), mobile ? 48 : 36, reason: 'mobile=$mobile');

      await tester.tapAt(const Offset(4, 4)); // dismiss
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink()); // unmount between rounds
    }
  });

  // ── 0.2.46: 「转发到…」 joined the menu — and nothing else moved ──────────────
  //
  // The change added **one** row. These cases pin the whole list, one entry at a
  // time, on every surface the menu has: the desktop (no 分享 / 在下载里查看), the
  // phone (both), and the file-menu-without-a-message case the folder-browse page
  // uses. A future "add an entry and relax the test" cannot pass here.

  testWidgets(
      '★ 0.2.46 / desktop: every row, in order — 转发到… is the one new entry and '
      'not a single existing one moved', (WidgetTester tester) async {
    await _openMenu(
      tester,
      file: _video(),
      onDelete: () {},
      onForward: () {},
    );

    expect(
      _menuValues(tester),
      <String>[
        'open', // 打开
        'reveal', // 打开所在位置 (desktop only)
        'copyName', // 复制文件名
        'copyPath', // 复制文件路径
        'details', // 详细信息…
        'forward', // 转发到…  ← 0.2.46
        'delete', // 删除
      ],
      reason: '★ one row per assertion: a dropped row and an uninvited row both '
          'fail here, which "find.text(…) findsOneWidget" would not catch',
    );
  });

  testWidgets(
      '★ 0.2.46 / phone: the phone rows plus 转发到…, and 分享 is still there',
      (WidgetTester tester) async {
    await _openMenu(
      tester,
      file: _video(),
      onDelete: () {},
      onForward: () {},
      mobile: true,
    );

    expect(
      _menuValues(tester),
      <String>['open', 'copyName', 'copyPath', 'share', 'details', 'forward', 'delete'],
      reason: 'a phone has no 打开所在位置, and /src is not inside 下载/lanlink',
    );
  });

  testWidgets(
      '★ 0.2.46: no message, no 转发到… — the folder-browse page passes no '
      'onForward and gets exactly the menu it had before',
      (WidgetTester tester) async {
    await _openMenu(tester, file: _video());

    expect(
      _menuValues(tester),
      <String>['open', 'reveal', 'copyName', 'copyPath', 'details'],
      reason: 'an attachment with no message around it has nothing to forward',
    );
  });

  testWidgets(
      '★ 0.2.46: 转发到… is GREYED OUT for a file that is gone — the forward would '
      'refuse the whole message anyway (源文件已不在本地)',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform.setExists('/src/clip.mp4', false);

    await _openMenu(
      tester,
      file: _video(),
      backend: backend,
      onDelete: () {},
      onForward: () {},
    );

    expect(_rowEnabled(tester, 'forward'), isFalse,
        reason: 'a guaranteed failure must read as unavailable, not as a dead tap');
    // The rows that do not depend on the file keep working.
    expect(_rowEnabled(tester, 'copyName'), isTrue);
    expect(_rowEnabled(tester, 'copyPath'), isTrue);
  });

  testWidgets(
      '★ 0.2.46: tapping 转发到… reports exactly one forward request and touches no '
      'platform capability', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    int forwards = 0;

    await _openMenu(
      tester,
      file: _video(),
      backend: backend,
      onDelete: () {},
      onForward: () => forwards += 1,
    );

    await tester.tap(find.text('转发到…'));
    await tester.pumpAndSettle();

    expect(forwards, 1);
    expect(backend.platform.opened, isEmpty,
        reason: 'the row forwards something; it must not also try to open it');
    expect(_menuValues(tester), isEmpty, reason: 'the menu closed on the tap');
  });
}
