/// Widget tests for the shell's **最近文件 module** — the successor of the old
/// `RecentFilesPage` (spec §6 T04; PRD §4.3, A2-9/A2-11/A2-12/A2-13; design §8.1).
///
/// Every test mounts `ShellPage(initialModule: ShellModule.recentFiles)` (via
/// `pumpShell`) instead of the deleted `RecentFilesPage`; the middle-pane list
/// is now `RecentFilesList`, and a row tap selects the file for the right pane's
/// `FileDetail`. The assertions are end-to-end on the rendered tree.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/selectors.dart';
import 'package:lanlink_app/ui/panes/file_detail.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

/// `2026-01-<day>T12:00:00Z` — one fixed instant per day (times within a day are
/// identical so the local-day grouping can never split a single group).
DateTime _instant(int day) => DateTime.utc(2026, 1, day, 12);

FileAttachment _file(
  String id,
  String messageId,
  String name,
  String path, {
  String? mime,
}) =>
    FileAttachment(
      id: id,
      messageId: messageId,
      fileName: name,
      size: 2048,
      mime: mime,
      sha256: '00',
      localPath: path,
    );

/// One conversation with three files: two on day 2 (an image + a video) and one
/// on day 1 (a document).
FakeBackend _recentFixture() {
  final FakeBackend backend = FakeBackend();
  backend.repo.addConversation(
    id: 'c1',
    deviceFingerprint: 'AAAA1111',
    createdAt: _instant(1),
  );
  backend.repo.addMessage(
    id: 'm1',
    conversationId: 'c1',
    direction: MessageDirection.outgoing,
    status: MessageStatus.done,
    createdAt: _instant(2),
    files: <FileAttachment>[_file('f1', 'm1', 'photo.png', '/src/photo.png')],
  );
  backend.repo.addMessage(
    id: 'm2',
    conversationId: 'c1',
    direction: MessageDirection.incoming,
    status: MessageStatus.done,
    createdAt: _instant(2),
    files: <FileAttachment>[_file('f2', 'm2', 'clip.mp4', '/src/clip.mp4')],
  );
  backend.repo.addMessage(
    id: 'm3',
    conversationId: 'c1',
    direction: MessageDirection.outgoing,
    status: MessageStatus.done,
    createdAt: _instant(1),
    files: <FileAttachment>[
      _file('f3', 'm3', 'report.pdf', '/src/report.pdf'),
    ],
  );
  return backend;
}

/// One conversation carrying an audio, an installer and an archive file (no
/// shared content with [_recentFixture]) — proves the 音频 / 安装包 / 压缩包 tabs
/// filter by `classifyFile` (PRD §4.3). `.mp3` → audio, `.exe` → installer,
/// `.zip` → archive, per `domain/selectors.dart::kFileClassByExtension`.
FakeBackend _rarerKindsFixture() {
  final FakeBackend backend = FakeBackend();
  backend.repo.addConversation(
    id: 'ck',
    deviceFingerprint: 'BBBB2222',
    createdAt: _instant(3),
  );
  backend.repo.addMessage(
    id: 'mk-audio',
    conversationId: 'ck',
    direction: MessageDirection.incoming,
    status: MessageStatus.done,
    createdAt: _instant(3),
    files: <FileAttachment>[
      _file('fk-a', 'mk-audio', 'song.mp3', '/src/song.mp3'),
    ],
  );
  backend.repo.addMessage(
    id: 'mk-installer',
    conversationId: 'ck',
    direction: MessageDirection.outgoing,
    status: MessageStatus.done,
    createdAt: _instant(3),
    files: <FileAttachment>[
      _file('fk-i', 'mk-installer', 'setup.exe', '/src/setup.exe'),
    ],
  );
  backend.repo.addMessage(
    id: 'mk-archive',
    conversationId: 'ck',
    direction: MessageDirection.incoming,
    status: MessageStatus.done,
    createdAt: _instant(3),
    files: <FileAttachment>[
      _file('fk-z', 'mk-archive', 'bundle.zip', '/src/bundle.zip'),
    ],
  );
  return backend;
}

void main() {
  testWidgets(
    'renders the "no files" empty state (never the loading one) when nothing '
    'was ever transferred (PRD §4.3)',
    (WidgetTester tester) async {
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);

      await pumpShell(
        tester,
        initialModule: ShellModule.recentFiles,
        backend: backend,
        settle: true,
      );

      expect(find.text('还没有文件记录'), findsOneWidget);
      expect(find.text('正在整理最近文件…'), findsNothing);
    },
  );

  testWidgets(
    'groups files by local day; each header shows the date and the item count '
    '(A2-12)',
    (WidgetTester tester) async {
      final FakeBackend backend = _recentFixture();
      addTearDown(backend.dispose);

      await pumpShell(
        tester,
        initialModule: ShellModule.recentFiles,
        backend: backend,
        settle: true,
      );

      final String day2 = localDateKey(_instant(2));
      final String day1 = localDateKey(_instant(1));
      // The separator moved from `·` to `|` when this page was aligned with the
      // reference: docs/18 §3.2 spells the header `01.07 | 1 项` and the user's
      // screenshot shows a bar. Same fact, same assertion strength — only the
      // glyph the spec asks for (a spec-driven expectation change, not a
      // weakened one).
      expect(find.text('$day2 | 2 项'), findsOneWidget);
      expect(find.text('$day1 | 1 项'), findsOneWidget);
      expect(find.text('photo.png'), findsOneWidget);
      expect(find.text('clip.mp4'), findsOneWidget);
      expect(find.text('report.pdf'), findsOneWidget);
    },
  );

  testWidgets(
    'the seven category tabs (PRD §4.3) filter by type: image / video / '
    'document, "全部" shows everything (A2-11)',
    (WidgetTester tester) async {
      final FakeBackend backend = _recentFixture();
      addTearDown(backend.dispose);
      // **Taller, same width.** The card layout is taller than the old flat rows,
      // so at the default 800x600 the last group fell below the fold and was
      // never built (`find.text` could not see it). The **width stays 800** on
      // purpose: 800 ≥ kNarrowBreakpoint (760) means this test still runs the
      // **compact** branch, exactly as before — only the height changed, so the
      // test's scope is unchanged (no silent move compact → phone). The phone
      // branch of this page is covered by `recent_files_flix_test.dart`.
      useSurfaceSize(tester, const Size(800, 1400));

      await pumpShell(
        tester,
        initialModule: ShellModule.recentFiles,
        backend: backend,
        settle: true,
      );

      expect(find.text('全部'), findsOneWidget);
      expect(find.text('图片'), findsOneWidget);
      expect(find.text('视频'), findsOneWidget);
      expect(find.text('音频'), findsOneWidget);
      expect(find.text('安装包'), findsOneWidget);
      expect(find.text('压缩包'), findsOneWidget);
      // 文档 was added in the M4 rework (round 2 反馈).
      expect(find.text('文档'), findsOneWidget);

      await tester.tap(find.text('图片'));
      await tester.pumpAndSettle();
      expect(find.text('photo.png'), findsOneWidget);
      expect(find.text('clip.mp4'), findsNothing);
      expect(find.text('report.pdf'), findsNothing);

      await tester.tap(find.text('视频'));
      await tester.pumpAndSettle();
      expect(find.text('clip.mp4'), findsOneWidget);
      expect(find.text('photo.png'), findsNothing);

      await tester.tap(find.text('文档'));
      await tester.pumpAndSettle();
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('photo.png'), findsNothing);

      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      expect(find.text('photo.png'), findsOneWidget);
      expect(find.text('clip.mp4'), findsOneWidget);
      expect(find.text('report.pdf'), findsOneWidget);
    },
  );

  testWidgets(
    'the search box filters by file-name substring, and an unmatched query '
    'shows its own empty state (A2-13)',
    (WidgetTester tester) async {
      final FakeBackend backend = _recentFixture();
      addTearDown(backend.dispose);

      await pumpShell(
        tester,
        initialModule: ShellModule.recentFiles,
        backend: backend,
        settle: true,
      );

      await tester.enterText(find.byType(TextField), 'photo');
      await tester.pumpAndSettle();
      expect(find.text('photo.png'), findsOneWidget);
      expect(find.text('clip.mp4'), findsNothing);
      expect(find.text('report.pdf'), findsNothing);

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的文件'), findsOneWidget);
    },
  );

  testWidgets(
    'a file whose source is gone is flagged unavailable with the "文件已不在原'
    '位置" note (A2-9 / §4.3)',
    (WidgetTester tester) async {
      final FakeBackend backend = _recentFixture();
      addTearDown(backend.dispose);
      backend.platform.setExists('/src/photo.png', false);

      await pumpShell(
        tester,
        initialModule: ShellModule.recentFiles,
        backend: backend,
        settle: true,
      );

      final FileTile tile = tester.widget<FileTile>(
        find.widgetWithText(FileTile, 'photo.png'),
      );
      expect(tile.unavailable, isTrue);
      expect(find.text('文件已不在原位置'), findsOneWidget);

      final FileTile present = tester.widget<FileTile>(
        find.widgetWithText(FileTile, 'clip.mp4'),
      );
      expect(present.unavailable, isFalse);
    },
  );

  testWidgets(
    'the 音频 / 安装包 / 压缩包 tabs each filter by classifyFile (PRD §4.3)',
    (WidgetTester tester) async {
      final FakeBackend backend = _rarerKindsFixture();
      addTearDown(backend.dispose);
      // Taller for the same reason as the tab test above (this fixture puts all
      // three files in one group). Width stays 800 ⟹ still the **compact**
      // branch, unchanged.
      useSurfaceSize(tester, const Size(800, 1400));

      await pumpShell(
        tester,
        initialModule: ShellModule.recentFiles,
        backend: backend,
        settle: true,
      );

      // "全部" shows all three.
      expect(find.text('song.mp3'), findsOneWidget);
      expect(find.text('setup.exe'), findsOneWidget);
      expect(find.text('bundle.zip'), findsOneWidget);

      await tester.tap(find.text('音频'));
      await tester.pumpAndSettle();
      expect(find.text('song.mp3'), findsOneWidget);
      expect(find.text('setup.exe'), findsNothing);
      expect(find.text('bundle.zip'), findsNothing);

      await tester.tap(find.text('安装包'));
      await tester.pumpAndSettle();
      expect(find.text('setup.exe'), findsOneWidget);
      expect(find.text('song.mp3'), findsNothing);

      await tester.tap(find.text('压缩包'));
      await tester.pumpAndSettle();
      expect(find.text('bundle.zip'), findsOneWidget);
      expect(find.text('setup.exe'), findsNothing);
    },
  );

  testWidgets(
    'narrow: the FILE-preview leg is untouched by the S3 conversation-header '
    'removal — it still renders, and the ← is in the one top bar',
    (WidgetTester tester) async {
      // The pit this guards: `_conversationHeader` was removed for the narrow
      // detail, and BOTH detail kinds share the ← bar. Verifying only the
      // conversation leg would not have noticed if the file leg had gone with it.
      useSurfaceSize(tester, const Size(600, 800));
      final FakeBackend backend = _recentFixture();
      addTearDown(backend.dispose);

      await pumpShell(
        tester,
        initialModule: ShellModule.recentFiles,
        backend: backend,
        settle: true,
      );

      await tester.tap(find.widgetWithText(FileTile, 'photo.png'));
      await tester.pumpAndSettle();

      expect(find.byType(FileDetail), findsOneWidget);
      final AppBar bar = tester.widget<AppBar>(find.byType(AppBar));
      expect(bar.leading, isNotNull,
          reason: 'the narrow ← lives in the top bar for every detail kind');
    },
  );

  testWidgets(
    'tapping a file row shows its detail in the right pane (design §1.4)',
    (WidgetTester tester) async {
      final FakeBackend backend = _recentFixture();
      addTearDown(backend.dispose);

      await pumpShell(
        tester,
        initialModule: ShellModule.recentFiles,
        backend: backend,
        settle: true,
      );

      // Nothing selected yet → the right pane shows its own prompt.
      expect(find.byType(FileDetail), findsNothing);

      await tester.tap(find.widgetWithText(FileTile, 'photo.png'));
      await tester.pumpAndSettle();

      expect(find.byType(FileDetail), findsOneWidget);
      expect(find.text('打开文件'), findsOneWidget);
      expect(find.text('打开所在位置'), findsOneWidget);
    },
  );

  testWidgets(
    'E: on a MOBILE build the file detail offers 打开 / 分享 instead of the '
    'desktop 打开文件 / 打开所在位置 (M5 §E)',
    (WidgetTester tester) async {
      final FakeBackend backend = _recentFixture();
      addTearDown(backend.dispose);
      backend.platform.setMobile(true);

      await pumpShell(
        tester,
        initialModule: ShellModule.recentFiles,
        backend: backend,
        settle: true,
      );

      await tester.tap(find.widgetWithText(FileTile, 'photo.png'));
      await tester.pumpAndSettle();

      // The same intent, a different landing: 打开 / 分享, NOT the desktop pair.
      expect(find.text('打开'), findsOneWidget);
      expect(find.text('分享'), findsOneWidget);
      expect(find.text('打开文件'), findsNothing);
      expect(find.text('打开所在位置'), findsNothing);

      // 分享 goes through the platform port (the OS share sheet).
      await tester.tap(find.text('分享'));
      await tester.pumpAndSettle();
      expect(backend.platform.shared, <String>['/src/photo.png']);
    },
  );
}
