/// Pure mapping between the `store`/`core` models and this app's domain
/// models (M4 spec §2 / §3.1).
///
/// **Layering (M4 §8.1):** this file lives in `data/real/**`, the only place
/// allowed to import `package:lanlink_core` / `package:lanlink_store`. Every
/// function here is pure (no I/O, no clock, no network) so it can be exercised
/// in a plain `dart run` harness — the mapping layer is where the "Web-safe
/// domain model" and the "platform-bound store/core model" meet.
///
/// Naming note: `store` and the domain both define `MessageStatus`,
/// `MessageDirection` and `MessageKind`. Importing the store barrel **with a
/// prefix** keeps the unprefixed names bound to the domain enums (spec §3.1).
library;

import 'package:lanlink_core/lanlink_core.dart' as core;
import 'package:lanlink_store/lanlink_store.dart' as store;

import '../../domain/models.dart';
import '../../domain/session_repository.dart';

// ── enums ────────────────────────────────────────────────────────────────

/// Maps a stored `device_type` wire string to a [DeviceKind].
///
/// An unknown / absent string becomes [DeviceKind.unknown] (never throws): a
/// device row written by an older peer must not crash the home screen.
DeviceKind deviceKindFromWire(String? wire) => switch (wire) {
      'mobile' => DeviceKind.mobile,
      'desktop' => DeviceKind.desktop,
      'web' => DeviceKind.web,
      'headless' => DeviceKind.headless,
      'server' => DeviceKind.server,
      _ => DeviceKind.unknown,
    };

/// Maps a core [DeviceType] to a [DeviceKind].
DeviceKind deviceKindFromDeviceType(core.DeviceType type) =>
    deviceKindFromWire(type.wire);

/// Maps a [DeviceKind] back to the core [DeviceType] announced on the wire.
///
/// [DeviceKind.unknown] falls back to [core.DeviceType.desktop], matching the
/// permissive default the reference implementations use.
core.DeviceType deviceTypeFromKind(DeviceKind kind) => switch (kind) {
      DeviceKind.mobile => core.DeviceType.mobile,
      DeviceKind.desktop => core.DeviceType.desktop,
      DeviceKind.web => core.DeviceType.web,
      DeviceKind.headless => core.DeviceType.headless,
      DeviceKind.server => core.DeviceType.server,
      DeviceKind.unknown => core.DeviceType.desktop,
    };

/// Maps a domain [MessageDirection] to the store enum (same wire string).
store.MessageDirection storeDirectionFromDomain(MessageDirection direction) =>
    switch (direction) {
      MessageDirection.incoming => store.MessageDirection.incoming,
      MessageDirection.outgoing => store.MessageDirection.outgoing,
    };

/// Maps a store direction to the domain enum.
MessageDirection domainDirectionFromStore(store.MessageDirection direction) =>
    switch (direction) {
      store.MessageDirection.incoming => MessageDirection.incoming,
      store.MessageDirection.outgoing => MessageDirection.outgoing,
    };

/// Maps a domain [MessageKind] to the store enum (same wire string).
store.MessageKind storeKindFromDomain(MessageKind kind) => switch (kind) {
      MessageKind.file => store.MessageKind.file,
      MessageKind.text => store.MessageKind.text,
    };

/// Maps a store kind to the domain enum.
MessageKind domainKindFromStore(store.MessageKind kind) => switch (kind) {
      store.MessageKind.file => MessageKind.file,
      store.MessageKind.text => MessageKind.text,
    };

/// Maps a domain [MessageStatus] to the store enum (same wire string).
store.MessageStatus storeStatusFromDomain(MessageStatus status) =>
    switch (status) {
      MessageStatus.pending => store.MessageStatus.pending,
      MessageStatus.awaitingConfirm => store.MessageStatus.awaitingConfirm,
      MessageStatus.transferring => store.MessageStatus.transferring,
      MessageStatus.done => store.MessageStatus.done,
      MessageStatus.failed => store.MessageStatus.failed,
      MessageStatus.canceled => store.MessageStatus.canceled,
      MessageStatus.rejected => store.MessageStatus.rejected,
    };

/// Maps a store status to the domain enum (same wire string).
MessageStatus domainStatusFromStore(store.MessageStatus status) =>
    switch (status) {
      store.MessageStatus.pending => MessageStatus.pending,
      store.MessageStatus.awaitingConfirm => MessageStatus.awaitingConfirm,
      store.MessageStatus.transferring => MessageStatus.transferring,
      store.MessageStatus.done => MessageStatus.done,
      store.MessageStatus.failed => MessageStatus.failed,
      store.MessageStatus.canceled => MessageStatus.canceled,
      store.MessageStatus.rejected => MessageStatus.rejected,
    };

// ── rows: store -> domain ──────────────────────────────────────────────────

/// Maps a `conversations` row to the domain [Conversation].
Conversation conversationFromRecord(store.ConversationRecord record) =>
    Conversation(
      id: record.id,
      deviceFingerprint: record.deviceFingerprint,
      createdAt: record.createdAt,
      lastMessageAt: record.lastMessageAt,
      lastPreview: record.lastPreview,
      isArchived: record.isArchived,
    );

/// Maps a `messages` row to the domain [ChatMessage].
ChatMessage chatMessageFromRecord(store.MessageRecord record) => ChatMessage(
      id: record.id,
      conversationId: record.conversationId,
      direction: domainDirectionFromStore(record.direction),
      kind: domainKindFromStore(record.kind),
      textBody: record.textBody,
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
      status: domainStatusFromStore(record.status),
      // 0.2.38 — a folder message is one row with N `files`; the bubble needs the
      // name and the declared count to draw a folder card instead of N rows.
      // Dropping these here would silently turn every received folder back into
      // a pile of loose files (the store has had the columns since T02).
      folderName: record.folderName,
      folderFiles: record.folderFiles ?? 0,
      // 0.2.40 — the stored event anchor. A **text** message's nonce is the only
      // way to resume a queued text send idempotently (see
      // `ChatMessage.eventNonce`); dropping it here would leave the outbox pump
      // with nothing to reuse and force it to mint a fresh one, which would
      // duplicate the message on the receiver after a lost ack.
      eventNonce: record.eventNonce,
    );

/// Maps a `files` row to the domain [FileAttachment].
FileAttachment fileAttachmentFromRecord(store.MessageFileRecord record) =>
    FileAttachment(
      id: record.id,
      messageId: record.messageId,
      fileName: record.fileName,
      size: record.size,
      mime: record.mime,
      sha256: record.sha256,
      localPath: record.localPath,
      // 0.2.38 — the last link that makes `files.relative_path` readable by the
      // UI. Without it the column is write-only and no tree can be rebuilt.
      relativePath: record.relativePath,
    );

/// Maps a `transfers` row to the domain [TransferProgress].
TransferProgress transferProgressFromRecord(store.TransferRecord record) =>
    TransferProgress(
      fileId: record.fileId,
      bytesDone: record.bytesDone,
      bytesTotal: record.bytesTotal,
      error: record.error,
    );

/// Maps a `devices` row to a domain [PeerDevice] (the stored half of a card).
///
/// The conversation-scoped fields (`lastPreview` / `lastActivityAt` /
/// `conversationId`) are **not** on a device row; they are filled in by
/// `selectors.dart::mergeDeviceCards` from the active conversation. The card is
/// built offline here; live discovery overrides `isOnline` in the merge
/// (spec §4.2).
PeerDevice peerDeviceFromRecord(store.DeviceRecord record) => PeerDevice(
      fingerprint: record.fingerprint,
      alias: record.alias,
      kind: deviceKindFromWire(record.deviceType),
      model: record.model,
      isOnline: false,
      lastPort: record.lastPort,
      lastIp: record.lastIp,
      lastSeenAt: record.lastSeenAt,
    );

// ── events ─────────────────────────────────────────────────────────────────

/// Maps one store [store.StoreEvent] to the matching [RepoEvent].
///
/// The data layer emits three event types (M3 §12.2 C1, plus `0.2.51`'s
/// `MessageFilesAppended`); the adapter publishes the same order it observed
/// (a `MessageInserted` first, then any `MessageStatusChanged`, and an append
/// never coincides with either — it is the *other* branch of the folder write).
RepoEvent repoEventFromStoreEvent(store.StoreEvent event) => switch (event) {
      store.MessageInserted(:final message) =>
        MessageAdded(chatMessageFromRecord(message)),
      // 0.2.51 — a folder's files 2…N. No message appears, but one grew, so the
      // id is all a listener needs to re-read it.
      store.MessageFilesAppended(:final messageId) =>
        MessageFilesAppended(messageId: messageId),
      store.MessageStatusChanged(:final messageId, :final from, :final to) =>
        MessageStatusUpdated(
          messageId: messageId,
          from: domainStatusFromStore(from),
          to: domainStatusFromStore(to),
        ),
    };

// ── core <-> domain peers ────────────────────────────────────────────────────

/// Builds a domain [DiscoveredPeer] from a core [core.DeviceInfo] plus the
/// observation metadata the discovery layer tracks.
DiscoveredPeer discoveredPeerFromInfo(
  core.DeviceInfo info, {
  required String address,
  required bool isOnline,
  required DateTime lastSeen,
}) =>
    DiscoveredPeer(
      fingerprint: info.fingerprint,
      alias: info.alias,
      kind: deviceKindFromDeviceType(info.deviceType),
      address: address,
      port: info.port,
      isOnline: isOnline,
      lastSeen: lastSeen,
      model: info.deviceModel,
    );

/// Builds a domain [DiscoveredPeer] from a registry [core.Peer].
DiscoveredPeer discoveredPeerFromPeer(core.Peer peer) => DiscoveredPeer(
      fingerprint: peer.fingerprint,
      alias: peer.info.alias,
      kind: deviceKindFromDeviceType(peer.info.deviceType),
      address: peer.address,
      port: peer.info.port,
      isOnline: peer.isOnline,
      lastSeen: peer.lastSeen,
      model: peer.info.deviceModel,
    );

/// Builds a core [core.DeviceInfo] from a stored domain [PeerDevice].
///
/// Used to hand a peer back to the store's write use-cases (which take a
/// `DeviceInfo`).
///
/// **Consequence of `null` handling (read before relying on it):** a `null`
/// [PeerDevice.lastPort] is mapped to `0` because the store's `last_port`
/// column cannot hold "unknown" (only `NULL` or an integer), and the facade's
/// `_deviceFromInfo` always writes an integer. But `0` is *not* "empty" — it
/// means **"the peer runs no inbound server"**. Since the UI's
/// [PeerDevice.canSend] is `lastPort != 0`, this mapping turns "unknown" into
/// **"sending disabled"**. In practice the app runs a resident server and every
/// announcement carries a `port > 0`, so `null` is a corner case; a send only
/// reaches this path for a dialable peer anyway (`TransferOrchestrator` guards
/// on `isDialable`, spec §4.5).
core.DeviceInfo deviceInfoFromPeerDevice(PeerDevice peer) => core.DeviceInfo(
      alias: peer.alias,
      fingerprint: peer.fingerprint,
      port: peer.lastPort ?? 0,
      deviceType: deviceTypeFromKind(peer.kind),
      deviceModel: peer.model,
      protocol: core.ProtocolScheme.https,
      download: false,
      announce: false,
    );

/// Builds a core [core.DeviceInfo] from a live domain [DiscoveredPeer].
core.DeviceInfo deviceInfoFromDiscoveredPeer(DiscoveredPeer peer) =>
    core.DeviceInfo(
      alias: peer.alias,
      fingerprint: peer.fingerprint,
      port: peer.port,
      deviceType: deviceTypeFromKind(peer.kind),
      deviceModel: peer.model,
      protocol: core.ProtocolScheme.https,
      download: false,
      announce: false,
    );

// ── transfer payloads ────────────────────────────────────────────────────────

/// Maps a domain [OutgoingFile] to the core [core.FileMetadata] sent in
/// `prepare-upload`.
///
/// [OutgoingFile.relativePath] goes straight through as `FileMetadata.relativePath`
/// (wire key `path`), **unencoded** — it travels in the JSON body, which escapes
/// itself; a `Uri.encodeComponent` here would make the receiver write a file
/// literally named `a%20b.bin` (`docs/22` §4.3a). A flat send passes `null`, and
/// `FileMetadata.toJson` then omits the key entirely, so a 0.2.37 peer receives
/// the exact frame it always did.
core.FileMetadata fileMetadataFromOutgoing(OutgoingFile file) =>
    core.FileMetadata(
      id: file.id,
      fileName: file.fileName,
      size: file.size,
      fileType: file.mime ?? 'application/octet-stream',
      sha256: file.sha256,
      relativePath: file.relativePath,
    );

/// Maps a domain [FolderRef] to the core [core.FolderDescriptor] sent in
/// `prepare`'s optional `folder` object (0.2.38).
///
/// **A blank name is "not a folder"**, matching what the receive side does with
/// a descriptor that sanitises to nothing: returning `null` here keeps a
/// message that renders as a folder with no title from ever reaching the wire.
core.FolderDescriptor? folderDescriptorFromRef(FolderRef? folder) {
  if (folder == null || folder.name.isEmpty) {
    return null;
  }
  return core.FolderDescriptor(name: folder.name, count: folder.count);
}

/// Maps a domain [FolderRef] to the store's [store.FolderRef] (0.2.38).
///
/// Two distinct types on purpose (`docs/22` §6·T03): the store owns
/// persistence, core owns the wire, and this app owns the UI-facing model. The
/// conversion is explicit so a future change to one of the three cannot silently
/// ride along on the other two.
store.FolderRef? storeFolderRefFromDomain(FolderRef? folder) {
  if (folder == null || folder.name.isEmpty) {
    return null;
  }
  return store.FolderRef(name: folder.name, count: folder.count);
}

/// Maps a domain [OutgoingFile] to the store's [store.OutgoingFileSpec].
store.OutgoingFileSpec outgoingFileSpecFromDomain(OutgoingFile file) =>
    store.OutgoingFileSpec(
      id: file.id,
      fileName: file.fileName,
      size: file.size,
      sha256: file.sha256,
      localPath: file.localPath,
      mime: file.mime,
      relativePath: file.relativePath,
    );

/// Maps a domain [IncomingFile] to the store's [store.IncomingFileSpec].
///
/// [publishError] rides along (0.2.23): the store persists it on the transfer
/// row, which is the only place a received-then-not-exported file's reason can
/// survive a restart.
///
/// [IncomingFile.relativePath] is carried too (0.2.38). **This is one of the
/// three hand-written field-by-field copies in the receive path**, and every one
/// of them fails silently: a field that is not listed here does not error, it
/// just arrives as `null` and the folder renders flat. The other two are
/// [incomingFileFromReceived] and `ReceivedFilePublisher.publishTransfer`.
store.IncomingFileSpec incomingFileSpecFromDomain(
  IncomingFile file, {
  String? publishError,
}) =>
    store.IncomingFileSpec(
      fileId: file.fileId,
      fileName: file.fileName,
      size: file.size,
      sha256: file.sha256,
      savedPath: file.savedPath,
      mime: file.mime,
      publishError: publishError,
      relativePath: file.relativePath,
    );

/// Maps a core [core.ReceivedFile] to the domain [IncomingFile].
///
/// Carries `relativePath` (0.2.38) — see [incomingFileSpecFromDomain] for why
/// every field of this copy has to be added by hand.
IncomingFile incomingFileFromReceived(core.ReceivedFile received) =>
    IncomingFile(
      fileId: received.fileId,
      fileName: received.fileName,
      size: received.size,
      sha256: received.sha256,
      savedPath: received.savedPath,
      relativePath: received.relativePath,
    );

/// Builds the domain [ReceivedTransfer] for a verified incoming file.
///
/// The sender is taken from the report's embedded [core.DeviceInfo]; when the
/// sender is unknown (an older peer that did not announce itself) a placeholder
/// carrying an **empty fingerprint** is used, so the event stream never yields
/// `null`. A recorder must ignore an empty fingerprint (it cannot own a
/// device/conversation).
ReceivedTransfer receivedTransferFromReceived(
  core.ReceivedFile received, {
  required DateTime now,
}) {
  final sender = received.sender;
  final DiscoveredPeer peer = sender == null
      ? DiscoveredPeer(
          fingerprint: '',
          alias: 'Unknown',
          kind: DeviceKind.unknown,
          address: '',
          port: 0,
          isOnline: true,
          lastSeen: now,
        )
      : discoveredPeerFromInfo(
          sender,
          address: '',
          isOnline: true,
          lastSeen: now,
        );
  return ReceivedTransfer(
    file: incomingFileFromReceived(received),
    sender: peer,
    // 0.2.38 — the three fields that turn N arrivals back into one message.
    // `sessionId` is the receiver's own `prepare` id (identical for every file
    // of a batch), so it is the aggregation anchor; `folderName`/`folderFiles`
    // are the declared descriptor. Dropping any of them here does not error —
    // it silently degrades a folder to N loose files, which is why the
    // judgement for this task asserts on the *stored* shape, not on this
    // function's return.
    sessionId: received.sessionId,
    folderName: received.folderName,
    folderFiles: received.folderFiles,
  );
}

/// Builds the domain [ReceivedText] for an accepted inbound text frame
/// (docs/13 §7.3).
///
/// The sender is the frame's `peer`, projected onto a [DiscoveredPeer] the same
/// way [receivedTransferFromReceived] projects a file's sender.
ReceivedText receivedTextFromCore(
  core.DeviceInfo sender,
  core.TextMessage message, {
  required DateTime now,
}) =>
    ReceivedText(
      sender: discoveredPeerFromInfo(
        sender,
        address: '',
        isOnline: true,
        lastSeen: now,
      ),
      id: message.id,
      text: message.text,
    );

/// Maps a core refusal ([core.UploadRejectReason]) to the domain
/// [InboundRejectReason].
InboundRejectReason inboundRejectReasonFromCore(
  core.UploadRejectReason reason,
) =>
    switch (reason) {
      core.UploadRejectReason.acceptingDisabled =>
        InboundRejectReason.acceptingDisabled,
      core.UploadRejectReason.tooLarge => InboundRejectReason.tooLarge,
      core.UploadRejectReason.sessionCapReached =>
        InboundRejectReason.sessionCapReached,
      core.UploadRejectReason.badRequest => InboundRejectReason.badRequest,
      core.UploadRejectReason.unauthorized => InboundRejectReason.unauthorized,
    };

/// Builds the domain [UploadRejected] event for a refusal the receiver made.
///
/// [peer] is `null` when the core server could not identify the sender (a device
/// that never registered); the event then carries a `null` peer and the UI says
/// "身份未知".
UploadRejected uploadRejectedFromCore(
  core.DeviceInfo? peer,
  core.UploadRejectReason reason, {
  required DateTime now,
}) =>
    UploadRejected(
      peer: peer == null
          ? null
          : discoveredPeerFromInfo(
              peer,
              address: '',
              isOnline: true,
              lastSeen: now,
            ),
      reason: inboundRejectReasonFromCore(reason),
    );
