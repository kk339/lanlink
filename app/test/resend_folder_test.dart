/// 0.2.42 — `ConversationController.resend` / `resendUnsent` must re-declare the
/// folder descriptor (`docs/22` §1.1 / §4.2).
///
/// The gap this locks shut: the receiver decides "one folder message or N flat
/// bubbles" from the presence of `folder` in the `prepare` frame, and only the
/// **first** send used to declare it. Re-sending a failed folder therefore
/// delivered N loose files under a message that the sender still called a
/// folder — the same content, two different shapes, depending on whether the
/// first attempt happened to work.
///
/// Every "the folder went" assertion here is paired with "and so did the files,
/// with their positions": a `folder.count` alone is also true of an
/// implementation that declared three files and sent two.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/real/mappers.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/transfer_service.dart';
import 'package:lanlink_core/lanlink_core.dart' as core;

import 'support/fakes.dart';

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'AAAA1111',
      alias: 'Alice',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// One stored attachment row. [relative] is the value the row really holds in
/// `files.relative_path` (the **landed** name), which is what a re-send has to
/// hand back to the wire.
FileAttachment _row(
  String messageId, {
  required String id,
  required String fileName,
  required String path,
  String? relative,
}) =>
    FileAttachment(
      id: id,
      messageId: messageId,
      fileName: fileName,
      size: 5,
      sha256: 'aa',
      localPath: path,
      relativePath: relative,
    );

void main() {
  late FakeBackend backend;
  late TransferOrchestrator orchestrator;
  late ConversationController controller;
  late String conversationId;

  setUp(() {
    backend = FakeBackend(
      devices: <PeerDevice>[_peer()],
      online: <DiscoveredPeer>[
        DiscoveredPeer(
          fingerprint: 'AAAA1111',
          alias: 'Alice',
          kind: DeviceKind.desktop,
          address: '192.168.1.10',
          port: 53317,
          isOnline: true,
          lastSeen: fixedEpoch,
        ),
      ],
    );
    conversationId = backend.repo
        .addConversation(id: 'c-1', deviceFingerprint: 'AAAA1111')
        .id;
    orchestrator = TransferOrchestrator(
      repo: backend.repo,
      transfer: backend.transfer,
    );
    controller = ConversationController(
      repo: backend.repo,
      orchestrator: orchestrator,
      platform: backend.platform,
      ids: backend.ids,
      clock: backend.clock,
      conversationId: conversationId,
    );
  });

  tearDown(() {
    controller.dispose();
    orchestrator.dispose();
    backend.dispose();
  });

  /// Seeds one `failed` outgoing message and answers the row the controller will
  /// be handed (the same object a bubble holds).
  ChatMessage seed({
    required String id,
    required List<FileAttachment> files,
    String? folderName,
    int folderFiles = 0,
  }) {
    backend.repo.addMessage(
      id: id,
      conversationId: conversationId,
      direction: MessageDirection.outgoing,
      status: MessageStatus.failed,
      folderName: folderName,
      folderFiles: folderFiles,
      files: files,
    );
    return backend.repo
        .history(conversationId)
        .firstWhere((ChatMessage m) => m.id == id);
  }

  // ---------------------------------------------------------------------
  // Criterion 1 — a folder re-send still declares the folder.
  // ---------------------------------------------------------------------
  test(
    'criterion 1: a re-sent folder declares name + count on the wire, carries '
    'both positions, and the new row records the folder too',
    () async {
      final ChatMessage failed = seed(
        id: 'm-folder',
        folderName: '素材',
        folderFiles: 2,
        files: <FileAttachment>[
          _row('m-folder',
              id: 'f-1', fileName: 'a.txt', path: '/素材/a.txt', relative: 'a.txt'),
          _row('m-folder',
              id: 'f-2',
              fileName: 'b.txt',
              path: '/素材/sub/b.txt',
              relative: 'sub/b.txt'),
        ],
      );

      final SendOutcome? outcome = await controller.resend(
        peer: _peer(),
        message: failed,
      );
      expect(outcome, isNotNull);
      expect(outcome!.delivered, isTrue);

      // 1. The descriptor reached `prepare` — this is the assertion that fails
      //    on the 0.2.41 code (which called `send` without a `folder`).
      final FolderRef? preparedFolder = backend.transfer.lastPreparedFolder;
      expect(preparedFolder, isNotNull,
          reason: '★ a re-sent folder must still say "folder" on the wire');
      expect(preparedFolder!.name, '素材');
      expect(preparedFolder.count, 2);

      // 2. …and the files, each with its own position, asserted on the **wire
      //    value** through the real mapper (not just the domain field).
      final List<OutgoingFile> prepared = backend.transfer.lastPreparedFiles;
      expect(prepared, hasLength(2));
      expect(
        prepared.map((OutgoingFile f) => f.relativePath).toList(),
        const <String>['a.txt', 'sub/b.txt'],
      );
      for (final OutgoingFile file in prepared) {
        final core.FileMetadata wire = fileMetadataFromOutgoing(file);
        expect(wire.relativePath, file.relativePath);
      }
      expect(preparedFolder.count, prepared.length);

      // 3. …and it "落库": the frame alone would not survive a restart, and the
      //    bubble renders from the row.
      final List<ChatMessage> history = backend.repo.history(conversationId);
      expect(history, hasLength(2), reason: 'a re-send is a new message');
      final ChatMessage resent =
          history.firstWhere((ChatMessage m) => m.id != 'm-folder');
      expect(resent.isFolder, isTrue);
      expect(resent.folderName, '素材');
      expect(resent.folderFiles, 2);
      expect(
        backend.repo.outboundFolderOf(resent.id),
        const FolderRef(name: '素材', count: 2),
      );
      expect(
        backend.repo.filesOf(resent.id).map((FileAttachment f) => f.relativePath),
        const <String?>['a.txt', 'sub/b.txt'],
      );
    },
  );

  // ---------------------------------------------------------------------
  // Criterion 2 — the regression red line: flat stays flat.
  // ---------------------------------------------------------------------
  test(
    'criterion 2 (red line): a flat multi-file re-send declares no folder and '
    'no positions',
    () async {
      final ChatMessage failed = seed(
        id: 'm-flat',
        files: <FileAttachment>[
          _row('m-flat', id: 'f-1', fileName: 'a.txt', path: '/src/a.txt'),
          _row('m-flat', id: 'f-2', fileName: 'b.txt', path: '/src/b.txt'),
        ],
      );

      final SendOutcome? outcome = await controller.resend(
        peer: _peer(),
        message: failed,
      );
      expect(outcome!.delivered, isTrue);

      expect(backend.transfer.lastPreparedFolder, isNull,
          reason: '★ a flat send must not grow a folder descriptor');
      final List<OutgoingFile> prepared = backend.transfer.lastPreparedFiles;
      expect(prepared, hasLength(2));
      for (final OutgoingFile file in prepared) {
        // `null`, never `''` — the receiver tests "is there a value".
        expect(file.relativePath, isNull);
        expect(fileMetadataFromOutgoing(file).relativePath, isNull);
      }

      final ChatMessage resent = backend.repo
          .history(conversationId)
          .firstWhere((ChatMessage m) => m.id != 'm-flat');
      expect(resent.folderName, isNull);
      expect(backend.repo.outboundFolderOf(resent.id), isNull);
      for (final FileAttachment file in backend.repo.filesOf(resent.id)) {
        expect(file.relativePath, isNull);
      }
    },
  );

  test(
    'criterion 2b: a flat message whose rows DO carry a position never puts '
    '`path` on the wire without a `folder` (that frame is a 400)',
    () async {
      // Unreachable through this app's own writers (folder_name and
      // relative_path are written together), so it is a guard: a re-send must
      // not smuggle a position in from a stored row and turn a working flat send
      // into a refused one.
      final ChatMessage failed = seed(
        id: 'm-flat-odd',
        files: <FileAttachment>[
          _row('m-flat-odd',
              id: 'f-1', fileName: 'a.txt', path: '/src/a.txt', relative: 'sub/a.txt'),
        ],
      );

      await controller.resend(peer: _peer(), message: failed);

      expect(backend.transfer.lastPreparedFolder, isNull);
      expect(backend.transfer.lastPreparedFiles.single.relativePath, isNull);
    },
  );

  // ---------------------------------------------------------------------
  // Criterion 3 — paths[i] must stay paired with relativePaths[i].
  // ---------------------------------------------------------------------
  test(
    'criterion 3: a path stays with its own position when file-name order and '
    'path order disagree',
    () async {
      // ★ How the fixture is built so a re-ordering bug actually shows:
      //   seeded order  → [a.jpg @ z/a.jpg,  z.jpg @ z.jpg]
      //   sorted by fileName     → a.jpg, z.jpg        (= seeded order)
      //   sorted by relativePath → z.jpg, z/a.jpg      (= REVERSED)
      // `a.jpg` is one level down under a directory that sorts *after* its own
      // name (`z/`), so the two sort keys disagree. A fixture where they agree
      // (e.g. `a.jpg` under `sub/`) passes under either implementation and would
      // prove nothing.
      final ChatMessage failed = seed(
        id: 'm-drift',
        folderName: '素材',
        folderFiles: 2,
        files: <FileAttachment>[
          _row('m-drift',
              id: 'f-1',
              fileName: 'a.jpg',
              path: '/素材/z/a.jpg',
              relative: 'z/a.jpg'),
          _row('m-drift',
              id: 'f-2', fileName: 'z.jpg', path: '/素材/z.jpg', relative: 'z.jpg'),
        ],
      );

      await controller.resend(peer: _peer(), message: failed);

      final List<OutgoingFile> prepared = backend.transfer.lastPreparedFiles;
      expect(prepared, hasLength(2));
      expect(prepared[0].localPath, '/素材/z/a.jpg');
      expect(prepared[0].relativePath, 'z/a.jpg');
      expect(prepared[1].localPath, '/素材/z.jpg');
      expect(prepared[1].relativePath, 'z.jpg');
      // Stated as a pairing so a swap cannot hide behind two independently
      // correct-looking lists.
      expect(
        <String, String?>{
          for (final OutgoingFile file in prepared)
            file.localPath: file.relativePath,
        },
        const <String, String?>{
          '/素材/z/a.jpg': 'z/a.jpg',
          '/素材/z.jpg': 'z.jpg',
        },
      );
    },
  );

  test(
    'criterion 3b: two files with the SAME name in different directories both '
    'keep their own position (a name-keyed Map would collapse them to one)',
    () async {
      final ChatMessage failed = seed(
        id: 'm-same-name',
        folderName: '素材',
        folderFiles: 2,
        files: <FileAttachment>[
          _row('m-same-name',
              id: 'f-1', fileName: 'a.jpg', path: '/素材/x/a.jpg', relative: 'x/a.jpg'),
          _row('m-same-name',
              id: 'f-2', fileName: 'a.jpg', path: '/素材/y/a.jpg', relative: 'y/a.jpg'),
        ],
      );

      await controller.resend(peer: _peer(), message: failed);

      final List<OutgoingFile> prepared = backend.transfer.lastPreparedFiles;
      expect(prepared, hasLength(2),
          reason: '★ a Map<String, String> keyed by file name loses one of these');
      expect(prepared[0].relativePath, 'x/a.jpg');
      expect(prepared[1].relativePath, 'y/a.jpg');
      expect(backend.transfer.lastPreparedFolder!.count, 2);
    },
  );

  // ---------------------------------------------------------------------
  // Criterion 4 — a missing source fails the WHOLE folder; never flat.
  // ---------------------------------------------------------------------
  test(
    'criterion 4: one missing source fails the whole folder re-send — it never '
    'falls back to flat, and the same message can be retried once the file is '
    'back',
    () async {
      final ChatMessage failed = seed(
        id: 'm-partial',
        folderName: '素材',
        folderFiles: 2,
        files: <FileAttachment>[
          _row('m-partial',
              id: 'f-1', fileName: 'a.txt', path: '/素材/a.txt', relative: 'a.txt'),
          _row('m-partial',
              id: 'f-2',
              fileName: 'b.txt',
              path: '/素材/sub/b.txt',
              relative: 'sub/b.txt'),
        ],
      );
      // The chosen strategy is the one `resend` already had: `canResend` is the
      // only gate, and it refuses a message **any** of whose sources is gone. So
      // a folder message with a hole fails as a whole (nothing is sent, it stays
      // retryable) instead of going out as a flat batch of whatever is left.
      backend.platform.setExists('/素材/sub/b.txt', false);

      final int messagesBefore = backend.repo.history(conversationId).length;
      expect(await controller.canResend(failed), isFalse);
      expect(await controller.resend(peer: _peer(), message: failed), isNull);

      // ★ "No flat fallback" has to be asserted on the wire, not just on the
      // return value: a degraded send would have prepared one file.
      expect(backend.transfer.prepareCalls, 0,
          reason: 'nothing may be offered to the peer');
      expect(backend.transfer.lastPreparedFolder, isNull);
      expect(backend.transfer.lastPreparedFiles, isEmpty);
      expect(backend.repo.history(conversationId), hasLength(messagesBefore),
          reason: 'no message row may be recorded');

      // …and it is still retryable, with the descriptor: the failure is a pause,
      // not a loss of the folder.
      backend.platform.setExists('/素材/sub/b.txt', true);
      final SendOutcome? retried =
          await controller.resend(peer: _peer(), message: failed);
      expect(retried!.delivered, isTrue);
      expect(backend.transfer.lastPreparedFolder!.name, '素材');
      expect(backend.transfer.lastPreparedFolder!.count, 2);
      expect(backend.transfer.lastPreparedFiles, hasLength(2));
    },
  );

  // ---------------------------------------------------------------------
  // Criterion 5 — 全部重试 re-declares the folder for every message it retries.
  // ---------------------------------------------------------------------
  test(
    'criterion 5: resendUnsent re-declares the folder for every folder message '
    'it retries',
    () async {
      seed(
        id: 'm-a',
        folderName: '素材A',
        folderFiles: 2,
        files: <FileAttachment>[
          _row('m-a', id: 'a-1', fileName: 'a.txt', path: '/素材A/a.txt', relative: 'a.txt'),
          _row('m-a',
              id: 'a-2', fileName: 'b.txt', path: '/素材A/sub/b.txt', relative: 'sub/b.txt'),
        ],
      );
      seed(
        id: 'm-b',
        folderName: '素材B',
        folderFiles: 1,
        files: <FileAttachment>[
          _row('m-b', id: 'b-1', fileName: 'c.txt', path: '/素材B/c.txt', relative: 'c.txt'),
        ],
      );
      await controller.load();
      expect(controller.unsentMessages, hasLength(2));

      final BulkResendResult result =
          await controller.resendUnsent(peer: _peer());
      expect(result.sent, 2);
      expect(result.failed, 0);
      expect(result.skipped, 0);
      expect(backend.transfer.prepareCalls, 2,
          reason: 'one prepare per retried message, no batching');

      // ★ Read this carefully before trusting the green: `FakeTransferService`
      // remembers only the **last** `prepare` (`lastPreparedFolder` /
      // `lastPreparedFiles` are single slots), so this test does **not** observe
      // two prepares carrying two descriptors. What "both messages were re-sent
      // WITH their folder" rests on is the *other* half — the rows:
      // `TransferOrchestrator.send` hands the **very same `FolderRef` object** to
      // `recordOutgoing` and to `prepare` (`transfer_orchestrator.dart` — the
      // repository write and `_deliver(..., folder)` come from one argument), so a
      // `FolderRef` in the repository proves the descriptor existed on that
      // message's send, and `prepareCalls == 2` proves both sends really ran.
      // Do **not** read this as "prepare was verified twice"; making that claim
      // needs a fake that records every prepare (out of scope here — the fakes
      // live in `lib/data/fake/`, which this change must not touch).
      final List<ChatMessage> resent = backend.repo
          .history(conversationId)
          .where((ChatMessage m) =>
              m.id != 'm-a' &&
              m.id != 'm-b' &&
              m.direction == MessageDirection.outgoing)
          .toList();
      expect(resent, hasLength(2), reason: 'two messages, two new rows');
      final Map<String, ChatMessage> byName = <String, ChatMessage>{
        for (final ChatMessage m in resent) m.folderName!: m,
      };
      expect(byName.keys.toSet(), <String>{'素材A', '素材B'});
      expect(byName['素材A']!.folderFiles, 2);
      expect(byName['素材B']!.folderFiles, 1);
      expect(
        backend.repo.outboundFolderOf(byName['素材A']!.id),
        const FolderRef(name: '素材A', count: 2),
      );
      expect(
        backend.repo.outboundFolderOf(byName['素材B']!.id),
        const FolderRef(name: '素材B', count: 1),
      );
      expect(
        backend.repo.filesOf(byName['素材A']!.id).map((FileAttachment f) => f.relativePath),
        const <String?>['a.txt', 'sub/b.txt'],
      );
      expect(
        backend.repo.filesOf(byName['素材B']!.id).map((FileAttachment f) => f.relativePath),
        const <String?>['c.txt'],
      );
      // The last prepare the fake saw must be a folder as well.
      expect(backend.transfer.lastPreparedFolder, isNotNull);
      expect(backend.transfer.lastPreparedFolder!.name, isIn(<String>['素材A', '素材B']));
    },
  );

  // ---------------------------------------------------------------------
  // The two judgement calls, pinned so they cannot drift silently.
  // ---------------------------------------------------------------------
  test(
    'decision: `count` is the stored DECLARED total, not the number of rows — a '
    'short row keeps showing 2/3 instead of claiming a complete folder',
    () async {
      // Only reachable through a row that never got all of its files, which is
      // exactly the case where "the sender declared 3" is the honest answer, and
      // the same number `OutboxPump` declares when it re-delivers this message.
      final ChatMessage failed = seed(
        id: 'm-short',
        folderName: '素材',
        folderFiles: 3,
        files: <FileAttachment>[
          _row('m-short',
              id: 'f-1', fileName: 'a.txt', path: '/素材/a.txt', relative: 'a.txt'),
          _row('m-short',
              id: 'f-2', fileName: 'b.txt', path: '/素材/b.txt', relative: 'b.txt'),
        ],
      );

      await controller.resend(peer: _peer(), message: failed);

      expect(backend.transfer.lastPreparedFolder!.count, 3,
          reason: 'the declared total travels, not the row count');
      expect(backend.transfer.lastPreparedFiles, hasLength(2),
          reason: 'and no file is invented to reach three');
    },
  );

  test(
    'decision: a folder row without a stored position still goes out AS a folder '
    '(its own file name as a root segment), never as a body-less 400 frame',
    () async {
      final ChatMessage failed = seed(
        id: 'm-no-pos',
        folderName: '素材',
        folderFiles: 2,
        files: <FileAttachment>[
          _row('m-no-pos',
              id: 'f-1', fileName: 'a.txt', path: '/素材/a.txt', relative: 'a.txt'),
          _row('m-no-pos', id: 'f-2', fileName: 'b.txt', path: '/素材/b.txt'),
        ],
      );

      await controller.resend(peer: _peer(), message: failed);

      final List<OutgoingFile> prepared = backend.transfer.lastPreparedFiles;
      expect(backend.transfer.lastPreparedFolder, isNotNull,
          reason: '★ one null position must not demote the whole message to flat');
      expect(prepared[0].relativePath, 'a.txt');
      expect(prepared[1].relativePath, 'b.txt',
          reason: 'the missing value falls back to a valid single segment');
      for (final OutgoingFile file in prepared) {
        expect(file.relativePath, isNotNull);
        expect(fileMetadataFromOutgoing(file).relativePath, isNotNull);
      }
    },
  );
}
