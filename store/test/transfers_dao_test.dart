import 'package:lanlink_store/lanlink_store.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;
import 'package:test/test.dart';

import 'support/test_db.dart';

void main() {
  late LanlinkDatabase db;
  late TransfersDao dao;

  setUp(() {
    db = openTestDatabase();
    dao = TransfersDao(db);
    _seedConversation(db, 'conv-1');
    _seedMessage(db, 'MSG1');
    for (final id in <String>['FA', 'FB', 'FC', 'FD']) {
      _seedFile(db, id);
    }
  });

  tearDown(() => db.close());

  TransferRecord transfer({
    String id = 'T-a',
    String fileId = 'FA',
    String? sessionId,
    String? token,
    int bytesDone = 0,
    int bytesTotal = 100,
    int? chunkSize,
    int retryCount = 0,
    DateTime? nextAttemptAt,
    String? error,
    DateTime? updatedAt,
  }) =>
      TransferRecord(
        id: id,
        fileId: fileId,
        sessionId: sessionId,
        token: token,
        bytesDone: bytesDone,
        bytesTotal: bytesTotal,
        chunkSize: chunkSize,
        retryCount: retryCount,
        nextAttemptAt: nextAttemptAt,
        error: error,
        updatedAt: updatedAt ?? t0,
      );

  test('insert + byId round-trips every column', () {
    final record = transfer(
      sessionId: 'S',
      token: 'K',
      bytesDone: 40,
      bytesTotal: 100,
      chunkSize: 4096,
      retryCount: 2,
      nextAttemptAt: at(60),
      error: 'boom',
      updatedAt: at(5),
    );

    dao.insert(record);

    expect(dao.byId('T-a'), record);
  });

  test('round-trips a record whose optional columns are null', () {
    dao.insert(transfer(id: 'T-b', fileId: 'FB', bytesTotal: -1));

    final loaded = dao.byId('T-b')!;
    expect(loaded.sessionId, isNull);
    expect(loaded.token, isNull);
    expect(loaded.chunkSize, isNull);
    expect(loaded.nextAttemptAt, isNull);
    expect(loaded.error, isNull);
    expect(loaded.bytesTotal, -1);
  });

  test('byFileId finds the transfer or returns null', () {
    dao.insert(transfer());

    expect(dao.byFileId('FA')?.id, 'T-a');
    expect(dao.byFileId('nope'), isNull);
  });

  group('dueForRetry', () {
    setUp(() {
      dao.insert(transfer(id: 'T-a', fileId: 'FA', nextAttemptAt: at(10)));
      dao.insert(transfer(id: 'T-b', fileId: 'FB', nextAttemptAt: at(30)));
      dao.insert(transfer(id: 'T-c', fileId: 'FC'));
      dao.insert(transfer(id: 'T-d', fileId: 'FD', nextAttemptAt: at(20)));
    });

    test('returns only rows due at now, ordered by next_attempt_at', () {
      expect(
        dao.dueForRetry(now: at(25)).map((t) => t.id),
        <String>['T-a', 'T-d'],
      );
      expect(
        dao.dueForRetry(now: at(30)).map((t) => t.id),
        <String>['T-a', 'T-d', 'T-b'],
      );
      expect(dao.dueForRetry(now: at(5)), isEmpty);
    });

    test('the boundary is inclusive: next_attempt_at == now is due', () {
      expect(
        dao.dueForRetry(now: at(10)).map((t) => t.id),
        <String>['T-a'],
      );
    });

    test('honours limit', () {
      expect(
        dao.dueForRetry(now: at(30), limit: 2).map((t) => t.id),
        <String>['T-a', 'T-d'],
      );
    });
  });

  test('updateProgress writes bytes_done and updated_at', () {
    dao.insert(transfer());

    dao.updateProgress(id: 'T-a', bytesDone: 40, now: at(5));

    final loaded = dao.byId('T-a')!;
    expect(loaded.bytesDone, 40);
    expect(loaded.updatedAt, at(5));
  });

  test('attachSession records the attempt session and token', () {
    dao.insert(transfer());

    dao.attachSession(id: 'T-a', sessionId: 'S', token: 'K', now: at(5));

    final loaded = dao.byId('T-a')!;
    expect(loaded.sessionId, 'S');
    expect(loaded.token, 'K');
    expect(loaded.updatedAt, at(5));
  });

  test('markDone sets bytes_done = bytes_total and clears the schedule', () {
    dao.insert(transfer(bytesTotal: 100, nextAttemptAt: at(10)));

    dao.markDone(id: 'T-a', now: at(5));

    final loaded = dao.byId('T-a')!;
    expect(loaded.bytesDone, 100);
    expect(loaded.nextAttemptAt, isNull);
    expect(loaded.updatedAt, at(5));
  });

  test('markFailed increments retry_count and schedules the next attempt', () {
    dao.insert(transfer());
    dao.updateProgress(id: 'T-a', bytesDone: 40, now: at(2));

    dao.markFailed(id: 'T-a', error: 'boom', nextAttemptAt: at(60), now: at(5));

    final loaded = dao.byId('T-a')!;
    expect(loaded.retryCount, 1);
    expect(loaded.error, 'boom');
    expect(loaded.nextAttemptAt, at(60));
    expect(loaded.updatedAt, at(5));
    // bytes_done counts the bytes of the *current* attempt and is never carried
    // forward as an offset (spec §5.9): the failed attempt's value is retained
    // until the next attempt begins.
    expect(loaded.bytesDone, 40);
  });

  test('markFailed with a null nextAttemptAt clears the schedule', () {
    dao.insert(transfer(nextAttemptAt: at(10)));

    dao.markFailed(id: 'T-a', error: 'x', nextAttemptAt: null, now: at(5));

    final loaded = dao.byId('T-a')!;
    expect(loaded.retryCount, 1);
    expect(loaded.nextAttemptAt, isNull);
  });

  test('rejects a transfer whose file does not exist', () {
    expect(
      () => dao.insert(transfer(id: 'T-x', fileId: 'missing')),
      throwsA(isA<SqliteException>()),
    );
  });

  test('deleting the file cascades to its transfer', () {
    dao.insert(transfer());

    db.execute('DELETE FROM files WHERE id = ?', <Object?>['FA']);

    expect(dao.byId('T-a'), isNull);
  });
}

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

/// Inserts a minimal valid `files` row owned by `MSG1`.
void _seedFile(LanlinkDatabase db, String id) {
  db.execute(
    'INSERT INTO files (id, message_id, file_name, size) VALUES (?, ?, ?, ?)',
    <Object?>[id, 'MSG1', 'f-$id', 0],
  );
}
