/// `SessionStore.deleteMessage` — the local half of 0.2.36's 右键气泡删除.
///
/// Three things are being pinned down here, and each of them is a way the
/// feature could be wrong without any test noticing a difference on screen:
///
/// * **the whole sub-tree goes** — `messages` **and** its `files` **and** their
///   `transfers`. The schema declares `ON DELETE CASCADE` on both edges and the
///   connection turns `foreign_keys` on, so a bare `DELETE FROM messages` would
///   *also* work; but a cascade is invisible in code, and an implementation that
///   relied on it would leave orphan rows the moment the pragma changed. The
///   row counts are asserted per table for that reason;
/// * **it is durable** — a *second* store opened on the same file must not see
///   the message either. "Gone until you restart" is the class of bug this whole
///   project keeps removing;
/// * **the bytes on disk are untouched** — a received file is still there after
///   its bubble is deleted. Deleting a message is a statement about the
///   *conversation record*, not about the user's file.
library;

import 'dart:io';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:lanlink_store/lanlink_store.dart';
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
    if (!db.isClosed) {
      store.close();
    }
  });

  /// The number of rows in [table], read through the store's own connection.
  int count(String table) =>
      db.selectAll('SELECT count(*) AS n FROM $table').first['n']! as int;

  group('deleteMessage', () {
    test('removes the message, its files and their transfers in one go', () {
      final result = store.recordOutgoingFiles(
        peer: const DeviceInfo(alias: 'Peer', fingerprint: 'FP1', port: 53317),
        files: <OutgoingFileSpec>[
          _outgoing('f1'),
          _outgoing('f2', fileName: 'b.txt'),
        ],
        now: t0,
      );

      expect(count('messages'), 1);
      expect(count('files'), 2);
      expect(count('transfers'), 2);

      expect(store.deleteMessage(messageId: result.messageId), isTrue);

      expect(count('messages'), 0, reason: 'the message row must be gone');
      expect(count('files'), 0,
          reason: 'a deleted message may not leave orphaned files rows');
      expect(count('transfers'), 0,
          reason: 'a deleted message may not leave orphaned transfers rows');
      // The conversation and the device are **not** part of the delete: the
      // thread is still there, one bubble lighter.
      expect(count('conversations'), 1);
      expect(count('devices'), 1);

      expect(store.history(result.conversationId), isEmpty);
      expect(store.filesOf(result.messageId), isEmpty);
      expect(store.transferOf('f1'), isNull);
    });

    test('a second call is a no-op that answers false', () {
      final result = store.recordOutgoingFiles(
        peer: const DeviceInfo(alias: 'Peer', fingerprint: 'FP1', port: 53317),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        now: t0,
      );

      expect(store.deleteMessage(messageId: result.messageId), isTrue);
      expect(store.deleteMessage(messageId: result.messageId), isFalse,
          reason: 'deleting twice must not throw — a stale menu row can do it');
      expect(count('messages'), 0);
    });

    test('an unknown id answers false and touches nothing', () {
      store.recordOutgoingFiles(
        peer: const DeviceInfo(alias: 'Peer', fingerprint: 'FP1', port: 53317),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        now: t0,
      );

      expect(store.deleteMessage(messageId: 'never-existed'), isFalse);
      expect(count('messages'), 1);
      expect(count('files'), 1);
      expect(count('transfers'), 1);
    });

    test('deleting one message leaves its neighbour and that one\'s rows', () {
      final first = store.recordOutgoingFiles(
        peer: const DeviceInfo(alias: 'Peer', fingerprint: 'FP1', port: 53317),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        now: t0,
      );
      final second = store.recordOutgoingFiles(
        peer: const DeviceInfo(alias: 'Peer', fingerprint: 'FP1', port: 53317),
        files: <OutgoingFileSpec>[_outgoing('f2', fileName: 'b.txt')],
        now: at(1),
      );
      expect(first.messageId, isNot(second.messageId));

      expect(store.deleteMessage(messageId: first.messageId), isTrue);

      final remaining = store.history(first.conversationId);
      expect(remaining.map((m) => m.id), <String>[second.messageId]);
      expect(count('files'), 1);
      expect(count('transfers'), 1);
      expect(store.transferOf('f2'), isNotNull);
    });

    test('the file on disk is NOT deleted with the message', () {
      // A real file in a real temp directory: "the bubble is gone, the file is
      // still there" is a fact about the filesystem, not about a row.
      final Directory dir =
          Directory.systemTemp.createTempSync('lanlink-delete-test');
      addTearDown(() {
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      });
      final File received = File('${dir.path}${Platform.pathSeparator}x.bin')
        ..writeAsBytesSync(<int>[1, 2, 3, 4, 5]);
      expect(received.existsSync(), isTrue);

      final result = store.recordIncomingFile(
        sender: const DeviceInfo(
          alias: 'Peer',
          fingerprint: 'FP1',
          port: 53317,
        ),
        file: IncomingFileSpec(
          fileId: 'f-in',
          fileName: 'x.bin',
          size: 5,
          sha256: 'BB',
          savedPath: received.path,
        ),
        now: t0,
      );

      expect(store.filesOf(result.messageId).single.localPath, received.path);
      expect(store.deleteMessage(messageId: result.messageId), isTrue);

      expect(received.existsSync(), isTrue,
          reason: '删除的是会话记录，不是下载目录里的文件');
      expect(received.readAsBytesSync(), <int>[1, 2, 3, 4, 5]);
    });

    test('the deletion is durable — a fresh store on the same file agrees', () {
      final Directory dir =
          Directory.systemTemp.createTempSync('lanlink-delete-persist');
      final String path = '${dir.path}${Platform.pathSeparator}lanlink.db';
      addTearDown(() {
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      });

      // First run: record a text message, then delete it.
      final LanlinkDatabase firstDb = LanlinkDatabase.openFile(path);
      final SessionStore first = SessionStore(
        db: firstDb,
        ids: SequentialIdGenerator(),
      );
      late String conversationId;
      late String messageId;
      try {
        final result = first.recordOutgoingText(
          peer: const DeviceInfo(
            alias: 'Peer',
            fingerprint: 'FP1',
            port: 53317,
          ),
          text: 'hello',
          eventNonce: 'nonce-1',
          now: t0,
        );
        conversationId = result.conversationId;
        messageId = result.messageId;
        expect(first.history(conversationId), hasLength(1));
        expect(first.deleteMessage(messageId: messageId), isTrue);
        expect(first.history(conversationId), isEmpty);
      } finally {
        first.close();
      }

      // Second run: a brand-new connection, the same file — the message must not
      // be back. This is the "重启后不再出现" half of the criterion, and the only
      // way to prove it is to re-open.
      final LanlinkDatabase secondDb = LanlinkDatabase.openFile(path);
      addTearDown(secondDb.close);
      final SessionStore second = SessionStore(
        db: secondDb,
        ids: SequentialIdGenerator(),
      );
      expect(second.history(conversationId), isEmpty,
          reason: 'a deleted message must not come back after a restart');
      expect(second.messagesByStatus(<MessageStatus>{MessageStatus.pending}),
          isEmpty);
    });

    test('a closed store refuses, like every other facade method', () {
      final result = store.recordOutgoingFiles(
        peer: const DeviceInfo(alias: 'Peer', fingerprint: 'FP1', port: 53317),
        files: <OutgoingFileSpec>[_outgoing('f1')],
        now: t0,
      );
      store.close();
      expect(
        () => store.deleteMessage(messageId: result.messageId),
        throwsA(isA<StoreClosedException>()),
      );
    });
  });
}

/// A file to send.
OutgoingFileSpec _outgoing(
  String id, {
  String fileName = 'a.txt',
  int size = 9,
  String sha256 = 'AA',
}) =>
    OutgoingFileSpec(
      id: id,
      fileName: fileName,
      size: size,
      sha256: sha256,
      localPath: '/src/$fileName',
    );
