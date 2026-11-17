/// The native [SessionRepository]: wraps the frozen `SessionStore` facade and
/// maps its two `StoreEvent`s onto [RepoEvent] (M4 spec §2 / §3.2 / §4).
///
/// **Layering (M4 §8.1):** this file lives in `data/real/**` and is the only
/// kind of file allowed to import `package:lanlink_store` / `dart:io`; it is
/// referenced solely by `bootstrap/create_deps_native.dart`, so the Web build
/// never parses it. Reads/writes are **synchronous** (the store is a sync API,
/// M3 §9.2); the adapter stamps every write with its injected [Clock] so the UI
/// never touches time (M4 §8.3).
library;

import 'package:lanlink_core/lanlink_core.dart' show normalizeFingerprint;
import 'package:lanlink_store/lanlink_store.dart' as store;

import '../../domain/clock.dart';
import '../../domain/models.dart';
import '../../domain/session_repository.dart';
import 'mappers.dart';

/// [SessionRepository] backed by a [store.SessionStore] and its database.
class SqliteSessionRepository implements SessionRepository {
  /// Creates the adapter over [sessionStore], sharing [db] and [ids] with the
  /// facade.
  ///
  /// [db] and [ids] are needed because two port methods have no facade
  /// counterpart in the frozen store — `archiveConversation` (per-id archive)
  /// and the create-on-first-use half of `openActive`; both are served through
  /// the store's own `ConversationsDao`.
  ///
  /// **★ Ownership invariant (the sole basis for this being safe):** [db] and
  /// [ids] MUST be the **very same instances** the facade ([sessionStore]) was
  /// built with — never a second connection and never a second id source. Two
  /// paths into one store are only consistent if they share one
  /// `LanlinkDatabase` (one transaction/write visibility domain) and one
  /// `IdGenerator` (so a minted conversation id cannot collide across the two
  /// paths). `create_deps_native.dart` constructs both objects once and passes
  /// the identical instances here (M4 §3.3 / §8.1).
  SqliteSessionRepository({
    required store.LanlinkDatabase db,
    required store.SessionStore sessionStore,
    required Clock clock,
    required store.IdGenerator ids,
  })  : _db = db,
        _store = sessionStore,
        _clock = clock,
        _ids = ids,
        // Built over the *same* [db] and [ids] as the facade above.
        _conversations = store.ConversationsDao(db, ids);

  final store.LanlinkDatabase _db;
  final store.SessionStore _store;
  final Clock _clock;
  final store.IdGenerator _ids;
  final store.ConversationsDao _conversations;

  /// Provisional device-less / discovered-only conversations, keyed by
  /// normalised fingerprint (see [openActive]).
  final Map<String, Conversation> _provisional = <String, Conversation>{};

  @override
  Stream<RepoEvent> get events => _store.events.map(repoEventFromStoreEvent);

  // ── reads (synchronous) ─────────────────────────────────────────────────

  @override
  List<Conversation> conversations({bool includeArchived = false}) => _store
      .conversations(includeArchived: includeArchived)
      .map(conversationFromRecord)
      .toList(growable: false);

  @override
  List<ChatMessage> history(String conversationId, {int? limit}) => _store
      .history(conversationId, limit: limit)
      // The store returns newest-first (`created_at DESC`); the domain contract
      // is chronological, so reverse the (already limit-capped) page.
      .reversed
      .map(chatMessageFromRecord)
      .toList(growable: false);

  @override
  List<FileAttachment> filesOf(String messageId) => _store
      .filesOf(messageId)
      .map(fileAttachmentFromRecord)
      .toList(growable: false);

  @override
  TransferProgress? transferOf(String fileId) {
    final record = _store.transferOf(fileId);
    return record == null ? null : transferProgressFromRecord(record);
  }

  @override
  PeerDevice? device(String fingerprint) {
    final record = _store.device(fingerprint);
    return record == null ? null : peerDeviceFromRecord(record);
  }

  @override
  List<PeerDevice> devices() =>
      _store.devices().map(peerDeviceFromRecord).toList(growable: false);

  @override
  List<ChatMessage> messagesByStatus(Set<MessageStatus> statuses) => _store
      .messagesByStatus(statuses.map(storeStatusFromDomain).toSet())
      .map(chatMessageFromRecord)
      .toList(growable: false);

  /// Straight delegation to `store.SessionStore.lastActivityAt`, which derives
  /// the answer on read: `MAX(transfers.updated_at)` over the message's files,
  /// falling back to `messages.created_at`.
  ///
  /// **No column is added for this** (0.2.42). `transfers.updated_at` already
  /// moves on every attempt-related write — progress, session attach, done,
  /// failed — so a folder that is still arriving keeps it fresh and a stalled
  /// one lets it go stale; that is precisely the signal the folder card needs.
  /// Writing `messages.updated_at` on each arrival would have been the cheap
  /// alternative, but that column means *when the status last changed* and every
  /// other reader (ordering, display, cleanup) would silently change meaning.
  @override
  DateTime? lastActivityAt(String messageId) =>
      _store.lastActivityAt(messageId);

  // ── writes (the adapter stamps `now` from its Clock) ─────────────────────

  @override
  SendHandle recordOutgoing({
    required PeerDevice peer,
    required List<OutgoingFile> files,
    FolderRef? folder,
  }) {
    final result = _store.recordOutgoingFiles(
      peer: deviceInfoFromPeerDevice(peer),
      files: files.map(outgoingFileSpecFromDomain).toList(growable: false),
      // 0.2.38 — an explicit, prefixed conversion. `store.FolderRef` and
      // `domain.FolderRef` are deliberately different types (`docs/22` §6·T03):
      // letting one stand in for the other would carry the domain's unsanitised
      // name straight into the database, and the two models are free to diverge.
      folder: storeFolderRefFromDomain(folder),
      now: _clock.nowUtc(),
    );
    return SendHandle(
      messageId: result.messageId,
      conversationId: result.conversationId,
      created: result.created,
    );
  }

  @override
  ChatMessage? recordIncoming({
    required PeerDevice sender,
    required IncomingFile file,
    String? publishError,
  }) {
    final result = _store.recordIncomingFile(
      sender: deviceInfoFromPeerDevice(sender),
      file: incomingFileSpecFromDomain(file, publishError: publishError),
      now: _clock.nowUtc(),
    );
    if (!result.created) {
      return null;
    }
    final record = _findMessage(result.messageId);
    return record == null ? null : chatMessageFromRecord(record);
  }

  @override
  ({
    String messageId,
    bool createdMessage,
    bool createdFile,
  }) recordIncomingFolderFile({
    required PeerDevice sender,
    required IncomingFile file,
    required String sessionId,
    required String folderName,
    required int folderFiles,
    String? publishError,
  }) {
    // Straight delegation with no judgement of its own: the store owns the
    // four-step order (device → conversation → existing anchor → append) and
    // the `insertIfAbsent` tolerance that makes a re-delivered file a no-op
    // rather than a constraint failure. Re-deciding any of that here is how a
    // 200-file folder ends up as two messages.
    final result = _store.recordIncomingFolderFile(
      sender: deviceInfoFromPeerDevice(sender),
      file: incomingFileSpecFromDomain(file, publishError: publishError),
      sessionId: sessionId,
      folderName: folderName,
      folderFiles: folderFiles,
      now: _clock.nowUtc(),
    );
    return (
      messageId: result.messageId,
      createdMessage: result.createdMessage,
      createdFile: result.createdFile,
    );
  }

  @override
  ({
    String messageId,
    bool createdMessage,
    bool createdFile,
  }) recordIncomingSessionFile({
    required PeerDevice sender,
    required IncomingFile file,
    required String sessionId,
    int folderFiles = 0,
    String? publishError,
  }) {
    // Same "straight delegation" rule as `recordIncomingFolderFile`: the store
    // owns the four-step order and the batch anchor
    // (`eventNonceForBatchSession`). The one thing that must not be decided here
    // is `folder_name` — the store leaves it NULL for this path, which is what
    // keeps `isFolder` false and the bubble a multi-row bubble.
    //
    // 0.2.52: `folderFiles` (the `prepare`'s declared file count) **is** passed
    // through, straight into the existing `folder_files` column. It carries no
    // descriptor, so it cannot turn this row into a folder — see
    // `SessionStore.recordIncomingSessionFile`.
    final result = _store.recordIncomingSessionFile(
      sender: deviceInfoFromPeerDevice(sender),
      file: incomingFileSpecFromDomain(file, publishError: publishError),
      sessionId: sessionId,
      folderFiles: folderFiles,
      now: _clock.nowUtc(),
    );
    return (
      messageId: result.messageId,
      createdMessage: result.createdMessage,
      createdFile: result.createdFile,
    );
  }

  @override
  SendHandle recordOutgoingText({
    required PeerDevice peer,
    required String text,
    required String nonce,
  }) {
    final result = _store.recordOutgoingText(
      peer: deviceInfoFromPeerDevice(peer),
      text: text,
      // The port's `nonce` is the store's `event_nonce` (the dedupe anchor).
      eventNonce: nonce,
      now: _clock.nowUtc(),
    );
    return SendHandle(
      messageId: result.messageId,
      conversationId: result.conversationId,
      created: result.created,
    );
  }

  @override
  ChatMessage? recordIncomingText({
    required PeerDevice sender,
    required String text,
    required String nonce,
  }) {
    final result = _store.recordIncomingText(
      sender: deviceInfoFromPeerDevice(sender),
      text: text,
      eventNonce: nonce,
      now: _clock.nowUtc(),
    );
    if (!result.created) {
      return null;
    }
    final record = _findMessage(result.messageId);
    return record == null ? null : chatMessageFromRecord(record);
  }

  @override
  bool setStatus({
    required String messageId,
    required MessageStatus from,
    required MessageStatus to,
  }) =>
      _store.setStatus(
        messageId: messageId,
        from: storeStatusFromDomain(from),
        to: storeStatusFromDomain(to),
        now: _clock.nowUtc(),
      );

  @override
  void attachSession({
    required String fileId,
    required String sessionId,
    required String token,
  }) =>
      _store.attachSession(
        fileId: fileId,
        sessionId: sessionId,
        token: token,
        now: _clock.nowUtc(),
      );

  @override
  void markTransferProgress({
    required String fileId,
    required int bytesDone,
  }) =>
      _store.markTransferProgress(
        fileId: fileId,
        bytesDone: bytesDone,
        now: _clock.nowUtc(),
      );

  @override
  void markSendSucceeded({required String messageId}) =>
      _store.markSendSucceeded(messageId: messageId, now: _clock.nowUtc());

  @override
  void markSendFailed({required String messageId, required String error}) =>
      // M4 does not schedule a retry (that is M5); `retryIn` stays `null`.
      _store.markSendFailed(
        messageId: messageId,
        error: error,
        now: _clock.nowUtc(),
      );

  @override
  bool deleteMessage(String messageId) =>
      _store.deleteMessage(messageId: messageId);

  @override
  Conversation openActive({required String? deviceFingerprint}) {
    final now = _clock.nowUtc();
    final normalized = _normalize(deviceFingerprint);

    final existing = _conversations.activeForDevice(normalized ?? '');
    if (existing != null) {
      return conversationFromRecord(existing);
    }

    // No active conversation yet. Create the real row when it can exist: the
    // device-less thread always can, and a device-bound thread can once the
    // `devices` row exists (the FK requires one). This makes the id returned
    // here the very id the first message will land in.
    final hasDeviceRow = normalized == null ||
        _store.devices().any((device) => device.fingerprint == normalized);
    if (hasDeviceRow) {
      final created = _db.transaction<store.ConversationRecord>(
        () => _conversations.openActive(
          deviceFingerprint: normalized,
          now: now,
        ),
      );
      return conversationFromRecord(created);
    }

    // A merely-discovered peer with no device row: it cannot own a conversation
    // yet. Return a stable provisional thread so repeated calls agree; the row —
    // and the authoritative id — arrives with the first send
    // (`SendHandle.conversationId`, M4 §5.2).
    return _provisional.putIfAbsent(
      normalized,
      () => Conversation(
        id: _ids.newId(),
        deviceFingerprint: normalized,
        createdAt: now,
      ),
    );
  }

  @override
  void archiveConversation(String conversationId) {
    try {
      _conversations.archive(conversationId, now: _clock.nowUtc());
    } on store.RowNotFound {
      // Already gone: archiving is idempotent from the UI's point of view.
    }
  }

  @override
  int failInterruptedMessages() {
    final now = _clock.nowUtc();
    final interrupted = _store.messagesByStatus(<store.MessageStatus>{
      store.MessageStatus.awaitingConfirm,
      store.MessageStatus.transferring,
    });
    var changed = 0;
    for (final message in interrupted) {
      final moved = _store.setStatus(
        messageId: message.id,
        from: message.status,
        to: store.MessageStatus.failed,
        now: now,
      );
      if (moved) {
        changed++;
      }
    }
    return changed;
  }

  @override
  void close() => _store.close();

  /// The message with [messageId], scanned across conversations, or `null`.
  ///
  /// Only used on the just-created incoming path (the store's
  /// `recordIncomingFile` returns the id but not the row); personal-tool data
  /// volumes make the linear scan irrelevant.
  store.MessageRecord? _findMessage(String messageId) {
    for (final conversation in _store.conversations(includeArchived: true)) {
      for (final message in _store.history(conversation.id)) {
        if (message.id == messageId) {
          return message;
        }
      }
    }
    return null;
  }

  /// Normalises [fingerprint], collapsing `null` and an empty result to `null`.
  String? _normalize(String? fingerprint) {
    if (fingerprint == null) {
      return null;
    }
    final normalized = normalizeFingerprint(fingerprint);
    return normalized.isEmpty ? null : normalized;
  }
}
