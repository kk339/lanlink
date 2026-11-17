/// A row of the `files` table: one attachment of a [MessageRecord].
///
/// A message may carry several files, so this is a separate row type keyed by
/// its own `id`. That `id` doubles as the **wire `fileId`** (spec §5.6.2): it is
/// generated once when a send is enqueued and reused on every retry, which is
/// what anchors the idempotent message id.
library;

/// Immutable `files` row.
class MessageFileRecord {
  /// Creates a file row.
  const MessageFileRecord({
    required this.id,
    required this.messageId,
    required this.fileName,
    required this.size,
    this.mime,
    this.sha256,
    this.localPath,
    this.thumbnailPath,
    this.relativePath,
  });

  /// Local primary key, also used verbatim as the wire `fileId`.
  final String id;

  /// Owning message.
  final String messageId;

  /// The file's name as it travels on the wire.
  final String fileName;

  /// The file's size in bytes; `-1` means unknown, matching the wire semantics.
  final int size;

  /// MIME type, or `null` when unknown.
  final String? mime;

  /// SHA-256 of the content (uppercase hex), or `null` when undeclared.
  final String? sha256;

  /// Source path on the sender, or saved path on the receiver, or `null`.
  final String? localPath;

  /// Path to a generated thumbnail, or `null`.
  final String? thumbnailPath;

  /// Where this file sits inside its folder message, or `null` (docs/22 §2.3).
  ///
  /// Semantics, identical on both ends: **relative to the folder root,
  /// `/`-separated, not including the folder's own name** (that name is stored
  /// once, on `messages.folder_name`), e.g. `data/sqlite3.dll`.
  ///
  /// `null` = flat: a pre-v2 row, an old peer that sent no `path`, or an
  /// ordinary multi-select send. Never `''` — the flat case is "no path", not
  /// "empty path", so `relativePath != null` can be used as "there is a level".
  ///
  /// On the receiving side this is the path that was **actually written**, so a
  /// de-duplicating rename (`x.dll` → `x (1).dll`) is recorded as it landed —
  /// otherwise opening the row would target a name that does not exist.
  final String? relativePath;

  /// Builds a record from a `files` row map (column name -> value).
  factory MessageFileRecord.fromRow(Map<String, Object?> row) =>
      MessageFileRecord(
        id: row['id'] as String,
        messageId: row['message_id'] as String,
        fileName: row['file_name'] as String,
        size: row['size'] as int,
        mime: row['mime'] as String?,
        sha256: row['sha256'] as String?,
        localPath: row['local_path'] as String?,
        thumbnailPath: row['thumbnail_path'] as String?,
        relativePath: row['relative_path'] as String?,
      );

  /// Serialises to a `files` row map.
  Map<String, Object?> toRow() => <String, Object?>{
        'id': id,
        'message_id': messageId,
        'file_name': fileName,
        'size': size,
        'mime': mime,
        'sha256': sha256,
        'local_path': localPath,
        'thumbnail_path': thumbnailPath,
        'relative_path': relativePath,
      };

  /// Returns a copy with the given fields replaced.
  MessageFileRecord copyWith({
    String? id,
    String? messageId,
    String? fileName,
    int? size,
    String? mime,
    String? sha256,
    String? localPath,
    String? thumbnailPath,
    String? relativePath,
  }) =>
      MessageFileRecord(
        id: id ?? this.id,
        messageId: messageId ?? this.messageId,
        fileName: fileName ?? this.fileName,
        size: size ?? this.size,
        mime: mime ?? this.mime,
        sha256: sha256 ?? this.sha256,
        localPath: localPath ?? this.localPath,
        thumbnailPath: thumbnailPath ?? this.thumbnailPath,
        relativePath: relativePath ?? this.relativePath,
      );

  @override
  bool operator ==(Object other) =>
      other is MessageFileRecord &&
      other.id == id &&
      other.messageId == messageId &&
      other.fileName == fileName &&
      other.size == size &&
      other.mime == mime &&
      other.sha256 == sha256 &&
      other.localPath == localPath &&
      other.thumbnailPath == thumbnailPath &&
      other.relativePath == relativePath;

  @override
  int get hashCode => Object.hash(id, messageId, fileName, size, mime, sha256,
      localPath, thumbnailPath, relativePath);

  @override
  String toString() =>
      'MessageFileRecord($id, $fileName, size: $size, message: $messageId)';
}
