/// Pure derivation helpers for the M4 UI (spec §1.3 "纯选择器", §4.2, §4.3).
///
/// **Layering (M4 §8.1):** this file is pure Dart — it imports only
/// `domain/models.dart`, so it compiles on Web and is unit-testable without
/// Flutter. Every function here is side-effect free and deterministic: given the
/// same inputs it always returns the same output and never mutates its
/// arguments.
///
/// Two derivation problems live here:
/// - [mergeDeviceCards] — the home screen's **single** device view, merging the
///   live discovery list with stored conversations/devices (§4.2, P0-2).
/// - [buildRecentFiles] (+ [groupByLocalDay], [filterByQuery], [matchesKind]) —
///   the recent-files list and its grouping/classification/search (§4.3).
///
/// The single extension-classification table ([kFileClassByExtension] → the fine
/// [FileClass]) lives here rather than in `ui/format.dart` **because
/// `domain/**` may not import `ui/**`** (§8.1). Both the **icon** category
/// ([FileCategory]) and the recent-files **tab** filter ([matchesKind]) are
/// **derived** from it, so the two views can never drift apart.
library;

import 'models.dart';

// ─────────────────────────────────────────────────────────────────────────
// File classification (mime first, extension fallback — §8.4 / E8)
// ─────────────────────────────────────────────────────────────────────────

/// The **fine**, user-facing classification of a file — the single one this app
/// derives everything else from.
///
/// It drives the recent-files tabs ([FileKind]) through [matchesKind], and the
/// coarser icon category ([FileCategory]) is projected from it by
/// [_iconCategory], so there is exactly **one** extension table
/// ([kFileClassByExtension]) and the two views cannot diverge.
///
/// - [image] / [video] / [audio] — the media groups (`image/*` etc. when the
///   mime says so, else the extension).
/// - [installer] — runnable packages / disk images (`apk` / `exe` / `msi` /
///   `dmg` / `iso` / `deb` / `rpm`).
/// - [archive] — compressed containers (`zip` / `rar` / `7z` / `gz` / `tar` /
///   `bz2` / `xz` / `zst`).
/// - [document] — every other **known** extension (documents, source code,
///   markup, config, …).
/// - [other] — an **unknown** extension, or no extension at all.
enum FileClass {
  /// Image content.
  image,

  /// Video content.
  video,

  /// Audio content.
  audio,

  /// A runnable package / disk image.
  installer,

  /// A compressed archive / container.
  archive,

  /// A known non-media, non-archive, non-installer file.
  document,

  /// Unknown / no extension.
  other,
}

/// The **coarse, display-oriented** category that picks a type **icon**.
///
/// Frozen to four values because `ui/format.dart::fileTypeIcon` switches over it
/// exhaustively; it is **derived** from [FileClass] (via [_iconCategory]) rather
/// than being a second hand-maintained table. `ui/format.dart` reuses it so the
/// icon stays stable as the finer [FileClass] split grows.
enum FileCategory {
  /// Image content (`image/*`, or an image extension when mime is absent).
  image,

  /// Video content (`video/*`, or a video extension when mime is absent).
  video,

  /// A recognised non-media file — the icon shown for documents, source code,
  /// audio, archives and installers alike.
  file,

  /// Unknown / no extension — nothing could be inferred.
  other,
}

/// The **single** extension → [FileClass] table (lower-case, without the dot).
///
/// Anything absent from this table falls back to [FileClass.other]. The icon
/// category ([categorizeFile]) and the tab filter ([matchesKind]) are both
/// derived from this one table, so they can never diverge.
const Map<String, FileClass> kFileClassByExtension = <String, FileClass>{
  // images
  'jpg': FileClass.image,
  'jpeg': FileClass.image,
  'jfif': FileClass.image,
  'png': FileClass.image,
  'gif': FileClass.image,
  'bmp': FileClass.image,
  'webp': FileClass.image,
  'heic': FileClass.image,
  'heif': FileClass.image,
  'avif': FileClass.image,
  'tif': FileClass.image,
  'tiff': FileClass.image,
  'svg': FileClass.image,
  'ico': FileClass.image,
  'apng': FileClass.image,
  // video
  'mp4': FileClass.video,
  'm4v': FileClass.video,
  'mov': FileClass.video,
  'mkv': FileClass.video,
  'avi': FileClass.video,
  'webm': FileClass.video,
  'wmv': FileClass.video,
  'flv': FileClass.video,
  'mpg': FileClass.video,
  'mpeg': FileClass.video,
  'mpe': FileClass.video,
  '3gp': FileClass.video,
  '3g2': FileClass.video,
  'ogv': FileClass.video,
  'ts': FileClass.video,
  'm2ts': FileClass.video,
  // audio
  'mp3': FileClass.audio,
  'wav': FileClass.audio,
  'flac': FileClass.audio,
  'aac': FileClass.audio,
  'ogg': FileClass.audio,
  'oga': FileClass.audio,
  'm4a': FileClass.audio,
  'opus': FileClass.audio,
  'wma': FileClass.audio,
  'mid': FileClass.audio,
  'midi': FileClass.audio,
  // installers / disk images
  'apk': FileClass.installer,
  'exe': FileClass.installer,
  'msi': FileClass.installer,
  'dmg': FileClass.installer,
  'iso': FileClass.installer,
  'deb': FileClass.installer,
  'rpm': FileClass.installer,
  // archives / compressed containers
  'zip': FileClass.archive,
  'rar': FileClass.archive,
  '7z': FileClass.archive,
  'gz': FileClass.archive,
  'tar': FileClass.archive,
  'bz2': FileClass.archive,
  'xz': FileClass.archive,
  'zst': FileClass.archive,
  // documents / source / markup / config
  'pdf': FileClass.document,
  'txt': FileClass.document,
  'md': FileClass.document,
  'markdown': FileClass.document,
  'rtf': FileClass.document,
  'doc': FileClass.document,
  'docx': FileClass.document,
  'odt': FileClass.document,
  'xls': FileClass.document,
  'xlsx': FileClass.document,
  'ods': FileClass.document,
  'csv': FileClass.document,
  'tsv': FileClass.document,
  'ppt': FileClass.document,
  'pptx': FileClass.document,
  'odp': FileClass.document,
  'json': FileClass.document,
  'xml': FileClass.document,
  'yaml': FileClass.document,
  'yml': FileClass.document,
  'html': FileClass.document,
  'htm': FileClass.document,
  'css': FileClass.document,
  'js': FileClass.document,
  'mjs': FileClass.document,
  'tsx': FileClass.document,
  'dart': FileClass.document,
  'py': FileClass.document,
  'java': FileClass.document,
  'c': FileClass.document,
  'cpp': FileClass.document,
  'h': FileClass.document,
  'sh': FileClass.document,
};

/// The lower-cased extension of [fileName] **without** the dot, or `''` when the
/// name has none.
///
/// A leading dot (a dot-file such as `.gitignore`) is treated as "no
/// extension", and a trailing dot is ignored.
String fileExtension(String fileName) {
  final int dot = fileName.lastIndexOf('.');
  if (dot <= 0 || dot == fileName.length - 1) {
    return '';
  }
  return fileName.substring(dot + 1).toLowerCase();
}

/// The **fine** classification of a file into a [FileClass] — the single source
/// the tab filter and the icon category are both derived from.
///
/// A usable, specific [mime] wins (`image/*` / `video/*` / `audio/*` map to
/// their class, any other specific non-media type to [FileClass.document]);
/// otherwise the extension of [fileName] is used (E8). An
/// `application/octet-stream` mime is treated as "unknown" and falls back to the
/// extension.
FileClass classifyFile(String fileName, {String? mime}) {
  final String normalizedMime = (mime ?? '').trim().toLowerCase();
  if (normalizedMime.isNotEmpty &&
      normalizedMime != 'application/octet-stream') {
    if (normalizedMime.startsWith('image/')) {
      return FileClass.image;
    }
    if (normalizedMime.startsWith('video/')) {
      return FileClass.video;
    }
    if (normalizedMime.startsWith('audio/')) {
      return FileClass.audio;
    }
    return FileClass.document;
  }

  final String extension = fileExtension(fileName);
  if (extension.isEmpty) {
    return FileClass.other;
  }
  return kFileClassByExtension[extension] ?? FileClass.other;
}

/// The coarse [FileCategory] (icon grouping) for [fileName] (§8.4).
///
/// Derived from [classifyFile] via [_iconCategory], so a document, a source
/// file, an audio clip, an archive and an installer all share the generic
/// "file" icon while the fine [FileClass] still distinguishes them for the tabs.
FileCategory categorizeFile(String fileName, {String? mime}) =>
    _iconCategory(classifyFile(fileName, mime: mime));

/// Projects the fine [FileClass] onto the frozen four-value [FileCategory] —
/// the icon grouping consumed by `ui/format.dart::fileTypeIcon`.
FileCategory _iconCategory(FileClass category) => switch (category) {
      FileClass.image => FileCategory.image,
      FileClass.video => FileCategory.video,
      FileClass.audio => FileCategory.file,
      FileClass.installer => FileCategory.file,
      FileClass.archive => FileCategory.file,
      FileClass.document => FileCategory.file,
      FileClass.other => FileCategory.other,
    };

// ─────────────────────────────────────────────────────────────────────────
// Recent files (§4.3)
// ─────────────────────────────────────────────────────────────────────────

/// One row of the recent-files page: a file plus the context it was sent in.
///
/// Produced by [buildRecentFiles]. [sourceMissing] is computed from the
/// caller-supplied `isOnDisk` predicate (the async disk probe is done by the
/// controller — this type and its builder are pure).
class RecentFileItem {
  /// Creates a recent-file row.
  const RecentFileItem({
    required this.file,
    required this.messageId,
    required this.messageCreatedAt,
    required this.conversationId,
    required this.deviceFingerprint,
    required this.direction,
    required this.sourceMissing,
  });

  /// The attachment itself.
  final FileAttachment file;

  /// The id of the message this row was joined to — the row's context.
  ///
  /// It is the message `buildRecentFiles` joined the attachment to (the same id
  /// as [FileAttachment.messageId]). The middle pane passes it back through
  /// `ShellController.selectRecentFile` so the right pane can resolve the file
  /// detail's owning message — the UI cannot derive it on its own.
  final String messageId;

  /// When the owning message was created (local time is applied at render time).
  final DateTime messageCreatedAt;

  /// The owning conversation id.
  final String conversationId;

  /// The counterparty fingerprint, or `null` for a history-only conversation.
  final String? deviceFingerprint;

  /// Whether the file was received or sent.
  final MessageDirection direction;

  /// Whether the file's original location no longer exists on disk.
  ///
  /// Only meaningful when [FileAttachment.localPath] is known: a `null` path is
  /// left as `false` (undetermined) rather than being reported as missing.
  final bool sourceMissing;

  @override
  bool operator ==(Object other) =>
      other is RecentFileItem &&
      other.file == file &&
      other.messageId == messageId &&
      other.messageCreatedAt == messageCreatedAt &&
      other.conversationId == conversationId &&
      other.deviceFingerprint == deviceFingerprint &&
      other.direction == direction &&
      other.sourceMissing == sourceMissing;

  @override
  int get hashCode => Object.hash(file, messageId, messageCreatedAt,
      conversationId, deviceFingerprint, direction, sourceMissing);

  @override
  String toString() => 'RecentFileItem(${file.fileName}, '
      'conv: $conversationId, missing: $sourceMissing)';
}

/// Flattens conversations → messages → files into the recent-files list (§4.3).
///
/// **Pure and data-in:** the caller (a controller) performs the repository
/// traversal (`conversations(includeArchived: true)` → `history()` →
/// `filesOf()`), the async existence probe, and passes the flat inputs here.
/// The existence input is the synchronous predicate [isOnDisk] — the port's
/// `exists` stays async and is resolved by the controller before this call.
///
/// Join rules (frozen):
/// - an attachment whose `messageId` matches no message is **dropped** (its
///   `createdAt`/`direction` would be unknown, and both are non-null on
///   [RecentFileItem]);
/// - a message whose `conversationId` matches no conversation is **kept**:
///   [RecentFileItem.conversationId] comes from the message itself, and
///   [RecentFileItem.deviceFingerprint] is then `null`;
/// - only messages that carry at least one attachment produce rows.
///
/// The result is sorted by [RecentFileItem.messageCreatedAt] **descending**
/// (ties broken by file name then file id, so the order is deterministic).
List<RecentFileItem> buildRecentFiles({
  required List<Conversation> conversations,
  required List<ChatMessage> messages,
  required List<FileAttachment> files,
  required bool Function(String path) isOnDisk,
}) {
  final Map<String, String?> fingerprintByConversation = <String, String?>{
    for (final Conversation conversation in conversations)
      conversation.id: conversation.deviceFingerprint,
  };

  final Map<String, ChatMessage> messageById = <String, ChatMessage>{
    for (final ChatMessage message in messages) message.id: message,
  };

  final Map<String, List<FileAttachment>> filesByMessage =
      <String, List<FileAttachment>>{};
  for (final FileAttachment file in files) {
    (filesByMessage[file.messageId] ??= <FileAttachment>[]).add(file);
  }

  final List<RecentFileItem> items = <RecentFileItem>[];
  for (final MapEntry<String, List<FileAttachment>> entry
      in filesByMessage.entries) {
    final ChatMessage? message = messageById[entry.key];
    if (message == null) {
      continue;
    }
    final String? fingerprint =
        fingerprintByConversation[message.conversationId];
    for (final FileAttachment file in entry.value) {
      final String? path = file.localPath;
      items.add(
        RecentFileItem(
          file: file,
          messageId: message.id,
          messageCreatedAt: message.createdAt,
          conversationId: message.conversationId,
          deviceFingerprint: fingerprint,
          direction: message.direction,
          sourceMissing: path != null && !isOnDisk(path),
        ),
      );
    }
  }

  items.sort(_compareRecentDesc);
  return items;
}

/// Groups [items] by their **local** calendar day (§4.3).
///
/// The map key is `yyyy-MM-dd` (see [localDateKey]); keys are inserted in
/// **descending** date order and each group is sorted by
/// [RecentFileItem.messageCreatedAt] descending. The number of items in a group
/// header is `group.length`.
Map<String, List<RecentFileItem>> groupByLocalDay(
  List<RecentFileItem> items,
) {
  final Map<String, List<RecentFileItem>> groups =
      <String, List<RecentFileItem>>{};
  for (final RecentFileItem item in items) {
    (groups[localDateKey(item.messageCreatedAt)] ??= <RecentFileItem>[])
        .add(item);
  }
  for (final List<RecentFileItem> group in groups.values) {
    group.sort(_compareRecentDesc);
  }
  final List<String> descendingKeys = groups.keys.toList()
    ..sort((String a, String b) => b.compareTo(a));
  return <String, List<RecentFileItem>>{
    for (final String key in descendingKeys) key: groups[key]!,
  };
}

/// Formats [instant] as `yyyy-MM-dd` in the device's **local** time zone.
///
/// Local (not UTC) because the day boundary a user sees is local (§8.3). The
/// zero-padded form makes lexicographic order equal chronological order.
String localDateKey(DateTime instant) {
  final DateTime local = instant.toLocal();
  final String year = local.year.toString().padLeft(4, '0');
  final String month = local.month.toString().padLeft(2, '0');
  final String day = local.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

/// Returns the items whose file name contains [query], case-insensitively.
///
/// A blank [query] returns a copy of [items] unchanged. The input list is never
/// mutated.
List<RecentFileItem> filterByQuery(List<RecentFileItem> items, String query) {
  final String needle = query.trim().toLowerCase();
  if (needle.isEmpty) {
    return List<RecentFileItem>.of(items);
  }
  return <RecentFileItem>[
    for (final RecentFileItem item in items)
      if (item.file.fileName.toLowerCase().contains(needle)) item,
  ];
}

/// Whether [item] matches the recent-files tab [kind].
///
/// Uses the same fine classification as [classifyFile] (mime first, extension
/// fallback), so the tab filter and the icon category never diverge.
/// [FileKind.any] matches everything.
bool matchesKind(RecentFileItem item, FileKind kind) {
  final FileClass category =
      classifyFile(item.file.fileName, mime: item.file.mime);
  return switch (kind) {
    FileKind.any => true,
    FileKind.image => category == FileClass.image,
    FileKind.video => category == FileClass.video,
    FileKind.audio => category == FileClass.audio,
    FileKind.installer => category == FileClass.installer,
    FileKind.archive => category == FileClass.archive,
    FileKind.document => category == FileClass.document,
  };
}

// ─────────────────────────────────────────────────────────────────────────
// Conversation files (§3.4-⑤ / §4 — the per-conversation file tab)
// ─────────────────────────────────────────────────────────────────────────

/// One row of the per-conversation file list: an attachment plus the context
/// of the message it belongs to (PRD §3.4-⑤ / design §4).
///
/// Produced by [buildConversationFiles]. Unlike [RecentFileItem] it carries
/// **no `sourceMissing`** flag: the right-rail "files" tab does not probe the
/// disk (PRD §3.4-⑤, Q4) — that behaviour belongs to [buildRecentFiles] alone.
///
/// Classification is **not** stored on the item: callers reuse
/// `classifyFile(file.fileName, mime: file.mime)` so there is exactly one
/// extension table (PRD §3.4-⑤ / design §4).
class ConversationFileItem {
  /// Creates a conversation-file row.
  const ConversationFileItem({
    required this.file,
    required this.messageId,
    required this.messageCreatedAt,
    required this.direction,
  });

  /// The attachment itself.
  final FileAttachment file;

  /// The owning message.
  final String messageId;

  /// When the owning message was created (local time is applied at render time).
  final DateTime messageCreatedAt;

  /// Whether the file was received or sent.
  final MessageDirection direction;

  @override
  bool operator ==(Object other) =>
      other is ConversationFileItem &&
      other.file == file &&
      other.messageId == messageId &&
      other.messageCreatedAt == messageCreatedAt &&
      other.direction == direction;

  @override
  int get hashCode => Object.hash(file, messageId, messageCreatedAt, direction);

  @override
  String toString() => 'ConversationFileItem(${file.fileName}, '
      'msg: $messageId, ${direction.wire})';
}

/// Flattens [messages] × [filesByMessage] into the per-conversation file list
/// (PRD §3.4-⑤ / design §4).
///
/// **Pure and data-in:** it does not query the repository, read the clock or
/// mutate its arguments. [messages] may be in any order (indexed by id);
/// [filesByMessage] maps `messageId → attachments`.
///
/// Rules (frozen):
/// - **Orphans dropped:** an attachment whose `messageId` is not in [messages]
///   is discarded — its `createdAt`/`direction` would be unknown, and both are
///   non-null on [ConversationFileItem].
/// - **A message may carry many files** (outgoing); inbound is 1 file = 1
///   message in M3 and needs no special case.
/// - **Order:** `messageCreatedAt` descending, then `fileName`, then `file.id`
///   — the **same comparator** [buildRecentFiles] uses ([_compareByRecencyDesc]),
///   so the two lists never disagree on ties (PRD §3.4-⑤, hard requirement).
/// - **No `isOnDisk`:** the right-rail "files" tab does not probe existence.
List<ConversationFileItem> buildConversationFiles({
  required List<ChatMessage> messages,
  required Map<String, List<FileAttachment>> filesByMessage,
}) {
  final Map<String, ChatMessage> messageById = <String, ChatMessage>{
    for (final ChatMessage message in messages) message.id: message,
  };

  final List<ConversationFileItem> items = <ConversationFileItem>[];
  for (final MapEntry<String, List<FileAttachment>> entry
      in filesByMessage.entries) {
    final ChatMessage? message = messageById[entry.key];
    if (message == null) {
      continue;
    }
    for (final FileAttachment file in entry.value) {
      items.add(
        ConversationFileItem(
          file: file,
          messageId: message.id,
          messageCreatedAt: message.createdAt,
          direction: message.direction,
        ),
      );
    }
  }

  items.sort(
    (ConversationFileItem a, ConversationFileItem b) => _compareByRecencyDesc(
      aAt: a.messageCreatedAt,
      aName: a.file.fileName,
      aId: a.file.id,
      bAt: b.messageCreatedAt,
      bName: b.file.fileName,
      bId: b.file.id,
    ),
  );
  return items;
}

// ─────────────────────────────────────────────────────────────────────────
// Home device cards (§4.2, P0-2)
// ─────────────────────────────────────────────────────────────────────────

/// Merges the live discovery list with stored conversations + devices into the
/// home screen's **single** device view (§4.2, P0-2).
///
/// The merge key is the **normalised** fingerprint (upper-case hex, separators
/// stripped). Sources are fed in priority order:
/// 1. stored device rows ([devices]) seed each card's identity;
/// 2. active (non-archived, device-bearing) conversations ([conversations])
///    supply [PeerDevice.conversationId], [PeerDevice.lastPreview] and
///    [PeerDevice.lastActivityAt];
/// 3. live peers ([online]) override the volatile fields (see the conflict
///    table in §4.2): `isOnline`, `alias`, `kind`, `lastPort`, `lastIp`,
///    `lastSeenAt`.
///
/// Conversations with no device (`deviceFingerprint == null`) and archived
/// conversations never reach the home list (Q8). The result is ordered
/// online-first (by `lastSeenAt` descending), then offline (by
/// `lastActivityAt` descending, `null` last) — the caller must **not** re-sort.
List<PeerDevice> mergeDeviceCards({
  required List<DiscoveredPeer> online,
  required List<Conversation> conversations,
  required List<PeerDevice> devices,
}) {
  final Map<String, _CardAcc> cards = <String, _CardAcc>{};

  // 1. Stored device rows (identity baseline).
  for (final PeerDevice device in devices) {
    final String key = normalizeDeviceFingerprint(device.fingerprint);
    if (key.isEmpty) {
      continue;
    }
    cards[key] = _CardAcc(key)
      ..alias = device.alias
      ..kind = device.kind
      ..model = device.model
      ..lastPort = device.lastPort
      ..lastIp = device.lastIp
      ..lastSeenAt = device.lastSeenAt;
  }

  // 2. Active conversations (history fields; also creates cards for a
  //    conversation whose device row is absent).
  for (final Conversation conversation in conversations) {
    if (conversation.isArchived) {
      continue;
    }
    final String? fingerprint = conversation.deviceFingerprint;
    if (fingerprint == null) {
      continue;
    }
    final String key = normalizeDeviceFingerprint(fingerprint);
    if (key.isEmpty) {
      continue;
    }
    final _CardAcc card = cards.putIfAbsent(key, () => _CardAcc(key));
    card.conversationId = conversation.id;
    card.lastPreview = conversation.lastPreview;
    card.lastActivityAt = conversation.lastMessageAt;
  }

  // 3. Live peers override the volatile fields.
  for (final DiscoveredPeer peer in online) {
    final String key = normalizeDeviceFingerprint(peer.fingerprint);
    if (key.isEmpty) {
      continue;
    }
    final _CardAcc card = cards.putIfAbsent(key, () => _CardAcc(key));
    card.isOnline = true;
    card.alias = peer.alias;
    card.kind = peer.kind;
    if (peer.model != null) {
      card.model = peer.model;
    }
    card.lastPort = peer.port;
    card.lastIp = peer.address;
    card.lastSeenAt = peer.lastSeen;
  }

  final List<_CardAcc> onlineCards = <_CardAcc>[
    for (final _CardAcc card in cards.values)
      if (card.isOnline) card,
  ]..sort(
      (_CardAcc a, _CardAcc b) => _byInstantDesc(a.lastSeenAt, b.lastSeenAt));

  final List<_CardAcc> offlineCards = <_CardAcc>[
    for (final _CardAcc card in cards.values)
      if (!card.isOnline) card,
  ]..sort((_CardAcc a, _CardAcc b) =>
      _byInstantDesc(a.lastActivityAt, b.lastActivityAt));

  return <PeerDevice>[
    for (final _CardAcc card in onlineCards) card.toPeerDevice(),
    for (final _CardAcc card in offlineCards) card.toPeerDevice(),
  ];
}

// ─────────────────────────────────────────────────────────────────────────
// Private helpers
// ─────────────────────────────────────────────────────────────────────────

/// Mutable accumulator for one fingerprint while merging (§4.2).
class _CardAcc {
  _CardAcc(this.fingerprint);

  final String fingerprint;
  String alias = '';
  DeviceKind kind = DeviceKind.unknown;
  String? model;
  bool isOnline = false;
  int? lastPort;
  String? lastIp;
  DateTime? lastSeenAt;
  String? lastPreview;
  DateTime? lastActivityAt;
  String? conversationId;

  PeerDevice toPeerDevice() => PeerDevice(
        fingerprint: fingerprint,
        alias: alias,
        kind: kind,
        model: model,
        isOnline: isOnline,
        lastPort: lastPort,
        lastIp: lastIp,
        lastSeenAt: lastSeenAt,
        lastPreview: lastPreview,
        lastActivityAt: lastActivityAt,
        conversationId: conversationId,
      );
}

/// Upper-case hex with every separator removed (M4 merge key / §4.2).
///
/// Public since 0.2.40 so the outbox pump's `drainFor(fingerprint)` uses the
/// **same** key the home screen merges on. A second copy of this rule is how
/// "the peer I was notified about" and "the peer holding the queued message"
/// silently stop being the same peer (a lower-case or colon-separated
/// fingerprint would simply never match).
String normalizeDeviceFingerprint(String raw) =>
    raw.replaceAll(RegExp('[^0-9a-fA-F]'), '').toUpperCase();

/// Descending by instant, `null` sorting last.
int _byInstantDesc(DateTime? a, DateTime? b) {
  if (a == null && b == null) {
    return 0;
  }
  if (a == null) {
    return 1;
  }
  if (b == null) {
    return -1;
  }
  return b.compareTo(a);
}

/// The **single** recency comparator shared by [buildRecentFiles] and
/// [buildConversationFiles]: `messageCreatedAt` descending, then file name
/// ascending, then file id ascending — a deterministic total order for tests
/// and stable rendering.
///
/// Both list builders sort through this one function; using two different
/// strategies would order the same rows differently and make tests
/// non-reproducible (PRD §3.4-⑤, hard requirement).
int _compareByRecencyDesc({
  required DateTime aAt,
  required String aName,
  required String aId,
  required DateTime bAt,
  required String bName,
  required String bId,
}) {
  final int byTime = bAt.compareTo(aAt);
  if (byTime != 0) {
    return byTime;
  }
  final int byName = aName.compareTo(bName);
  if (byName != 0) {
    return byName;
  }
  return aId.compareTo(bId);
}

/// Descending by [RecentFileItem.messageCreatedAt], then name, then id — a
/// deterministic total order for tests and stable rendering.
///
/// Delegates to the shared [_compareByRecencyDesc] so it stays in lock-step
/// with [buildConversationFiles].
int _compareRecentDesc(RecentFileItem a, RecentFileItem b) =>
    _compareByRecencyDesc(
      aAt: a.messageCreatedAt,
      aName: a.file.fileName,
      aId: a.file.id,
      bAt: b.messageCreatedAt,
      bName: b.file.fileName,
      bId: b.file.id,
    );

// ─────────────────────────────────────────────────────────────────────────
// One message, N attachments (0.2.49)
// ─────────────────────────────────────────────────────────────────────────

/// How far along **one message** is, summed over **every** attachment it has.
///
/// A send is a *message* with N attachments, not N messages: a multi-select
/// (「多选了很多视频一次性发送」) is **one** `MessageRecord` plus N
/// `MessageFileRecord`s, and a folder send is the same shape with a declared
/// count on top (`docs/22` §2.5). The bubble therefore has exactly **one**
/// progress line, and that line has to answer about the batch.
///
/// Until 0.2.49 it answered about `files.first` — the file the orchestrator
/// uploads **first**, because `filesOf` is `ORDER BY rowid ASC`, i.e. selection
/// order, i.e. upload order (`transfer_orchestrator.dart` walks the same list
/// serially). The moment that one file completed, the bar read `100 %` and
/// stopped moving while the remaining N−1 files were still uploading: on the
/// user's screen 「在传下一个」 and 「卡死了」 were **the same picture**, which is
/// exactly the report this type exists to fix.
///
/// **This is the single message-level aggregate.** One attachment, a flat
/// multi-select and a folder all take their numbers from here
/// ([summarizeFolder] delegates to it), so there is no third branch that can
/// drift away from the other two. Two of the numbers do not exist per file:
///
/// * [bytesDone] / [bytesTotal] — the sum, i.e. what the bar draws;
/// * [filesDone] / [currentIndex] — how many attachments are home, and **which
///   one is being uploaded now** (1-based; `0` when nothing is in flight). The
///   second is the 「第 k/N 个」 caption: a byte percentage sits still for minutes
///   while one large file trickles in, and a percentage that sits still is
///   indistinguishable from a dead link.
class MessageTransferProgress {
  /// Creates an aggregate from its parts.
  const MessageTransferProgress({
    required this.fileCount,
    required this.filesDone,
    required this.currentIndex,
    required this.bytesDone,
    required this.bytesTotal,
    required this.bar,
  });

  /// Sums [files] up, reading each attachment's transfer row through
  /// [progressOf].
  ///
  /// Pure: the lookup is the caller's, so this is testable without a repository
  /// and without Flutter.
  ///
  /// **Where each number comes from** (none of them is stored):
  /// * `bytesTotal` = Σ `file.size` (`< 0` counts as 0). The **declared size on
  ///   disk**, deliberately not the transfer row's own `bytes_total`: that one is
  ///   `-1` until the peer has accepted the file, so a batch whose second file
  ///   has not started yet would divide by a number that is about to change.
  ///   `file.size` never changes. When the size is unknown the row's total is
  ///   used instead, so a file we know nothing about still contributes.
  /// * `bytesDone` = Σ `bytes_done`, clamped to that attachment's own total, so a
  ///   padded progress value can never push the batch past 100 %.
  /// * `filesDone` = attachments whose row says `bytesDone >= bytesTotal` with a
  ///   **known** total. A *file* that arrived is a fact the receiver can see; the
  ///   batch percentage is an aggregate that lags behind it.
  /// * `error` on [bar] = the **first** error any attachment reports, because a
  ///   failed batch is failed by whichever file failed, not necessarily the first.
  ///
  /// **The one-attachment case is that attachment's row, verbatim** — see [bar].
  factory MessageTransferProgress.of(
    List<FileAttachment> files, {
    required TransferProgress? Function(String fileId) progressOf,
  }) {
    if (files.isEmpty) {
      return none;
    }
    int filesDone = 0;
    int currentIndex = 0;
    int bytesDone = 0;
    int bytesTotal = 0;
    String? error;
    bool anyRow = false;
    // The first attachment's row, kept only for the degenerate one-file case.
    TransferProgress? only;
    for (int i = 0; i < files.length; i += 1) {
      final FileAttachment file = files[i];
      final TransferProgress? row = progressOf(file.id);
      if (row != null) {
        anyRow = true;
        // First non-null wins: file 3 being stalled is the reason a 5-file
        // batch died, whatever file 1 has to say.
        error ??= row.error;
      }
      if (i == 0) {
        only = row;
      }

      final int size = file.size < 0 ? 0 : file.size;
      final int declared = row?.bytesTotal ?? -1;
      final int total = size > 0 ? size : (declared > 0 ? declared : 0);
      bytesTotal += total;

      final int sent = row == null || row.bytesDone < 0 ? 0 : row.bytesDone;
      bytesDone += total > 0 && sent > total ? total : sent;

      final int rowTotal = row?.bytesTotal ?? size;
      if (row != null && rowTotal >= 0 && row.bytesDone >= rowTotal) {
        filesDone += 1;
      } else if (currentIndex == 0) {
        // The first attachment that is **not** home — including one whose row has
        // not been written yet, whose bytes are honestly 0.
        currentIndex = i + 1;
      }
    }

    // ★ A single attachment's aggregate is **not** an average of anything: it is
    // that attachment's own row, returned untouched. That is what makes a one-file
    // bubble impossible to change here — including `bytesTotal == -1` (unknown
    // size: no bar, 「未知大小」) and the row's `error`, which `_failureNote` /
    // `_publishNote` read.
    final TransferProgress? bar = files.length == 1
        ? only
        : (anyRow
            ? TransferProgress(
                fileId: files[currentIndex == 0 ? 0 : currentIndex - 1].id,
                bytesDone: bytesDone,
                bytesTotal: bytesTotal,
                error: error,
              )
            : null);

    return MessageTransferProgress(
      fileCount: files.length,
      filesDone: filesDone,
      currentIndex: currentIndex,
      bytesDone: bytesDone,
      bytesTotal: bytesTotal,
      bar: bar,
    );
  }

  /// The aggregate of **no** attachments — a text message.
  static const MessageTransferProgress none = MessageTransferProgress(
    fileCount: 0,
    filesDone: 0,
    currentIndex: 0,
    bytesDone: 0,
    bytesTotal: 0,
    bar: null,
  );

  /// How many attachments this message has.
  final int fileCount;

  /// How many of them have **fully arrived** (`bytesDone >= bytesTotal`).
  final int filesDone;

  /// Which attachment is being uploaded **now**, 1-based, or `0` when none is
  /// (nothing started yet, or everything is home).
  final int currentIndex;

  /// Bytes transferred, summed over [fileCount].
  final int bytesDone;

  /// Bytes expected, summed over [fileCount].
  final int bytesTotal;

  /// What the bubble's progress line is drawn from — `MessageBubble.progress`.
  ///
  /// `null` when nothing has been recorded yet (no transfer row at all), so a
  /// message with no live transfer draws no bar, exactly as before. For one
  /// attachment this is the store's own [TransferProgress]; for N it is the sum,
  /// carrying the current file's id and the first error.
  final TransferProgress? bar;

  /// Whether this message carries more than one attachment — i.e. whether there
  /// is a batch to number.
  bool get isMultiFile => fileCount > 1;

  /// 「第 k/N 个」 — the caption that says the batch **moved on**, or `null`.
  ///
  /// `null` in the two cases where it would be noise or a lie: a one-attachment
  /// message (there is no batch), and a batch with nothing in flight (every file
  /// home — printing 「第 2/2 个」 then would claim file 2 is still uploading).
  String? get ordinal =>
      isMultiFile && currentIndex > 0 ? '第 $currentIndex/$fileCount 个' : null;

  /// The batch's fraction in `0..1`, or `null` when the total is unknown.
  double? get fraction =>
      bytesTotal > 0 ? (bytesDone / bytesTotal).clamp(0.0, 1.0) : null;

  @override
  String toString() => 'MessageTransferProgress($filesDone/$fileCount files, '
      'current: $currentIndex, $bytesDone/$bytesTotal B)';
}

// ─────────────────────────────────────────────────────────────────────────
// Folder sends (0.2.38 / docs/22 §2.5, §3.4)
// ─────────────────────────────────────────────────────────────────────────

/// How far along **one folder send** is — the numbers on the bubble's card.
///
/// Two counts, deliberately not one ratio: a 200-file folder's byte percentage
/// sits at 97 % for minutes while the last video trickles in, whereas `12/20`
/// moves on every file (the reference app prints `20/20` for the same reason).
class FolderProgress {
  /// Creates a progress snapshot.
  const FolderProgress({
    required this.done,
    required this.total,
    required this.bytesDone,
    required this.bytesTotal,
  });

  /// Files that have **fully arrived** (transfer `bytesDone >= bytesTotal`).
  final int done;

  /// The denominator: the sender's declared count, widened to the number of
  /// rows we actually hold (see [summarizeFolder]).
  final int total;

  /// Bytes received so far, summed over the files we hold.
  final int bytesDone;

  /// Bytes expected, summed over the files we hold (`size < 0` counts as 0).
  final int bytesTotal;
}

/// Derives a [FolderProgress] for one folder message.
///
/// **Where each number comes from** (`docs/22` §2.5 — none of them is stored):
/// * `total` = `max(declaredCount, files.length)`. The declared count is what the
///   sender claims; if we somehow hold more rows than that (a padded or a
///   resumed batch), `files.length` is the honest floor. `declaredCount <= 0`
///   (an old row, or a flat multi-select) falls back to `files.length`, so the
///   card never prints `0` as a denominator.
/// * `done` = the files whose transfer says `bytesDone >= bytesTotal` with
///   `bytesTotal >= 0`. A **file** that arrived is a fact the receiver can see;
///   the message-level percentage is an aggregate that lags behind.
/// * the byte pair is summed over [files] (`bytesTotal` from `file.size`, with
///   `-1` — "unknown" — falling back to the row's own total and otherwise
///   counting as 0; `bytesDone` clamped to that total so a padded progress value
///   cannot exceed 100 %).
///
/// Pure: [progressOf] is the caller's lookup, so this stays testable without a
/// repository.
///
/// **0.2.49 — the numbers come from [MessageTransferProgress.of].** A folder and
/// a flat multi-select are the *same* shape (one message, N attachments); they
/// differed only in that the folder printed `12/20` and the flat batch printed
/// the first file's percentage, which is how the reported "只显示某一个视频的传输
/// 过程" survived a whole release next to working folder code. Counting lives in
/// one function now; this one only renames its fields and adds the sender's
/// declared denominator.
FolderProgress summarizeFolder({
  required int declaredCount,
  required List<FileAttachment> files,
  required TransferProgress? Function(String fileId) progressOf,
}) {
  final MessageTransferProgress progress =
      MessageTransferProgress.of(files, progressOf: progressOf);
  return FolderProgress(
    done: progress.filesDone,
    total: declaredCount > files.length ? declaredCount : files.length,
    bytesDone: progress.bytesDone,
    bytesTotal: progress.bytesTotal,
  );
}

/// How long a folder has to be **silent** before the receiver will say files
/// are missing (`docs/22` §4.4).
///
/// 90 seconds, and the number is chosen against both failure modes:
///
/// * too short and a slow-but-healthy transfer prints 「N 个未收到」 on a folder
///   that is still arriving — the user sees a lie about a file that then lands;
/// * too long and a genuinely stalled folder stays silent, so the user waits for
///   something that will never come.
///
/// A single file's `put` finishes in well under this even on a weak Wi-Fi link,
/// and a *paused* folder (the composer, a screen lock) resumes with a fresh
/// attempt, which touches `transfers.updated_at` and so restarts the window.
const Duration kFolderQuietPeriod = Duration(seconds: 90);

/// How many files of a batch are **not coming**, or `0` when that cannot be
/// proven.
///
/// The receiver has no "batch finished" frame — `put` is per file (`docs/22`
/// §4.4) — so a folder that stalled and a folder that is merely between files
/// look identical from the rows alone. The only honest discriminator is
/// **silence**: [lastActivityAt] (the newest `transfers.updated_at` over the
/// batch's files, see `SessionRepository.lastActivityAt`) older than
/// [kFolderQuietPeriod] relative to [now].
///
/// **Both shapes that can declare more than they delivered come through here**
/// (0.2.52): a folder card (`messages.folder_name` set, declared =
/// `FolderDescriptor.count`) and a **flat multi-select batch** (`folder_name`
/// NULL, declared = the number of files its `prepare` carried). The rule is the
/// same subtraction either way; only the surface that prints it differs, and that
/// is the caller's business, not this function's.
///
/// [now] is a **parameter**, never read from the system clock here: the caller
/// owns the time source (a `Clock` in production, a `FixedClock` in tests), so
/// this decision is reproducible and testable at 89 s / 90 s / 91 s.
///
/// Returns `0` — never a guess — in every case that is not provably stalled:
///
/// * [declaredCount] is `0`/negative (a **single-file** send — nothing was
///   declared, so nothing can be missing — or a pre-0.2.52 record);
/// * [arrivedCount] already meets the declared count (a **complete** batch is
///   complete however long it has been quiet);
/// * [lastActivityAt] is `null` (no such row, so nothing can be concluded);
/// * the quiet period is exactly [kFolderQuietPeriod] or shorter — the rule is
///   **strictly greater than** 90 s;
/// * [now] is **before** [lastActivityAt] (a clock that stepped backwards must
///   not manufacture missing files).
int missingFolderFiles({
  required int declaredCount,
  required int arrivedCount,
  required DateTime? lastActivityAt,
  required DateTime now,
}) {
  if (declaredCount <= 0 || arrivedCount < 0) {
    return 0;
  }
  if (arrivedCount >= declaredCount) {
    return 0;
  }
  final DateTime? lastActivity = lastActivityAt;
  if (lastActivity == null) {
    return 0;
  }
  final Duration quiet = now.difference(lastActivity);
  if (quiet <= kFolderQuietPeriod) {
    return 0;
  }
  return declaredCount - arrivedCount;
}

/// What the bubble's **folder card** prints — computed once, in the caller.
///
/// `docs/22` §5.1: the bubble must not walk `files` itself, or the card's `20/20`
/// and the directory page's row count would slowly disagree. So the thread builds
/// this and hands it to [MessageBubble].
class FolderSummary {
  /// Creates a summary.
  const FolderSummary({
    required this.name,
    required this.done,
    required this.total,
    required this.bytes,
    this.missing = 0,
  });

  /// Builds the summary for [message] from its [files].
  ///
  /// [missing] is **required to be earned**, not assumed: it is what
  /// [missingFolderFiles] returned for this message, i.e. `declared - arrived`
  /// *and only* once the folder has been silent for longer than
  /// [kFolderQuietPeriod]. The default `0` is for callers that have no activity
  /// signal at hand (the Web preview, a card built from a fixture): the card
  /// then simply never shows that line, which is the correct answer when
  /// nothing is known — 「0 个未收到」 is not printed, and no number is invented.
  factory FolderSummary.of(
    ChatMessage message,
    List<FileAttachment> files, {
    required TransferProgress? Function(String fileId) progressOf,
    int missing = 0,
  }) {
    final FolderProgress progress = summarizeFolder(
      declaredCount: message.folderFiles,
      files: files,
      progressOf: progressOf,
    );
    return FolderSummary(
      name: message.folderName ?? '',
      done: progress.done,
      total: progress.total,
      bytes: progress.bytesTotal,
      missing: missing < 0 ? 0 : missing,
    );
  }

  /// The folder's name (`messages.folder_name`), one path segment.
  final String name;

  /// Files that have arrived.
  final int done;

  /// Files the sender declared (or the rows we hold, whichever is larger).
  final int total;

  /// Total bytes (`-1` sizes counted as 0).
  final int bytes;

  /// Files that will not arrive, when the caller can prove it; `0` otherwise.
  final int missing;

  /// Whether every declared file is here.
  bool get isComplete => total > 0 && done >= total;

  @override
  String toString() => 'FolderSummary($name, $done/$total, $bytes B, '
      'missing: $missing)';
}
