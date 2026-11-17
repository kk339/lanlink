/// Data access for the `messages` table (spec §5.3).
///
/// One row is one transfer event; a message's file attachments live in the
/// `files` table. The idempotency contract of the milestone lives here:
/// [MessagesDao.insertIfAbsent] is backed by the unique index
/// `ux_messages_event(conversation_id, direction, event_nonce)`, so a replayed
/// event never inserts a second row.
///
/// Every method is synchronous (spec §9.2) and never reads the clock: each
/// write takes an explicit `now` in UTC (spec §5.10).
library;

import '../db/lanlink_database.dart';
import '../db/time_codec.dart';
import '../models/message_record.dart';
import '../status/message_status_machine.dart';

/// The `messages` columns, in the exact order used by the INSERT statement.
///
/// The column names are always spelled out — never `INSERT INTO messages VALUES
/// (...)` — so a build that does not know about a later column still writes a
/// valid row (this is what makes opening a v2 database with a v1 binary fail
/// only on the version check, not on every insert), and so adding a column is a
/// one-line change here plus its placeholder.
const List<String> _messageColumns = <String>[
  'id',
  'conversation_id',
  'direction',
  'kind',
  'text_body',
  'folder_name',
  'folder_files',
  'created_at',
  'updated_at',
  'status',
  'event_nonce',
];

/// Single-table access to `messages`.
class MessagesDao {
  /// Creates a DAO over the connection [db].
  MessagesDao(this._db);

  final LanlinkDatabase _db;

  /// Inserts [message] unless an equivalent event already exists.
  ///
  /// De-duplication is done by the database via `INSERT OR IGNORE` over the
  /// unique index `ux_messages_event`, so a replayed event leaves the table
  /// untouched. The returned record carries the stored row's [id] (which may
  /// differ from `message.id` when the content key changed but the event anchor
  /// did not) together with [created] (`true` when a new row was written,
  /// `false` when an existing row was hit).
  ({String id, bool created}) insertIfAbsent(MessageRecord message) {
    _db.execute(
      'INSERT OR IGNORE INTO messages (${_messageColumns.join(', ')}) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        message.id,
        message.conversationId,
        message.direction.wire,
        message.kind.wire,
        message.textBody,
        message.folderName,
        message.folderFiles,
        toEpochMillis(message.createdAt),
        toEpochMillis(message.updatedAt),
        message.status.wire,
        message.eventNonce,
      ],
    );
    if (_db.updatedRows > 0) {
      return (id: message.id, created: true);
    }
    // Ignored: the same (conversation, direction, event_nonce) is already
    // present. Report *its* id, which is the stable identity of the event.
    final existing = byEventNonce(
      conversationId: message.conversationId,
      direction: message.direction,
      eventNonce: message.eventNonce,
    );
    return (id: existing?.id ?? message.id, created: false);
  }

  /// Returns the message with [id], or `null` when there is none.
  MessageRecord? byId(String id) {
    final row = _db.selectOne(
      'SELECT * FROM messages WHERE id = ?',
      <Object?>[id],
    );
    return row == null ? null : MessageRecord.fromRow(row);
  }

  /// Returns the message for a `(conversation, direction, event_nonce)` triple,
  /// or `null` when there is none.
  MessageRecord? byEventNonce({
    required String conversationId,
    required MessageDirection direction,
    required String eventNonce,
  }) {
    final row = _db.selectOne(
      'SELECT * FROM messages '
      'WHERE conversation_id = ? AND direction = ? AND event_nonce = ?',
      <Object?>[conversationId, direction.wire, eventNonce],
    );
    return row == null ? null : MessageRecord.fromRow(row);
  }

  /// The messages of [conversationId], newest first.
  ///
  /// [before] is an exclusive upper bound on `created_at`, used to page
  /// backwards through history; [limit] caps the page size. The order is fully
  /// deterministic: `created_at DESC, id DESC`.
  List<MessageRecord> forConversation(
    String conversationId, {
    int? limit,
    DateTime? before,
  }) {
    final buffer = StringBuffer(
      'SELECT * FROM messages WHERE conversation_id = ?',
    );
    final parameters = <Object?>[conversationId];
    if (before != null) {
      buffer.write(' AND created_at < ?');
      parameters.add(toEpochMillis(before));
    }
    buffer.write(' ORDER BY created_at DESC, id DESC');
    if (limit != null) {
      buffer.write(' LIMIT ?');
      parameters.add(limit);
    }
    return <MessageRecord>[
      for (final row in _db.selectAll(buffer.toString(), parameters))
        MessageRecord.fromRow(row),
    ];
  }

  /// The messages whose status is in [statuses], ordered `created_at ASC,
  /// id ASC`.
  ///
  /// An empty [statuses] yields an empty list rather than a malformed
  /// `IN ()` query.
  List<MessageRecord> byStatus(Set<MessageStatus> statuses) {
    if (statuses.isEmpty) {
      return <MessageRecord>[];
    }
    final placeholders = List<String>.filled(statuses.length, '?').join(', ');
    final rows = _db.selectAll(
      'SELECT * FROM messages WHERE status IN ($placeholders) '
      'ORDER BY created_at ASC, id ASC',
      <Object?>[for (final status in statuses) status.wire],
    );
    return <MessageRecord>[
      for (final row in rows) MessageRecord.fromRow(row),
    ];
  }

  /// Deletes the message row with [id], returning whether a row was removed
  /// (0.2.36).
  ///
  /// **Single-table, like every other method here.** The `files` and `transfers`
  /// rows that point at this message are *not* touched: deleting them is the
  /// cross-table use-case and lives in `SessionStore.deleteMessage`, which owns
  /// the transaction. Calling this directly on a message that has attachments
  /// would leave orphans (or, with `foreign_keys = ON`, be refused outright by
  /// the `files.message_id` reference).
  bool deleteById(String id) {
    _db.execute('DELETE FROM messages WHERE id = ?', <Object?>[id]);
    return _db.updatedRows > 0;
  }

  /// Optimistic status change: moves the row `from -> to` only when its stored
  /// status is currently [from].
  ///
  /// Throws `InvalidStatusTransition` when the edge itself is illegal (see
  /// `assertTransition`, which also rejects `from == to`). Returns `true` when a
  /// row was updated and `false` when the stored status did not equal [from] —
  /// in the latter case the row is left completely untouched.
  bool updateStatus({
    required String id,
    required MessageStatus from,
    required MessageStatus to,
    required DateTime now,
  }) {
    assertTransition(from, to);
    _db.execute(
      'UPDATE messages SET status = ?, updated_at = ? '
      'WHERE id = ? AND status = ?',
      <Object?>[to.wire, toEpochMillis(now), id, from.wire],
    );
    return _db.updatedRows > 0;
  }
}
