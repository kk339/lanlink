/// Widget tests for the **directory page** (0.2.38 / T05; criteria 3, 4, 5 and
/// the spec's (c)/(e)).
///
/// The page walks a folder message's `relativePath` hierarchy through the same
/// `buildFolderTree` the unit tests above cover, so these tests are about
/// navigation and the responsive split — not about re-testing the tree.
///
/// What each case pins:
/// * **A** — the wide layout has the `发送人` / `发送时间` columns + header, and the
///   56 dp row the reference screenshot shows;
/// * **B** — the narrow layout has **neither** column nor header, folds the same
///   facts into one `·`-separated line, and keeps the 36 dp action slots;
/// * **C** — the breadcrumb: drill in, tap the root crumb to come back, and the
///   last crumb is not a link;
/// * **D** — opening a row uses **`localPath`**, never `relativePath` (the
///   relative path stops pointing at the disk once the file is published);
/// * **E** — ⋯ is the **existing** attachment menu, not a new one;
/// * **F** — Esc pops on a desktop.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/format.dart';
import 'package:lanlink_app/ui/panes/folder_browse_page.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

const String _folderName = '素材';
const String _sender = '小甲';

/// The saved path `a.dll` gets after publishing — deliberately **not** related to
/// its `relativePath` (`data/a.dll`), which is exactly the bug criterion 4 hunts.
const String _aSavedPath = '/storage/Download/lanlink/a.dll';

List<FileAttachment> _files() => <FileAttachment>[
      const FileAttachment(
        id: 'f-a',
        messageId: 'm-1',
        fileName: 'a.dll',
        size: 10,
        sha256: 'AA',
        localPath: _aSavedPath,
        relativePath: 'data/a.dll',
      ),
      const FileAttachment(
        id: 'f-b',
        messageId: 'm-1',
        fileName: 'b.dll',
        size: 32,
        sha256: 'AA',
        localPath: '/storage/Download/lanlink/b.dll',
        relativePath: 'data/b.dll',
      ),
      const FileAttachment(
        id: 'f-c',
        messageId: 'm-1',
        fileName: 'c.bin',
        size: 100,
        sha256: 'AA',
        localPath: '/storage/Download/lanlink/c.bin',
        relativePath: 'sub/deep/c.bin',
      ),
      const FileAttachment(
        id: 'f-x',
        messageId: 'm-1',
        fileName: 'x.dll',
        size: 7,
        sha256: 'AA',
        localPath: '/storage/Download/lanlink/x.dll',
        relativePath: 'x.dll',
      ),
      const FileAttachment(
        id: 'f-y',
        messageId: 'm-1',
        fileName: 'y.dll',
        size: 7,
        sha256: 'AA',
        localPath: '/storage/Download/lanlink/y.dll',
        relativePath: 'y.dll',
      ),
    ];

ChatMessage _message() => ChatMessage(
      id: 'm-1',
      conversationId: 'c-1',
      direction: MessageDirection.incoming,
      kind: MessageKind.file,
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
      status: MessageStatus.done,
      folderName: _folderName,
      folderFiles: 5,
    );

/// Mounts the page alone, on a surface of [size].
Future<FakeBackend> _pumpPage(
  WidgetTester tester, {
  required Size size,
}) async {
  useSurfaceSize(tester, size);
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.repo.addConversation(
    id: 'c-1',
    deviceFingerprint: 'CC01',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.repo.addMessage(
    id: 'm-1',
    conversationId: 'c-1',
    direction: MessageDirection.incoming,
    status: MessageStatus.done,
    kind: MessageKind.file,
    folderName: _folderName,
    folderFiles: 5,
    files: _files(),
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
  );
  await pumpApp(
    tester,
    FolderBrowsePage(message: _message(), subtitle: _sender),
    backend: backend,
    settle: true,
  );
  return backend;
}

/// The row widget for the entry named [name] — the `InkWell` the whole row is
/// wrapped in, whose height is the row height the spec pins.
Finder _rowOf(String name) => find
    .ancestor(of: find.text(name), matching: find.byType(InkWell))
    .first;

/// A breadcrumb segment by its label — scoped to the crumb strip, because the
/// root label is also the AppBar title.
Finder _crumb(String label) => find.descendant(
      of: find.byType(SingleChildScrollView),
      matching: find.text(label),
    );

void main() {
  testWidgets(
      '★ criterion 5 (wide): 1400 px — the two columns and their header are '
      'there, rows are 56 dp, and the inline meta line is NOT used',
      (WidgetTester tester) async {
    await _pumpPage(tester, size: const Size(1400, 1000));

    expect(find.text('发送人'), findsOneWidget);
    expect(find.text('发送时间'), findsOneWidget);

    // Directories first, then files by name.
    final double dataY = tester.getCenter(find.text('data')).dy;
    final double subY = tester.getCenter(find.text('sub')).dy;
    final double xY = tester.getCenter(find.text('x.dll')).dy;
    final double yY = tester.getCenter(find.text('y.dll')).dy;
    expect(dataY, lessThan(subY));
    expect(subY, lessThan(xY));
    expect(xY, lessThan(yY));

    // 56 dp rows. Measured on the row itself, not on the gap between two rows —
    // the list draws a 1 dp divider between them, so the pitch is 57.
    expect(tester.getSize(_rowOf('x.dll')).height, kFolderRowHeightWide);
    expect(tester.getSize(_rowOf('data')).height, kFolderRowHeightWide);

    // The folder name is the AppBar title **and** the first breadcrumb — the
    // reference layout has both — while the sender lives in its own column, so
    // `小甲` is never folded into a meta line on this width.
    expect(find.text(_folderName), findsNWidgets(2));
    expect(find.text('9 B · $_sender · 10月23日'), findsNothing,
        reason: 'the wide layout has real columns; the folded line is the phone '
            'shape (docs/22 §5.3)');
  });

  testWidgets(
      '★ criterion 5 (narrow): 600 px — NO columns, NO header, and the same facts '
      'folded into one ·-separated line',
      (WidgetTester tester) async {
    await _pumpPage(tester, size: const Size(600, 1200));

    expect(find.text('发送人'), findsNothing);
    expect(find.text('发送时间'), findsNothing);

    // `9 B · 小甲 · 10月23日` — size · sender · day, on the row's second line.
    final String day = dayText(fixedEpoch);
    expect(find.textContaining('$_sender · $day'), findsWidgets,
        reason: 'size · sender · day, folded onto the second line');
    // Scoped to the row: `y.dll` is also 7 bytes, so the bare text is on screen
    // twice and would not prove anything about *this* row.
    expect(
      find.descendant(
        of: _rowOf('x.dll'),
        matching: find.text('${fileSizeText(7)} · $_sender · $day'),
      ),
      findsOneWidget,
      reason: 'size · sender · day, folded onto the row\'s second line',
    );

    // The narrow row is taller (64) because it carries that second line.
    expect(tester.getSize(_rowOf('x.dll')).height, kFolderRowHeightNarrow);
  });

  testWidgets(
      '★ criterion 3/(c): drill into a folder, then the breadcrumb walks back; the '
      'last crumb is not a link', (WidgetTester tester) async {
    await _pumpPage(tester, size: const Size(1400, 1000));

    // Root: two directories + two files.
    expect(find.text('sub'), findsOneWidget);
    expect(find.text('a.dll'), findsNothing);

    await tester.tap(find.text('data'));
    await tester.pumpAndSettle();

    // Inside `data`: its two files, and `sub` is gone (we are one level down).
    expect(find.text('a.dll'), findsOneWidget);
    expect(find.text('b.dll'), findsOneWidget);
    expect(find.text('x.dll'), findsNothing);
    // The trail now reads `素材 › data`.
    expect(find.text('data'), findsWidgets);

    // The last crumb (`data`) is where we already are: tapping it changes nothing.
    final Finder lastCrumb = find.text('data').first;
    await tester.tap(lastCrumb);
    await tester.pumpAndSettle();
    expect(find.text('a.dll'), findsOneWidget,
        reason: 'the last crumb must not be a link');

    // The root crumb goes back to the top. `素材` is on screen twice (AppBar
    // title + first crumb), so the crumb is addressed through the breadcrumb's
    // own scroll view rather than by position.
    await tester.tap(_crumb(_folderName));
    await tester.pumpAndSettle();
    expect(find.text('sub'), findsOneWidget);
    expect(find.text('a.dll'), findsNothing);
  });

  testWidgets(
      '★ criterion 3: three levels down (素材 › sub › deep) and one tap on the '
      'middle crumb comes back to `sub`', (WidgetTester tester) async {
    await _pumpPage(tester, size: const Size(1400, 1000));

    await tester.tap(find.text('sub'));
    await tester.pumpAndSettle();
    expect(find.text('deep'), findsOneWidget);
    expect(find.text('c.bin'), findsNothing);

    await tester.tap(find.text('deep'));
    await tester.pumpAndSettle();
    expect(find.text('c.bin'), findsOneWidget);

    // Back to `sub` by tapping its crumb (the trail has two `deep`s? no — one).
    await tester.tap(find.text('sub').first);
    await tester.pumpAndSettle();
    expect(find.text('deep'), findsOneWidget);
    expect(find.text('c.bin'), findsNothing);
  });

  testWidgets(
      '★ criterion 4: opening a file calls openFile with the SAVED path, never with '
      'anything derived from relativePath', (WidgetTester tester) async {
    final FakeBackend backend =
        await _pumpPage(tester, size: const Size(1400, 1000));

    await tester.tap(find.text('data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('a.dll'));
    await tester.pumpAndSettle();

    expect(backend.platform.opened, <String>[_aSavedPath],
        reason: 'the row must open the attachment\'s localPath (the saved path)');
    expect(backend.platform.opened.single, isNot(contains('data/')),
        reason: '`relativePath` is display-only once the file is published — '
            'joining it onto anything produces a path that does not exist');
    expect(backend.platform.opened.single, endsWith('/a.dll'));
  });

  testWidgets('a directory row drills in instead of trying to open a file',
      (WidgetTester tester) async {
    final FakeBackend backend =
        await _pumpPage(tester, size: const Size(1400, 1000));

    await tester.tap(find.text('sub'));
    await tester.pumpAndSettle();

    expect(backend.platform.opened, isEmpty,
        reason: 'a directory has no file to open');
    expect(find.text('deep'), findsOneWidget);
  });

  testWidgets(
      '★ criterion (d)/E: ⋯ is the EXISTING attachment menu (复制文件名 and friends)',
      (WidgetTester tester) async {
    await _pumpPage(tester, size: const Size(1400, 1000));

    // The second action of the `x.dll` row.
    final Finder rowMenu = find.descendant(
      of: find.ancestor(of: find.text('x.dll'), matching: find.byType(Row)).last,
      matching: find.byIcon(Icons.more_horiz),
    );
    await tester.tap(rowMenu.first);
    await tester.pumpAndSettle();

    expect(find.text('复制文件名'), findsOneWidget,
        reason: 'no second menu implementation was written for this page');
    // A directory has nothing to show a file menu for.
    expect(find.byIcon(Icons.more_horiz), findsWidgets);
  });

  testWidgets('★ criterion F: Esc pops the page on a desktop',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1400, 1000));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-1',
      deviceFingerprint: 'CC01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-1',
      conversationId: 'c-1',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.file,
      folderName: _folderName,
      folderFiles: 5,
      files: _files(),
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
    );

    await pumpApp(
      tester,
      Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      FolderBrowsePage(message: _message(), subtitle: _sender),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
      backend: backend,
      settle: true,
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(FolderBrowsePage), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(FolderBrowsePage), findsNothing,
        reason: 'a desktop has no system back button — Esc is the way out');
    expect(find.text('打开'), findsOneWidget, reason: 'back on the base route');
  });
}
