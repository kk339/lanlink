import 'package:lanlink_store/lanlink_store.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;
import 'package:test/test.dart';

import 'support/test_db.dart';

void main() {
  late LanlinkDatabase db;
  late FilesDao dao;

  setUp(() {
    db = openTestDatabase();
    dao = FilesDao(db);
    _seedConversation(db, 'conv-1');
    _seedMessage(db, 'MSG1');
    _seedMessage(db, 'MSG2');
  });

  tearDown(() => db.close());

  test('insert + byId round-trips every column', () {
    const file = MessageFileRecord(
      id: 'F1',
      messageId: 'MSG1',
      fileName: 'report.pdf',
      size: 42,
      mime: 'application/pdf',
      sha256: 'ABC',
      localPath: '/tmp/report.pdf',
      thumbnailPath: '/tmp/report.png',
    );

    dao.insert(file);

    expect(dao.byId('F1'), file);
  });

  test('round-trips a record whose optional columns are null', () {
    const file = MessageFileRecord(
      id: 'F2',
      messageId: 'MSG1',
      fileName: 'x',
      size: -1,
    );

    dao.insert(file);

    final loaded = dao.byId('F2')!;
    expect(loaded.size, -1);
    expect(loaded.mime, isNull);
    expect(loaded.sha256, isNull);
    expect(loaded.localPath, isNull);
    expect(loaded.thumbnailPath, isNull);
    expect(loaded, file);
  });

  test('byId returns null for a missing row', () {
    expect(dao.byId('nope'), isNull);
  });

  test("forMessage returns only that message's files, in insertion order", () {
    dao.insert(const MessageFileRecord(
        id: 'A', messageId: 'MSG1', fileName: 'a', size: 1));
    dao.insert(const MessageFileRecord(
        id: 'B', messageId: 'MSG2', fileName: 'b', size: 2));
    dao.insert(const MessageFileRecord(
        id: 'C', messageId: 'MSG1', fileName: 'c', size: 3));

    expect(dao.forMessage('MSG1').map((f) => f.id), <String>['A', 'C']);
    expect(dao.forMessage('MSG2').map((f) => f.id), <String>['B']);
    expect(dao.forMessage('MSG-other'), isEmpty);
  });

  test('rejects a file whose message does not exist', () {
    expect(
      () => dao.insert(const MessageFileRecord(
          id: 'X', messageId: 'missing', fileName: 'x', size: 0)),
      throwsA(isA<SqliteException>()),
    );
  });

  test('deleting the message cascades to its files', () {
    dao.insert(const MessageFileRecord(
        id: 'A', messageId: 'MSG1', fileName: 'a', size: 1));

    db.execute('DELETE FROM messages WHERE id = ?', <Object?>['MSG1']);

    expect(dao.byId('A'), isNull);
  });

  // docs/22 §6·T02 (g) / §4.2 step 3. The receive path calls this once per
  // arriving file of a folder session, and a re-delivery of a file that already
  // landed is a **normal shape of the input**, not a bug — so the second call
  // must neither throw (which would roll back the whole arrival) nor touch the
  // stored row.
  group('insertIfAbsent', () {
    test('inserting the same id twice does not throw and reports false', () {
      const file = MessageFileRecord(
        id: 'F1',
        messageId: 'MSG1',
        fileName: 'a.dll',
        size: 10,
        localPath: '/tmp/a.dll',
        relativePath: 'data/a.dll',
      );

      final first = dao.insertIfAbsent(file);
      final second = dao.insertIfAbsent(file);

      expect(first, (id: 'F1', created: true));
      expect(second, (id: 'F1', created: false));
      expect(_count(db, 'files'), 1);
      // The stored row is the *first* arrival, untouched by the replay.
      expect(dao.byId('F1'), file);
    });

    test('a re-delivery with different bytes keeps the first row', () {
      dao.insertIfAbsent(const MessageFileRecord(
          id: 'F2', messageId: 'MSG1', fileName: 'b.dll', size: 10));
      final replay = dao.insertIfAbsent(const MessageFileRecord(
          id: 'F2', messageId: 'MSG1', fileName: 'b (1).dll', size: 99));

      expect(replay.created, isFalse);
      expect(dao.byId('F2')!.fileName, 'b.dll');
      expect(dao.byId('F2')!.size, 10);
    });

    test('different ids for one message both land', () {
      expect(
        dao.insertIfAbsent(const MessageFileRecord(
                id: 'F3', messageId: 'MSG1', fileName: 'c', size: 1))
            .created,
        isTrue,
      );
      expect(
        dao.insertIfAbsent(const MessageFileRecord(
                id: 'F4', messageId: 'MSG1', fileName: 'd', size: 2))
            .created,
        isTrue,
      );
      expect(dao.forMessage('MSG1').map((file) => file.id), <String>['F3', 'F4']);
    });

    // `INSERT OR IGNORE` suppresses UNIQUE / NOT NULL / CHECK conflicts, but a
    // foreign-key violation is still an error — and it must stay one: silently
    // dropping a file whose message does not exist would lose the attachment.
    test('still rejects a file whose message does not exist', () {
      expect(
        () => dao.insertIfAbsent(const MessageFileRecord(
            id: 'X', messageId: 'missing', fileName: 'x', size: 0)),
        throwsA(isA<SqliteException>()),
      );
    });
  });

  // docs/22 §2.3: `files.relative_path` is the file's level inside its folder
  // message, relative to the folder root and `/`-separated, `NULL` when flat.
  test('round-trips relative_path, and leaves it null when flat', () {
    dao.insert(const MessageFileRecord(
      id: 'N1',
      messageId: 'MSG1',
      fileName: 'a.bin',
      size: 1,
      relativePath: 'sub/a.bin',
    ));
    dao.insert(const MessageFileRecord(
      id: 'N2',
      messageId: 'MSG1',
      fileName: 'b.bin',
      size: 1,
    ));

    expect(dao.byId('N1')!.relativePath, 'sub/a.bin');
    // Flat is `NULL`, never `''` — `relativePath != null` is the "has a level"
    // test on both ends.
    expect(dao.byId('N2')!.relativePath, isNull);
  });
}

/// The number of rows in [table].
int _count(LanlinkDatabase db, String table) =>
    db.selectAll('SELECT count(*) AS n FROM $table').first['n']! as int;

/// Inserts a bare `conversations` row (history-only: no device).
void _seedConversation(LanlinkDatabase db, String id) {
  db.execute(
    'INSERT INTO conversations (id, created_at) VALUES (?, ?)',
    <Object?>[id, toEpochMillis(t0)],
  );
}

/// Inserts a minimal valid `messages` row owned by `conv-1`.
void _seedMessage(LanlinkDatabase db, String id) {
  db.execute(
    'INSERT INTO messages '
    '(id, conversation_id, direction, kind, created_at, updated_at, status, '
    'event_nonce) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
    <Object?>[
      id,
      'conv-1',
      'out',
      'file',
      toEpochMillis(t0),
      toEpochMillis(t0),
      'pending',
      'nonce-$id',
    ],
  );
}
