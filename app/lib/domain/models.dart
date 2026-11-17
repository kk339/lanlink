/// Pure-Dart domain models for the M4 app (spec §3.1).
///
/// **Layering rule (M4 §1.3 / §8.1):** this file is pure Dart — it must never
/// import `package:lanlink_core`, `package:lanlink_store`, `dart:io` or
/// `dart:ffi`, so the whole `domain/` layer compiles on Web. The native
/// adapters map the `store`/`core` models onto these types (`data/real/mappers.dart`).
library;

// The default received-files folder (`lanlink`). `downloads_folder.dart` is pure
// Dart too, so this keeps the layering rule above intact.
import 'downloads_folder.dart' show kLanlinkDownloadsSubdirectory;

/// Direction of a message relative to this device.
///
/// The `wire` string mirrors `store`'s `MessageDirection` **verbatim** (kept in
/// sync by `enum_contract_test`).
enum MessageDirection {
  /// Received from a peer.
  incoming('in'),

  /// Sent to a peer.
  outgoing('out');

  const MessageDirection(this.wire);

  /// The exact string stored by the data layer.
  final String wire;
}

/// Whether a message carries files or a plain text body (spec §3.1).
enum MessageKind {
  /// One or more files.
  file('file'),

  /// A plain text message (entry point lands later; M4 keeps the input disabled).
  text('text');

  const MessageKind(this.wire);

  /// The exact string stored by the data layer.
  final String wire;
}

/// Message lifecycle, aligned **verbatim** with `store`'s `MessageStatus`.
///
/// The seven states and their wire strings are the contract `ui/format.dart`
/// renders and `enum_contract_test` guards. `queued`/`sent`/`delivered`/`read`
/// deliberately do **not** exist (M3 §12 C6: "queued" folds into `pending`).
enum MessageStatus {
  /// Queued locally; nothing sent yet (offline queue lives here too).
  pending('pending'),

  /// `prepare-upload` sent, awaiting the peer's answer.
  awaitingConfirm('awaiting_confirm'),

  /// Upload in progress.
  transferring('transferring'),

  /// Completed and verified.
  done('done'),

  /// Failed; a retry scheduler (M5) may re-queue it.
  failed('failed'),

  /// Canceled by the user.
  canceled('canceled'),

  /// Refused by the peer (403/413/503/204).
  rejected('rejected');

  const MessageStatus(this.wire);

  /// The exact string stored by the data layer.
  final String wire;

  /// Terminal states: nothing else follows.
  bool get isTerminal => this == done || this == canceled || this == rejected;
}

/// The message states a user may cancel (0.2.22).
///
/// It lives in `domain/` because **two layers** must agree on it and they may
/// not import each other: `ui/widgets/message_bubble.dart` draws 取消 only for
/// these, and `controllers/conversation_controller.dart` accepts only these.
/// A second hand-written copy is exactly how a button reappears on a state the
/// controller refuses — the "看着能点但没用" shape docs/18 §8.2 rules out.
///
/// These are also precisely the three the store can move to [canceled]
/// (M3 §5.5): `pending`, `awaitingConfirm`, `transferring`.
const Set<MessageStatus> kCancelableStatuses = <MessageStatus>{
  MessageStatus.pending,
  MessageStatus.awaitingConfirm,
  MessageStatus.transferring,
};

/// Coarse device classification shown on cards/icons.
enum DeviceKind {
  mobile,
  desktop,
  web,
  headless,
  server,

  /// Unknown / not yet observed.
  unknown,
}

/// Which files a picker should offer, **and** the recent-files tab filter
/// (spec §3.2 `PlatformPorts.pickFiles`; PRD §4.3).
///
/// The order is the PRD tab order: `any` ("全部") first, then the six category
/// tabs. `any` matches every file (see `selectors.dart::matchesKind`); each of
/// the other six mirrors one `selectors.dart::classifyFile` class (its remaining
/// `other` class has no tab).
enum FileKind { any, image, video, audio, installer, archive, document }

/// The **single** home-card view of a device: the merge of live discovery and
/// stored history, produced by `selectors.dart::mergeDeviceCards` (spec §4.2).
class PeerDevice {
  /// Creates a device card.
  const PeerDevice({
    required this.fingerprint,
    required this.alias,
    required this.kind,
    this.model,
    this.isOnline = false,
    this.lastPort,
    this.lastIp,
    this.lastSeenAt,
    this.lastPreview,
    this.lastActivityAt,
    this.conversationId,
  });

  /// Normalised (uppercase, separator-free) certificate fingerprint.
  final String fingerprint;

  /// Display name.
  final String alias;

  /// Coarse classification.
  final DeviceKind kind;

  /// Free-form model string, or `null`.
  final String? model;

  /// Whether a live peer is currently present.
  final bool isOnline;

  /// Last observed TCP port: `null` = unknown, `0` = no inbound server, `>0` =
  /// dialable (M3 §5.7).
  final int? lastPort;

  /// Last observed IPv4 address, or `null`.
  final String? lastIp;

  /// Last time the peer was seen, or `null`.
  final DateTime? lastSeenAt;

  /// Preview of the latest message, from history, or `null`.
  final String? lastPreview;

  /// Latest message time, from history, or `null`.
  final DateTime? lastActivityAt;

  /// The active conversation id, or `null` when only a device row exists.
  final String? conversationId;

  /// Dialable: a real port (>0) — used to decide whether to open a connection.
  bool get isDialable => (lastPort ?? 0) > 0;

  /// Whether sending is allowed: **only `lastPort == 0` is forbidden** (Q9 / E6).
  /// `null` and `>0` are allowed (`null` just queues, never dials).
  bool get canSend => lastPort != 0;

  /// Whether any history is attached (drives the "no transfer yet" hint).
  bool get hasHistory => lastActivityAt != null || lastPreview != null;

  /// Returns a copy with the given fields replaced.
  PeerDevice copyWith({
    String? fingerprint,
    String? alias,
    DeviceKind? kind,
    String? model,
    bool? isOnline,
    int? lastPort,
    String? lastIp,
    DateTime? lastSeenAt,
    String? lastPreview,
    DateTime? lastActivityAt,
    String? conversationId,
  }) =>
      PeerDevice(
        fingerprint: fingerprint ?? this.fingerprint,
        alias: alias ?? this.alias,
        kind: kind ?? this.kind,
        model: model ?? this.model,
        isOnline: isOnline ?? this.isOnline,
        lastPort: lastPort ?? this.lastPort,
        lastIp: lastIp ?? this.lastIp,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        lastPreview: lastPreview ?? this.lastPreview,
        lastActivityAt: lastActivityAt ?? this.lastActivityAt,
        conversationId: conversationId ?? this.conversationId,
      );

  @override
  bool operator ==(Object other) =>
      other is PeerDevice &&
      other.fingerprint == fingerprint &&
      other.alias == alias &&
      other.kind == kind &&
      other.model == model &&
      other.isOnline == isOnline &&
      other.lastPort == lastPort &&
      other.lastIp == lastIp &&
      other.lastSeenAt == lastSeenAt &&
      other.lastPreview == lastPreview &&
      other.lastActivityAt == lastActivityAt &&
      other.conversationId == conversationId;

  @override
  int get hashCode => Object.hash(
      fingerprint,
      alias,
      kind,
      model,
      isOnline,
      lastPort,
      lastIp,
      lastSeenAt,
      lastPreview,
      lastActivityAt,
      conversationId);

  @override
  String toString() =>
      'PeerDevice($fingerprint, $alias, online: $isOnline, port: $lastPort)';
}

/// A message thread with one counterparty.
class Conversation {
  /// Creates a conversation.
  const Conversation({
    required this.id,
    this.deviceFingerprint,
    required this.createdAt,
    this.lastMessageAt,
    this.lastPreview,
    this.isArchived = false,
  });

  /// Local primary key.
  final String id;

  /// Counterparty fingerprint, or `null` for a history-only thread.
  final String? deviceFingerprint;

  /// When created.
  final DateTime createdAt;

  /// When the latest message was added, or `null` while empty.
  final DateTime? lastMessageAt;

  /// Preview of the latest message, or `null`.
  final String? lastPreview;

  /// Whether archived.
  final bool isArchived;

  /// Returns a copy with the given fields replaced.
  Conversation copyWith({
    String? id,
    String? deviceFingerprint,
    DateTime? createdAt,
    DateTime? lastMessageAt,
    String? lastPreview,
    bool? isArchived,
  }) =>
      Conversation(
        id: id ?? this.id,
        deviceFingerprint: deviceFingerprint ?? this.deviceFingerprint,
        createdAt: createdAt ?? this.createdAt,
        lastMessageAt: lastMessageAt ?? this.lastMessageAt,
        lastPreview: lastPreview ?? this.lastPreview,
        isArchived: isArchived ?? this.isArchived,
      );

  @override
  bool operator ==(Object other) =>
      other is Conversation &&
      other.id == id &&
      other.deviceFingerprint == deviceFingerprint &&
      other.createdAt == createdAt &&
      other.lastMessageAt == lastMessageAt &&
      other.lastPreview == lastPreview &&
      other.isArchived == isArchived;

  @override
  int get hashCode => Object.hash(
      id, deviceFingerprint, createdAt, lastMessageAt, lastPreview, isArchived);

  @override
  String toString() => 'Conversation($id, device: ${deviceFingerprint ?? '-'})';
}

/// One message in a conversation thread.
class ChatMessage {
  /// Creates a message.
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.direction,
    required this.kind,
    required this.createdAt,
    required this.updatedAt,
    required this.status,
    this.textBody,
    this.folderName,
    this.folderFiles = 0,
    this.eventNonce,
  });

  /// Idempotent message id.
  final String id;

  /// Owning conversation.
  final String conversationId;

  /// Direction relative to this device.
  final MessageDirection direction;

  /// File or text.
  final MessageKind kind;

  /// Text body, or `null` for file messages.
  final String? textBody;

  /// The folder this message **is**, or `null` for an ordinary message
  /// (0.2.38 / `docs/22` §2.3, `messages.folder_name`).
  ///
  /// A folder send is **one** message carrying N attachments — the same shape a
  /// multi-select has — so the bubble needs to know it should draw a folder card
  /// instead of N rows. Storage has had this since T02; the domain model only
  /// gains it now, in T05, because this is the first thing that reads it.
  final String? folderName;

  /// How many files the sender **declared** for [folderName]; `0` when this is
  /// not a folder (or an old row that predates the column).
  ///
  /// Declared, not arrived — see [ReceivedTransfer.folderFiles] for why the UI
  /// must never print this next to a `/` without counting the `files` rows too.
  final int folderFiles;

  /// Whether this message is one folder rather than a list of loose files.
  bool get isFolder => folderName != null;

  /// The persisted event anchor (`messages.event_nonce`), or `null` when the
  /// caller did not supply one (0.2.40).
  ///
  /// **Why the domain model needs it.** A text message's nonce is minted once
  /// per logical send and is what makes a re-delivery de-duplicate on the
  /// receiver (`docs/13` §7.3). Until 0.2.40 nothing read it back — the
  /// `TransferOrchestrator` doc said so out loud ("a future retry path must
  /// expose `eventNonce` on the domain model"). The outbox pump **is** that
  /// retry path: it resumes a message that was queued for an offline peer, and
  /// reusing the stored nonce is what keeps that resume idempotent. Minting a
  /// fresh one would turn "the frame arrived but the ack was lost" into a
  /// duplicate message on the other side.
  ///
  /// For a **file** message the anchor is derived from the attachment ids
  /// (`eventNonceForFiles`); the pump does not read it there, because it reuses
  /// those ids verbatim.
  final String? eventNonce;

  /// When created.
  final DateTime createdAt;

  /// When the status last changed.
  final DateTime updatedAt;

  /// Current lifecycle status.
  final MessageStatus status;

  /// Returns a copy with the given fields replaced.
  ChatMessage copyWith({
    String? id,
    String? conversationId,
    MessageDirection? direction,
    MessageKind? kind,
    String? textBody,
    DateTime? createdAt,
    DateTime? updatedAt,
    MessageStatus? status,
    String? folderName,
    int? folderFiles,
    String? eventNonce,
  }) =>
      ChatMessage(
        id: id ?? this.id,
        conversationId: conversationId ?? this.conversationId,
        direction: direction ?? this.direction,
        kind: kind ?? this.kind,
        textBody: textBody ?? this.textBody,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        status: status ?? this.status,
        folderName: folderName ?? this.folderName,
        folderFiles: folderFiles ?? this.folderFiles,
        eventNonce: eventNonce ?? this.eventNonce,
      );

  @override
  bool operator ==(Object other) =>
      other is ChatMessage &&
      other.id == id &&
      other.conversationId == conversationId &&
      other.direction == direction &&
      other.kind == kind &&
      other.textBody == textBody &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt &&
      other.status == status &&
      other.folderName == folderName &&
      other.folderFiles == folderFiles &&
      other.eventNonce == eventNonce;

  @override
  int get hashCode => Object.hash(id, conversationId, direction, kind, textBody,
      createdAt, updatedAt, status, folderName, folderFiles, eventNonce);

  @override
  String toString() =>
      'ChatMessage($id, ${direction.wire}, ${kind.wire}, ${status.wire}'
      '${folderName == null ? '' : ', folder: $folderName/$folderFiles'})';
}

/// One file attached to a [ChatMessage].
class FileAttachment {
  /// Creates a file attachment.
  const FileAttachment({
    required this.id,
    required this.messageId,
    required this.fileName,
    required this.size,
    this.mime,
    this.sha256,
    this.localPath,
    this.relativePath,
  });

  /// Local primary key, also the wire `fileId`.
  final String id;

  /// Owning message.
  final String messageId;

  /// File name on the wire.
  final String fileName;

  /// Size in bytes; `-1` = unknown (E7).
  final int size;

  /// MIME type, or `null`.
  final String? mime;

  /// Uppercase-hex SHA-256, or `null`.
  final String? sha256;

  /// Source path (outgoing) or saved path (incoming), or `null`.
  final String? localPath;

  /// Where this file sits inside its folder, `/`-separated, folder name not
  /// included; `null` when it has no level (0.2.38).
  ///
  /// This is what lets the UI rebuild the tree the sender saw, and it is the
  /// **stored** value (`files.relative_path`), i.e. the landed name — a
  /// de-duplicating rename and a reserved-name escape both appear in their
  /// final form. Like [IncomingFile.relativePath], it must never be used to
  /// open the file: [localPath] is the only locator.
  final String? relativePath;

  @override
  bool operator ==(Object other) =>
      other is FileAttachment &&
      other.id == id &&
      other.messageId == messageId &&
      other.fileName == fileName &&
      other.size == size &&
      other.mime == mime &&
      other.sha256 == sha256 &&
      other.localPath == localPath &&
      other.relativePath == relativePath;

  @override
  int get hashCode => Object.hash(
      id, messageId, fileName, size, mime, sha256, localPath, relativePath);

  @override
  String toString() => 'FileAttachment($id, $fileName, size: $size'
      '${relativePath == null ? '' : ', at $relativePath'})';
}

/// Delivery progress of one file (uncertain: the client reports only the total).
class TransferProgress {
  /// Creates progress.
  const TransferProgress({
    required this.fileId,
    required this.bytesDone,
    required this.bytesTotal,
    this.error,
  });

  /// The file this progress belongs to.
  final String fileId;

  /// Bytes sent **within the current attempt**.
  final int bytesDone;

  /// Total bytes (`-1` = unknown).
  final int bytesTotal;

  /// Last error, or `null`.
  final String? error;

  @override
  bool operator ==(Object other) =>
      other is TransferProgress &&
      other.fileId == fileId &&
      other.bytesDone == bytesDone &&
      other.bytesTotal == bytesTotal &&
      other.error == error;

  @override
  int get hashCode => Object.hash(fileId, bytesDone, bytesTotal, error);

  @override
  String toString() => 'TransferProgress($fileId, $bytesDone/$bytesTotal)';
}

/// A verified file that finished landing on disk (from `onUploadFinished`).
class IncomingFile {
  /// Creates an incoming-file description.
  const IncomingFile({
    required this.fileId,
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.savedPath,
    this.mime,
    this.relativePath,
  });

  /// Sender-assigned wire file id.
  final String fileId;

  /// Sanitised name actually written to disk.
  final String fileName;

  /// Bytes received; `-1` = unknown.
  final int size;

  /// Uppercase-hex SHA-256 computed while streaming.
  final String sha256;

  /// Absolute path where the file was written.
  ///
  /// **This is the only field allowed to locate the file on disk** (0.2.38,
  /// `docs/22` §4.3a). See [relativePath] for why.
  final String savedPath;

  /// MIME type, or `null`.
  final String? mime;

  /// Where this file sits inside its folder, `/`-separated, folder name not
  /// included; `null` for a plain single-file arrival (0.2.38).
  ///
  /// It is the name **as actually written** — a de-duplicating rename
  /// (`x.dll` → `x (1).dll`) and a reserved-name escape (`nul/` → `_nul/`) both
  /// appear here in their landed form, because that is what the receiver's own
  /// sanitisation produced.
  ///
  /// **Never use it to open the file.** On Android a successful publish moves
  /// the bytes into `Download/<subdirectory>/` and *flattens* them, and
  /// [savedPath] is rewritten to that public location — after which this value
  /// describes the private tree the file no longer sits in. It is for display
  /// ("在文件夹里的位置") and for "does this attachment have a level".
  final String? relativePath;

  @override
  bool operator ==(Object other) =>
      other is IncomingFile &&
      other.fileId == fileId &&
      other.fileName == fileName &&
      other.size == size &&
      other.sha256 == sha256 &&
      other.savedPath == savedPath &&
      other.mime == mime &&
      other.relativePath == relativePath;

  @override
  int get hashCode =>
      Object.hash(fileId, fileName, size, sha256, savedPath, mime, relativePath);

  @override
  String toString() => 'IncomingFile($fileId, $fileName, $size bytes'
      '${relativePath == null ? '' : ', at $relativePath'})';
}

/// A domain event: "one file finished landing on disk" (spec §3.1/§5.3).
///
/// **For a folder send this fires once per file**, all carrying the same
/// [sessionId] — one `prepare` session *is* one folder, and the repository
/// folds the N events into one message on that anchor (`docs/22` §4.2).
class ReceivedTransfer {
  /// Creates the event.
  const ReceivedTransfer({
    required this.file,
    required this.sender,
    this.publishError,
    this.sessionId = '',
    this.folderName,
    this.folderFiles = 0,
  });

  /// The file that landed.
  final IncomingFile file;

  /// The peer that sent it.
  final DiscoveredPeer sender;

  /// Why exporting the received file to the user-visible store failed, or
  /// `null` when it did not fail (0.2.23).
  ///
  /// **This is the field that makes a failed export visible.** Before it, the
  /// publisher's failure lived only in the log: the record kept the *private*
  /// path and the bubble still said 已完成, so a user on Android was told the
  /// file had arrived in `下载` while it sat in app-internal storage. The
  /// receive itself still succeeded — the bytes are on disk and hash-verified —
  /// which is exactly why this is a *note on a `done` message*, not a failure
  /// status: "已收到，但没能导出" is the truth, and 分享 still gets the file out.
  ///
  /// `null` on desktop (there is nothing to export: the app-data directory is
  /// already reachable) and on every successful publish.
  final String? publishError;

  /// The receiver's own `prepare` session id, identical for every file of one
  /// batch; empty when unknown (0.2.38).
  ///
  /// This is the **aggregation anchor**: `sessionId` + the sender's fingerprint
  /// is what makes N arrivals become one message. It is the receiver's id, not
  /// the sender's, so two senders cannot collide on it.
  final String sessionId;

  /// Display name of the folder this file belongs to, or `null` when the sender
  /// declared none — a plain, flat arrival (0.2.38).
  final String? folderName;

  /// How many files the sender **declared** for [folderName]; `0` when this is
  /// not a folder transfer.
  ///
  /// Declared, not arrived: a peer may lie or a link may drop mid-batch. The
  /// honest "how many actually came" is the number of `files` rows, and the UI
  /// must count those rather than print this number next to a `/`.
  final int folderFiles;

  /// Whether this arrival belongs to a folder message.
  bool get isFolder => folderName != null;

  /// Returns a copy with the given fields replaced.
  ReceivedTransfer copyWith({
    IncomingFile? file,
    DiscoveredPeer? sender,
    String? publishError,
    String? sessionId,
    String? folderName,
    int? folderFiles,
  }) =>
      ReceivedTransfer(
        file: file ?? this.file,
        sender: sender ?? this.sender,
        publishError: publishError ?? this.publishError,
        sessionId: sessionId ?? this.sessionId,
        folderName: folderName ?? this.folderName,
        folderFiles: folderFiles ?? this.folderFiles,
      );

  @override
  String toString() => 'ReceivedTransfer(${file.fileName} from '
      '${sender.alias}${publishError == null ? '' : ', publishError: $publishError'}'
      '${folderName == null ? '' : ', folder: $folderName ($folderFiles)'})';
}

/// A native text message that arrived from a peer (docs/13 §7.3).
///
/// Mirrors [ReceivedTransfer]: the native adapter turns the core server's
/// `onTextReceived` callback into a stream of these, and the orchestrator maps
/// each onto `SessionRepository.recordIncomingText`.
class ReceivedText {
  /// Creates the event.
  const ReceivedText({
    required this.sender,
    required this.id,
    required this.text,
  });

  /// The peer that sent it.
  final DiscoveredPeer sender;

  /// The sender's nonce (the frame's `id`) — stored as the receiver's
  /// `event_nonce`, so a re-delivery of the same frame de-duplicates.
  final String id;

  /// The message body.
  final String text;

  @override
  String toString() =>
      'ReceivedText(${sender.alias}, id: $id, ${text.length} chars)';
}

/// Why this receiver refused an inbound transfer — the local "被拒留痕" trace
/// (P0-7 follow-up).
///
/// Named distinctly from the core server's `UploadRejectReason` on purpose:
/// `data/real/**` imports core **unprefixed** alongside this file, so two
/// same-named enums would be an ambiguous reference there. `ui/**` and
/// `controllers/**` only ever see this domain enum (M4 §8.1).
enum InboundRejectReason {
  /// Receiving is off — the case the receive switch directly explains.
  acceptingDisabled,

  /// A file exceeded the receiver's size limit.
  tooLarge,

  /// The receiver's concurrent-session cap was reached.
  sessionCapReached,

  /// The request was malformed.
  badRequest,

  /// No open session for the id, or a mismatched token.
  unauthorized,
}

/// A domain event: "a peer tried to send to us and we refused".
///
/// Deliberately **not** a [ChatMessage]: it has no file and no body, and it
/// belongs to no conversation (any device may send, and there may be no
/// conversation at all). Putting it in the message table would pollute the
/// conversation and move its `lastPreview`, so the UI renders it as a
/// dismissible, app-level notice instead.
class UploadRejected {
  /// Creates the event.
  const UploadRejected({required this.peer, required this.reason});

  /// The refused sender, or `null` when it could not be identified (a device
  /// that did not register first).
  final DiscoveredPeer? peer;

  /// Why the request was refused.
  final InboundRejectReason reason;

  @override
  String toString() => 'UploadRejected(${peer?.alias ?? 'unknown'}, $reason)';
}

/// The result of recording one outgoing send.
class SendHandle {
  /// Creates a send handle.
  const SendHandle({
    required this.messageId,
    required this.conversationId,
    required this.created,
  });

  /// The (idempotent) message id.
  final String messageId;

  /// The owning conversation.
  final String conversationId;

  /// Whether the message row was newly created (false on a de-duplicated replay).
  final bool created;

  @override
  String toString() => 'SendHandle($messageId, created: $created)';
}

/// The folder a batch of outgoing files belongs to (0.2.38, `docs/22` §1.1).
///
/// **This is the domain type; `store` has its own `store.FolderRef` and `core`
/// has `core.FolderDescriptor`.** Three names for one idea on purpose: each layer
/// owns its own model and the boundary converts explicitly
/// (`data/real/mappers.dart`). Deliberately *not* re-exported or aliased — an
/// alias would let a `store.FolderRef` reach the wire and quietly lose the
/// invariant that the name is sanitised by the receiver, not the sender.
class FolderRef {
  /// Creates a folder reference.
  const FolderRef({required this.name, required this.count});

  /// Display name of the folder — a single path segment.
  ///
  /// Taken from the picked directory's own name (`p.basename`), never joined
  /// with anything: the per-file hierarchy lives on
  /// [OutgoingFile.relativePath], and the name appears on the wire exactly once.
  final String name;

  /// How many files this folder declares. Equals the number of [OutgoingFile]s
  /// in the same send — it is what the receiver stores as `folder_files` and
  /// what the bubble's `N/M` uses as the denominator.
  final int count;

  @override
  bool operator ==(Object other) =>
      other is FolderRef && other.name == name && other.count == count;

  @override
  int get hashCode => Object.hash(name, count);

  @override
  String toString() => 'FolderRef($name, count: $count)';
}

/// The caller's description of one file to send.
class OutgoingFile {
  /// Creates an outgoing-file description.
  const OutgoingFile({
    required this.id,
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.localPath,
    this.mime,
    this.relativePath,
  });

  /// The wire `fileId`: minted once per send and **reused on every retry**
  /// (M3 §5.6) — regenerating it would change the idempotent message id.
  final String id;

  /// File name on the wire.
  final String fileName;

  /// Size in bytes (`-1` = unknown).
  final int size;

  /// Uppercase-hex SHA-256.
  final String sha256;

  /// Absolute source path.
  final String localPath;

  /// MIME type, or `null`.
  final String? mime;

  /// Where this file sits inside the folder being sent, `/`-separated, folder
  /// name **not** included; `null` for an ordinary multi-select / drag-and-drop
  /// send (`docs/22` §3.2).
  ///
  /// **`null`, never `''`, for a flat send** — the receiver uses
  /// "is there a value" as the single test for "does this file have a level",
  /// and the wire field is omitted entirely so a 0.2.37 peer sees the exact
  /// frame it always did.
  ///
  /// **Never `Uri.encodeComponent`d** (`docs/22` §4.3a): it travels in the JSON
  /// body, which escapes itself. Encoding it here would make the receiver write
  /// a file literally named `a%20b.bin` — neither end decodes.
  final String? relativePath;

  @override
  bool operator ==(Object other) =>
      other is OutgoingFile &&
      other.id == id &&
      other.fileName == fileName &&
      other.size == size &&
      other.sha256 == sha256 &&
      other.localPath == localPath &&
      other.mime == mime &&
      other.relativePath == relativePath;

  @override
  int get hashCode =>
      Object.hash(id, fileName, size, sha256, localPath, mime, relativePath);

  @override
  String toString() => 'OutgoingFile($id, $fileName, $size bytes'
      '${relativePath == null ? '' : ', at $relativePath'})';
}

/// A peer currently visible to the discovery layer.
class DiscoveredPeer {
  /// Creates a discovered peer.
  const DiscoveredPeer({
    required this.fingerprint,
    required this.alias,
    required this.kind,
    required this.address,
    required this.port,
    required this.isOnline,
    required this.lastSeen,
    this.model,
  });

  /// Normalised fingerprint.
  final String fingerprint;

  /// Display name.
  final String alias;

  /// Coarse classification.
  final DeviceKind kind;

  /// Address the peer was last seen at.
  final String address;

  /// The peer's advertised TCP port.
  final int port;

  /// Whether the peer is currently online.
  final bool isOnline;

  /// Last observation time.
  final DateTime lastSeen;

  /// Free-form model string, or `null`.
  final String? model;

  /// Returns a copy with the given fields replaced.
  DiscoveredPeer copyWith({
    String? fingerprint,
    String? alias,
    DeviceKind? kind,
    String? address,
    int? port,
    bool? isOnline,
    DateTime? lastSeen,
    String? model,
  }) =>
      DiscoveredPeer(
        fingerprint: fingerprint ?? this.fingerprint,
        alias: alias ?? this.alias,
        kind: kind ?? this.kind,
        address: address ?? this.address,
        port: port ?? this.port,
        isOnline: isOnline ?? this.isOnline,
        lastSeen: lastSeen ?? this.lastSeen,
        model: model ?? this.model,
      );

  @override
  bool operator ==(Object other) =>
      other is DiscoveredPeer &&
      other.fingerprint == fingerprint &&
      other.alias == alias &&
      other.kind == kind &&
      other.address == address &&
      other.port == port &&
      other.isOnline == isOnline &&
      other.lastSeen == lastSeen &&
      other.model == model;

  @override
  int get hashCode => Object.hash(
      fingerprint, alias, kind, address, port, isOnline, lastSeen, model);

  @override
  String toString() =>
      'DiscoveredPeer($fingerprint, $alias, $address:$port, online: $isOnline)';
}

/// One address the user **typed by hand** to reach a peer that discovery could
/// not find (0.2.54), remembered so it does not have to be typed again after a
/// restart.
///
/// **What is remembered is a dial target, not a device.** The pairing of a peer
/// is its certificate fingerprint, and that is deliberately **not** stored here:
/// a phone that reinstalls lanlink (or hits the 「重置」 path) comes back under a
/// new identity, and a remembered fingerprint would then make the saved target
/// refuse a peer that is standing right there — permanently, and with no visible
/// cause. Only the address is kept; the fingerprint is observed fresh on every
/// probe, which is what lets a stored target heal itself.
///
/// Immutable and pure Dart (the `domain/` layering rule), so the persistence
/// adapter and the tests share one definition of "what an address is".
class ManualPeerTarget {
  /// Creates a target. [host] is stored as given; [port] must be a real port.
  const ManualPeerTarget({required this.host, required this.port});

  /// The smallest port a peer can listen on.
  static const int minPort = 1;

  /// The largest port a peer can listen on.
  static const int maxPort = 65535;

  /// The address the user typed — an IPv4 literal, an IPv6 literal
  /// (`fe80::1`, brackets already stripped) or whatever the probe accepts.
  ///
  /// A hostname is **not** rejected here: this type describes what is stored,
  /// and the probe is the one authority on what it can dial
  /// (`PeerDiscovery.probeHost`). The only host shape that is refused is the one
  /// that can never be dialled by anybody — the empty string.
  final String host;

  /// The port to dial, `1…65535`.
  final int port;

  /// Whether this target could be dialled at all.
  ///
  /// Used at both ends of persistence: an entry that fails this is dropped on
  /// read (one bad entry must not lose the user's alias) and is never written
  /// (a document must not contain something its own reader would throw away).
  bool get isValid => host.isNotEmpty && port >= minPort && port <= maxPort;

  /// Parses one stored entry, or `null` when it cannot be dialled.
  ///
  /// **Never throws** and never resets anything: this runs inside
  /// `loadSettings`, where an exception would cost the user their alias and
  /// save folder because of one malformed address. The rules mirror the
  /// persistence criteria exactly — a non-map, a non-string host, a blank host,
  /// a non-numeric port and a port outside `1…65535` all answer `null`.
  ///
  /// A JSON number decodes as `double` when it was written with a decimal point
  /// (`49494.0`), so the port is read as a `num` and required to be whole;
  /// `49494.5` is not a port anybody typed and is refused.
  static ManualPeerTarget? tryParse(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? rawHost = json['host'];
    if (rawHost is! String) {
      return null;
    }
    final String host = rawHost.trim();
    if (host.isEmpty) {
      return null;
    }
    final Object? rawPort = json['port'];
    if (rawPort is! num) {
      return null;
    }
    final double asDouble = rawPort.toDouble();
    if (asDouble != asDouble.truncateToDouble()) {
      return null;
    }
    final int port = rawPort.toInt();
    if (port < minPort || port > maxPort) {
      return null;
    }
    return ManualPeerTarget(host: host, port: port);
  }

  /// Parses a whole stored list, **dropping the entries it cannot use**.
  ///
  /// The failure mode this shape exists to prevent: a hand-edited document with
  /// one bad address throwing out of `loadSettings`, which the port answers by
  /// falling back to *defaults* — the user silently loses their device name, the
  /// chosen save folder and every other saved target because of one typo. One
  /// bad entry costs exactly that one entry.
  ///
  /// A missing or non-list value is an empty list, which is what makes an old
  /// document (written before this key existed) upgrade with no migration step.
  /// Order is preserved as stored, so what the user sees after a restart is what
  /// they saw before it.
  static List<ManualPeerTarget> listFromJson(Object? json) {
    if (json is! List) {
      return const <ManualPeerTarget>[];
    }
    final List<ManualPeerTarget> parsed = <ManualPeerTarget>[];
    for (final Object? entry in json) {
      final ManualPeerTarget? target = tryParse(entry);
      if (target != null) {
        parsed.add(target);
      }
    }
    return parsed;
  }

  /// Returns a copy with the given fields replaced.
  ManualPeerTarget copyWith({String? host, int? port}) => ManualPeerTarget(
        host: host ?? this.host,
        port: port ?? this.port,
      );

  /// The stored shape: `{"host": "192.168.1.23", "port": 49494}`.
  Map<String, Object?> toJson() => <String, Object?>{
        'host': host,
        'port': port,
      };

  @override
  bool operator ==(Object other) =>
      other is ManualPeerTarget && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => 'ManualPeerTarget($host:$port)';
}

/// Whether [a] and [b] hold equal targets in the same order.
///
/// The domain layer is pure Dart (no `package:flutter/foundation.dart`), so
/// `listEquals` is not available here; a shared list comparison keeps the two
/// `AppSettings` value-objects honest about `==`.
bool _sameManualPeers(List<ManualPeerTarget> a, List<ManualPeerTarget> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i += 1) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// Persisted, user-editable application settings (spec §3.1/§4.6).
class AppSettings {
  /// Creates settings.
  const AppSettings({
    required this.alias,
    required this.saveDirectory,
    this.acceptByDefault = true,
    this.receivedSubdirectory = kLanlinkDownloadsSubdirectory,
    this.manualPeers = const <ManualPeerTarget>[],
  });

  /// This device's display name (applied to discovery + transfer service).
  final String alias;

  /// Where accepted files are written.
  final String saveDirectory;

  /// Whether the receiver starts accepting on launch.
  ///
  /// **0.2.25 — the default flipped from off to on** ("接收模式默认开着就行").
  /// P0-7 chose off when receiving was still a background daemon nobody had
  /// asked for; the user's verdict on the shipped behaviour was the opposite, so
  /// a device now starts receivable.
  ///
  /// The model default is only half of the story: a device that already ran an
  /// earlier build has `acceptByDefault: false` written in its settings JSON, and
  /// no default on this field can reach it. That one-time migration lives where
  /// the document is read/written (`SystemPlatformPorts.loadSettings`, guarded by
  /// `settingsVersion`) — keeping the persistence detail out of the model.
  final bool acceptByDefault;

  /// The folder under the phone's `Download` that received files are published
  /// into, as a **name relative to `Download/`** (0.2.29) — `lanlink` by
  /// default, `素材` or `素材/2026` once the user picks one.
  ///
  /// **Deliberately its own field, not a second meaning for [saveDirectory].**
  /// On a phone [saveDirectory] is the receiver's private landing directory and
  /// takes part in real filesystem work — `saveSettings` writes a probe file into
  /// it, `LanTransferService.setSaveDirectory` re-opens the receiver on it, and
  /// on the desktop it *is* the destination. A MediaStore `RELATIVE_PATH`
  /// fragment pushed through that field would be probed, opened as a `File` and
  /// fail. Two different questions, two fields.
  ///
  /// Stored **as given**; the value is normalised at the boundaries
  /// (`normalizeDownloadsSubdirectory`), because a model that silently rewrites
  /// its own field cannot report what was actually on disk.
  final String receivedSubdirectory;

  /// The addresses the user typed by hand (0.2.54), in the order they were
  /// added.
  ///
  /// **Why this lives in settings and not in the `devices` table.** Discovery
  /// being blocked by the network is exactly when a hand-typed address is the
  /// only way through, and what the user types is a *telephone number they chose
  /// to dial* — not a device the app has seen. The `devices` row is keyed on a
  /// certificate fingerprint, which a hand-typed address does not have until a
  /// probe succeeds; filing it there would mean inventing a device row for an
  /// address that may well be a typo, plus a schema migration and a new write
  /// path through the store just to remember a string the user entered.
  ///
  /// Empty by default, so a device that never used the feature — and every
  /// document written before it existed — behaves exactly as before.
  final List<ManualPeerTarget> manualPeers;

  /// Returns a copy with the given fields replaced.
  AppSettings copyWith({
    String? alias,
    String? saveDirectory,
    bool? acceptByDefault,
    String? receivedSubdirectory,
    List<ManualPeerTarget>? manualPeers,
  }) =>
      AppSettings(
        alias: alias ?? this.alias,
        saveDirectory: saveDirectory ?? this.saveDirectory,
        acceptByDefault: acceptByDefault ?? this.acceptByDefault,
        receivedSubdirectory:
            receivedSubdirectory ?? this.receivedSubdirectory,
        // `?? this.…`, not an "empty means keep" rule: clearing the list is a
        // legitimate edit (the user removes their last address), and an empty
        // list is not `null`, so it replaces the old one as intended.
        manualPeers: manualPeers ?? this.manualPeers,
      );

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.alias == alias &&
      other.saveDirectory == saveDirectory &&
      other.acceptByDefault == acceptByDefault &&
      other.receivedSubdirectory == receivedSubdirectory &&
      _sameManualPeers(other.manualPeers, manualPeers);

  @override
  int get hashCode => Object.hash(alias, saveDirectory, acceptByDefault,
      receivedSubdirectory, Object.hashAll(manualPeers));

  @override
  String toString() => 'AppSettings($alias, $saveDirectory, '
      'acceptByDefault: $acceptByDefault, '
      'receivedSubdirectory: $receivedSubdirectory, '
      'manualPeers: $manualPeers)';
}
