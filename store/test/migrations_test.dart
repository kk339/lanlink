// Migration tests, with an emphasis on the one thing a test suite usually gets
// wrong: **the old database must be real**.
//
// `openInMemory()` starts from an empty schema, so it can only ever prove that
// `CREATE TABLE` runs. It cannot prove that a migration keeps the rows that
// were already there — the failure mode this milestone actively risks is
// "upgrade erased every attachment", and an empty database has no attachments
// to lose. So every upgrade test below writes a **v1 database to a temp file**,
// inserts rows through the v1 shape, closes the handle, and only then opens it
// with the current build (docs/22 §10 判据 19).

import 'dart:io';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:lanlink_store/lanlink_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/test_db.dart';

void main() {
  test('migrates a fresh database from v0 to the current version', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);

    expect(db.userVersion, 0);

    applyMigrations(db);

    expect(db.userVersion, kSchemaVersion);
    expect(kSchemaVersion, 2);

    final tables = db
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name'] as String)
        .toSet();
    expect(tables, containsAll(kSchemaV1Tables));
  });

  test('refuses a database from the future', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);

    db.userVersion = 999;

    expect(() => applyMigrations(db), throwsA(isA<MigrationException>()));
    // The refused migration must not have touched the schema.
    final tables = db
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name'] as String)
        .toSet();
    expect(tables, isEmpty);
  });

  test('is a no-op when already at the current version', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);

    applyMigrations(db);
    expect(() => applyMigrations(db), returnsNormally);
    expect(db.userVersion, kSchemaVersion);
  });

  // 0.2.51 — the receiving-side batch aggregation added **no DDL**, and this is
  // the executable half of "an older install can still open a database this build
  // wrote". A claim in a comment is not evidence: a real file is written through
  // the NEW code path (one message aggregated from two sessions' worth of `put`s),
  // then opened the way an older build opens it — the only place a version is
  // refused or upgraded is [applyMigrations], so that call *is* the old build's
  // decision. It must short-circuit: same `user_version`, byte-identical
  // `sqlite_master`, no exception, and the new rows still readable.
  test('a database written by the 0.2.51 batch path opens as plain v2', () {
    final path = _tempDbPath('lanlink_migrate_batch_');

    // (a) write it through the real store, using the new aggregation method.
    final writer = LanlinkDatabase.openFile(path);
    final store = SessionStore(db: writer, ids: SequentialIdGenerator());
    for (final (index, id) in <String>['b1', 'b2'].indexed) {
      store.recordIncomingSessionFile(
        sender: const DeviceInfo(
          alias: 'peer',
          fingerprint: 'BATCHFP',
          port: 53317,
        ),
        file: IncomingFileSpec(
          fileId: id,
          fileName: '$id.bin',
          size: 4,
          sha256: 'AA',
          savedPath: '/tmp/$id.bin',
        ),
        sessionId: 'BATCH-1',
        now: at(index),
      );
    }
    expect(store.history(store.conversations().single.id), hasLength(1));
    store.close();

    // (b) the old build's decision: version 2 is what it understands.
    configureSqlite();
    final db = sqlite3.open(path);
    addTearDown(db.dispose);
    expect(db.userVersion, kSchemaVersion);
    final before = _schemaSnapshot(db);
    expect(() => applyMigrations(db), returnsNormally,
        reason: 'a newer build must never leave a database that raises '
            'MigrationException when an older one opens it');
    expect(db.userVersion, kSchemaVersion);
    expect(_schemaSnapshot(db), before,
        reason: 'the migration runner must not rewrite the schema of a database '
            'that is already at the version it knows');

    // (c) …and the aggregated row is exactly one message with two attachments,
    // with the folder columns NULL — so an older UI renders it as an ordinary
    // multi-attachment bubble, and nothing new has to be understood.
    final List<Row> messages = db.select('SELECT * FROM messages');
    expect(messages, hasLength(1));
    expect(messages.single['folder_name'], isNull);
    expect(messages.single['folder_files'], isNull);
    expect(db.select('SELECT * FROM files'), hasLength(2));
  });

  // ── v1 -> v2, on a real file ─────────────────────────────────────────────

  test('upgrades a real v1 file to v2 and keeps the 1 message / 2 files', () {
    final path = _tempDbPath('lanlink_migrate_small_');
    final seeded = _seedV1Database(path);

    final db = LanlinkDatabase.openFile(path);
    addTearDown(db.close);

    // (a) the version stamp and the three new columns.
    expect(db.selectAll('PRAGMA user_version').first['user_version'], 2);
    expect(
      db.selectAll('PRAGMA table_info(messages)').map((row) => row['name']),
      containsAll(<String>['folder_name', 'folder_files']),
    );
    expect(
      db.selectAll('PRAGMA table_info(files)').map((row) => row['name']),
      contains('relative_path'),
    );

    // (a) ...and the rows that were already there are still there. `files` is
    // the one that a table rebuild would have cascaded away: 2 before, 2 after.
    expect(_count(db, 'files'), seeded['files']);
    expect(_count(db, 'messages'), seeded['messages']);
    expect(seeded['files'], 2);
    expect(seeded['messages'], 1);

    // (a) the pre-migration rows are untouched, and the new columns are NULL
    // for them — which is exactly what makes old history render as before.
    final files = db.selectAll('SELECT * FROM files ORDER BY rowid ASC');
    final expected = _expectedV1Files(1, 2);
    expect(
      files.map((row) => row['file_name']).toList(),
      expected.map((file) => file.fileName).toList(),
    );
    expect(
      files.map((row) => row['local_path']).toList(),
      expected.map((file) => file.localPath).toList(),
    );
    for (final row in files) {
      expect(row['relative_path'], isNull);
    }
    final message = db.selectAll('SELECT * FROM messages').single;
    expect(message['folder_name'], isNull);
    expect(message['folder_files'], isNull);
    expect(message['kind'], 'file');

    // (a) the database is structurally sound after the ALTERs.
    expect(
      db.selectAll('PRAGMA integrity_check').first['integrity_check'],
      'ok',
    );

    // (b) foreign keys are still enforced, and no row violates a reference.
    expect(db.selectAll('PRAGMA foreign_keys').first['foreign_keys'], 1);
    expect(db.selectAll('PRAGMA foreign_key_check'), isEmpty);
  });

  test('a v1 file with many rows keeps every sampled row identical', () {
    final path = _tempDbPath('lanlink_migrate_bulk_');
    // 3 messages × 4 files = 12 attachments: enough to sample 5 and to make a
    // "cascade wiped the table" regression impossible to miss.
    final seeded = _seedV1Database(path, messages: 3, filesPerMessage: 4);

    final db = LanlinkDatabase.openFile(path);
    addTearDown(db.close);

    expect(db.selectAll('PRAGMA user_version').first['user_version'], 2);
    expect(_count(db, 'messages'), seeded['messages']);
    expect(_count(db, 'files'), seeded['files']);
    expect(seeded['files'], 12);

    final rows = db.selectAll(
      'SELECT file_name, local_path FROM files ORDER BY rowid ASC',
    );
    expect(rows, hasLength(12));

    // The expected values are reproduced from the same generator the seeding
    // used, so "identical" is checked against the v1 content, not against
    // whatever the migration left behind.
    final expected = _expectedV1Files(3, 4);
    for (var index = 0; index < rows.length; index++) {
      expect(rows[index]['file_name'], expected[index].fileName);
      expect(rows[index]['local_path'], expected[index].localPath);
    }

    // A 5-row sample of the same data (deterministic stride so the test is
    // reproducible), asserted field by field.
    const sampleIndexes = <int>[0, 3, 5, 8, 11];
    for (final index in sampleIndexes) {
      expect(rows[index]['file_name'], expected[index].fileName);
      expect(rows[index]['local_path'], expected[index].localPath);
    }

    expect(
      db.selectAll('PRAGMA integrity_check').first['integrity_check'],
      'ok',
    );
    expect(db.selectAll('PRAGMA foreign_keys').first['foreign_keys'], 1);
    expect(db.selectAll('PRAGMA foreign_key_check'), isEmpty);
  });

  test('the v2 step is exactly three nullable ADD COLUMNs', () {
    // Guards the two rules of docs/22 §2.2 at the source level, so a future
    // edit cannot quietly reintroduce either disaster:
    //  * a rebuild (`DROP TABLE`) would cascade every `files` row away;
    //  * `ADD COLUMN ... NOT NULL` without a DEFAULT fails the statement on a
    //    non-empty table, which rolls the step back and leaves the app unable
    //    to open its database at all.
    expect(kSchemaV2Statements, hasLength(3));
    for (final statement in kSchemaV2Statements) {
      final upper = statement.toUpperCase();
      expect(upper, startsWith('ALTER TABLE'));
      expect(upper, contains('ADD COLUMN'));
      expect(upper, isNot(contains('DROP')));
      expect(upper, isNot(contains('NOT NULL')));
      expect(upper, isNot(contains('DEFAULT')));
    }
  });
}

/// One seeded attachment, remembered so the assertions can compare against it.
class _V1File {
  const _V1File(this.fileName, this.localPath);

  final String fileName;
  final String localPath;
}

/// The attachments [seedV1Database] writes, in insert order.
List<_V1File> _expectedV1Files(int messages, int filesPerMessage) {
  final files = <_V1File>[];
  for (var message = 0; message < messages; message++) {
    for (var file = 0; file < filesPerMessage; file++) {
      final name = 'file-$message-$file.dll';
      files.add(_V1File(name, '/home/kk/.local/share/lanlink/files/$name'));
    }
  }
  return files;
}

/// Creates a temp directory with a database path inside it.
String _tempDbPath(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });
  return '${dir.path}${Platform.pathSeparator}lanlink.db';
}

/// Writes a **v1** database to [path] and returns its row counts.
///
/// "v1" means: exactly `kSchemaV1Statements` (the DDL the previous release
/// shipped, which this milestone is forbidden to edit), `user_version = 1`, and
/// rows inserted through that shape — the same thing a 0.2.37 installation has
/// on disk. `foreign_keys` is switched on first, as
/// `LanlinkDatabase._configure` does on every connection, so the seeding runs
/// under the same enforcement the migration will run under.
Map<String, int> _seedV1Database(
  String path, {
  int messages = 1,
  int filesPerMessage = 2,
}) {
  configureSqlite();
  final db = sqlite3.open(path);
  try {
    db.execute('PRAGMA foreign_keys = ON');
    for (final statement in kSchemaV1Statements) {
      db.execute(statement);
    }
    db.userVersion = 1;

    db.execute(
      'INSERT INTO devices (fingerprint, alias) VALUES (?, ?)',
      <Object?>['V1FINGERPRINT', 'old-peer'],
    );
    db.execute(
      'INSERT INTO conversations (id, device_fingerprint, created_at) '
      'VALUES (?, ?, ?)',
      <Object?>['conv-v1', 'V1FINGERPRINT', toEpochMillis(t0)],
    );

    final files = _expectedV1Files(messages, filesPerMessage);
    var fileIndex = 0;
    for (var message = 0; message < messages; message++) {
      final messageId = 'MSG-V1-$message';
      db.execute(
        'INSERT INTO messages '
        '(id, conversation_id, direction, kind, created_at, updated_at, '
        'status, event_nonce) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          messageId,
          'conv-v1',
          'in',
          'file',
          toEpochMillis(at(message)),
          toEpochMillis(at(message)),
          'done',
          'nonce-v1-$message',
        ],
      );
      for (var file = 0; file < filesPerMessage; file++) {
        final seeded = files[fileIndex++];
        final fileId = 'FILE-V1-$message-$file';
        db.execute(
          'INSERT INTO files '
          '(id, message_id, file_name, size, mime, sha256, local_path) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            fileId,
            messageId,
            seeded.fileName,
            1024 + file,
            null,
            'SHA$file',
            seeded.localPath,
          ],
        );
        db.execute(
          'INSERT INTO transfers '
          '(id, file_id, bytes_done, bytes_total, updated_at) '
          'VALUES (?, ?, ?, ?, ?)',
          <Object?>[
            'T-V1-$message-$file',
            fileId,
            1024 + file,
            1024 + file,
            toEpochMillis(at(message)),
          ],
        );
      }
    }
    return <String, int>{
      'messages': messages,
      'files': files.length,
    };
  } finally {
    // Closing the handle flushes the journal; the file is a complete v1
    // database on disk after this point.
    db.dispose();
  }
}

/// The number of rows in [table].
int _count(LanlinkDatabase db, String table) =>
    db.selectAll('SELECT count(*) AS n FROM $table').first['n']! as int;

/// Everything about the schema that a future open must not change: every table,
/// index and trigger with its DDL, sorted so the comparison is order-free.
String _schemaSnapshot(Database db) => db
    .select("SELECT type, name, COALESCE(sql, '') AS sql FROM sqlite_master "
        'ORDER BY type, name')
    .map((row) => '${row['type']}:${row['name']}:${row['sql']}')
    .join('\n');
