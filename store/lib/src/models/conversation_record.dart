/// A row of the `conversations` table: the message thread with one counterparty.
///
/// A conversation is deliberately **separate** from its device so it can be
/// **archived** rather than deleted (spec §5.8): `archived_at` is `NULL` while
/// the conversation is active and non-`NULL` once it is archived. The device
/// link uses `ON DELETE SET NULL`, so a history-only conversation with no
/// current device ([deviceFingerprint] == `null`) is valid.
library;

import '../db/time_codec.dart';

/// Immutable `conversations` row.
class ConversationRecord {
  /// Creates a conversation row.
  const ConversationRecord({
    required this.id,
    required this.createdAt,
    this.deviceFingerprint,
    this.lastMessageAt,
    this.lastPreview,
    this.archivedAt,
  });

  /// Local primary key.
  final String id;

  /// The counterparty's normalised fingerprint, or `null` for a history-only
  /// conversation whose device row has been removed.
  final String? deviceFingerprint;

  /// When the conversation was created (UTC).
  final DateTime createdAt;

  /// When the latest message was added (UTC), or `null` while empty.
  final DateTime? lastMessageAt;

  /// A short preview of the latest message, or `null`.
  final String? lastPreview;

  /// When the conversation was archived (UTC); `NULL` means active.
  final DateTime? archivedAt;

  /// Whether this conversation has been archived.
  bool get isArchived => archivedAt != null;

  /// Builds a record from a `conversations` row map (column name -> value).
  factory ConversationRecord.fromRow(Map<String, Object?> row) =>
      ConversationRecord(
        id: row['id'] as String,
        deviceFingerprint: row['device_fingerprint'] as String?,
        createdAt: fromEpochMillis(row['created_at'] as int),
        lastMessageAt: fromEpochMillisOrNull(row['last_message_at']),
        lastPreview: row['last_preview'] as String?,
        archivedAt: fromEpochMillisOrNull(row['archived_at']),
      );

  /// Serialises to a `conversations` row map.
  Map<String, Object?> toRow() => <String, Object?>{
        'id': id,
        'device_fingerprint': deviceFingerprint,
        'created_at': toEpochMillis(createdAt),
        'last_message_at': toEpochMillisOrNull(lastMessageAt),
        'last_preview': lastPreview,
        'archived_at': toEpochMillisOrNull(archivedAt),
      };

  /// Returns a copy with the given fields replaced.
  ConversationRecord copyWith({
    String? id,
    String? deviceFingerprint,
    DateTime? createdAt,
    DateTime? lastMessageAt,
    String? lastPreview,
    DateTime? archivedAt,
  }) =>
      ConversationRecord(
        id: id ?? this.id,
        deviceFingerprint: deviceFingerprint ?? this.deviceFingerprint,
        createdAt: createdAt ?? this.createdAt,
        lastMessageAt: lastMessageAt ?? this.lastMessageAt,
        lastPreview: lastPreview ?? this.lastPreview,
        archivedAt: archivedAt ?? this.archivedAt,
      );

  @override
  bool operator ==(Object other) =>
      other is ConversationRecord &&
      other.id == id &&
      other.deviceFingerprint == deviceFingerprint &&
      other.createdAt == createdAt &&
      other.lastMessageAt == lastMessageAt &&
      other.lastPreview == lastPreview &&
      other.archivedAt == archivedAt;

  @override
  int get hashCode => Object.hash(
      id, deviceFingerprint, createdAt, lastMessageAt, lastPreview, archivedAt);

  @override
  String toString() =>
      'ConversationRecord($id, device: ${deviceFingerprint ?? '-'}, '
      'archived: $isArchived)';
}
