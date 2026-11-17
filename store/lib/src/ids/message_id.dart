/// The idempotent message-id algorithm (spec §5.6).
///
/// History is purely local (§5.6.2), so a message id does **not** have to match
/// between the sender and the receiver. It only has to be
///
/// * **stable** across retries of one logical event (so a re-delivery dedupes),
///   and
/// * **distinct** between two logical events (so sending the same bytes twice
///   produces two rows).
///
/// The anchor that provides both is [eventNonce]: for a file message it is the
/// sorted set of wire `fileId`s (regenerated once at enqueue and reused on every
/// retry); for a text message it is a random 16-byte hex string minted once when
/// the message is created. See [FileContentKey] for the matching content key.
///
/// Everything here is a **pure function**: no clock, no database, no RNG. The
/// nonce and content key are supplied by the caller, which is what makes the
/// whole store deterministic under test (spec §9.4 / §5.10).
library;

import 'dart:convert';

import 'package:lanlink_core/lanlink_core.dart';

import '../models/message_record.dart';

/// Unit Separator (U+001F): the field joiner of the canonical form.
const String _unitSeparator = '\u001f';

/// Record Separator (U+001E): the joiner inside multi-valued fields (several
/// `fileId`s, several per-file keys).
const String _recordSeparator = '\u001e';

/// Domain-separation prefix, so ids from this scheme can never collide with
/// ids minted by a future, differently-shaped scheme.
const String _idNamespace = 'lanlink.msg.v1';

/// Computes the idempotent id of one message event.
///
/// [fingerprint] is normalised with `normalizeFingerprint` before hashing, so a
/// lowercase or colon-separated input yields the same id as the canonical form
/// (spec V6). [direction] and [kind] contribute their wire strings; [eventNonce]
/// and [contentKey] are supplied by the caller (see the library docs). The
/// result is always 64 uppercase hex characters.
String computeMessageId({
  required String fingerprint,
  required MessageDirection direction,
  required MessageKind kind,
  required String eventNonce,
  required String contentKey,
}) {
  final canonical = <String>[
    _idNamespace,
    normalizeFingerprint(fingerprint),
    direction.wire,
    kind.wire,
    eventNonce,
    contentKey,
  ].join(_unitSeparator);
  return sha256HexOfBytes(utf8.encode(canonical));
}

/// The event anchor of a file message: the sorted `fileId`s joined by RS.
///
/// Sorting makes the anchor (and therefore the message id) independent of the
/// order in which the files happen to be enumerated (spec V3).
String eventNonceForFiles(Iterable<String> fileIds) =>
    _joinSorted(_recordSeparator, fileIds);

/// The domain prefix of a folder-session nonce, terminated by US.
///
/// The prefix is what keeps the nonce families **permanently disjoint**: a
/// plain file message's nonce is bare `fileId`s joined by RS, so it can never
/// begin with `folder` + US. Without it, a peer that happened to name a file
/// `folder\u001f<sessionId>` could alias another message's anchor.
const String _folderNoncePrefix = 'folder$_unitSeparator';

/// The domain prefix of a **batch** (flat multi-select) nonce, terminated by US.
///
/// The third family, and disjoint from the other two for exactly the reason
/// above: `batch` + US cannot be a bare `fileId` (family 1) and cannot be
/// `folder` + US + … (family 2). Two prefixes rather than one shared
/// `session` prefix because the two aggregations are **different messages** on
/// purpose — a folder writes `folder_name` and draws a folder card, a batch
/// writes neither — and a peer that reused a string across the two shapes must
/// not be able to alias them into one row.
const String _batchNoncePrefix = 'batch$_unitSeparator';

/// The event anchor of a **folder** message: one anchor per `prepare` session
/// (docs/22 §4.2 / §5).
///
/// [sessionId] is the receiving peer's own per-`prepare` session id — 16 random
/// bytes of hex it minted itself — so it is unique per send and **must not** be
/// replaced by the folder's name: sending a folder named `素材` three times a
/// day is normal, and a name-based anchor would collapse all three into one
/// history row.
///
/// Every file of one `prepare` carries the same `ReceivedFile.sessionId`, so
/// the N arrivals of one folder send all resolve to this same nonce, and the
/// idempotency index `ux_messages_event` folds them into **one** message whose
/// attachments accumulate (docs/22 §2.2 / §4.2).
String eventNonceForFolderSession(String sessionId) =>
    '$_folderNoncePrefix$sessionId';

/// The event anchor of an **aggregated batch** message: one anchor per
/// `prepare` session of a **flat** multi-select send (0.2.51).
///
/// A multi-select send is one `prepare` carrying N files (the sender has always
/// done that — one session, N `put`s), so its N arrivals share [sessionId] just
/// like a folder's do and fold into one message for the same reason. What is
/// **not** shared with the folder path is the descriptor: there is no folder
/// name, so the row keeps `folder_name` NULL, `isFolder` stays `false`, and the
/// bubble draws rows rather than a folder card (`session_store
/// .recordIncomingSessionFile`).
///
/// The bare `eventNonceForFiles([fileId])` family stays what a **single-file**
/// arrival uses: one file, one message, exactly as before 0.2.51.
String eventNonceForBatchSession(String sessionId) =>
    '$_batchNoncePrefix$sessionId';

/// The content key of an **aggregated batch** message, derived from its anchor.
///
/// It deliberately carries **no** per-file information: the attachment set grows
/// between calls (files 1…N of one session), so a key built from "the files seen
/// so far" would change on every arrival. The anchor is what de-duplicates, so
/// this only has to be stable — and hashing the anchor is the most stable thing
/// available without inventing a second identifier.
String contentKeyForBatchSession(String sessionId) =>
    sha256HexOfBytes(utf8.encode(eventNonceForBatchSession(sessionId)));

/// The content key of a text message: the SHA-256 of its UTF-8 body, uppercase
/// hex.
String contentKeyForText(String textBody) =>
    sha256HexOfBytes(utf8.encode(textBody));

/// One file's contribution to a file message's content key.
///
/// When the peer declared a hash, it is used (upper-cased so a lowercase
/// producer still matches). When no hash is available, the key falls back to a
/// deterministic `'n:' + fileName + NUL + size` so the id is still reproducible
/// across retries.
class FileContentKey {
  /// Creates a per-file content key.
  const FileContentKey({
    required this.fileName,
    required this.size,
    this.sha256,
  });

  /// The file's name as it travels on the wire.
  final String fileName;

  /// The file's size in bytes (`-1` means unknown, matching the wire).
  final int size;

  /// The declared SHA-256 (uppercase hex), or `null` when the peer sent none.
  final String? sha256;

  /// This file's key within the message's content key.
  String get perFileKey {
    final hash = sha256;
    if (hash != null && hash.isNotEmpty) {
      return hash.toUpperCase();
    }
    return 'n:$fileName\u0000$size';
  }

  @override
  bool operator ==(Object other) =>
      other is FileContentKey &&
      other.fileName == fileName &&
      other.size == size &&
      other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(fileName, size, sha256);

  @override
  String toString() =>
      'FileContentKey($fileName, size: $size, sha256: ${sha256 ?? '-'})';
}

/// The content key of a file message: each [FileContentKey.perFileKey], sorted
/// and joined by RS.
///
/// Sorting again guarantees order-invariance (spec V3), matching
/// [eventNonceForFiles].
String contentKeyForFiles(Iterable<FileContentKey> files) =>
    _joinSorted(_recordSeparator, files.map((file) => file.perFileKey));

/// Sorts [values] and joins them with [separator].
///
/// The single place the "sorted then joined" convention of both the event
/// nonce and the file content key is applied, so the two cannot drift apart.
String _joinSorted(String separator, Iterable<String> values) {
  final sorted = values.toList()..sort();
  return sorted.join(separator);
}
