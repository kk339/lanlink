/// A row of the `messages` table, plus the three wire enums it uses.
///
/// The enums store their **wire strings** verbatim (`'out'`, `'awaiting_confirm'`
/// ...) so the on-disk values are self-describing and evolve without renumbering.
library;

import '../db/time_codec.dart';

/// Direction of a message relative to this device.
enum MessageDirection {
  /// Received from a peer.
  incoming('in'),

  /// Sent to a peer.
  outgoing('out');

  const MessageDirection(this.wire);

  /// The exact string stored in the `direction` column.
  final String wire;

  /// Parses a stored value, throwing [FormatException] on anything unknown —
  /// the database should never hold an unrecognised direction.
  static MessageDirection parse(Object? value) {
    for (final direction in values) {
      if (direction.wire == value) {
        return direction;
      }
    }
    throw FormatException('unknown message direction: $value');
  }
}

/// Whether a message carries file attachments or a plain text body.
enum MessageKind {
  /// One or more files.
  file('file'),

  /// A plain text message (entry point lands in M4).
  text('text');

  const MessageKind(this.wire);

  /// The exact string stored in the `kind` column.
  final String wire;

  /// Parses a stored value, throwing [FormatException] on anything unknown.
  static MessageKind parse(Object? value) {
    for (final kind in values) {
      if (kind.wire == value) {
        return kind;
      }
    }
    throw FormatException('unknown message kind: $value');
  }
}

/// Lifecycle of a message (spec §5.5).
enum MessageStatus {
  /// Queued locally, nothing sent yet.
  pending('pending'),

  /// `prepare-upload` sent, awaiting the peer's answer.
  awaitingConfirm('awaiting_confirm'),

  /// Upload in progress.
  transferring('transferring'),

  /// Completed and verified.
  done('done'),

  /// Failed; a retry scheduler may re-queue it.
  failed('failed'),

  /// Canceled by the user.
  canceled('canceled'),

  /// Refused by the peer (403 / 413 / 503).
  rejected('rejected');

  const MessageStatus(this.wire);

  /// The exact string stored in the `status` column.
  final String wire;

  /// Parses a stored value, throwing [FormatException] on anything unknown.
  static MessageStatus parse(Object? value) {
    for (final status in values) {
      if (status.wire == value) {
        return status;
      }
    }
    throw FormatException('unknown message status: $value');
  }
}

/// Immutable `messages` row.
class MessageRecord {
  /// Creates a message row.
  const MessageRecord({
    required this.id,
    required this.conversationId,
    required this.direction,
    required this.kind,
    required this.createdAt,
    required this.updatedAt,
    required this.status,
    required this.eventNonce,
    this.textBody,
    this.folderName,
    this.folderFiles,
  });

  /// Idempotent message id (see `ids/message_id.dart`).
  final String id;

  /// Owning conversation.
  final String conversationId;

  /// Direction relative to this device.
  final MessageDirection direction;

  /// File or text.
  final MessageKind kind;

  /// Text body; required when [kind] is [MessageKind.text].
  final String? textBody;

  /// When the message was created (UTC).
  final DateTime createdAt;

  /// When the status last changed (UTC).
  final DateTime updatedAt;

  /// Current lifecycle status.
  final MessageStatus status;

  /// The event anchor that makes [id] stable across retries.
  final String eventNonce;

  /// Display name of the folder this message represents, or `null` for a plain
  /// message (docs/22 §2.3).
  ///
  /// **This is the only "is this a folder message?" signal in the whole
  /// repository** — `kind` stays `file` on purpose, because widening its CHECK
  /// would force a table rebuild that cascades every attachment away
  /// (docs/22 §2.2). Never infer a folder from `files.length > 1`: an ordinary
  /// multi-select send is one message with N attachments too.
  final String? folderName;

  /// The sender's **declared** file count for a folder message, or `null` for a
  /// plain message.
  ///
  /// It is stored rather than derived because only the sender knows it: while
  /// the files are still arriving, counting local rows yields "arrived so far",
  /// not "declared total" (docs/22 §2.5). What has actually arrived is
  /// `COUNT(files WHERE message_id = ?)`.
  final int? folderFiles;

  /// Whether this message represents a folder (docs/22 §2.2 / §7).
  bool get isFolder => folderName != null;

  /// Builds a record from a `messages` row map.
  factory MessageRecord.fromRow(Map<String, Object?> row) => MessageRecord(
        id: row['id'] as String,
        conversationId: row['conversation_id'] as String,
        direction: MessageDirection.parse(row['direction']),
        kind: MessageKind.parse(row['kind']),
        textBody: row['text_body'] as String?,
        folderName: row['folder_name'] as String?,
        folderFiles: row['folder_files'] as int?,
        createdAt: fromEpochMillis(row['created_at'] as int),
        updatedAt: fromEpochMillis(row['updated_at'] as int),
        status: MessageStatus.parse(row['status']),
        eventNonce: row['event_nonce'] as String,
      );

  /// Serialises to a `messages` row map.
  Map<String, Object?> toRow() => <String, Object?>{
        'id': id,
        'conversation_id': conversationId,
        'direction': direction.wire,
        'kind': kind.wire,
        'text_body': textBody,
        'folder_name': folderName,
        'folder_files': folderFiles,
        'created_at': toEpochMillis(createdAt),
        'updated_at': toEpochMillis(updatedAt),
        'status': status.wire,
        'event_nonce': eventNonce,
      };

  /// Returns a copy with the given fields replaced.
  MessageRecord copyWith({
    String? id,
    String? conversationId,
    MessageDirection? direction,
    MessageKind? kind,
    String? textBody,
    String? folderName,
    int? folderFiles,
    DateTime? createdAt,
    DateTime? updatedAt,
    MessageStatus? status,
    String? eventNonce,
  }) =>
      MessageRecord(
        id: id ?? this.id,
        conversationId: conversationId ?? this.conversationId,
        direction: direction ?? this.direction,
        kind: kind ?? this.kind,
        textBody: textBody ?? this.textBody,
        folderName: folderName ?? this.folderName,
        folderFiles: folderFiles ?? this.folderFiles,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        status: status ?? this.status,
        eventNonce: eventNonce ?? this.eventNonce,
      );

  @override
  bool operator ==(Object other) =>
      other is MessageRecord &&
      other.id == id &&
      other.conversationId == conversationId &&
      other.direction == direction &&
      other.kind == kind &&
      other.textBody == textBody &&
      other.folderName == folderName &&
      other.folderFiles == folderFiles &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt &&
      other.status == status &&
      other.eventNonce == eventNonce;

  @override
  int get hashCode => Object.hash(id, conversationId, direction, kind, textBody,
      folderName, folderFiles, createdAt, updatedAt, status, eventNonce);

  @override
  String toString() => 'MessageRecord($id, ${direction.wire}, ${kind.wire}, '
      '${status.wire}${folderName == null ? '' : ', folder: $folderName'})';
}
