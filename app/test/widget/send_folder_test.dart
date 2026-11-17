/// 0.2.33 — 「发送文件夹」 in the composer.
///
/// The user's ask: 「4加上吧」 (send a whole folder at once), for the case this app
/// is actually used for — a batch of photos / videos that already sits in one
/// directory on the laptop, the desktop or the phone.
///
/// What these tests pin, in the order the task states them:
///  1. a folder with three files (one of them in a sub-directory) is offered as
///     **3 个文件** with a total size, and after confirming they really land in
///     the conversation;
///  2. an over-limit folder sends **nothing** and says how many there are;
///  3. an empty folder says so, without sending and without an error;
///  4. hidden / 0-byte files are skipped **and counted in the dialog**;
///  6. cancelling the picker does nothing at all — no dialog, no toast;
///  and the two entries that must stay honest: no folder entry where the platform
///  cannot do it, and a pick that fails says why.
///
/// The scan itself (depth, 200-file limit, hidden/empty skipping) lives in
/// `test/folder_send_test.dart` — it is a pure function and is tested there
/// against an in-memory tree. Here the platform already answered, so the tests
/// are about **what the user sees and whether anything is sent**.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/folder_send.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';

import '../support/pump_app.dart';

PeerDevice _peer(String fingerprint, {required String alias}) => PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

const String _conversationId = 'c-folder';

/// A picked-folder answer with three files, one of them from a sub-directory.
SendFolderSelection _threeFiles() => const SendFolderSelection(
      outcome: PickSendFolderOutcome.picked,
      files: <FolderScanFile>[
        FolderScanFile(path: '/素材/a.jpg', relativePath: 'a.jpg', size: 1048576),
        FolderScanFile(path: '/素材/b.jpg', relativePath: 'b.jpg', size: 1048576),
        FolderScanFile(
            path: '/素材/2026/c.jpg', relativePath: '2026/c.jpg', size: 1048576),
      ],
      totalBytes: 3 * 1024 * 1024,
      availableCount: 3,
      folderName: '素材',
    );

/// Mounts the conversation and opens the attachment menu.
Future<FakeBackend> _pumpThread(
  WidgetTester tester, {
  required SendFolderSelection reply,
  bool supportsFolder = true,
}) async {
  useSurfaceSize(tester, const Size(600, 800));
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.repo.addConversation(
    id: _conversationId,
    deviceFingerprint: 'EE07',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.platform.setSupportsSendFolder(supportsFolder);
  backend.platform.setSendFolderReply(reply);

  await pumpShell(
    tester,
    backend: backend,
    settle: true,
    initialPeer: _peer('EE07', alias: 'Eve'),
  );
  return backend;
}

/// Taps the attach button and then 「发送文件夹…」.
Future<void> _chooseFolder(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.attach_file));
  await tester.pumpAndSettle();
  await tester.tap(find.text('发送文件夹…'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      '★ criterion 1: three files (one in a sub-folder) → the dialog says '
      '「将发送 3 个文件，共 3.0 MB」, and confirming puts all three in the thread',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpThread(
      tester,
      reply: _threeFiles(),
    );

    await _chooseFolder(tester);

    expect(backend.platform.pickSendFolderCalls, 1);
    expect(find.text('发送「素材」？'), findsOneWidget);
    expect(find.text('将发送 3 个文件，共 3.0 MB'), findsOneWidget);

    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    final List<ChatMessage> messages = backend.repo.history(_conversationId);
    expect(messages, hasLength(1),
        reason: 'one message carries the whole batch (the same shape a '
            'multi-file pick produces)');
    final List<FileAttachment> files =
        backend.repo.filesOf(messages.single.id);
    expect(files.map((FileAttachment f) => f.fileName), <String>[
      'a.jpg',
      'b.jpg',
      'c.jpg',
    ], reason: 'the sub-folder file came along too');
    expect(find.byType(MessageBubble), findsWidgets);
  });

  testWidgets(
      '★ criterion 2: 300 files → NOTHING is sent, and the message names the '
      'count and the limit instead of quietly sending 200',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpThread(
      tester,
      reply: const SendFolderSelection(
        outcome: PickSendFolderOutcome.tooMany,
        availableCount: 300,
        folderName: '素材',
      ),
    );

    await _chooseFolder(tester);

    expect(find.textContaining('300 个文件'), findsOneWidget);
    expect(find.textContaining('上限（$kFolderSendMaxFiles 个）'), findsOneWidget);
    // No confirmation dialog, because there is nothing to confirm.
    expect(find.text('发送'), findsNothing);
    expect(backend.repo.history(_conversationId), isEmpty);
  });

  testWidgets('★ criterion 3: an empty folder says so — no send, no error',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpThread(
      tester,
      reply: const SendFolderSelection(
        outcome: PickSendFolderOutcome.empty,
        skippedHidden: 2,
        skippedEmpty: 1,
        folderName: '素材',
      ),
    );

    await _chooseFolder(tester);

    expect(find.textContaining('这个文件夹里没有可发送的文件'), findsOneWidget);
    // The skips are named, so "empty" is not mistaken for "the app lost them".
    expect(find.textContaining('2 个隐藏项'), findsOneWidget);
    expect(find.textContaining('1 个空文件'), findsOneWidget);
    expect(backend.repo.history(_conversationId), isEmpty);
  });

  testWidgets(
      '★ criterion 4: hidden / 0-byte / unreadable files are named in the '
      'confirmation — the user must know a batch is incomplete BEFORE sending',
      (WidgetTester tester) async {
    await _pumpThread(
      tester,
      reply: const SendFolderSelection(
        outcome: PickSendFolderOutcome.picked,
        files: <FolderScanFile>[
          FolderScanFile(path: '/素材/a.jpg', relativePath: 'a.jpg', size: 1048576),
          FolderScanFile(path: '/素材/b.jpg', relativePath: 'b.jpg', size: 1048576),
        ],
        totalBytes: 2 * 1024 * 1024,
        skippedHidden: 2,
        skippedEmpty: 1,
        skippedTooDeep: 3,
        failedCopies: 1,
        availableCount: 2,
        folderName: '素材',
      ),
    );

    await _chooseFolder(tester);

    expect(find.text('将发送 2 个文件，共 2.0 MB'), findsOneWidget);
    expect(find.text('跳过 2 个隐藏项'), findsOneWidget);
    expect(find.text('跳过 1 个空文件'), findsOneWidget);
    expect(find.text('另有 3 个更深层的文件夹没有展开'), findsOneWidget);
    expect(find.text('其中 1 个文件没能读取，已跳过'), findsOneWidget);
  });

  testWidgets(
      '★ criterion 4b: a path the receiver cannot place is named in the '
      'confirmation — the batch still goes, minus that file (CR-2 ②)',
      (WidgetTester tester) async {
    // The failure this replaces: the sender declared the path anyway, the
    // receiver answered `400 malformed prepare frame` for the **whole** batch,
    // and the user got "发送失败" with no file and no reason.
    await _pumpThread(
      tester,
      reply: const SendFolderSelection(
        outcome: PickSendFolderOutcome.picked,
        files: <FolderScanFile>[
          FolderScanFile(path: '/素材/a.jpg', relativePath: 'a.jpg', size: 1048576),
        ],
        totalBytes: 1048576,
        skippedPathTooLong: 2,
        availableCount: 1,
        folderName: '素材',
      ),
    );

    await _chooseFolder(tester);

    expect(find.text('将发送 1 个文件，共 1.0 MB'), findsOneWidget,
        reason: 'the two dropped files are not in the count — they are not sent');
    expect(find.textContaining('跳过 2 个文件（路径太长，对方存不下）'),
        findsOneWidget,
        reason: '★ the number AND the reason, on screen, before the send');
  });

  testWidgets('★ criterion 6: cancelling the folder picker does nothing at all',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpThread(
      tester,
      reply: const SendFolderSelection.cancelled(),
    );

    await _chooseFolder(tester);

    expect(backend.platform.pickSendFolderCalls, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing,
        reason: '「你改主意了」 is not something to announce — the same rule a '
            'cancelled file pick follows');
    expect(backend.repo.history(_conversationId), isEmpty);
  });

  testWidgets(
      'the dialog can be dismissed: 取消 sends nothing (a 300-file folder is one '
      'tap away from the wrong outcome)',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpThread(
      tester,
      reply: _threeFiles(),
    );

    await _chooseFolder(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(backend.repo.history(_conversationId), isEmpty);
    // …and the composer is usable again (no stuck "preparing" state).
    expect(find.textContaining('正在'), findsNothing);
  });

  testWidgets('a failed pick says why, and sends nothing',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpThread(
      tester,
      reply: const SendFolderSelection(
        outcome: PickSendFolderOutcome.failed,
        reason: '权限被拒绝',
      ),
    );

    await _chooseFolder(tester);

    expect(find.text('选择文件夹失败：权限被拒绝'), findsOneWidget);
    expect(backend.repo.history(_conversationId), isEmpty);
  });

  testWidgets(
      '★ no folder entry where the platform cannot do it — and 发送文件 still '
      'works there (Web / an unsupported platform keeps an honest menu)',
      (WidgetTester tester) async {
    await _pumpThread(
      tester,
      reply: _threeFiles(),
      supportsFolder: false,
    );

    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pumpAndSettle();

    expect(find.text('发送文件'), findsOneWidget);
    expect(find.text('发送文件夹…'), findsNothing,
        reason: 'a row that cannot work must not be built at all');
  });

  testWidgets(
      '★ while the folder is being read the composer shows a caption — not the '
      'single-file wording, and not silence (a walk of 200 photos takes seconds)',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpThread(
      tester,
      reply: _threeFiles(),
    );
    final Completer<void> gate = Completer<void>();
    backend.platform.holdNextSendFolderPick(gate);

    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发送文件夹…'));
    // Two frames, not `pumpAndSettle`: the spinner animates forever, so settle
    // would never return while the pick is parked — and `MenuAnchor` needs one
    // frame to close before the item's callback runs (measured: frame 1 shows the
    // page without the caption, frame 2 has it).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('正在读取文件夹…'), findsOneWidget);
    expect(find.textContaining('正在准备选中的文件'), findsNothing,
        reason: 'folder wording, not the single-file one');

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('将发送 3 个文件，共 3.0 MB'), findsOneWidget);
    expect(find.text('正在读取文件夹…'), findsNothing,
        reason: 'the caption goes away once the pick answered');
  });
}
