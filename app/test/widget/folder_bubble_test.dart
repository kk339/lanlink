/// Widget tests for the **folder card in the timeline** (0.2.38 / T05, criteria
/// 1 and (d); regression (f)).
///
/// A folder send is one message with N attachments, so the bubble must draw
/// **one card** — not N rows, and not a thumbnail grid for a 200-photo folder.
/// What the card prints is decided by `FolderSummary`, which the thread computes
/// once (`selectors.dart::summarizeFolder`); these tests feed the same path the
/// app does, through the real `ConversationThread`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/draft_store.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/panes/folder_browse_page.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';
import 'package:lanlink_app/ui/widgets/status_chip.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

const String _folderName = 'lanlink-电脑版-0.2.33-正式版';
const String _conversationId = 'c-folder';

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'CC01',
      alias: '小甲',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// [count] attachments of 1 MiB each, laid out under `data/` and `sub/deep/`.
List<FileAttachment> _files(int count) => <FileAttachment>[
      for (int i = 0; i < count; i++)
        FileAttachment(
          id: 'f-$i',
          messageId: 'm-folder',
          fileName: 'file_$i.bin',
          size: 1024 * 1024,
          sha256: 'AA',
          localPath: '/downloads/lanlink/file_$i.bin',
          relativePath: i.isEven ? 'data/file_$i.bin' : 'sub/deep/file_$i.bin',
        ),
    ];

/// Mounts the thread with **one** message: a folder declaring [declared] files
/// while [arrived] of them have landed.
Future<FakeBackend> _pumpThread(
  WidgetTester tester, {
  required int arrived,
  required int declared,
  Size size = const Size(600, 1200),
  bool mobile = true,
  /// Also seed a **flat** multi-file message (three PDFs, no folder name): the
  /// regression half of criterion 1.
  bool flatToo = false,
}) async {
  useSurfaceSize(tester, size);
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.repo.addConversation(
    id: _conversationId,
    deviceFingerprint: 'CC01',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.repo.addMessage(
    id: 'm-folder',
    conversationId: _conversationId,
    direction: MessageDirection.incoming,
    status: MessageStatus.done,
    kind: MessageKind.file,
    folderName: _folderName,
    folderFiles: declared,
    files: _files(arrived),
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
  );
  if (flatToo) {
    backend.repo.addMessage(
      id: 'm-flat',
      conversationId: _conversationId,
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.file,
      files: <FileAttachment>[
        for (int i = 0; i < 3; i++)
          FileAttachment(
            id: 'flat-$i',
            messageId: 'm-flat',
            fileName: 'loose_$i.pdf',
            size: 2048,
            sha256: 'AA',
            localPath: '/downloads/loose_$i.pdf',
          ),
      ],
      createdAt: fixedEpoch.add(const Duration(minutes: 1)),
      updatedAt: fixedEpoch.add(const Duration(minutes: 1)),
    );
  }
  backend.platform.setMobile(mobile);
  final ConversationController controller = ConversationController(
    repo: backend.repo,
    orchestrator: TransferOrchestrator(
      repo: backend.repo,
      transfer: backend.transfer,
    ),
    platform: backend.platform,
    ids: backend.ids,
    clock: backend.clock,
    conversationId: _conversationId,
    drafts: ComposerDraftStore(),
  );
  addTearDown(controller.dispose);
  // Load **before** mounting: a thread still in `Loading` shows the indeterminate
  // spinner, and `pumpAndSettle` would never settle on it.
  unawaited(controller.load());
  await tester.pumpWidget(
    appWithScope(
      child: MaterialApp(
        home: Scaffold(
          body: ConversationThread(controller: controller, peer: _peer()),
        ),
      ),
      deps: testDeps(backend),
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}

void main() {
  testWidgets(
      '★ criterion 1: a folder message draws ONE card — icon, name, 总大小, 文件数 '
      '— and 「已收到 12/20」 while the batch is still arriving',
      (WidgetTester tester) async {
    await _pumpThread(tester, arrived: 12, declared: 20);

    // 1. The card: an amber folder glyph (not the grey "unknown file" document a
    //    FileTile would have shown), the name, one meta line.
    expect(find.byIcon(Icons.folder), findsOneWidget);
    expect(find.text(_folderName), findsOneWidget);
    expect(find.text('12 MB · 20 个文件'), findsOneWidget,
        reason: '12 files × 1 MiB, and the **declared** count as the denominator');

    // 2. The two numbers come from two different places (`docs/22` §2.5): the
    //    denominator is the sender's claim, the numerator is what actually landed.
    expect(find.text('已收到 12/20'), findsOneWidget);

    // 3. **Not** a pile of rows: a folder is one object.
    expect(find.byType(FileTile), findsNothing,
        reason: 'a folder message must not draw one row per file');
    // …and no media grid either, even though half the attachments are under
    // `data/` — a 200-photo folder must not inflate a bubble (`docs/22` §5.1).
    expect(find.byType(Image), findsNothing);
  });

  testWidgets(
      'a COMPLETE folder prints no 「已收到」 line (the count already says so)',
      (WidgetTester tester) async {
    await _pumpThread(tester, arrived: 20, declared: 20);

    expect(find.text('20 MB · 20 个文件'), findsOneWidget);
    expect(find.textContaining('已收到'), findsNothing);
  });

  testWidgets(
      '★ criterion (d): tapping the card opens the directory page',
      (WidgetTester tester) async {
    await _pumpThread(tester, arrived: 12, declared: 20);

    expect(find.byType(FolderBrowsePage), findsNothing);

    await tester.tap(find.text(_folderName));
    await tester.pumpAndSettle();

    expect(find.byType(FolderBrowsePage), findsOneWidget,
        reason: 'the whole card is the tap target — not one per file');
    // …and the page shows the folder's own top level.
    expect(find.text('data'), findsOneWidget);
    expect(find.text('sub'), findsOneWidget);
  });

  testWidgets(
      '★ criterion 1 (regression): a FLAT multi-file message still draws rows and '
      'no folder element at all', (WidgetTester tester) async {
    await _pumpThread(tester, arrived: 3, declared: 3, flatToo: true);

    // The flat message: three rows, no folder card.
    expect(find.byType(FileTile), findsNWidgets(3),
        reason: 'a multi-select send is still one bubble with N rows');
    expect(find.text('loose_0.pdf'), findsOneWidget);
    // Exactly one folder glyph in the whole timeline — the folder message's.
    expect(find.byIcon(Icons.folder), findsOneWidget,
        reason: 'the flat message must not grow a folder card');
    expect(find.textContaining('已收到'), findsNothing);
  });

  testWidgets(
      'desktop: the same card, inside a normal 12 dp bubble, with the status chip '
      'on the meta row below it', (WidgetTester tester) async {
    await _pumpThread(
      tester,
      arrived: 12,
      declared: 20,
      size: const Size(1400, 1000),
      mobile: false,
    );

    expect(find.byIcon(Icons.folder), findsOneWidget);
    expect(find.text(_folderName), findsOneWidget);
    expect(find.text('12 MB · 20 个文件'), findsOneWidget);
    expect(find.text('已收到 12/20'), findsOneWidget);
    expect(find.byType(FileTile), findsNothing);

    // The card sits in the ordinary bubble (12 dp padding) — a folder is content,
    // not a hero media card.
    final Finder card = find
        .ancestor(of: find.byIcon(Icons.folder), matching: find.byType(Container))
        .first;
    expect(tester.widget<Container>(card).padding, const EdgeInsets.all(12));

    // …and the status chip is on the meta row **below** it, not inside the card
    // (that is why `_folderCard` deliberately omits a chip).
    final Finder chip = find.byType(StatusChip);
    expect(chip, findsOneWidget);
    expect(find.descendant(of: card, matching: chip), findsNothing);
    expect(tester.getRect(chip).top, greaterThan(tester.getRect(card).bottom));
  });
}
