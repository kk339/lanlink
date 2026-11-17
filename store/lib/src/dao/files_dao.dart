/// Data access for the `files` table (spec §5.3).
///
/// A file row is one attachment of a message. Its `id` doubles as the wire
/// `fileId` (spec §5.6.2): generated once when a send is enqueued and reused on
/// every retry, which is what anchors the idempotent message id. This DAO is
/// deliberately single-table CRUD — the cross-table transaction that keeps
/// messages and their files consistent lives in the `SessionStore` facade.
library;

import '../db/lanlink_database.dart';
import '../models/message_file_record.dart';

/// Single-table access to `files`.
class FilesDao {
  /// Creates a DAO over the connection [db].
  FilesDao(this._db);

  final LanlinkDatabase _db;

  /// Inserts [file].
  ///
  /// `id` is the primary key and, being the wire `fileId`, is minted once per
  /// send and reused across retries. Inserting the same `id` twice is therefore
  /// a logic error and surfaces as a constraint failure: this DAO never
  /// swallows errors (spec §9.5), and a caller replaying an event must guard on
  /// the message's idempotency result before inserting files again.
  ///
  /// Use [insertIfAbsent] instead when a duplicate id is an **expected** shape
  /// of the input (re-delivered inbound file) rather than a bug.
  void insert(MessageFileRecord file) {
    _db.execute(
      'INSERT INTO files '
      '(id, message_id, file_name, size, mime, sha256, local_path, '
      'thumbnail_path, relative_path) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        file.id,
        file.messageId,
        file.fileName,
        file.size,
        file.mime,
        file.sha256,
        file.localPath,
        file.thumbnailPath,
        file.relativePath,
      ],
    );
  }

  /// Inserts [file] unless a row with the same `id` already exists.
  ///
  /// Returns the id that was written ([file].id) plus `created`: `true` when a
  /// row was inserted, `false` when an existing row was hit and **nothing** was
  /// changed — a second call with the same id is a harmless no-op instead of
  /// the constraint failure [insert] would raise (docs/22 §4.2 step 3).
  ///
  /// That tolerance is needed on the receive path: one folder session calls
  /// this once per arriving file, and a re-delivery of a file that already
  /// landed is normal, not an error. On a conflict the stored row is left
  /// **exactly as it was** (the first arrival's name/path win), so `created ==
  /// false` tells the caller not to write a second `transfers` row.
  ///
  /// Note that `INSERT OR IGNORE` only suppresses UNIQUE / NOT NULL / CHECK
  /// conflicts, **not** foreign-key violations: inserting a file for a message
  /// that does not exist still throws, which is what we want.
  ///
  /// `(id, created)` mirrors
  /// [MessagesDao.insertIfAbsent] so the two read alike at the call site.
  ({String id, bool created}) insertIfAbsent(MessageFileRecord file) {
    _db.execute(
      'INSERT OR IGNORE INTO files '
      '(id, message_id, file_name, size, mime, sha256, local_path, '
      'thumbnail_path, relative_path) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        file.id,
        file.messageId,
        file.fileName,
        file.size,
        file.mime,
        file.sha256,
        file.localPath,
        file.thumbnailPath,
        file.relativePath,
      ],
    );
    return (id: file.id, created: _db.updatedRows > 0);
  }

  /// Returns the file with [id], or `null` when there is none.
  MessageFileRecord? byId(String id) {
    final row = _db.selectOne(
      'SELECT * FROM files WHERE id = ?',
      <Object?>[id],
    );
    return row == null ? null : MessageFileRecord.fromRow(row);
  }

  /// Deletes every file row attached to [messageId], returning whether anything
  /// was removed (0.2.36).
  ///
  /// Single-table on purpose: the `transfers` rows hanging off these file ids
  /// are deleted by the caller (`SessionStore.deleteMessage`) first, because
  /// this DAO cannot see another table.
  bool deleteForMessage(String messageId) {
    _db.execute(
      'DELETE FROM files WHERE message_id = ?',
      <Object?>[messageId],
    );
    return _db.updatedRows > 0;
  }

  /// The files attached to [messageId], in insertion (`rowid`) order — the
  /// order in which the sender selected them.
  List<MessageFileRecord> forMessage(String messageId) {
    final rows = _db.selectAll(
      'SELECT * FROM files WHERE message_id = ? ORDER BY rowid ASC',
      <Object?>[messageId],
    );
    return <MessageFileRecord>[
      for (final row in rows) MessageFileRecord.fromRow(row),
    ];
  }
}
