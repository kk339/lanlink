/// A row of the `transfers` table: the (retryable, queueable) delivery task of
/// one [MessageFileRecord].
///
/// A transfer does **not** support resume (spec §5.9): [bytesDone] counts the
/// bytes sent **within the current attempt**, not a resumable offset, and
/// [sessionId] / [token] change on every attempt because the peer mints a fresh
/// session and one-shot token each time. [nextAttemptAt] is the M5 retry
/// scheduler's "do not retry before" instant (`NULL` = no retry pending).
library;

import '../db/time_codec.dart';

/// Immutable `transfers` row.
class TransferRecord {
  /// Creates a transfer row.
  const TransferRecord({
    required this.id,
    required this.fileId,
    required this.bytesTotal,
    required this.updatedAt,
    this.sessionId,
    this.token,
    this.bytesDone = 0,
    this.chunkSize,
    this.retryCount = 0,
    this.nextAttemptAt,
    this.error,
  });

  /// Local primary key.
  final String id;

  /// The file this transfer delivers.
  final String fileId;

  /// The peer's session id for the current attempt, or `null` before the first
  /// `prepare-upload`.
  final String? sessionId;

  /// The peer's one-shot upload token for the current attempt, or `null`.
  final String? token;

  /// Bytes sent **within the current attempt** (not a resume offset).
  final int bytesDone;

  /// The file's total size; equals `files.size` and may be `-1` (unknown).
  final int bytesTotal;

  /// Negotiated chunk size, or `null`.
  final int? chunkSize;

  /// How many attempts have been made so far.
  final int retryCount;

  /// Earliest instant (UTC) at which M5 may retry, or `null` for "no retry".
  final DateTime? nextAttemptAt;

  /// Last failure message, or `null`.
  final String? error;

  /// When this row was last updated (UTC).
  final DateTime updatedAt;

  /// Builds a record from a `transfers` row map (column name -> value).
  factory TransferRecord.fromRow(Map<String, Object?> row) => TransferRecord(
        id: row['id'] as String,
        fileId: row['file_id'] as String,
        sessionId: row['session_id'] as String?,
        token: row['token'] as String?,
        bytesDone: row['bytes_done'] as int,
        bytesTotal: row['bytes_total'] as int,
        chunkSize: row['chunk_size'] as int?,
        retryCount: row['retry_count'] as int,
        nextAttemptAt: fromEpochMillisOrNull(row['next_attempt_at']),
        error: row['error'] as String?,
        updatedAt: fromEpochMillis(row['updated_at'] as int),
      );

  /// Serialises to a `transfers` row map.
  Map<String, Object?> toRow() => <String, Object?>{
        'id': id,
        'file_id': fileId,
        'session_id': sessionId,
        'token': token,
        'bytes_done': bytesDone,
        'bytes_total': bytesTotal,
        'chunk_size': chunkSize,
        'retry_count': retryCount,
        'next_attempt_at': toEpochMillisOrNull(nextAttemptAt),
        'error': error,
        'updated_at': toEpochMillis(updatedAt),
      };

  /// Returns a copy with the given fields replaced.
  TransferRecord copyWith({
    String? id,
    String? fileId,
    String? sessionId,
    String? token,
    int? bytesDone,
    int? bytesTotal,
    int? chunkSize,
    int? retryCount,
    DateTime? nextAttemptAt,
    String? error,
    DateTime? updatedAt,
  }) =>
      TransferRecord(
        id: id ?? this.id,
        fileId: fileId ?? this.fileId,
        sessionId: sessionId ?? this.sessionId,
        token: token ?? this.token,
        bytesDone: bytesDone ?? this.bytesDone,
        bytesTotal: bytesTotal ?? this.bytesTotal,
        chunkSize: chunkSize ?? this.chunkSize,
        retryCount: retryCount ?? this.retryCount,
        nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
        error: error ?? this.error,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  bool operator ==(Object other) =>
      other is TransferRecord &&
      other.id == id &&
      other.fileId == fileId &&
      other.sessionId == sessionId &&
      other.token == token &&
      other.bytesDone == bytesDone &&
      other.bytesTotal == bytesTotal &&
      other.chunkSize == chunkSize &&
      other.retryCount == retryCount &&
      other.nextAttemptAt == nextAttemptAt &&
      other.error == error &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(id, fileId, sessionId, token, bytesDone,
      bytesTotal, chunkSize, retryCount, nextAttemptAt, error, updatedAt);

  @override
  String toString() => 'TransferRecord($id, file: $fileId, '
      '$bytesDone/$bytesTotal, retry: $retryCount)';
}
