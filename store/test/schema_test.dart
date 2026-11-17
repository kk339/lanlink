import 'dart:io';

import 'package:lanlink_store/lanlink_store.dart';
import 'package:test/test.dart';

import 'support/test_db.dart';

void main() {
  late LanlinkDatabase db;

  setUp(() {
    db = openTestDatabase();
  });

  tearDown(() {
    db.close();
  });

  test('creates the five tables', () {
    final names = db
        .selectAll("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name'] as String)
        .toSet();
    for (final table in kSchemaV1Tables) {
      expect(names, contains(table), reason: 'missing table $table');
    }
  });

  test('creates every index', () {
    final names = db
        .selectAll("SELECT name FROM sqlite_master WHERE type = 'index'")
        .map((row) => row['name'] as String)
        .toSet();
    for (final index in kSchemaV1Indexes) {
      expect(names, contains(index), reason: 'missing index $index');
    }
  });

  test('stamps user_version = kSchemaVersion', () {
    final version = db.selectAll('PRAGMA user_version').first['user_version'];
    expect(version, kSchemaVersion);
  });

  // docs/22 §6·T02 (c): a brand-new database goes 0 -> 2 in one open, and it
  // ends up with the v1 shape *plus* the three v2 columns — not with a shape of
  // its own. The point of running the same migration list for a fresh file is
  // that a fresh install and an upgraded install are byte-for-byte the same
  // schema; if they ever diverge, bugs appear only on one of the two.
  test('a fresh database lands at v2 with the v1 shape plus three columns', () {
    expect(
      db.selectAll('PRAGMA user_version').first['user_version'],
      2,
    );

    final tables = db
        .selectAll("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name'] as String)
        .toSet();
    expect(tables, containsAll(kSchemaV1Tables));

    final indexes = db
        .selectAll("SELECT name FROM sqlite_master WHERE type = 'index'")
        .map((row) => row['name'] as String)
        .toSet();
    expect(indexes, containsAll(kSchemaV1Indexes));

    expect(_column(db, 'messages', 'folder_name'), 'TEXT');
    expect(_column(db, 'messages', 'folder_files'), 'INTEGER');
    expect(_column(db, 'files', 'relative_path'), 'TEXT');
  });

  // docs/22 §2.2 / R13: every v2 column MUST be nullable and MUST NOT carry a
  // DEFAULT. `notnull` is what `ADD COLUMN` chokes on for the rows that already
  // exist; asserting it on the created table keeps the two paths (fresh and
  // migrated) honest about the same promise.
  test('the v2 columns are nullable and have no default', () {
    for (final column in <(String, String)>[
      ('messages', 'folder_name'),
      ('messages', 'folder_files'),
      ('files', 'relative_path'),
    ]) {
      final row = db
          .selectAll('PRAGMA table_info(${column.$1})')
          .firstWhere((info) => info['name'] == column.$2);
      expect(row['notnull'], 0, reason: '${column.$1}.${column.$2} is nullable');
      expect(row['dflt_value'], isNull,
          reason: '${column.$1}.${column.$2} has no DEFAULT');
    }
  });

  test('enables foreign key enforcement', () {
    final on = db.selectAll('PRAGMA foreign_keys').first['foreign_keys'];
    expect(on, 1);
  });

  test('re-applying migrations on an open database is a no-op', () {
    expect(() => applyMigrations(db.raw), returnsNormally);
    final version = db.selectAll('PRAGMA user_version').first['user_version'];
    expect(version, kSchemaVersion);
  });

  test('reopening a file database is idempotent', () {
    final dir = Directory.systemTemp.createTempSync('lanlink_store_schema_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}lanlink.db';

    final first = LanlinkDatabase.openFile(path);
    final tablesBefore = _tableNames(first);
    first.close();

    final second = LanlinkDatabase.openFile(path);
    addTearDown(second.close);
    expect(_tableNames(second), tablesBefore);
    expect(second.selectAll('PRAGMA user_version').first['user_version'],
        kSchemaVersion);
  });
  // 0.2.51 (multi-select aggregation on the receiving side) introduced **no**
  // schema change: no new column, no new table, no `user_version` bump. That is
  // not a comment, it is the compatibility contract — a 0.2.50 binary knows only
  // `kSchemaVersion == 2` and refuses anything **newer** (`migrations.dart`), so
  // a database written by this build must stay at v2 and stay column-identical,
  // or an older install would fail to open the file. The lists below are exact
  // on purpose: adding a column makes this test fail by name, which is cheaper
  // than discovering it on a user's machine.
  test('0.2.51 adds no column: messages/files are exactly the v2 shape', () {
    expect(kSchemaVersion, 2);
    expect(
      _columns(db, 'messages')..sort(),
      <String>[
        'conversation_id',
        'created_at',
        'direction',
        'event_nonce',
        'folder_files',
        'folder_name',
        'id',
        'kind',
        'status',
        'text_body',
        'updated_at',
      ],
    );
    expect(
      _columns(db, 'files')..sort(),
      <String>[
        'file_name',
        'id',
        'local_path',
        'message_id',
        'mime',
        'relative_path',
        'sha256',
        'size',
        'thumbnail_path',
      ],
    );
  });
}

/// The declared type of `table.column`, or `null` when the column is missing.
String? _column(LanlinkDatabase db, String table, String column) {
  for (final row in db.selectAll('PRAGMA table_info($table)')) {
    if (row['name'] == column) {
      return row['type'] as String?;
    }
  }
  return null;
}

/// The column names of [table], in declaration order.
List<String> _columns(LanlinkDatabase db, String table) => db
    .selectAll('PRAGMA table_info($table)')
    .map((row) => row['name'] as String)
    .toList();

/// The user tables currently present in [db].
Set<String> _tableNames(LanlinkDatabase db) => db
    .selectAll("SELECT name FROM sqlite_master WHERE type = 'table'")
    .map((row) => row['name'] as String)
    .toSet();
