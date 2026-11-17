/// Connection wrapper: opening, the per-connection PRAGMAs, transactions and
/// the row <-> map helpers used by the DAOs.
///
/// The API is deliberately **synchronous** (spec §9.2): `package:sqlite3` 2.x
/// is itself a synchronous API, and this project's data volume makes any
/// blocking concern moot. If M4 ever moves the database into a background
/// isolate, the whole package moves and this contract stays the same.
library;

import 'package:sqlite3/sqlite3.dart';

import '../errors/store_errors.dart';
import '../schema/migrations.dart';
import 'sqlite_bootstrap.dart';

/// The filename used for private in-memory databases.
const String _memoryPath = ':memory:';

/// A thin wrapper around a native [Database] handle.
///
/// Opening sets `foreign_keys` on, turns on `WAL` for on-disk databases and
/// applies migrations, so a freshly constructed [LanlinkDatabase] is always
/// ready for the v1 schema. `synchronous` is left at SQLite's default `FULL`
/// on purpose — see [_configure].
class LanlinkDatabase {
  LanlinkDatabase._(this._db, this.path);

  /// Opens (creating if necessary) the on-disk database at [path].
  factory LanlinkDatabase.openFile(String path) {
    configureSqlite();
    return LanlinkDatabase._(sqlite3.open(path), path).._configure();
  }

  /// Opens a private in-memory database (used by tests).
  factory LanlinkDatabase.openInMemory() {
    configureSqlite();
    return LanlinkDatabase._(sqlite3.openInMemory(), _memoryPath).._configure();
  }

  final Database _db;

  /// The path this connection was opened with (`:memory:` for in-memory).
  final String path;

  bool _closed = false;

  void _configure() {
    _db.execute('PRAGMA foreign_keys = ON');
    if (path != _memoryPath) {
      _db.execute('PRAGMA journal_mode = WAL');
    }
    // `synchronous` is deliberately left at SQLite's default `FULL`.
    //
    // Dropping it to `NORMAL` would make the upload path's progress writes ~11x
    // cheaper (measured: 256 writes 104 ms -> 9 ms, 94% of it fsync), i.e. ~0.5%
    // of a desktop transfer and 1.4-4.1% on a phone. That is not worth the
    // durability change: with `NORMAL` a power cut can lose the last commits,
    // which here includes a message row for a file that has already been sent.
    // The write *count* is what the orchestrator throttles instead.
    applyMigrations(_db);
  }

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  /// The raw handle, for the rare escape hatch (e.g. `prepare`).
  Database get raw {
    _ensureOpen();
    return _db;
  }

  /// Runs a statement, ignoring any rows it returns.
  void execute(String sql, [List<Object?> parameters = const <Object?>[]]) {
    _ensureOpen();
    _db.execute(sql, parameters);
  }

  /// Runs a query and returns every row as a column-name -> value map.
  List<Map<String, Object?>> selectAll(
    String sql, [
    List<Object?> parameters = const <Object?>[],
  ]) {
    _ensureOpen();
    return <Map<String, Object?>>[
      for (final row in _db.select(sql, parameters)) _rowToMap(row),
    ];
  }

  /// Runs a query and returns the first row as a map, or `null` when empty.
  Map<String, Object?>? selectOne(
    String sql, [
    List<Object?> parameters = const <Object?>[],
  ]) {
    _ensureOpen();
    final result = _db.select(sql, parameters);
    if (result.isEmpty) {
      return null;
    }
    return _rowToMap(result.first);
  }

  /// Rows inserted, updated or deleted by the last write statement.
  int get updatedRows {
    _ensureOpen();
    return _db.updatedRows;
  }

  /// Runs [action] inside a `BEGIN`/`COMMIT`, rolling back on any error.
  ///
  /// Nesting is **not** supported: the `SessionStore` facade is the only place
  /// that opens a transaction (spec §5.4), and the DAOs it calls must not open
  /// their own.
  T transaction<T>(T Function() action) {
    _ensureOpen();
    _db.execute('BEGIN');
    try {
      final result = action();
      _db.execute('COMMIT');
      return result;
    } on Object {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Disposes the underlying connection. Idempotent.
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _db.dispose();
  }

  void _ensureOpen() {
    if (_closed) {
      throw StoreClosedException();
    }
  }
}

/// Converts a result [Row] into a plain `column -> value` map.
Map<String, Object?> _rowToMap(Row row) =>
    <String, Object?>{for (final key in row.keys) key: row[key]};
