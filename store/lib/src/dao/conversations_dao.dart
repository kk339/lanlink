/// The `conversations` table access object: the message thread with one
/// counterparty.
///
/// Signatures are frozen by spec §5.3. Writes take a UTC [DateTime] `now` and
/// never read the clock (spec §5.10); new ids come from the injected
/// [IdGenerator], never from a hidden source. Conversations are **archived**
/// rather than deleted (spec §5.8).
library;

import 'package:lanlink_core/lanlink_core.dart';

import '../db/lanlink_database.dart';
import '../db/time_codec.dart';
import '../errors/store_errors.dart';
import '../ids/ids.dart';
import '../models/conversation_record.dart';

/// Reads and writes rows of the `conversations` table.
class ConversationsDao {
  /// Wraps an open [LanlinkDatabase] and the [IdGenerator] used for new ids.
  ConversationsDao(this._db, this._ids);

  final LanlinkDatabase _db;
  final IdGenerator _ids;

  /// Returns the active conversation for `deviceFingerprint`, creating one
  /// (`created_at = now`) when none exists.
  ///
  /// At most one active conversation exists per fingerprint thanks to the
  /// partial unique index `ux_conversations_active`, so repeated calls return
  /// the **same** row. A `null` fingerprint selects the device-less (history
  /// only) active conversation and is deduplicated on that same "no device"
  /// key; an empty fingerprint after normalisation is treated as `null`.
  ///
  /// Because `conversations.device_fingerprint` is a real foreign key, a
  /// non-null fingerprint must already exist in `devices` (call
  /// `DevicesDao.upsert` first), otherwise the insert is rejected.
  ConversationRecord openActive({
    required String? deviceFingerprint,
    required DateTime now,
  }) {
    final fingerprint = _normalizeOrNull(deviceFingerprint);
    final existing = _selectActive(fingerprint);
    if (existing != null) {
      return existing;
    }
    final id = _ids.newId();
    _db.execute(
      'INSERT INTO conversations '
      '(id, device_fingerprint, created_at, last_message_at, last_preview, '
      'archived_at) VALUES (?, ?, ?, NULL, NULL, NULL)',
      <Object?>[id, fingerprint, toEpochMillis(now)],
    );
    return ConversationRecord(
      id: id,
      deviceFingerprint: fingerprint,
      createdAt: now,
    );
  }

  /// Returns the active (non-archived) conversation for [fingerprint], or
  /// `null` when there is none.
  ConversationRecord? activeForDevice(String fingerprint) =>
      _selectActive(_normalizeOrNull(fingerprint));

  /// Returns conversations in reverse chronological order by activity
  /// (`last_message_at` descending, never-messaged rows last, id breaking
  /// ties). Archived conversations are excluded unless [includeArchived].
  List<ConversationRecord> all({bool includeArchived = false}) {
    final sql = includeArchived
        ? 'SELECT * FROM conversations '
            'ORDER BY last_message_at DESC, id ASC'
        : 'SELECT * FROM conversations WHERE archived_at IS NULL '
            'ORDER BY last_message_at DESC, id ASC';
    return _db.selectAll(sql).map(ConversationRecord.fromRow).toList();
  }

  /// Records that a message landed in [conversationId]: sets `last_message_at`
  /// to [now] and stores [preview].
  ///
  /// Throws [RowNotFound] when no such conversation exists — the caller is
  /// naming a row that must already be there (spec §9.5).
  void touchLastMessage({
    required String conversationId,
    required DateTime now,
    required String? preview,
  }) {
    _db.execute(
      'UPDATE conversations SET last_message_at = ?, last_preview = ? '
      'WHERE id = ?',
      <Object?>[toEpochMillis(now), preview, conversationId],
    );
    if (_db.updatedRows == 0) {
      throw RowNotFound(conversationId);
    }
  }

  /// Archives [conversationId] by stamping `archived_at = now` (reversible,
  /// never a hard delete — spec §5.8).
  ///
  /// Throws [RowNotFound] when no such conversation exists.
  void archive(String conversationId, {required DateTime now}) {
    _db.execute(
      'UPDATE conversations SET archived_at = ? WHERE id = ?',
      <Object?>[toEpochMillis(now), conversationId],
    );
    if (_db.updatedRows == 0) {
      throw RowNotFound(conversationId);
    }
  }

  /// Archives every **active** conversation belonging to [deviceFingerprint]
  /// (used when a peer reinstalls and its fingerprint changes, spec §5.8).
  ///
  /// Returns the number of rows archived; `0` is a valid, quiet outcome.
  int archiveAllForDevice(
    String deviceFingerprint, {
    required DateTime now,
  }) {
    _db.execute(
      'UPDATE conversations SET archived_at = ? '
      'WHERE device_fingerprint = ? AND archived_at IS NULL',
      <Object?>[toEpochMillis(now), normalizeFingerprint(deviceFingerprint)],
    );
    return _db.updatedRows;
  }

  /// Selects the active conversation for [fingerprint] (or the device-less one
  /// when `null`), or `null`.
  ConversationRecord? _selectActive(String? fingerprint) {
    final row = fingerprint == null
        ? _db.selectOne(
            'SELECT * FROM conversations '
            'WHERE device_fingerprint IS NULL AND archived_at IS NULL '
            'ORDER BY created_at ASC, id ASC LIMIT 1',
          )
        : _db.selectOne(
            'SELECT * FROM conversations '
            'WHERE device_fingerprint = ? AND archived_at IS NULL '
            'ORDER BY created_at ASC, id ASC LIMIT 1',
            <Object?>[fingerprint],
          );
    return row == null ? null : ConversationRecord.fromRow(row);
  }

  /// Normalises [fingerprint] to its canonical form, collapsing `null` and an
  /// empty result to `null` (the "no device" key).
  String? _normalizeOrNull(String? fingerprint) {
    if (fingerprint == null) {
      return null;
    }
    final normalized = normalizeFingerprint(fingerprint);
    return normalized.isEmpty ? null : normalized;
  }
}
