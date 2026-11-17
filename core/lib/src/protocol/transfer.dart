/// lanlink v1 transfer payloads and the shared frame codec.
///
/// Field names mirror our own wire format (`docs/13`). The **Dart** property
/// names are kept for source compatibility; only the JSON keys differ
/// (`fileName`→`name`, `fileType`→`mime`, `preview`→`thumb`, `sessionId`→
/// `session`, `files`→`tokens`).
///
/// Design choice: a declared SHA-256 that does not match the received bytes is
/// a hard failure — the server deletes the file and replies `400` (see
/// `PeerServer`).
library;

import 'constants.dart';
import 'device_info.dart';

// --- Shared frame codec (docs/13 §1) ---------------------------------------

/// Wraps [body] into a full wire frame of type [type] at [kFrameVersion].
///
/// Every JSON frame body carries `v` (version) and `t` (type); the `put`
/// request body is raw bytes and is identified by its path instead.
Map<String, dynamic> encodeFrame(String type, Map<String, dynamic> body) =>
    <String, dynamic>{'v': kFrameVersion, 't': type, ...body};

/// Validates the frame header of [json] and returns its `t` value.
///
/// Throws a [FormatException] when `v` is missing or not [kFrameVersion], or
/// `t` is missing / not a non-empty string. Whether a *known* `t` is required is
/// the caller's decision; this only guarantees the header is well-formed.
String requireFrameType(Map<String, dynamic> json) {
  final version = json['v'];
  if (version is! num || version.toInt() != kFrameVersion) {
    throw FormatException(
      'unsupported frame version: $version (want $kFrameVersion)',
    );
  }
  final type = json['t'];
  if (type is! String || type.isEmpty) {
    throw const FormatException('frame is missing a non-empty "t"');
  }
  return type;
}

/// Asserts that [json] is a well-formed frame of exactly the [expected] type.
void requireFrameTypeIs(Map<String, dynamic> json, String expected) {
  final actual = requireFrameType(json);
  if (actual != expected) {
    throw FormatException('expected frame "$expected", got "$actual"');
  }
}

/// Extracts the `peer` object of [json] as a [DeviceInfo].
///
/// Throws a [FormatException] when `peer` is missing or not an object.
DeviceInfo peerOf(Map<String, dynamic> json) {
  final peer = json['peer'];
  if (peer is! Map) {
    throw const FormatException('frame is missing an object "peer"');
  }
  return DeviceInfo.fromJson(Map<String, dynamic>.from(peer));
}

// --- Transfer payloads ------------------------------------------------------

/// The optional `folder` object of a `prepare` frame: "these N files are one
/// folder" (`docs/22` §1.1).
///
/// It carries **no** per-file information — the hierarchy lives in each
/// [FileMetadata.relativePath], and the folder's own name appears exactly once,
/// here. A frame without this object is the pre-0.2.38 shape and is still fully
/// valid: N unrelated files.
class FolderDescriptor {
  const FolderDescriptor({required this.name, required this.count});

  /// Folder display name. A **single** segment: the receiver sanitises it with
  /// `sanitizeFileName` (see `security/relative_path.dart`), so a value
  /// containing `/` collapses to its last component rather than creating
  /// nesting.
  final String name;

  /// How many files the sender *declared* for this folder.
  ///
  /// Deliberately not trusted as the received count: files may be refused or a
  /// link may drop mid-batch, and the honest received count is the number of
  /// `files` rows that actually landed (`docs/22` §2.5).
  final int count;

  /// Parses the wire shape leniently: a missing `name` becomes `''` and a
  /// missing `count` becomes `0`, both of which the receiver treats as "nothing
  /// usable was declared" rather than as a parse failure — an added optional
  /// key must never be able to make an otherwise readable frame unreadable
  /// (`docs/22` §1.2).
  factory FolderDescriptor.fromJson(Map<String, dynamic> json) =>
      FolderDescriptor(
        name: (json['name'] as String?) ?? '',
        count: (json['count'] as num?)?.toInt() ?? 0,
      );

  /// Serialises to the exact wire shape.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'count': count,
      };

  @override
  String toString() => 'FolderDescriptor(name: $name, count: $count)';
}

/// Metadata describing a single file in a `prepare` frame.
class FileMetadata {
  const FileMetadata({
    required this.id,
    required this.fileName,
    required this.size,
    this.fileType,
    this.sha256,
    this.preview,
    this.offset = 0,
    this.relativePath,
  });

  /// Sender-generated identifier, unique within a session.
  final String id;

  /// Original file name supplied by the sender (untrusted — sanitise it);
  /// wire key `name`.
  final String fileName;

  /// Exact byte length of the file, or a negative value when the sender did not
  /// state one.
  final int size;

  /// MIME type, or `null` when the sender did not state one; wire key `mime`.
  ///
  /// Deliberately nullable (docs/13 §7.2): no forced
  /// `application/octet-stream` default on the wire — a missing MIME means
  /// "unknown", not "binary".
  final String? fileType;

  /// Uppercase hex SHA-256 of the file contents, optional.
  final String? sha256;

  /// Base64 encoded thumbnail, optional; wire key `thumb`.
  final String? preview;

  /// Resume start offset in bytes (`0` for a fresh upload). Reserved — see
  /// docs/13 §3; V1 never sends a non-zero value.
  final int offset;

  /// Path of this file **relative to the folder root**, `/` separated, without
  /// the folder name and without a leading `/`; wire key `path`.
  ///
  /// `null` means "flat" — either the sender had no folder at all or it is a
  /// pre-0.2.38 peer. The receiver never trusts this value: it runs it through
  /// `normalizeRelativePath` before it reaches a `File` (`docs/22` §4.3), and
  /// `path` is deliberately *not* folded into [fileName], which the whole
  /// product treats as a single segment.
  ///
  /// **Senders: put the plain string in, do not `Uri.encodeComponent` it.**
  /// It travels in the JSON body (judgement 18), which does its own escaping;
  /// percent-encoding it here would be a second, undecoded layer — the receiver
  /// does not decode by design, so `a b.bin` would arrive as a file literally
  /// called `a%20b.bin`.
  final String? relativePath;

  /// Builds a [FileMetadata] from decoded JSON.
  ///
  /// Every field is optional and falls back to a sane default, so a truncated
  /// or partially-understood payload never throws. The `-1` size default means
  /// "unknown", which the upload handler treats as "do not enforce".
  ///
  /// Unknown keys are **left alone on purpose**: this is a hand-written
  /// per-key reader, not a schema validator, and an added optional key must not
  /// be able to make an otherwise readable frame unreadable (`docs/22` §1.2 —
  /// turning this into a strict parser would break both upgrade directions).
  factory FileMetadata.fromJson(Map<String, dynamic> json) {
    return FileMetadata(
      id: (json['id'] as String?) ?? '',
      fileName: (json['name'] as String?) ?? 'unnamed',
      size: (json['size'] as num?)?.toInt() ?? -1,
      fileType: json['mime'] as String?,
      sha256: json['sha256'] as String?,
      preview: json['thumb'] as String?,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
      relativePath: json['path'] as String?,
    );
  }

  /// Serialises to the exact wire JSON shape.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': fileName,
        'size': size,
        if (fileType != null) 'mime': fileType,
        if (sha256 != null) 'sha256': sha256,
        if (preview != null) 'thumb': preview,
        'offset': offset,
        if (relativePath != null) 'path': relativePath,
      };

  /// Returns a copy with the given fields replaced.
  ///
  /// A `null` argument means "keep the current value" (this class cannot clear
  /// an optional field); the server therefore keeps a normalised relative path
  /// on its own per-file record instead of trying to write `null` back here.
  FileMetadata copyWith({
    String? id,
    String? fileName,
    int? size,
    String? fileType,
    String? sha256,
    String? preview,
    int? offset,
    String? relativePath,
  }) {
    return FileMetadata(
      id: id ?? this.id,
      fileName: fileName ?? this.fileName,
      size: size ?? this.size,
      fileType: fileType ?? this.fileType,
      sha256: sha256 ?? this.sha256,
      preview: preview ?? this.preview,
      offset: offset ?? this.offset,
      relativePath: relativePath ?? this.relativePath,
    );
  }

  @override
  String toString() =>
      'FileMetadata(id: $id, name: $fileName, size: $size, type: $fileType, '
      'path: $relativePath)';
}

/// The decoded body of a `prepare` frame:
/// `{v, t:"prepare", peer:<DeviceInfo>, files:{fileId:<FileMetadata>}, folder?,
/// pin?}`.
class PrepareUploadRequest {
  const PrepareUploadRequest({
    required this.info,
    required this.files,
    this.pin,
    this.folder,
  });

  /// The sender, so the receiver can attribute the transfer; wire key `peer`.
  final DeviceInfo info;

  /// The declared files, keyed by file id.
  final Map<String, FileMetadata> files;

  /// Optional pairing code (the M6 short-code, unused in M2).
  final String? pin;

  /// The folder these files belong to, or `null` for the pre-0.2.38 shape.
  ///
  /// One folder message is still exactly "one `prepare` + N `put`s": the
  /// session, tokens, size limits and identity checks that already work need no
  /// new frame type or endpoint (`docs/22` §1.4).
  final FolderDescriptor? folder;

  /// Parses the wire shape (ignoring the frame header).
  ///
  /// Throws a [FormatException] when `peer` or `files` is missing or not an
  /// object, or when any file entry is not an object, so the server can map that
  /// to a `400 Bad Request`. Nothing else is validated here — in particular an
  /// unknown top-level key or an unknown per-file key is ignored, never
  /// rejected.
  factory PrepareUploadRequest.fromJson(Map<String, dynamic> json) {
    final infoJson = json['peer'];
    final filesJson = json['files'];
    if (infoJson is! Map || filesJson is! Map) {
      throw const FormatException(
        'prepare requires an object "peer" and an object "files"',
      );
    }
    final files = <String, FileMetadata>{};
    for (final entry in filesJson.entries) {
      final value = entry.value;
      if (value is! Map) {
        throw FormatException('file entry "${entry.key}" is not an object');
      }
      final meta = FileMetadata.fromJson(Map<String, dynamic>.from(value));
      // The map key is the file id of record; a missing/blank `id` inside the
      // value falls back to the key (matching the reference implementation).
      final id = meta.id.isNotEmpty ? meta.id : entry.key.toString();
      files[id] = id == meta.id ? meta : meta.copyWith(id: id);
    }
    final folderJson = json['folder'];
    return PrepareUploadRequest(
      info: DeviceInfo.fromJson(Map<String, dynamic>.from(infoJson)),
      files: files,
      pin: json['pin'] as String?,
      // A `folder` that is not an object is ignored rather than fatal, for the
      // same reason as the unknown-key rule: the files themselves are still
      // perfectly deliverable, and refusing them would be a compatibility
      // regression against a future peer.
      folder: folderJson is Map
          ? FolderDescriptor.fromJson(Map<String, dynamic>.from(folderJson))
          : null,
    );
  }

  /// Serialises to the exact wire frame (header included).
  Map<String, dynamic> toJson() => encodeFrame(kFramePrepare, <String, dynamic>{
        'peer': info.toJson(),
        'files': <String, dynamic>{
          for (final entry in files.entries) entry.key: entry.value.toJson(),
        },
        if (pin != null) 'pin': pin,
        if (folder != null) 'folder': folder!.toJson(),
      });

  @override
  String toString() => 'PrepareUploadRequest(from: ${info.alias}, '
      'files: ${files.length}, pin: ${pin == null ? 'none' : 'set'}, '
      'folder: ${folder?.name ?? 'none'})';
}

/// Result of a successful `prepare` call: the session id, a
/// `fileId -> upload token` map, and the bytes the receiver already holds.
class PrepareUploadResponse {
  const PrepareUploadResponse({
    required this.sessionId,
    required this.files,
    this.received = const <String, int>{},
  });

  /// Empty when the server replied `204` (nothing to upload); wire key
  /// `session`.
  final String sessionId;

  /// Maps `fileId` → upload `token`; wire key `tokens`.
  final Map<String, String> files;

  /// Maps `fileId` → bytes already received (resume support, docs/13 §3).
  final Map<String, int> received;

  /// True when the server had no files to accept.
  bool get isEmpty => sessionId.isEmpty;

  /// Builds a [PrepareUploadResponse] from the decoded wire shape.
  factory PrepareUploadResponse.fromJson(Map<String, dynamic> json) {
    final rawFiles = json['tokens'];
    final rawReceived = json['received'];
    return PrepareUploadResponse(
      sessionId: (json['session'] as String?) ?? '',
      files: <String, String>{
        if (rawFiles is Map)
          for (final entry in rawFiles.entries)
            entry.key.toString(): entry.value.toString(),
      },
      received: <String, int>{
        if (rawReceived is Map)
          for (final entry in rawReceived.entries)
            entry.key.toString(): (entry.value as num?)?.toInt() ?? 0,
      },
    );
  }

  /// Serialises to the exact wire frame (header included).
  Map<String, dynamic> toJson() =>
      encodeFrame(kFramePrepareReply, <String, dynamic>{
        'session': sessionId,
        'tokens': files,
        'received': received,
      });

  @override
  String toString() =>
      'PrepareUploadResponse(sessionId: $sessionId, files: ${files.length})';
}

/// A native text message frame (`POST /text`).
class TextMessage {
  const TextMessage({
    required this.peer,
    required this.id,
    required this.text,
  });

  /// The sender, so the receiver can attribute the message; wire key `peer`.
  final DeviceInfo peer;

  /// Sender-generated string nonce; used by the receiver for idempotent
  /// de-duplication (the `event_nonce` uniqueness key).
  final String id;

  /// The message body; carried directly in the frame (no `.txt` disguise).
  final String text;

  /// Parses the wire shape (ignoring the frame header).
  factory TextMessage.fromJson(Map<String, dynamic> json) => TextMessage(
        peer: peerOf(json),
        id: (json['id'] as String?) ?? '',
        text: (json['text'] as String?) ?? '',
      );

  /// Serialises to the exact wire frame (header included).
  Map<String, dynamic> toJson() => encodeFrame(kFrameText, <String, dynamic>{
        'peer': peer.toJson(),
        'id': id,
        'text': text,
      });

  @override
  String toString() =>
      'TextMessage(from: ${peer.alias}, id: $id, ${text.length} chars)';
}

/// Record describing a file that finished uploading (and, under this design,
/// verified).
class ReceivedFile {
  const ReceivedFile({
    required this.fileId,
    required this.fileName,
    required this.savedPath,
    required this.size,
    required this.sha256,
    this.sha256Matched = true,
    this.sender,
    this.sessionId = '',
    this.folderName,
    this.folderFiles = 0,
    this.relativePath,
  });

  /// Sender-assigned file id.
  final String fileId;

  /// Sanitised file name that was actually written.
  ///
  /// A single segment even inside a folder: the directories live in
  /// [relativePath], never here.
  final String fileName;

  /// Absolute path on disk where the file was written.
  final String savedPath;

  /// Number of bytes received.
  final int size;

  /// Uppercase hex SHA-256 computed while streaming.
  final String sha256;

  /// Whether [sha256] matched the value declared in `prepare`.
  ///
  /// `true` when the sender declared no hash, **and** — under this project's
  /// design — always `true` on the success path, because a declared mismatch is
  /// rejected (file deleted + `400`) before a [ReceivedFile] is ever produced.
  final bool sha256Matched;

  /// The peer that sent the file, if known.
  final DeviceInfo? sender;

  /// The `prepare` session this file arrived in; empty when unknown.
  ///
  /// The receiver mints it (`PeerServer`), so it is unique per batch even when
  /// the same folder is sent three times a day. The store uses it as the
  /// aggregation key that turns N arrivals back into **one** folder message
  /// (`docs/22` §4.2) — which is why it is carried here instead of adding a
  /// "session started" callback.
  final String sessionId;

  /// Display name of the folder this file belongs to, or `null` when the sender
  /// declared none (a plain, flat transfer).
  final String? folderName;

  /// How many files the sender declared for [folderName]; `0` when this is not
  /// a folder transfer.
  final int folderFiles;

  /// Path of the file **as it was actually written**, relative to the folder
  /// root, `/` separated, excluding [folderName]; `null` for a flat transfer.
  ///
  /// This is the post-`resolveUniqueFile` value, so it already carries every
  /// adjustment the receiver makes to a name (`docs/22` §4.3a):
  ///
  ///  * a duplicate that landed as `x (1).dll` records `x (1).dll`;
  ///  * a Windows reserved segment (`nul/x.bin`) records `_nul/x.bin` — the
  ///    rename applies to **directories** too, not only to the file name.
  ///
  /// **Use this to find the file; never rebuild the path from the frame.**
  /// The name on disk is deliberately not always the name on the wire, so
  /// joining `folderName + FileMetadata.relativePath` yourself would open a
  /// path that does not exist. Recording the requested name instead of the
  /// actual one was the bug this field exists to prevent (`docs/22` §4.3).
  final String? relativePath;

  @override
  String toString() => 'ReceivedFile(fileId: $fileId, name: $fileName, '
      'bytes: $size, sha256: $sha256, matched: $sha256Matched, '
      'session: $sessionId, folder: $folderName, path: $relativePath)';
}
