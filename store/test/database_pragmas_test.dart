/// Guards the connection pragmas an **on-disk** database is opened with.
///
/// Two decisions are pinned here, both from measurements taken on 2026-10-21:
///
/// * `journal_mode = WAL` — concurrent read + progress write stay cheap.
/// * `synchronous` stays at SQLite's **default `FULL` (2)**. Dropping it to
///   `NORMAL` was measured (256 progress writes: 104 ms -> 9 ms, 94% of it
///   fsync) but **rejected**: it buys ~0.5% of a desktop transfer and 1.4-4.1%
///   on a phone, at the cost of a power cut being able to drop the last commits
///   — which can include the row for a file that was already sent. The write
///   *count* is throttled in `TransferOrchestrator` instead, with no durability
///   change. This test is what stops someone re-adding the PRAGMA by accident.
///
/// The in-memory databases used by every other test skip this branch on purpose
/// (there is no journal to fsync), so this is the one test that opens a real
/// file.
library;

import 'dart:io';

import 'package:lanlink_store/lanlink_store.dart';
import 'package:test/test.dart';

/// The single value out of a one-row, one-column pragma query.
Object? _pragma(LanlinkDatabase db, String sql) =>
    db.raw.select(sql).first.values.first;

void main() {
  test('an on-disk database keeps WAL but stays on synchronous=FULL', () {
    final Directory dir =
        Directory.systemTemp.createTempSync('lanlink_pragmas_');
    final String path = '${dir.path}/pragmas.db';
    final LanlinkDatabase db = LanlinkDatabase.openFile(path);
    try {
      expect(
        _pragma(db, 'PRAGMA journal_mode'),
        'wal',
        reason: 'WAL is what makes concurrent read + progress write cheap',
      );
      expect(
        _pragma(db, 'PRAGMA synchronous'),
        2,
        reason: 'FULL (2) on purpose: the durability loss of NORMAL is not '
            'worth 0.5-4% throughput; progress writes are throttled instead',
      );
      expect(_pragma(db, 'PRAGMA foreign_keys'), 1);
    } finally {
      db.close();
      dir.deleteSync(recursive: true);
    }
  });
}
