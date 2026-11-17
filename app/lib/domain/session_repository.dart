/// Session-history port (spec §3.2): the **single** entry point for reading and
/// writing conversations, messages, files and transfers.
///
/// **Layering (M4 §8.1):** pure Dart — imports only this package's `domain/`,
/// never `lanlink_core` / `lanlink_store` / `dart:io`. The native adapter
/// (`data/real/sqlite_session_repository.dart`) wraps `SessionStore` and maps
/// its `StoreEvent`s onto [RepoEvent] (spec §4); the fake replays the same
/// events in the same order (§8.8).
///
/// Port write methods take **no** `now`: the adapter stamps time from its
/// injected `Clock` and feeds it to the store (spec §3.2 / §8.3). Read methods
/// are **synchronous** because the store is a sync API (M3 §9.2).
library;

import 'models.dart';

/// A domain event emitted by a [SessionRepository].
///
/// Mirrors the data layer's `StoreEvent`s 1:1 (spec §4.1 / §12.1): a row is
/// inserted first, then any status change follows. 0.2.51 added the third —
/// [MessageFilesAppended] — because a folder's files 2…N grow an existing
/// message without adding one, and "a message arrived" is not the only change
/// the timeline has to redraw.
sealed class RepoEvent {
  /// Const constructor for subclasses.
  const RepoEvent();
}

/// A message was added to a conversation (maps `StoreEvent.MessageInserted`).
final class MessageAdded extends RepoEvent {
  /// Creates the event for [message].
  const MessageAdded(this.message);

  /// The newly persisted message.
  final ChatMessage message;
}

/// An attachment was appended to a message that **already existed**
/// (maps `StoreEvent.MessageFilesAppended`, 0.2.51).
///
/// The folder path folds a whole `prepare` session onto one message
/// (`recordIncomingFolderFile`, docs/22 §4.2): the first file creates the
/// message ([MessageAdded]) and every later file is an attachment added to a
/// message the UI is already showing. Such an arrival changes **no message
/// count** — only that message's attachment count — so without this event a
/// controller that refreshes on "a message arrived" never redraws the growth and
/// the card stays at 「已收到 1/3」 until an unrelated message goes by.
///
/// Only [messageId] travels: the attachments themselves are one [SessionRepository.filesOf]
/// read away, and carrying a second copy of them here would give a listener two
/// sources for the same rows.
final class MessageFilesAppended extends RepoEvent {
  /// Creates the event for [messageId].
  const MessageFilesAppended({required this.messageId});

  /// The message that grew.
  final String messageId;
}

/// A message's status moved from [from] to [to]
/// (maps `StoreEvent.MessageStatusChanged`).
final class MessageStatusUpdated extends RepoEvent {
  /// Creates the event.
  const MessageStatusUpdated({
    required this.messageId,
    required this.from,
    required this.to,
  });

  /// The message whose status changed.
  final String messageId;

  /// The previous status.
  final MessageStatus from;

  /// The new status.
  final MessageStatus to;
}

/// Read/write access to session history. The **only** entry point — the UI must
/// never reach into `SessionStore` or the DAOs directly (spec §3.2).
abstract interface class SessionRepository {
  /// Broadcast domain events (see [RepoEvent]).
  Stream<RepoEvent> get events;

  // ── Read (synchronous; the store is a sync API, M3 §9.2) ───────────────

  /// Conversations, most recently active first. Archived threads are excluded
  /// unless [includeArchived] is `true`.
  List<Conversation> conversations({bool includeArchived = false});

  /// The messages of [conversationId] in chronological order, at most [limit].
  List<ChatMessage> history(String conversationId, {int? limit});

  /// The files attached to [messageId].
  List<FileAttachment> filesOf(String messageId);

  /// Delivery progress for [fileId], or `null` when unknown.
  TransferProgress? transferOf(String fileId);

  /// The stored device row for [fingerprint] (normalised), or `null`
  /// (spec §3.3 Q5).
  PeerDevice? device(String fingerprint);

  /// Every stored device row, most recently seen first (spec §3.3 Q5).
  List<PeerDevice> devices();

  /// The messages whose status is in [statuses]
  /// (used by the E2 startup zombie cleanup).
  List<ChatMessage> messagesByStatus(Set<MessageStatus> statuses);

  /// When [messageId] last saw **activity** — the newest arrival/attempt over
  /// its files, falling back to the message's own `created_at`; `null` when the
  /// message does not exist.
  ///
  /// This is the one signal the receiver has for "is this batch still being
  /// sent?" (`docs/22` §4.4): `put` is per file and there is **no** "batch
  /// finished" frame, so a batch that stalled with N files missing looks
  /// exactly like a batch that is merely slow — unless you can measure silence.
  /// It answers for **both** shapes that can declare more than they delivered: a
  /// folder card and, since 0.2.52, a flat multi-select bubble.
  /// `selectors.dart::missingFolderFiles` is the only consumer, and it requires
  /// this to be quiet for `kFolderQuietPeriod` (90 s) before it will claim
  /// anything is missing.
  ///
  /// Returned in **UTC**, like every other timestamp in the repository layer, so
  /// a caller can subtract it from a `Clock.nowUtc()` without a timezone
  /// argument. Read-only: it opens no transaction and writes nothing.
  DateTime? lastActivityAt(String messageId);

  // ── Write (the adapter stamps `now` from its injected Clock, §8.3) ─────

  /// Persists an outgoing send and returns the (idempotent) message handle.
  ///
  /// [folder] marks the message as **one folder** rather than N loose files
  /// (0.2.38): the adapter stores its name and declared count on
  /// `messages.folder_name` / `folder_files`, and every file's
  /// [OutgoingFile.relativePath] on `files.relative_path`. `null` — every
  /// multi-select, drag-and-drop and share-import send — writes the same two
  /// `NULL`s it always did, so an old send is indistinguishable from before.
  ///
  /// The message id is unchanged by this: it is the `event_nonce` over the
  /// **sorted file ids** (`eventNonceForFiles`), so a folder is one message for
  /// the same reason a multi-select is — not because of the folder object.
  SendHandle recordOutgoing({
    required PeerDevice peer,
    required List<OutgoingFile> files,
    FolderRef? folder,
  });

  /// Persists one verified incoming file. Returns the created message, or
  /// `null` when the send was a deduplicated replay (spec §6.3 / E5).
  ///
  /// [publishError] is the reason exporting the file to the user-visible store
  /// failed, or `null` (0.2.23). The message is still recorded at `done` — the
  /// bytes arrived — but the reason is persisted with it so the UI can say
  /// 「已收到，但没能导出到「下载」」 instead of a bare 已完成, and so the
  /// explanation survives a restart.
  ChatMessage? recordIncoming({
    required PeerDevice sender,
    required IncomingFile file,
    String? publishError,
  });

  /// Persists **one file of a folder send**, folding the whole `prepare`
  /// session into a single message (0.2.38, `docs/22` §4.2).
  ///
  /// Called once per arriving file. The first call creates the message, the
  /// rest append to it — [sessionId] is the anchor, so no in-memory
  /// "session → message id" map is needed and a restart mid-batch simply
  /// re-attaches to the row the database already holds.
  ///
  /// **Which method to call (0.2.51).** A caller picks by the arrival's own
  /// shape, and the three cases are mutually exclusive:
  ///
  /// * `ReceivedTransfer.isFolder` → this method. The row gets a folder
  ///   descriptor, so the bubble draws a folder card with 打开文件夹;
  /// * a flat arrival **with** a `sessionId` → [recordIncomingSessionFile]
  ///   (a multi-select batch: one bubble, one row per file, no folder card);
  /// * a flat arrival **without** a `sessionId` → [recordIncoming].
  ///
  /// This replaces the pre-0.2.51 wording "never merge the two", which said a
  /// flat arrival must always be one file per message. That was true of the
  /// single-file send and wrong about the batch: a multi-select is one
  /// `prepare` carrying N files, so its N arrivals share a session and belong in
  /// one bubble. What must still never happen is the reverse — a **folder**
  /// arrival taking the batch/flat path (it would lose its descriptor and draw
  /// N loose rows) or a flat arrival taking this one (it would grow a folder
  /// card and a directory page for something the user never sent as a folder).
  ///
  /// [folderFiles] is the sender's **declared** count; the honest "how many
  /// arrived" is the number of `files` rows for [sessionId]'s message.
  ///
  /// Returns which rows this call actually created. `createdMessage` is `true`
  /// for exactly one call per session — a 200-file folder must not emit 200
  /// "message added" events at the UI — and `createdFile` is `true` when the
  /// attachment was new (a re-delivered file is a normal shape here, not an
  /// error).
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
  });

  /// Persists **one file of a flat multi-select send**, folding the whole
  /// `prepare` session into a single message (0.2.51).
  ///
  /// The sibling of [recordIncomingFolderFile] without the folder descriptor:
  /// `folder_name` stays `NULL`, so `ChatMessage.isFolder` is `false` and the
  /// bubble draws one row per attachment instead of a folder card. Why it
  /// exists: the sender already encodes N selected files as one `prepare`, and
  /// every arrival already carries the receiver's session id — the only thing
  /// that used to split the batch was the store anchoring each file on its own
  /// `fileId`.
  ///
  /// [recordIncoming] stays what a **single-file** send uses, and its behaviour
  /// is unchanged: one file, one message. A caller must not send a single-file
  /// arrival here (it would still work, but the message id would depend on the
  /// session id rather than on the file, which changes history identity for no
  /// benefit), and must not send a folder arrival here (the folder descriptor
  /// would be dropped).
  ///
  /// **[folderFiles] is the sender's *declared* count for this session** — 0.2.52.
  /// `core` fills `ReceivedFile.folderFiles` with the number of files the
  /// `prepare` declared (0 for a one-file session), and it is the only input the
  /// 「N 个未收到」 line needs: `declared - arrived`, judged against the 90 s
  /// quiet period. It is stored in `messages.folder_files` while `folder_name`
  /// stays `NULL`, so `isFolder` is still false — a count is not a descriptor,
  /// and a batch must not grow a folder card or a directory page. Defaults to
  /// `0` ("nothing declared", stored as `NULL`), which is what every other
  /// caller and every pre-0.2.52 record means.
  ///
  /// Returns the same triple as [recordIncomingFolderFile]:
  /// `createdMessage` is `true` for exactly one call per session, `createdFile`
  /// for every call that really added an attachment. Later calls also emit
  /// `MessageFilesAppended`, which is what keeps a growing bubble from freezing
  /// after its first file.
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
  });

  /// Persists an outgoing **text** message and returns the (idempotent) handle.
  ///
  /// The text mirror of [recordOutgoing]: no files, no transfers. [nonce] is
  /// the event anchor — minted **once per logical send** and **reused on every
  /// retry** (the text analogue of `OutgoingFile.id`, M3 §5.6) — so a retry
  /// de-duplicates instead of inserting a second row. The adapter persists it
  /// as the store's `event_nonce`.
  SendHandle recordOutgoingText({
    required PeerDevice peer,
    required String text,
    required String nonce,
  });

  /// Persists one incoming **text** message. Returns the created message, or
  /// `null` when it was a deduplicated replay.
  ///
  /// [nonce] is the sender's nonce carried by the wire frame
  /// (`TextMessage.id`, docs/13 §7.3); a re-delivery of the same frame reuses
  /// it, so the message de-duplicates. The message lands directly at `done`.
  ChatMessage? recordIncomingText({
    required PeerDevice sender,
    required String text,
    required String nonce,
  });

  /// Transitions [messageId] from [from] to [to]; `false` when the move is
  /// illegal (the status machine rejects it).
  bool setStatus({
    required String messageId,
    required MessageStatus from,
    required MessageStatus to,
  });

  /// Records the peer's session id + per-file token for an in-flight send.
  void attachSession({
    required String fileId,
    required String sessionId,
    required String token,
  });

  /// Records [bytesDone] uploaded for [fileId].
  void markTransferProgress({required String fileId, required int bytesDone});

  /// Marks [messageId] as delivered (`done`).
  void markSendSucceeded({required String messageId});

  /// Marks [messageId] as failed with [error].
  void markSendFailed({required String messageId, required String error});

  /// Deletes [messageId] from the **local** history (0.2.36).
  ///
  /// Local only, and that is the whole scope of this release: the protocol has
  /// no delete frame, so the peer's copy stays; and no file on disk is touched,
  /// so a received file is still where it was written after its bubble is gone.
  /// There is no undo — a deleted message is gone from the store.
  ///
  /// Returns `true` when a row was removed, `false` when there was nothing to
  /// remove (already deleted, or never existed) — so a second call is a no-op
  /// rather than an error.
  ///
  /// Callers must not delete a message that is **still in flight** (`pending` /
  /// `awaitingConfirm` / `transferring`): the row would be gone while the
  /// transfer kept running. `ConversationController.deleteMessage` enforces it.
  bool deleteMessage(String messageId);

  /// Opens (or reuses) the active conversation for [deviceFingerprint].
  Conversation openActive({required String? deviceFingerprint});

  /// Archives [conversationId] (hidden from the home list; Q8).
  void archiveConversation(String conversationId);

  /// E2: on launch, flips every leftover `awaiting_confirm` / `transferring`
  /// message to **failed** (never back to `pending`). Returns how many changed.
  int failInterruptedMessages();

  /// Releases any underlying resources (e.g. the database connection).
  void close();
}
