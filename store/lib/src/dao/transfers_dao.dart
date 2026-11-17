/// Data access for the `transfers` table (spec §5.3).
///
/// A transfer is the (retryable, queueable) delivery task of one file. It does
/// **not** support resume (spec §5.9): [bytesDone] counts the bytes sent within
/// the current attempt — it is reset to zero when a new attempt begins, never
/// carried forward as an offset — and `session_id` / `token` are refreshed on
/// every attempt because the peer mints a fresh session and one-shot token each
/// time. [TransfersDao.dueForRetry] is the only scheduling surface M3 exposes;
/// M3 starts no timer (spec §2.2).
library;

import '../db/lanlink_database.dart';
import '../db/time_codec.dart';
import '../models/transfer_record.dart';

/// Single-table access to `transfers`.
class TransfersDao {
  /// Creates a DAO over the connection [db].
  TransfersDao(this._db);

  final LanlinkDatabase _db;

  /// Inserts [transfer].
  ///
  /// Like [FilesDao.insert] this is a strict insert and never swallows a
  /// constraint failure (spec §9.5).
  void insert(TransferRecord transfer) {
    _db.execute(
      'INSERT INTO transfers '
      '(id, file_id, session_id, token, bytes_done, bytes_total, chunk_size, '
      'retry_count, next_attempt_at, error, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        transfer.id,
        transfer.fileId,
        transfer.sessionId,
        transfer.token,
        transfer.bytesDone,
        transfer.bytesTotal,
        transfer.chunkSize,
        transfer.retryCount,
        toEpochMillisOrNull(transfer.nextAttemptAt),
        transfer.error,
        toEpochMillis(transfer.updatedAt),
      ],
    );
  }

  /// Returns the transfer with [id], or `null` when there is none.
  TransferRecord? byId(String id) {
    final row = _db.selectOne(
      'SELECT * FROM transfers WHERE id = ?',
      <Object?>[id],
    );
    return row == null ? null : TransferRecord.fromRow(row);
  }

  /// Returns the transfer delivering [fileId], or `null`.
  ///
  /// One file has a single transfer row that is reused across attempts; the
  /// most recently updated row wins if that invariant is ever violated.
  TransferRecord? byFileId(String fileId) {
    final row = _db.selectOne(
      'SELECT * FROM transfers WHERE file_id = ? '
      'ORDER BY updated_at DESC, id DESC LIMIT 1',
      <Object?>[fileId],
    );
    return row == null ? null : TransferRecord.fromRow(row);
  }

  /// Deletes the transfer row delivering [fileId], returning whether one was
  /// removed (0.2.36). Single-table; the file row itself is the caller's job
  /// (see `SessionStore.deleteMessage`).
  bool deleteByFileId(String fileId) {
    _db.execute(
      'DELETE FROM transfers WHERE file_id = ?',
      <Object?>[fileId],
    );
    return _db.updatedRows > 0;
  }

  /// Transfers that are due for a retry at [now]: `next_attempt_at` is not
  /// `NULL` and is `<= now`, ordered `next_attempt_at ASC`, capped at [limit].
  ///
  /// This is a query only — M3 schedules nothing (spec §2.2); the M5 retry
  /// executor calls it.
  List<TransferRecord> dueForRetry({
    required DateTime now,
    int limit = 32,
  }) {
    final rows = _db.selectAll(
      'SELECT * FROM transfers '
      'WHERE next_attempt_at IS NOT NULL AND next_attempt_at <= ? '
      'ORDER BY next_attempt_at ASC, id ASC LIMIT ?',
      <Object?>[toEpochMillis(now), limit],
    );
    return <TransferRecord>[
      for (final row in rows) TransferRecord.fromRow(row),
    ];
  }

  /// Records progress within the current attempt.
  ///
  /// [bytesDone] is "bytes sent so far in this attempt", never a resume offset
  /// (spec §5.9): callers pass `0` when an attempt begins and the running total
  /// while it proceeds.
  void updateProgress({
    required String id,
    required int bytesDone,
    required DateTime now,
  }) {
    _db.execute(
      'UPDATE transfers SET bytes_done = ?, updated_at = ? WHERE id = ?',
      <Object?>[bytesDone, toEpochMillis(now), id],
    );
  }

  /// Records the peer's fresh `session_id` / `token` for the current attempt.
  void attachSession({
    required String id,
    required String sessionId,
    required String token,
    required DateTime now,
  }) {
    _db.execute(
      'UPDATE transfers SET session_id = ?, token = ?, updated_at = ? '
      'WHERE id = ?',
      <Object?>[sessionId, token, toEpochMillis(now), id],
    );
  }

  /// Marks the transfer complete: `bytes_done` becomes `bytes_total` and the
  /// retry schedule is cleared (`next_attempt_at = NULL`).
  void markDone({required String id, required DateTime now}) {
    _db.execute(
      'UPDATE transfers SET bytes_done = bytes_total, next_attempt_at = NULL, '
      'updated_at = ? WHERE id = ?',
      <Object?>[toEpochMillis(now), id],
    );
  }

  /// Records a failed attempt: `retry_count` is incremented, [error] stored and
  /// the next attempt scheduled at [nextAttemptAt] (`NULL` clears the schedule).
  ///
  /// `bytes_done` is intentionally left at the failed attempt's value: the
  /// per-attempt counter is reset when the **next** attempt begins, and is
  /// never carried forward as an offset (spec §5.9).
  void markFailed({
    required String id,
    required String error,
    required DateTime? nextAttemptAt,
    required DateTime now,
  }) {
    _db.execute(
      'UPDATE transfers SET retry_count = retry_count + 1, error = ?, '
      'next_attempt_at = ?, updated_at = ? WHERE id = ?',
      <Object?>[
        error,
        toEpochMillisOrNull(nextAttemptAt),
        toEpochMillis(now),
        id,
      ],
    );
  }
}
