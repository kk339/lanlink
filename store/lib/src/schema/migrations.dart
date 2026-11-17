/// `PRAGMA user_version` based migration runner.
///
/// Each migration is keyed by the version it installs. Opening a database reads
/// the stored version and steps forward one migration at a time, so a database
/// created by an older build picks up every later change. A database from the
/// **future** (a higher `user_version` than this build knows) is refused rather
/// than silently downgraded.
library;

import 'package:sqlite3/sqlite3.dart';

import '../errors/store_errors.dart';
import 'schema.dart';

/// Migrations keyed by the version they install.
///
/// Forward-only: a key is **added**, never edited. Rewriting a published step
/// (e.g. redefining what "v1" creates) would make an old database and a fresh
/// one end up with different shapes while both claim the same version
/// (docs/22 §7).
const Map<int, List<String>> _migrations = <int, List<String>>{
  1: kSchemaV1Statements,
  // v2 = three nullable ADD COLUMNs (docs/22 §2.2). It runs inside the same
  // per-step transaction as every other step, so a failure here rolls back the
  // three statements *and* leaves user_version at 1 — the database stays
  // readable by the old build instead of being half-migrated.
  2: kSchemaV2Statements,
};

/// Brings [db] up to [kSchemaVersion].
///
/// Runs on a raw handle so it can also be exercised directly by tests. Throws a
/// [MigrationException] when the stored version is newer than supported, when a
/// step has no registered migration, or when a step's statements fail (the step
/// is rolled back first).
void applyMigrations(Database db) {
  final current = db.userVersion;
  if (current > kSchemaVersion) {
    throw MigrationException(
      'database user_version=$current is newer than this build supports '
      '(kSchemaVersion=$kSchemaVersion); refusing to open',
    );
  }
  if (current == kSchemaVersion) {
    return;
  }
  for (var target = current + 1; target <= kSchemaVersion; target++) {
    final statements = _migrations[target];
    if (statements == null) {
      throw MigrationException('no migration registered for version $target');
    }
    _runStep(db, target, statements);
  }
}

/// Applies one migration step inside a transaction, stamping the new version.
void _runStep(Database db, int target, List<String> statements) {
  db.execute('BEGIN');
  try {
    for (final statement in statements) {
      db.execute(statement);
    }
    db.userVersion = target;
    db.execute('COMMIT');
  } on Object catch (error) {
    try {
      db.execute('ROLLBACK');
    } on Object {
      // Rollback can fail if the transaction already aborted; the original
      // error is the one worth surfacing, so swallow this one.
    }
    throw MigrationException('migration to version $target failed: $error');
  }
}
