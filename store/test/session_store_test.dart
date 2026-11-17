import 'dart:async';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:lanlink_store/lanlink_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/test_db.dart';

void main() {
  late LanlinkDatabase db;
  late SessionStore store;

  setUp(() {
    db = openTestDatabase();
    store = SessionStore(db: db, ids: SequentialIdGenerator());
  });

  tearDown(() {
    store.close();
  });

  // Records a single `f1` send and drives it to `transferring`, returning the
  // result of the initial insert.
  ({String messageId, String conversationId, bool created}) sendToTransferring(
      {int size = 9}) {
    final result = store.recordOutgoingFiles(
      peer: _peer(),
      files: <OutgoingFileSpec>[_outgoing('f1', size: size)],
      now: t0,
    );
    store.setStatus(
      messageId: result.messageId,
      from: MessageStatus.pending,
      to: MessageStatus.awaitingConfirm,
      now: t0,
    );
    store.setStatus(
      messageId: result.messageId,
      from: MessageStatus.awaitingConfirm,
      to: MessageStatus.transferring,
      now: at(1),
    );
    return result;
  }

  group('recordOutgoingFiles', () {
    test('writes all five tables in one go', () {
      final result = store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[_outgoing('f1', size: 100)],
        now: t0,
      );

      expect(result.created, isTrue);
      for (final table in <String>[
        'devices',
        'conversations',
        'messages',
        'files',
        'transfers',
      ]) {
        expect(_count(db, table), 1, reason: 'exactly one $table row');
      }

      final message = store.history(result.conversationId).single;
      expect(message.id, result.messageId);
      expect(message.direction, MessageDirection.outgoing);
      expect(message.kind, MessageKind.file);
      expect(message.status, MessageStatus.pending);

      final file = store.filesOf(result.messageId).single;
      expect(file.id, 'f1');
      expect(file.size, 100);
      expect(file.localPath, '/src/a.txt');

      final transfer = store.transferOf('f1')!;
      expect(transfer.bytesTotal, 100);
      expect(transfer.bytesDone, 0);
      expect(transfer.nextAttemptAt, isNull);
      expect(transfer.sessionId, isNull);
    });

    test('a replay keeps exactly one message and never re-inserts files', () {
      final first = store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        now: t0,
      );
      final second = store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        now: at(60),
      );

      expect(first.created, isTrue);
      expect(second.created, isFalse);
      expect(second.messageId, first.messageId);
      expect(store.history(first.conversationId), hasLength(1));
      expect(_count(db, 'files'), 1);
      expect(_count(db, 'transfers'), 1);
    });

    test('rolls the whole transaction back when a write fails', () {
      expect(
        () => store.recordOutgoingFiles(
          peer: _peer(),
          // The same fileId twice: the second file insert violates the primary
          // key, aborting the transaction after the device/message were written.
          files: <OutgoingFileSpec>[_outgoing('dup'), _outgoing('dup')],
          now: t0,
        ),
        throwsA(isA<SqliteException>()),
      );

      for (final table in <String>[
        'devices',
        'conversations',
        'messages',
        'files',
        'transfers',
      ]) {
        expect(_count(db, table), 0,
            reason: '$table must be empty after rollback');
      }
      expect(store.conversations(), isEmpty);
    });

    test('stores two files of one message in selection order', () {
      final result = store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[_outgoing('f1'), _outgoing('f2')],
        now: t0,
      );
      expect(
        store.filesOf(result.messageId).map((file) => file.id).toList(),
        <String>['f1', 'f2'],
      );
      expect(_count(db, 'transfers'), 2);
    });
  });

  group('recordIncomingFile', () {
    test('lands directly at done and bumps the conversation', () {
      final result = store.recordIncomingFile(
        sender: _peer(fingerprint: 'FP9'),
        file: const IncomingFileSpec(
          fileId: 'rf1',
          fileName: 'x.bin',
          size: 5,
          sha256: 'BB',
          savedPath: '/tmp/x.bin',
        ),
        now: t0,
      );

      expect(result.created, isTrue);
      final conversation = store.conversations().single;
      final message = store.history(conversation.id).single;
      expect(message.id, result.messageId);
      expect(message.direction, MessageDirection.incoming);
      expect(message.status, MessageStatus.done);

      final file = store.filesOf(result.messageId).single;
      expect(file.id, 'rf1');
      expect(file.localPath, '/tmp/x.bin');

      final transfer = store.transferOf('rf1')!;
      expect(transfer.bytesDone, 5);
      expect(transfer.bytesTotal, 5);

      expect(conversation.lastMessageAt, t0);
      expect(conversation.lastPreview, 'x.bin');
    });

    // 0.2.23: a received file whose export to the user-visible store failed is
    // still `done` (the bytes arrived), but the **reason** must be persisted —
    // it is what the bubble reads back to stop claiming 已完成 while the file
    // sits in app-private storage.
    test('persists the publish failure reason on the transfer row', () {
      final result = store.recordIncomingFile(
        sender: _peer(fingerprint: 'FP9'),
        file: const IncomingFileSpec(
          fileId: 'rf2',
          fileName: 'y.bin',
          size: 7,
          sha256: 'DD',
          savedPath: '/tmp/y.bin',
          publishError: '空间不足',
        ),
        now: t0,
      );

      final message =
          store.history(store.conversations().single.id).single;
      expect(message.status, MessageStatus.done,
          reason: 'the receive succeeded — only the export did not');
      expect(store.transferOf('rf2')!.error, '空间不足');
      expect(result.created, isTrue);
    });

    test('a normal receive leaves the transfer error null', () {
      store.recordIncomingFile(
        sender: _peer(fingerprint: 'FP9'),
        file: const IncomingFileSpec(
          fileId: 'rf3',
          fileName: 'z.bin',
          size: 7,
          sha256: 'EE',
          savedPath: '/tmp/z.bin',
        ),
        now: t0,
      );

      expect(store.transferOf('rf3')!.error, isNull);
    });

    test('a replay keeps exactly one message', () {
      IncomingFileSpec file() => const IncomingFileSpec(
            fileId: 'rf1',
            fileName: 'x.bin',
            size: 5,
            sha256: 'BB',
            savedPath: '/tmp/x.bin',
          );
      final first = store.recordIncomingFile(
        sender: _peer(fingerprint: 'FP9'),
        file: file(),
        now: t0,
      );
      final second = store.recordIncomingFile(
        sender: _peer(fingerprint: 'FP9'),
        file: file(),
        now: at(10),
      );

      expect(second.created, isFalse);
      expect(second.messageId, first.messageId);
      expect(_count(db, 'messages'), 1);
      expect(_count(db, 'files'), 1);
    });

    test('IncomingFileSpec.fromReceivedFile copies the wire fields', () {
      const received = ReceivedFile(
        fileId: 'r7',
        fileName: 'p.pdf',
        savedPath: '/s/p.pdf',
        size: 42,
        sha256: 'CC',
      );
      final spec = IncomingFileSpec.fromReceivedFile(received);
      expect(spec.fileId, 'r7');
      expect(spec.fileName, 'p.pdf');
      expect(spec.savedPath, '/s/p.pdf');
      expect(spec.size, 42);
      expect(spec.sha256, 'CC');
      expect(spec.mime, isNull);
    });
  });

  // ── docs/22 · folder messages ────────────────────────────────────────────
  //
  // The outgoing half: a folder send is still one message with N attachments
  // (that already worked), it now additionally records the folder's name and
  // declared file count, and each attachment records its level.
  group('recordOutgoingFiles with a folder (docs/22 §6·T02 (f))', () {
    test('stores folder_name / folder_files and previews the folder name', () {
      final result = store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[
          _outgoing('f1', fileName: 'a.dll', relativePath: 'a.dll'),
          _outgoing('f2', fileName: 'b.dll', relativePath: 'data/b.dll'),
          _outgoing('f3', fileName: 'c.dll', relativePath: 'data/deep/c.dll'),
        ],
        folder: const FolderRef(name: '素材', count: 3),
        now: t0,
      );

      expect(result.created, isTrue);
      final message = store.history(result.conversationId).single;
      expect(message.folderName, '素材');
      expect(message.folderFiles, 3);
      expect(message.isFolder, isTrue);
      // The deliberate half-truth: `kind` stays `file`. Widening its CHECK would
      // need a table rebuild, which cascades every `files` row away
      // (docs/22 §2.2); `isFolder` is the single folder test in the repository.
      expect(message.kind, MessageKind.file);

      // Each attachment keeps its own level; the folder name is not repeated.
      expect(
        store.filesOf(result.messageId).map((file) => file.relativePath),
        <String>['a.dll', 'data/b.dll', 'data/deep/c.dll'],
      );
      expect(
        store.filesOf(result.messageId).map((file) => file.fileName),
        <String>['a.dll', 'b.dll', 'c.dll'],
      );
      expect(_count(db, 'transfers'), 3);

      // (f) the conversation preview of a completed folder send is the folder
      // name — not "3 files", which would say less.
      store.setStatus(
        messageId: result.messageId,
        from: MessageStatus.pending,
        to: MessageStatus.awaitingConfirm,
        now: t0,
      );
      store.setStatus(
        messageId: result.messageId,
        from: MessageStatus.awaitingConfirm,
        to: MessageStatus.transferring,
        now: at(1),
      );
      store.markSendSucceeded(messageId: result.messageId, now: at(2));

      final conversation = store.conversations().single;
      expect(conversation.lastPreview, '素材');
      expect(conversation.lastMessageAt, at(2));
    });

    test('a flat send leaves both folder columns null (regression)', () {
      final result = store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[_outgoing('f1'), _outgoing('f2')],
        now: t0,
      );

      final message = store.history(result.conversationId).single;
      expect(message.folderName, isNull);
      expect(message.folderFiles, isNull);
      expect(message.isFolder, isFalse);
      // Null, never '': a flat send has no level at all.
      expect(
        store.filesOf(result.messageId).map((file) => file.relativePath),
        <String?>[null, null],
      );
    });

    test('an empty folder name is stored as "not a folder"', () {
      // A blank title would render a folder card with no name; treating it as a
      // flat send keeps `isFolder` honest and loses nothing.
      final result = store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        folder: const FolderRef(name: '', count: 1),
        now: t0,
      );

      final message = store.history(result.conversationId).single;
      expect(message.folderName, isNull);
      expect(message.folderFiles, isNull);
    });
  });

  // The receiving half: N arrivals of one `prepare` session fold into ONE
  // message (docs/22 §4.2 / §6·T02 (d) and (e)).
  group('recordIncomingFolderFile (docs/22 §4.2)', () {
    // (d) **The most easily-broken criterion of the whole spec.** Both calls use
    // the same `sessionId`, so both resolve to the same `event_nonce` and the
    // second call must find the message it just created and append to it.
    // If the anchor were the fileId (the old behaviour), or if the second call
    // skipped the append whenever "something already exists", these assertions
    // fail: `messages` would be 2 (one per file), or `files` would be 1.
    test('two files of one session are one message with two attachments', () {
      final first = store.recordIncomingFolderFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming('rf1', fileName: 'a.bin', relativePath: 'a.bin'),
        sessionId: 'S1',
        folderName: '素材',
        folderFiles: 2,
        now: t0,
      );
      final second = store.recordIncomingFolderFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming(
          'rf2',
          fileName: 'b.bin',
          size: 7,
          savedPath: '/tmp/素材/sub/b.bin',
          relativePath: 'sub/b.bin',
        ),
        sessionId: 'S1',
        folderName: '素材',
        folderFiles: 2,
        now: at(1),
      );

      // The message was created exactly once...
      expect(first.createdMessage, isTrue);
      expect(second.createdMessage, isFalse, reason: 'same session, same anchor');
      expect(second.messageId, first.messageId);
      expect(_count(db, 'messages'), 1);

      // ...while both attachments were recorded, each with its own transfer.
      expect(first.createdFile, isTrue);
      expect(second.createdFile, isTrue);
      expect(_count(db, 'files'), 2);
      expect(_count(db, 'transfers'), 2);
      expect(store.transferOf('rf2')!.bytesDone, 7);

      final message =
          store.history(store.conversations().single.id).single;
      expect(message.folderName, '素材');
      expect(message.folderFiles, 2);
      expect(message.isFolder, isTrue);
      expect(message.kind, MessageKind.file);
      expect(message.direction, MessageDirection.incoming);
      expect(message.status, MessageStatus.done);

      // The recorded levels are the paths as written, in arrival order.
      expect(
        store.filesOf(first.messageId).map((file) => file.relativePath),
        <String>['a.bin', 'sub/b.bin'],
      );
      expect(
        store.filesOf(first.messageId).map((file) => file.localPath),
        <String>['/tmp/x.bin', '/tmp/素材/sub/b.bin'],
      );

      // The conversation is touched once, with the folder name as preview.
      final conversation = store.conversations().single;
      expect(conversation.lastPreview, '素材');
      expect(conversation.lastMessageAt, t0);
    });

    // (e) A different session is a different event: same folder name, same
    // sender, still a second message. This is why the anchor is the session id
    // and not the folder name — sending `素材` three times a day is normal.
    test('two different sessions of the same folder are two messages', () {
      final first = store.recordIncomingFolderFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming('rf1', relativePath: 'a.bin'),
        sessionId: 'S1',
        folderName: '素材',
        folderFiles: 1,
        now: t0,
      );
      final second = store.recordIncomingFolderFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming('rf2', relativePath: 'a.bin'),
        sessionId: 'S2',
        folderName: '素材',
        folderFiles: 1,
        now: at(60),
      );

      expect(first.createdMessage, isTrue);
      expect(second.createdMessage, isTrue);
      expect(second.messageId, isNot(first.messageId));
      expect(_count(db, 'messages'), 2);
      expect(_count(db, 'files'), 2);
    });

    test('a re-delivered file of one session is not recorded twice', () {
      final file = _incoming('rf1', relativePath: 'a.bin');
      final first = store.recordIncomingFolderFile(
        sender: _peer(fingerprint: 'FP9'),
        file: file,
        sessionId: 'S1',
        folderName: '素材',
        folderFiles: 2,
        now: t0,
      );
      final replay = store.recordIncomingFolderFile(
        sender: _peer(fingerprint: 'FP9'),
        file: file,
        sessionId: 'S1',
        folderName: '素材',
        folderFiles: 2,
        now: at(5),
      );

      expect(first.createdFile, isTrue);
      expect(replay.createdMessage, isFalse);
      expect(replay.createdFile, isFalse);
      expect(_count(db, 'files'), 1);
      // No second transfer either: the duplicate insert short-circuits it, so a
      // retried `put` cannot make the N/N counter overshoot.
      expect(_count(db, 'transfers'), 1);
    });

    // CR-2 ③ — the *other* re-delivery shape: same attachment, **new** anchor.
    //
    // `OutboxPump` re-sends with the original `fileId` on purpose
    // (`outbox_pump.dart:378`: the send was answered but the answer never got
    // recorded, so the row is still `pending`). The receiver's second `prepare`
    // mints a fresh session id, so `event_nonce` differs and
    // `ux_messages_event` — the anchor that makes N arrivals of one session a
    // single message — lets a **second** message through. The attachment does
    // not follow: `files.id` *is* the fileId, so `INSERT OR IGNORE` skips it.
    //
    // Before the fix that left a message with zero attachments, and
    // `touchLastMessage` pushed it to the end of the conversation — a bubble the
    // user cannot open and cannot account for.
    test('★ a re-delivery under a NEW session id leaves no attachment-less '
        'message', () {
      final file = _incoming('rf1', fileName: 'a.bin', relativePath: 'a.bin');
      final first = store.recordIncomingFolderFile(
        sender: _peer(fingerprint: 'FP9'),
        file: file,
        sessionId: 'S1',
        folderName: '素材',
        folderFiles: 1,
        now: t0,
      );
      expect(first.createdMessage, isTrue);

      // The restart: same batch, same fileId, new session id.
      final replay = store.recordIncomingFolderFile(
        sender: _peer(fingerprint: 'FP9'),
        file: file,
        sessionId: 'S2',
        folderName: '素材',
        folderFiles: 1,
        now: at(30),
      );

      expect(replay.createdMessage, isFalse,
          reason: 'the attachment already landed; nothing new to announce');
      expect(replay.createdFile, isFalse, reason: 'the fileId is taken');
      expect(replay.messageId, first.messageId,
          reason: 'the answer must name the message that owns the file');

      // The three numbers of the criterion: message count unchanged, the
      // original attachment count unchanged, and **no** zero-attachment row.
      final messages = store.history(store.conversations().single.id);
      expect(messages, hasLength(1));
      expect(messages.single.id, first.messageId);
      expect(store.filesOf(first.messageId), hasLength(1));
      for (final message in messages) {
        expect(store.filesOf(message.id), isNotEmpty,
            reason: 'message ${message.id} has no attachments');
      }
      expect(_count(db, 'files'), 1);
      expect(_count(db, 'transfers'), 1);

      // …and the conversation was not dragged to the replay's timestamp.
      final conversation = store.conversations().single;
      expect(conversation.lastMessageAt, t0);
      expect(conversation.lastPreview, '素材');
    });

    test('a re-delivery with an unknown fileId still appends to its session',
        () {
      // The other half of ③: refusing the *empty* message must not turn the
      // folder path into "one message per file" or drop a genuine second arrival.
      store.recordIncomingFolderFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming('rf1', relativePath: 'a.bin'),
        sessionId: 'S1',
        folderName: '素材',
        folderFiles: 2,
        now: t0,
      );
      final second = store.recordIncomingFolderFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming('rf2', relativePath: 'b.bin'),
        sessionId: 'S1',
        folderName: '素材',
        folderFiles: 2,
        now: at(1),
      );
      expect(second.createdFile, isTrue);
      expect(second.createdMessage, isFalse);
      expect(store.filesOf(second.messageId), hasLength(2));
    });

    test('persists the publish failure reason on the transfer row', () {
      store.recordIncomingFolderFile(
        sender: _peer(fingerprint: 'FP9'),
        file: const IncomingFileSpec(
          fileId: 'rf1',
          fileName: 'a.bin',
          size: 5,
          sha256: 'BB',
          savedPath: '/tmp/a.bin',
          relativePath: 'a.bin',
          publishError: '路径过长',
        ),
        sessionId: 'S1',
        folderName: '素材',
        folderFiles: 1,
        now: t0,
      );

      expect(store.transferOf('rf1')!.error, '路径过长');
    });

    test('emits MessageInserted once for the whole session', () async {
      final events = <StoreEvent>[];
      final subscription = store.events.listen(events.add);
      addTearDown(subscription.cancel);

      for (final (index, fileId) in <String>['rf1', 'rf2', 'rf3'].indexed) {
        store.recordIncomingFolderFile(
          sender: _peer(fingerprint: 'FP9'),
          file: _incoming(fileId, relativePath: '$fileId.bin'),
          sessionId: 'S1',
          folderName: '素材',
          folderFiles: 3,
          now: at(index),
        );
        await _flush();
      }

      // 200 files must not push 200 "message inserted" events at the UI.
      expect(events.whereType<MessageInserted>(), hasLength(1));
    });

    test('emits MessageFilesAppended for files 2…N of a session — and only those',
        () async {
      // 0.2.51 — the silent half of "发一个文件夹，对面那张卡片不会从 1 个刷到 2 个".
      // File 1 creates the message (`MessageInserted`); files 2 and 3 append to
      // it, change no message count, and used to emit **nothing**, so a listener
      // that refreshes on "a message arrived" never redrew the growth.
      final events = <StoreEvent>[];
      final subscription = store.events.listen(events.add);
      addTearDown(subscription.cancel);

      String? messageId;
      for (final (index, fileId) in <String>['rf1', 'rf2', 'rf3'].indexed) {
        final result = store.recordIncomingFolderFile(
          sender: _peer(fingerprint: 'FP9'),
          file: _incoming(fileId, relativePath: '$fileId.bin'),
          sessionId: 'S1',
          folderName: '素材',
          folderFiles: 3,
          now: at(index),
        );
        // Every call of one session answers with the same anchor.
        messageId ??= result.messageId;
        expect(result.messageId, messageId);
        await _flush();
      }

      expect(events.whereType<MessageInserted>(), hasLength(1),
          reason: 'one message for the whole session — unchanged by 0.2.51');
      final List<MessageFilesAppended> appended =
          events.whereType<MessageFilesAppended>().toList();
      expect(appended, hasLength(2),
          reason: 'files 2 and 3 grew the message; 3 would mean the creating '
              'file announced itself twice, 0 is the defect');
      // Both name the message file 1 created, so a listener re-reads the right row.
      expect(
        appended.map((MessageFilesAppended event) => event.messageId).toSet(),
        <String>{messageId!},
      );

      // A re-delivered file writes no row, so it grows nothing and says nothing.
      store.recordIncomingFolderFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming('rf2', relativePath: 'rf2.bin'),
        sessionId: 'S1',
        folderName: '素材',
        folderFiles: 3,
        now: at(3),
      );
      await _flush();
      expect(events.whereType<MessageFilesAppended>(), hasLength(2),
          reason: 'insertIfAbsent wrote nothing, so there is no append to report');
    });

    test('rejects an empty session id or folder name', () {
      expect(
        () => store.recordIncomingFolderFile(
          sender: _peer(fingerprint: 'FP9'),
          file: _incoming('rf1'),
          sessionId: '',
          folderName: '素材',
          folderFiles: 1,
          now: t0,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => store.recordIncomingFolderFile(
          sender: _peer(fingerprint: 'FP9'),
          file: _incoming('rf1'),
          sessionId: 'S1',
          folderName: '',
          folderFiles: 1,
          now: t0,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(_count(db, 'messages'), 0);
    });

    test('IncomingFileSpec.fromReceivedFile carries relativePath', () {
      const received = ReceivedFile(
        fileId: 'r9',
        fileName: 'p.pdf',
        savedPath: '/s/p.pdf',
        size: 42,
        sha256: 'CC',
        sessionId: 'S9',
        folderName: '素材',
        folderFiles: 2,
        relativePath: 'docs/p.pdf',
      );
      final spec = IncomingFileSpec.fromReceivedFile(received);
      expect(spec.relativePath, 'docs/p.pdf');
    });
  });

  group('recordIncomingSessionFile (0.2.51 — a flat multi-select is one message)',
      () {
    // The sender's multi-select has always been one `prepare` with N files; the
    // receiver's session id is on every arrival. What used to split it is the
    // anchor: `recordIncomingFile` uses one `fileId`, this path uses the session.
    test('★ three files of one session → ONE message with THREE attachments',
        () {
      String? messageId;
      for (final (index, id) in <String>['b1', 'b2', 'b3'].indexed) {
        final result = store.recordIncomingSessionFile(
          sender: _peer(fingerprint: 'FP9'),
          file: _incoming(id, fileName: '$id.bin'),
          sessionId: 'BATCH1',
          now: at(index),
        );
        messageId ??= result.messageId;
        expect(result.messageId, messageId,
            reason: 'every arrival of one session resolves to the same row');
      }

      final List<MessageRecord> messages =
          store.history(store.conversations().single.id);
      expect(messages, hasLength(1), reason: '★ N arrivals, 1 message');
      expect(store.filesOf(messages.single.id), hasLength(3));

      // …and it is NOT a folder message: no descriptor, so `isFolder` is false
      // and the UI draws rows rather than a folder card.
      final MessageRecord message = messages.single;
      expect(message.folderName, isNull);
      expect(message.folderFiles, isNull,
          reason: 'this caller declared nothing (the one-file / pre-0.2.52 '
              'shape), and NULL is the honest answer to "unknown"');
      expect(message.isFolder, isFalse);
      expect(message.status, MessageStatus.done);
      expect(message.direction, MessageDirection.incoming);
    });

    test('★ the declared count is stored on the message, the folder stays NULL '
        '(0.2.52)', () {
      // 0.2.52 — `core` now fills `ReceivedFile.folderFiles` with the number of
      // files the `prepare` declared, for a flat session too. The store must
      // keep **both** halves apart: the count goes into the existing
      // `folder_files` column (no schema change, no new column), while
      // `folder_name` stays NULL so `isFolder` is false and the batch keeps
      // drawing attachment rows instead of a folder card.
      for (final (index, id) in <String>['k1', 'k2', 'k3'].indexed) {
        store.recordIncomingSessionFile(
          sender: _peer(fingerprint: 'FP9'),
          file: _incoming(id, fileName: '$id.bin'),
          sessionId: 'BATCH8',
          folderFiles: 8,
          now: at(index),
        );
      }

      final List<MessageRecord> messages =
          store.history(store.conversations().single.id);
      expect(messages, hasLength(1), reason: 'one session, one message');
      final MessageRecord message = messages.single;
      expect(message.folderFiles, 8,
          reason: 'the sender declared 8; 3 arrived — the UI needs the 8');
      expect(message.folderName, isNull,
          reason: '★ no descriptor: `isFolder` must stay false');
      expect(message.isFolder, isFalse);
      expect(store.filesOf(message.id), hasLength(3));

      // The row is still the batch family, not a folder: a re-arrival of the
      // same session keeps appending to it.
      final again = store.recordIncomingSessionFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming('k4', fileName: 'k4.bin'),
        sessionId: 'BATCH8',
        folderFiles: 8,
        now: at(4),
      );
      expect(again.messageId, message.id);
      expect(again.createdFile, isTrue);
      expect(store.filesOf(message.id), hasLength(4));
    });

    test('★ a single-file send still stores nothing in the declared column '
        '(criterion 5)', () {
      // The other half of the same rule: `core` fills 0 for a one-file session,
      // so the column stays NULL and the bubble can never grow 「N 个未收到」.
      store.recordIncomingSessionFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming('only'),
        sessionId: 'SINGLE1',
        folderFiles: 0,
        now: t0,
      );
      store.recordIncomingSessionFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming('only2'),
        sessionId: 'SINGLE2',
        now: at(1),
      );

      for (final MessageRecord message
          in store.history(store.conversations().single.id)) {
        expect(message.folderFiles, isNull,
            reason: 'explicit 0 and "not passed" must both mean NULL');
        expect(message.isFolder, isFalse);
      }
    });

    test('★ two DIFFERENT sessions → two messages', () {
      for (final (index, session) in <String>['S-A', 'S-B'].indexed) {
        store.recordIncomingSessionFile(
          sender: _peer(fingerprint: 'FP9'),
          file: _incoming('d$index'),
          sessionId: session,
          now: at(index),
        );
      }
      expect(store.history(store.conversations().single.id), hasLength(2),
          reason: 'aggregation is per session, never "all flat files together"');
    });

    test('★ the batch anchor is its own family — it cannot alias a folder or '
        'a bare file id', () {
      // One session id, three shapes: a folder send, a flat batch and a
      // single-file send. If two of them shared an anchor they would land on one
      // message (and the folder card would appear on a batch, or a batch would
      // swallow a folder).
      final folder = store.recordIncomingFolderFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming('x1'),
        sessionId: 'SHARED',
        folderName: '素材',
        folderFiles: 1,
        now: t0,
      );
      final batch = store.recordIncomingSessionFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming('x2'),
        sessionId: 'SHARED',
        now: at(1),
      );
      final single = store.recordIncomingFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming('x3'),
        now: at(2),
      );

      expect(
        <String>{folder.messageId, batch.messageId, single.messageId},
        hasLength(3),
        reason: 'folder / batch / single-file anchors are three disjoint '
            'families (ids/message_id.dart)',
      );
      expect(store.history(store.conversations().single.id), hasLength(3));

      // And the two anchors are literally the documented prefixes — a change to
      // either constant is a history-identity change and must be deliberate.
      final MessageRecord batchRow =
          store.history(store.conversations().single.id).firstWhere(
                (MessageRecord m) => m.id == batch.messageId,
              );
      expect(batchRow.eventNonce, eventNonceForBatchSession('SHARED'));
      expect(batchRow.eventNonce.startsWith('batch\u001f'), isTrue);
    });

    test('a re-delivered file is a no-op: no row, no event, same message', () {
      store.recordIncomingSessionFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming('b1'),
        sessionId: 'BATCH1',
        now: t0,
      );
      final before = store.filesOf(
        store.history(store.conversations().single.id).single.id,
      );
      final again = store.recordIncomingSessionFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming('b1'),
        sessionId: 'BATCH1',
        now: at(1),
      );
      expect(again.createdFile, isFalse);
      expect(again.createdMessage, isFalse);
      expect(
        store.filesOf(store.history(store.conversations().single.id).single.id),
        hasLength(before.length),
      );
    });

    test('emits MessageInserted once and MessageFilesAppended N-1 times',
        () async {
      // Criterion 5 at the store level: files 2..N must be announced, or the
      // receiving bubble stays frozen at one row.
      final events = <StoreEvent>[];
      final subscription = store.events.listen(events.add);
      addTearDown(subscription.cancel);

      for (final (index, id) in <String>['b1', 'b2', 'b3'].indexed) {
        store.recordIncomingSessionFile(
          sender: _peer(fingerprint: 'FP9'),
          file: _incoming(id),
          sessionId: 'BATCH1',
          now: at(index),
        );
        await _flush();
      }

      expect(events.whereType<MessageInserted>(), hasLength(1));
      expect(events.whereType<MessageFilesAppended>(), hasLength(2));
    });

    test('rejects an empty session id (no anchor ⇒ no aggregation)', () {
      expect(
        () => store.recordIncomingSessionFile(
          sender: _peer(fingerprint: 'FP9'),
          file: _incoming('b1'),
          sessionId: '',
          now: t0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('recordOutgoingText / recordIncomingText (docs/13 §7.3)', () {
    test('outgoing text lands exactly one kind=text row, no files/transfers',
        () {
      final result = store.recordOutgoingText(
        peer: _peer(),
        text: _v1Body,
        eventNonce: 'nonce-text-1',
        now: t0,
      );

      expect(result.created, isTrue);
      for (final table in <String>['devices', 'conversations', 'messages']) {
        expect(_count(db, table), 1, reason: 'exactly one $table row');
      }
      expect(_count(db, 'files'), 0);
      expect(_count(db, 'transfers'), 0);

      final message = store.history(result.conversationId).single;
      expect(message.id, result.messageId);
      expect(message.direction, MessageDirection.outgoing);
      expect(message.kind, MessageKind.text);
      expect(message.textBody, _v1Body);
      expect(message.status, MessageStatus.pending);
      expect(store.filesOf(result.messageId), isEmpty);
    });

    test('a retry reusing the nonce keeps exactly one message (idempotent)',
        () {
      final first = store.recordOutgoingText(
        peer: _peer(),
        text: 'ping',
        eventNonce: 'n-1',
        now: t0,
      );
      final second = store.recordOutgoingText(
        peer: _peer(),
        text: 'ping',
        eventNonce: 'n-1', // the retry reuses the same anchor
        now: at(30),
      );

      expect(first.created, isTrue);
      expect(second.created, isFalse);
      expect(second.messageId, first.messageId);
      expect(store.history(first.conversationId), hasLength(1));
      expect(_count(db, 'messages'), 1);
    });

    test('the same text as a new event (new nonce) is a second message', () {
      final first = store.recordOutgoingText(
        peer: _peer(),
        text: 'same',
        eventNonce: 'a',
        now: t0,
      );
      final second = store.recordOutgoingText(
        peer: _peer(),
        text: 'same',
        eventNonce: 'b',
        now: at(1),
      );

      expect(second.created, isTrue);
      expect(second.messageId, isNot(first.messageId));
      expect(store.history(first.conversationId), hasLength(2));
    });

    test('the stored id equals the pure computeMessageId (spec V1 vector)', () {
      final result = store.recordOutgoingText(
        peer: _peer(fingerprint: _v1Fingerprint),
        text: _v1Body,
        eventNonce: 'nonce-text-1',
        now: t0,
      );
      expect(
        result.messageId,
        computeMessageId(
          fingerprint: _v1Fingerprint,
          direction: MessageDirection.outgoing,
          kind: MessageKind.text,
          eventNonce: 'nonce-text-1',
          contentKey: contentKeyForText(_v1Body),
        ),
      );
      // The pre-computed hex of spec §5.6.4 (an independent regression guard).
      expect(result.messageId, _v1Id);
    });

    test('incoming text lands done, bumps the conversation, and is idempotent',
        () {
      final first = store.recordIncomingText(
        sender: _peer(fingerprint: 'FP9'),
        text: 'hi there',
        eventNonce: 'in-1',
        now: t0,
      );
      expect(first.created, isTrue);

      final conversation = store.conversations().single;
      final message = store.history(conversation.id).single;
      expect(message.id, first.messageId);
      expect(message.direction, MessageDirection.incoming);
      expect(message.kind, MessageKind.text);
      expect(message.textBody, 'hi there');
      expect(message.status, MessageStatus.done);
      expect(conversation.lastMessageAt, t0);
      expect(conversation.lastPreview, 'hi there');

      final second = store.recordIncomingText(
        sender: _peer(fingerprint: 'FP9'),
        text: 'hi there',
        eventNonce: 'in-1', // the sender re-delivers the same frame
        now: at(10),
      );
      expect(second.created, isFalse);
      expect(second.messageId, first.messageId);
      expect(_count(db, 'messages'), 1);
    });

    test('a sent text reaches done and its preview becomes the body', () {
      final result = store.recordOutgoingText(
        peer: _peer(),
        text: '你好，世界',
        eventNonce: 'n-done',
        now: t0,
      );

      // A text message has no confirm/transfer stage: pending -> done is legal
      // (docs/13 §7.3 / the B-ruling), so markSendSucceeded must not throw.
      store.markSendSucceeded(messageId: result.messageId, now: at(1));

      expect(
        store.history(result.conversationId).single.status,
        MessageStatus.done,
      );
      // The preview bug guard: a text preview must be the body, never null.
      expect(store.conversations().single.lastPreview, '你好，世界');
    });

    test('a long text preview is truncated to kPreviewMaxChars', () {
      final long = 'x' * (kPreviewMaxChars + 60);
      final result = store.recordIncomingText(
        sender: _peer(fingerprint: 'FP9'),
        text: long,
        eventNonce: 'i-long',
        now: t0,
      );

      expect(result.created, isTrue);
      final preview = store.conversations().single.lastPreview!;
      expect(preview.length, kPreviewMaxChars);
      expect(preview, 'x' * kPreviewMaxChars);
    });
  });

  group('setStatus', () {
    test('applies a legal edge and returns true', () {
      final result = store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        now: t0,
      );
      final moved = store.setStatus(
        messageId: result.messageId,
        from: MessageStatus.pending,
        to: MessageStatus.awaitingConfirm,
        now: t0,
      );
      expect(moved, isTrue);
      expect(
        store.history(result.conversationId).single.status,
        MessageStatus.awaitingConfirm,
      );
    });

    test('returns false and leaves the row when the status does not match', () {
      final result = store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        now: t0,
      );
      final moved = store.setStatus(
        messageId: result.messageId,
        from: MessageStatus.awaitingConfirm,
        to: MessageStatus.transferring,
        now: t0,
      );
      expect(moved, isFalse);
      expect(
        store.history(result.conversationId).single.status,
        MessageStatus.pending,
      );
    });

    test('throws on an illegal edge and changes nothing', () {
      final result = store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        now: t0,
      );
      expect(
        () => store.setStatus(
          messageId: result.messageId,
          // `pending -> done` is legal since docs/13 §7.3; `pending ->
          // transferring` is still illegal, so it exercises the error.
          from: MessageStatus.pending,
          to: MessageStatus.transferring,
          now: t0,
        ),
        throwsA(isA<InvalidStatusTransition>()),
      );
      expect(
        store.history(result.conversationId).single.status,
        MessageStatus.pending,
      );
    });
  });

  group('markSendSucceeded', () {
    test('completes the transfer and bumps the conversation', () {
      final result = sendToTransferring(size: 100);

      store.markSendSucceeded(messageId: result.messageId, now: at(5));

      expect(
        store.history(result.conversationId).single.status,
        MessageStatus.done,
      );
      final transfer = store.transferOf('f1')!;
      expect(transfer.bytesDone, 100);
      expect(transfer.nextAttemptAt, isNull);

      final conversation = store.conversations().single;
      expect(conversation.lastMessageAt, at(5));
      expect(conversation.lastPreview, 'a.txt');
    });

    test('is idempotent when the message is already done', () {
      final result = sendToTransferring();
      store.markSendSucceeded(messageId: result.messageId, now: at(5));
      expect(
        () => store.markSendSucceeded(messageId: result.messageId, now: at(6)),
        returnsNormally,
      );
    });

    test('throws RowNotFound for an unknown message', () {
      expect(
        () => store.markSendSucceeded(messageId: 'nope', now: t0),
        throwsA(isA<RowNotFound>()),
      );
    });
  });

  group('markSendFailed', () {
    test('schedules a retry on the transfer', () {
      final result = sendToTransferring();

      store.markSendFailed(
        messageId: result.messageId,
        error: 'boom',
        retryIn: const Duration(seconds: 30),
        now: at(2),
      );

      expect(
        store.history(result.conversationId).single.status,
        MessageStatus.failed,
      );
      final transfer = store.transferOf('f1')!;
      expect(transfer.retryCount, 1);
      expect(transfer.error, 'boom');
      expect(transfer.nextAttemptAt, at(32));

      final transfers = TransfersDao(db);
      expect(transfers.dueForRetry(now: at(31)), isEmpty);
      expect(transfers.dueForRetry(now: at(32)), hasLength(1));
    });

    test('a null retryIn clears the schedule', () {
      final result = sendToTransferring();
      store.markSendFailed(
        messageId: result.messageId,
        error: 'x',
        now: at(2),
      );
      expect(store.transferOf('f1')!.nextAttemptAt, isNull);
      expect(store.transferOf('f1')!.retryCount, 1);
    });
  });

  group('attachSession / markTransferProgress', () {
    test('store the session and the per-attempt byte count', () {
      final result = sendToTransferring();
      store.attachSession(
        fileId: 'f1',
        sessionId: 's-1',
        token: 'tok',
        now: t0,
      );
      store.markTransferProgress(fileId: 'f1', bytesDone: 40, now: t0);

      final transfer = store.transferOf('f1')!;
      expect(transfer.sessionId, 's-1');
      expect(transfer.token, 'tok');
      expect(transfer.bytesDone, 40);
      expect(result.created, isTrue);
    });

    test('throws RowNotFound for an unknown file', () {
      expect(
        () => store.attachSession(
          fileId: 'ghost',
          sessionId: 's',
          token: 't',
          now: t0,
        ),
        throwsA(isA<RowNotFound>()),
      );
      expect(
        () =>
            store.markTransferProgress(fileId: 'ghost', bytesDone: 1, now: t0),
        throwsA(isA<RowNotFound>()),
      );
    });
  });

  // docs/22 §4.4（改版）: the UI tells "still arriving" from "stalled with N
  // files missing" by asking this, instead of guessing from a 90-second timer on
  // `messages.updated_at` — that column keeps meaning "when the status last
  // changed" and is **not** written when a file arrives.
  group('lastActivityAt (docs/22 §4.4)', () {
    test('returns the newest transfer time when the transfers differ', () {
      final result = store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[_outgoing('f1'), _outgoing('f2')],
        now: t0,
      );
      // Two attempts at different times: T1 = at(5), T2 = at(9) (later).
      store.markTransferProgress(fileId: 'f1', bytesDone: 3, now: at(5));
      store.markTransferProgress(fileId: 'f2', bytesDone: 4, now: at(9));

      expect(store.lastActivityAt(result.messageId), at(9),
          reason: 'the maximum of the two, not the first or the last written');

      // ...and it does track *later* activity: completing at at(20) moves it.
      store.markSendSucceeded(messageId: result.messageId, now: at(20));
      expect(store.lastActivityAt(result.messageId), at(20));
    });

    test('falls back to created_at when the message has no transfer', () {
      // A text message has no files, hence no transfers, ever.
      final text = store.recordOutgoingText(
        peer: _peer(),
        text: 'hi',
        eventNonce: 'n-activity',
        now: t0,
      );
      expect(store.lastActivityAt(text.messageId), t0);
    });

    test('falls back to created_at when the file rows have no transfer', () {
      final result = store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        now: t0,
      );
      TransfersDao(db).deleteByFileId('f1');

      expect(store.lastActivityAt(result.messageId), t0);
    });

    test('returns null for an unknown message instead of throwing', () {
      expect(store.lastActivityAt('nope'), isNull);
    });

    test('a folder message moves as its files arrive', () {
      // The use-case this was added for: two arrivals, 3 seconds apart, and the
      // activity timestamp follows the second one — so "N 个未收到" can be judged
      // by data instead of a guess.
      final first = store.recordIncomingFolderFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming('rf1', relativePath: 'a.bin'),
        sessionId: 'S1',
        folderName: '素材',
        folderFiles: 2,
        now: t0,
      );
      expect(store.lastActivityAt(first.messageId), t0);

      store.recordIncomingFolderFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming('rf2', relativePath: 'b.bin'),
        sessionId: 'S1',
        folderName: '素材',
        folderFiles: 2,
        now: at(3),
      );
      expect(store.lastActivityAt(first.messageId), at(3));
      // Two attachments and the message row itself is untouched by arrivals:
      // `updated_at` still says "created at t0" (that is the point).
      final message = store.history(store.conversations().single.id).single;
      expect(message.createdAt, t0);
      expect(message.updatedAt, t0);
    });
  });

  group('reopenForNewFingerprint', () {
    test('archives the old thread and opens a fresh active one', () {
      final old = store.reopenForNewFingerprint(fingerprint: 'FP1', now: t0);
      final fresh =
          store.reopenForNewFingerprint(fingerprint: 'FP1', now: at(10));

      expect(fresh.id, isNot(old.id));
      final archived = store
          .conversations(includeArchived: true)
          .where((conversation) => conversation.id == old.id)
          .single;
      expect(archived.isArchived, isTrue);
      expect(archived.archivedAt, at(10));
      expect(
        store.conversations().map((conversation) => conversation.id),
        contains(fresh.id),
      );
    });

    test('creates the device row so the new conversation has an FK target', () {
      final conversation =
          store.reopenForNewFingerprint(fingerprint: 'brand:new', now: t0);
      expect(conversation.deviceFingerprint, 'BRANDNEW');
      expect(_count(db, 'devices'), 1);
    });

    test('rejects an empty fingerprint', () {
      expect(
        () => store.reopenForNewFingerprint(fingerprint: '', now: t0),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('events', () {
    test('emits MessageInserted then MessageStatusChanged, in order', () async {
      final events = <StoreEvent>[];
      final subscription = store.events.listen(events.add);
      addTearDown(subscription.cancel);

      final result = store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        now: t0,
      );
      store.setStatus(
        messageId: result.messageId,
        from: MessageStatus.pending,
        to: MessageStatus.awaitingConfirm,
        now: t0,
      );
      await _flush();

      expect(
        events.map((event) => event.runtimeType).toList(),
        <Type>[MessageInserted, MessageStatusChanged],
      );
      final changed = events[1] as MessageStatusChanged;
      expect(changed.messageId, result.messageId);
      expect(changed.from, MessageStatus.pending);
      expect(changed.to, MessageStatus.awaitingConfirm);
    });

    test('emits nothing for a replay or a rolled-back write', () async {
      final events = <StoreEvent>[];
      final subscription = store.events.listen(events.add);
      addTearDown(subscription.cancel);

      store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        now: t0,
      );
      await _flush();
      expect(events.whereType<MessageInserted>(), hasLength(1));

      store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        now: at(1),
      );
      await _flush();
      expect(
        events.whereType<MessageInserted>(),
        hasLength(1),
        reason: 'a de-duplicated replay emits nothing',
      );

      expect(
        () => store.recordOutgoingFiles(
          peer: _peer(),
          files: <OutgoingFileSpec>[_outgoing('dup'), _outgoing('dup')],
          now: at(2),
        ),
        throwsA(isA<SqliteException>()),
      );
      await _flush();
      expect(
        events.whereType<MessageInserted>(),
        hasLength(1),
        reason: 'a rolled-back write emits nothing',
      );
    });
  });

  group('close', () {
    test('is idempotent and blocks further use', () {
      store.close();
      store.close();
      expect(
        () => store.conversations(),
        throwsA(isA<StoreClosedException>()),
      );
      expect(
        () => store.setStatus(
          messageId: 'x',
          from: MessageStatus.pending,
          to: MessageStatus.canceled,
          now: t0,
        ),
        throwsA(isA<StoreClosedException>()),
      );
    });
  });

  group('reads', () {
    test('reflect what was written', () {
      final result = store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[_outgoing('f1'), _outgoing('f2')],
        now: t0,
      );
      expect(store.conversations().single.id, result.conversationId);
      expect(store.history(result.conversationId), hasLength(1));
      expect(store.filesOf(result.messageId), hasLength(2));
      expect(store.transferOf('f2'), isNotNull);
      expect(store.transferOf('nope'), isNull);
    });
  });

  // The three read-only accessors added in M4 (spec §3.3): pure pass-throughs
  // to DevicesDao.byFingerprint / .all() and MessagesDao.byStatus.
  group('device / devices / messagesByStatus (M4 §3.3)', () {
    test('device() returns the row and normalises its lookup key', () {
      store.recordOutgoingFiles(
        peer: _peer(fingerprint: 'fp:aa-bb'),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        now: t0,
      );

      // The stored key is normalised: the `:` separator is stripped and the
      // result is uppercased (a `-` is not a separator and is kept).
      expect(store.device('FPAA-BB')!.fingerprint, 'FPAA-BB');
      // A differently-spelled fingerprint still finds the same row.
      expect(store.device('fp:aa-bb'), isNotNull);
      expect(store.device('unknown'), isNull);
    });

    test('devices() returns every device row', () {
      store.recordOutgoingFiles(
        peer: _peer(fingerprint: 'A'),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        now: t0,
      );
      store.recordIncomingFile(
        sender: _peer(fingerprint: 'B'),
        file: _incoming('r1'),
        now: t0,
      );

      expect(
        store.devices().map((device) => device.fingerprint).toSet(),
        <String>{'A', 'B'},
      );
    });

    test('messagesByStatus() filters by status', () {
      final outgoing = store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        now: t0,
      );
      expect(
        store.messagesByStatus(<MessageStatus>{MessageStatus.pending}).map(
            (message) => message.id),
        <String>[outgoing.messageId],
      );

      final incoming = store.recordIncomingFile(
        sender: _peer(fingerprint: 'FP9'),
        file: _incoming('r1'),
        now: t0,
      );
      // The outgoing message stayed pending; the incoming one is done.
      expect(
        store.messagesByStatus(<MessageStatus>{MessageStatus.done}).map(
            (message) => message.id),
        <String>[incoming.messageId],
      );
      expect(
        store.messagesByStatus(<MessageStatus>{MessageStatus.pending}).map(
            (message) => message.id),
        <String>[outgoing.messageId],
      );
    });

    test('messagesByStatus() with an empty set yields an empty list', () {
      store.recordOutgoingFiles(
        peer: _peer(),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        now: t0,
      );
      expect(store.messagesByStatus(<MessageStatus>{}), isEmpty);
    });
  });
}

/// A peer that sends or receives.
DeviceInfo _peer({String fingerprint = 'FP1', int port = 53317}) =>
    DeviceInfo(alias: 'Peer', fingerprint: fingerprint, port: port);

/// A file to send.
OutgoingFileSpec _outgoing(
  String id, {
  String fileName = 'a.txt',
  int size = 9,
  String sha256 = 'AA',
  String localPath = '/src/a.txt',
  String? relativePath,
}) =>
    OutgoingFileSpec(
      id: id,
      fileName: fileName,
      size: size,
      sha256: sha256,
      localPath: localPath,
      relativePath: relativePath,
    );

/// A verified incoming file.
IncomingFileSpec _incoming(
  String id, {
  String fileName = 'x.bin',
  int size = 5,
  String sha256 = 'BB',
  String savedPath = '/tmp/x.bin',
  String? relativePath,
}) =>
    IncomingFileSpec(
      fileId: id,
      fileName: fileName,
      size: size,
      sha256: sha256,
      savedPath: savedPath,
      relativePath: relativePath,
    );

/// The spec §5.6.4 V1 vector: the normalised fingerprint, the text body (written
/// as ASCII escapes so this file stays pure ASCII), and the pre-computed id.
/// Repeated locally rather than imported because a test file is its own library.
const String _v1Fingerprint =
    '580AC9D0BEAB379FEBCE64B56775E4A4C24ECC2993AD974F30176DBF7CF74A07';
const String _v1Body = '\u4f60\u597d\uff0clanlink';
const String _v1Id =
    '9AF5C671087BA2B26D2F4AA0173EFA74A8952ED01B5CAE047D085882885D6A0D';

/// The number of rows in [table].
int _count(LanlinkDatabase db, String table) =>
    db.selectAll('SELECT count(*) AS n FROM $table').first['n']! as int;

/// Lets queued broadcast events be delivered before assertions run.
Future<void> _flush() async {
  for (var index = 0; index < 8; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}
