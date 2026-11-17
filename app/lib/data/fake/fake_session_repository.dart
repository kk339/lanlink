import 'dart:async';

import '../../domain/clock.dart';
import '../../domain/id_factory.dart';
import '../../domain/models.dart';
import '../../domain/session_repository.dart';
import '../../domain/text_limits.dart';

/// In-memory [SessionRepository] used by every controller / widget test and by
/// the Web preview.
///
/// Pure Dart: it imports only `dart:async` and this app's `domain/` (M4 §8.1),
/// so it compiles on Web/VM with no `dart:io`, `dart:ffi`, `lanlink_core` or
/// `lanlink_store`. Time comes from the injected [Clock] and ids from the
/// injected [IdFactory]; the fake never reads a real clock or an RNG.
///
/// Event order mirrors the real adapter (M4 §8.8): a message is added, then any
/// status change follows — never the other way round.
class FakeSessionRepository implements SessionRepository {
  /// Creates an empty repository. [devices] are seeded as known device rows.
  FakeSessionRepository({
    required Clock clock,
    required IdFactory ids,
    List<PeerDevice> devices = const <PeerDevice>[],
  })  : _clock = clock,
        _ids = ids {
    for (final device in devices) {
      _devices[device.fingerprint] = device;
    }
  }

  final Clock _clock;
  final IdFactory _ids;

  final StreamController<RepoEvent> _events =
      StreamController<RepoEvent>.broadcast();

  final Map<String, Conversation> _conversations = <String, Conversation>{};
  final Map<String, ChatMessage> _messages = <String, ChatMessage>{};
  final Map<String, List<FileAttachment>> _files =
      <String, List<FileAttachment>>{};
  final Map<String, TransferProgress> _transfers = <String, TransferProgress>{};
  final Map<String, PeerDevice> _devices = <String, PeerDevice>{};
  final Map<String, String> _sessions = <String, String>{};

  /// The folder each outgoing message was recorded with (0.2.38), keyed by
  /// message id. Absent = a flat send, which is also what every pre-0.2.38 test
  /// fixture is.
  final Map<String, FolderRef> _outboundFolders = <String, FolderRef>{};

  /// The folder each **incoming** folder message was recorded with (0.2.38).
  ///
  /// `declared` is the sender's number, not the number that arrived — a test
  /// that wants the latter counts `filesOf(messageId)`.
  final Map<String, ({String name, int declared})> _inboundFolders =
      <String, ({String name, int declared})>{};

  /// When each message last saw activity, keyed by message id (0.2.42).
  ///
  /// The real store **derives** this on read — `MAX(transfers.updated_at)` over
  /// the message's files, falling back to `messages.created_at`
  /// (`SessionStore.lastActivityAt`) — so the fake has to keep the equivalent
  /// fact explicitly; there is no transfer clock here to max over. Every write
  /// the real store would have moved `transfers.updated_at` with moves it here,
  /// in the same places, so a folder that keeps receiving files keeps its
  /// activity fresh in the fake too — otherwise a fake-driven test would report
  /// 「N 个未收到」 on a folder that is demonstrably still arriving.
  final Map<String, DateTime> _activityAt = <String, DateTime>{};

  /// file id → the message it belongs to, so a **transfer**-level write
  /// (`markTransferProgress` / `attachSession`) can find the message whose
  /// activity it bumps — the same join the real store's query does.
  final Map<String, String> _fileMessage = <String, String>{};

  /// The folder [recordOutgoing] was given for [messageId], or `null` when that
  /// message is not a folder send (0.2.38).
  FolderRef? outboundFolderOf(String messageId) => _outboundFolders[messageId];

  /// The folder [recordIncomingFolderFile] recorded for [messageId], or `null`
  /// when that message is a flat arrival (0.2.38).
  ({String name, int declared})? inboundFolderOf(String messageId) =>
      _inboundFolders[messageId];

  /// Overwrites the activity instant of [messageId] (test / preview only).
  ///
  /// This is the fake's equivalent of "the last `put` for this folder happened
  /// at T", which no amount of pumping can produce deterministically: the widget
  /// tests need a folder that has been **silent for 200 s** without waiting 200
  /// seconds. `null` forgets the message's activity entirely, which is how the
  /// "unknown, so claim nothing" path is reachable.
  void setLastActivity(String messageId, DateTime? at) {
    if (at == null) {
      _activityAt.remove(messageId);
      return;
    }
    _activityAt[messageId] = at;
  }

  bool _closed = false;

  @override
  Stream<RepoEvent> get events => _events.stream;

  // ── seeding helpers (test / preview only) ─────────────────────────────

  /// Registers (or replaces) a device row so `device()` / `devices()` answer.
  void addDevice(PeerDevice device) => _devices[device.fingerprint] = device;

  /// Inserts a conversation and returns it. [id] defaults to a fresh one.
  Conversation addConversation({
    String? id,
    String? deviceFingerprint,
    DateTime? createdAt,
    DateTime? lastMessageAt,
    String? lastPreview,
    bool isArchived = false,
  }) {
    final now = _clock.nowUtc();
    final conversation = Conversation(
      id: id ?? _ids.newId(),
      deviceFingerprint: deviceFingerprint,
      createdAt: createdAt ?? now,
      lastMessageAt: lastMessageAt,
      lastPreview: lastPreview,
      isArchived: isArchived,
    );
    _conversations[conversation.id] = conversation;
    return conversation;
  }

  /// Inserts a message (bypassing the state machine, so any status is seedable)
  /// together with its [files] and one transfer per file.
  ChatMessage addMessage({
    required String id,
    required String conversationId,
    required MessageDirection direction,
    required MessageStatus status,
    MessageKind kind = MessageKind.file,
    String? textBody,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<FileAttachment> files = const <FileAttachment>[],
    String? folderName,
    int folderFiles = 0,
    String? eventNonce,
  }) {
    final now = _clock.nowUtc();
    final message = ChatMessage(
      id: id,
      conversationId: conversationId,
      direction: direction,
      kind: kind,
      textBody: textBody,
      createdAt: createdAt ?? now,
      updatedAt: updatedAt ?? createdAt ?? now,
      status: status,
      folderName: folderName,
      folderFiles: folderFiles,
      eventNonce: eventNonce,
    );
    _messages[id] = message;
    // Activity is seeded from `created_at`, exactly like the store's fallback:
    // these rows exist without any transfer having ever moved.
    _activityAt[id] = message.createdAt;
    if (files.isNotEmpty) {
      _files[id] = List<FileAttachment>.of(files);
      for (final file in files) {
        _fileMessage[file.id] = id;
        _transfers[file.id] = TransferProgress(
          fileId: file.id,
          bytesDone: status == MessageStatus.done ? file.size : 0,
          bytesTotal: file.size,
        );
      }
    }
    return message;
  }

  /// Overwrites the transfer row for [progress].
  void addTransfer(TransferProgress progress) =>
      _transfers[progress.fileId] = progress;

  /// How many times [markTransferProgress] was called (test convenience).
  ///
  /// Lets a test assert that the orchestrator **throttles persistence**, which
  /// is otherwise invisible: the row ends up at the right value either way, so
  /// only the count distinguishes "one write per MiB" from "one per 500 ms".
  int progressWrites = 0;

  /// The session id most recently attached to [fileId], or `null`.
  String? sessionOf(String fileId) => _sessions[fileId];

  /// How many `MessageFilesAppended` events this fake has emitted (0.2.51).
  ///
  /// A **count**, not just an observable stream, because the interesting failure
  /// here is a rate and not an existence: one batch of N folder files must
  /// announce exactly `N - 1` appends (the first file *creates* the message and
  /// is a `MessageAdded`), while a re-delivered file — which writes no row —
  /// must announce nothing at all. A test cannot tell "2" from "3" by listening
  /// for the event once, and it cannot tell it from "0" at all without a counter.
  ///
  /// Mirrors [progressWrites] in spirit: a test convenience on the fake only.
  int filesAppendedEvents = 0;

  // ── reads ─────────────────────────────────────────────────────────────

  @override
  List<Conversation> conversations({bool includeArchived = false}) {
    final list = _conversations.values
        .where((c) => includeArchived || !c.isArchived)
        .toList();
    list.sort((a, b) {
      final x = a.lastMessageAt;
      final y = b.lastMessageAt;
      if (x == null && y == null) {
        return a.id.compareTo(b.id);
      }
      if (x == null) {
        return 1;
      }
      if (y == null) {
        return -1;
      }
      final byTime = y.compareTo(x);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return list;
  }

  /// Makes every [history] call throw [error] (M5c §4 — a behaviour a test can
  /// drive, so the "history failed" UI is verifiable). `null` clears it.
  void failHistoryWith(Object? error) => _historyFailure = error;

  Object? _historyFailure;

  @override
  List<ChatMessage> history(String conversationId, {int? limit}) {
    // An injectable read failure (test / preview only) — the UI's failure state
    // must be reachable (M5c §4).
    final Object? failure = _historyFailure;
    if (failure != null) {
      throw failure;
    }
    final list = _messages.values
        .where((m) => m.conversationId == conversationId)
        .toList()
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    if (limit != null && list.length > limit) {
      return list.sublist(list.length - limit);
    }
    return list;
  }

  @override
  List<FileAttachment> filesOf(String messageId) =>
      List<FileAttachment>.of(_files[messageId] ?? const <FileAttachment>[]);

  @override
  TransferProgress? transferOf(String fileId) => _transfers[fileId];

  @override
  PeerDevice? device(String fingerprint) => _devices[fingerprint];

  @override
  List<PeerDevice> devices() {
    final list = _devices.values.toList();
    list.sort((a, b) {
      final x = a.lastSeenAt;
      final y = b.lastSeenAt;
      if (x == null && y == null) {
        return a.fingerprint.compareTo(b.fingerprint);
      }
      if (x == null) {
        return 1;
      }
      if (y == null) {
        return -1;
      }
      return y.compareTo(x);
    });
    return list;
  }

  @override
  List<ChatMessage> messagesByStatus(Set<MessageStatus> statuses) {
    final list =
        _messages.values.where((m) => statuses.contains(m.status)).toList()
          ..sort((a, b) {
            final byTime = a.createdAt.compareTo(b.createdAt);
            return byTime != 0 ? byTime : a.id.compareTo(b.id);
          });
    return list;
  }

  @override
  DateTime? lastActivityAt(String messageId) => _activityAt[messageId];

  // ── writes ────────────────────────────────────────────────────────────

  @override
  SendHandle recordOutgoing({
    required PeerDevice peer,
    required List<OutgoingFile> files,
    FolderRef? folder,
  }) {
    final now = _clock.nowUtc();
    final conversation = openActive(deviceFingerprint: peer.fingerprint);
    final nonce = (files.map((f) => f.id).toList()..sort()).join('\u001e');
    final messageId = 'out:${conversation.id}:$nonce';

    if (_messages.containsKey(messageId)) {
      return SendHandle(
        messageId: messageId,
        conversationId: conversation.id,
        created: false,
      );
    }

    // 0.2.38 — "落库" for the fake means recorded here, keyed by message id, so a
    // test can ask what the message *is* rather than what the caller *meant*.
    // A blank name is "not a folder", mirroring `store.SessionStore`, which drops
    // an unusable `FolderRef` rather than writing a title-less folder card.
    if (folder != null && folder.name.isNotEmpty) {
      _outboundFolders[messageId] = folder;
    } else {
      _outboundFolders.remove(messageId);
    }

    _messages[messageId] = ChatMessage(
      id: messageId,
      conversationId: conversation.id,
      direction: MessageDirection.outgoing,
      kind: MessageKind.file,
      createdAt: now,
      updatedAt: now,
      status: MessageStatus.pending,
      // 0.2.41: the fake records the folder **on the message** as well, the way the
      // real adapter writes `messages.folder_name` / `folder_files`. Without it a
      // forwarded folder came back as a pile of loose rows and no UI test could tell
      // "kept the descriptor" from "lost it".
      folderName: folder == null || folder.name.isEmpty ? null : folder.name,
      folderFiles: folder == null || folder.name.isEmpty ? 0 : folder.count,
    );
    _files[messageId] = <FileAttachment>[
      for (final file in files)
        FileAttachment(
          id: file.id,
          messageId: messageId,
          fileName: file.fileName,
          size: file.size,
          mime: file.mime,
          sha256: file.sha256,
          localPath: file.localPath,
          // …and each file keeps its position inside the folder
          // (`files.relative_path`), which is what the directory page builds from.
          relativePath: file.relativePath,
        ),
    ];
    for (final file in files) {
      _fileMessage[file.id] = messageId;
      _transfers[file.id] = TransferProgress(
        fileId: file.id,
        bytesDone: 0,
        bytesTotal: file.size,
      );
    }
    // Recording the send is itself activity (`transfers.updated_at` is written
    // with `now` by the store at this point).
    _activityAt[messageId] = now;
    _touchConversation(conversation.id, now, _previewOf(files));
    _events.add(MessageAdded(_messages[messageId]!));

    return SendHandle(
      messageId: messageId,
      conversationId: conversation.id,
      created: true,
    );
  }

  @override
  ChatMessage? recordIncoming({
    required PeerDevice sender,
    required IncomingFile file,
    String? publishError,
  }) {
    final now = _clock.nowUtc();
    final conversation = openActive(deviceFingerprint: sender.fingerprint);
    final messageId = 'in:${conversation.id}:${file.fileId}';

    if (_messages.containsKey(messageId)) {
      return null;
    }

    final message = ChatMessage(
      id: messageId,
      conversationId: conversation.id,
      direction: MessageDirection.incoming,
      kind: MessageKind.file,
      createdAt: now,
      updatedAt: now,
      status: MessageStatus.done,
    );
    _messages[messageId] = message;
    _files[messageId] = <FileAttachment>[
      FileAttachment(
        id: file.fileId,
        messageId: messageId,
        fileName: file.fileName,
        size: file.size,
        mime: file.mime,
        sha256: file.sha256,
        localPath: file.savedPath,
      ),
    ];
    _transfers[file.fileId] = TransferProgress(
      fileId: file.fileId,
      bytesDone: file.size,
      bytesTotal: file.size,
      // 0.2.23: the same place the real store keeps it (the transfer row's
      // `error`), so a fake-driven test sees exactly what a device would.
      error: publishError,
    );
    _fileMessage[file.fileId] = messageId;
    _activityAt[messageId] = now;
    _touchConversation(conversation.id, now, file.fileName);
    _events.add(MessageAdded(message));

    return message;
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
  }) =>
      _recordAggregated(
        sender: sender,
        file: file,
        sessionId: sessionId,
        folderName: folderName,
        folderFiles: folderFiles,
        publishError: publishError,
        // The folder shape (0.2.38): the folded message **is** the folder.
        idPrefix: 'in-folder',
      );

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
  }) =>
      _recordAggregated(
        sender: sender,
        file: file,
        sessionId: sessionId,
        // 0.2.51 — a multi-select batch: the aggregation is identical, the
        // descriptor is absent, so the bubble stays a multi-row bubble and the
        // folder page / 打开文件夹 are never offered for it.
        folderName: null,
        // 0.2.52 — …but the *declared count* is not the descriptor. It mirrors
        // `messages.folder_files`: a batch that declared 8 files keeps the
        // number (so the thread can print 「5 个未收到」) while `folderName`
        // stays `null` (so `isFolder` stays false and no card is drawn).
        folderFiles: folderFiles,
        publishError: publishError,
        idPrefix: 'in-batch',
      );

  /// The shared write behind both aggregating paths (folder and flat batch).
  ///
  /// [idPrefix] is part of the message id, so the two shapes cannot collide even
  /// if a test reused one session id across them — mirroring the store's two
  /// disjoint nonce families (`eventNonceForFolderSession` /
  /// `eventNonceForBatchSession`). A `null` [folderName] means "no descriptor":
  /// `isFolder` stays false and no `_inboundFolders` row is written.
  ({String messageId, bool createdMessage, bool createdFile}) _recordAggregated({
    required PeerDevice sender,
    required IncomingFile file,
    required String sessionId,
    required String idPrefix,
    String? folderName,
    int folderFiles = 0,
    String? publishError,
  }) {
    final now = _clock.nowUtc();
    final conversation = openActive(deviceFingerprint: sender.fingerprint);
    // The **session** is the anchor (docs/22 §4.2): every file of one `prepare`
    // lands on the same message id, so the N arrivals become one message with N
    // attachments without any in-memory map — and a restart mid-batch simply
    // re-finds the row the database already holds.
    final messageId = '$idPrefix:${conversation.id}:$sessionId';

    final existing = _messages[messageId];
    final bool createdMessage = existing == null;
    if (createdMessage) {
      _messages[messageId] = ChatMessage(
        id: messageId,
        conversationId: conversation.id,
        direction: MessageDirection.incoming,
        kind: MessageKind.file,
        createdAt: now,
        updatedAt: now,
        status: MessageStatus.done,
        // 0.2.38 / T05: the folded message **is** the folder, so the two columns
        // travel with it (the real adapter stores the same pair). `null` for a
        // batch — the real store leaves `folder_name` NULL for that path.
        folderName: folderName,
        folderFiles: folderFiles,
      );
      _files[messageId] = <FileAttachment>[];
      if (folderName != null) {
        _inboundFolders[messageId] = (name: folderName, declared: folderFiles);
      }
    }

    final List<FileAttachment> attachments = _files[messageId]!;
    final bool createdFile =
        !attachments.any((FileAttachment f) => f.id == file.fileId);
    if (createdFile) {
      attachments.add(
        FileAttachment(
          id: file.fileId,
          messageId: messageId,
          fileName: file.fileName,
          size: file.size,
          mime: file.mime,
          sha256: file.sha256,
          localPath: file.savedPath,
          relativePath: file.relativePath,
        ),
      );
      _transfers[file.fileId] = TransferProgress(
        fileId: file.fileId,
        bytesDone: file.size,
        bytesTotal: file.size,
        error: publishError,
      );
      _fileMessage[file.fileId] = messageId;
      // ★ A **new** arrival restarts the quiet window. A duplicate one must not:
      // the store's `insertIfAbsent` writes nothing for a re-delivered file, so a
      // peer that keeps re-offering the same file would never look stalled if the
      // fake bumped here unconditionally.
      _activityAt[messageId] = now;
    }

    // One `MessageAdded` per session, not per file: a 200-file folder must not
    // push 200 "message added" events at the UI.
    if (createdMessage) {
      _touchConversation(conversation.id, now, folderName ?? file.fileName);
      _events.add(MessageAdded(_messages[messageId]!));
    } else if (createdFile) {
      // 0.2.51 — files 2…N of one session **grow** a message that is already on
      // screen, so they are invisible to anything that keys off "a message
      // arrived" (the real store had the same hole; see `MessageFilesAppended`
      // in `store/lib/src/store/store_events.dart`). One event per file that
      // actually wrote a row:
      //
      //  * the file that created the message is a `MessageAdded` and must not
      //    also be announced here, or a 3-file batch would cost 3 events for
      //    1 message and 2 appends;
      //  * a **re-delivered** file writes no row, so it announces nothing — the
      //    exact rule the store's `insertIfAbsent` gives us for free.
      filesAppendedEvents++;
      _events.add(MessageFilesAppended(messageId: messageId));
    }

    return (
      messageId: messageId,
      createdMessage: createdMessage,
      createdFile: createdFile,
    );
  }

  @override
  SendHandle recordOutgoingText({
    required PeerDevice peer,
    required String text,
    required String nonce,
  }) {
    final now = _clock.nowUtc();
    final conversation = openActive(deviceFingerprint: peer.fingerprint);
    final messageId = 'out:${conversation.id}:$nonce';

    if (_messages.containsKey(messageId)) {
      return SendHandle(
        messageId: messageId,
        conversationId: conversation.id,
        created: false,
      );
    }

    _messages[messageId] = ChatMessage(
      id: messageId,
      conversationId: conversation.id,
      direction: MessageDirection.outgoing,
      kind: MessageKind.text,
      textBody: text,
      createdAt: now,
      updatedAt: now,
      status: MessageStatus.pending,
      // 0.2.40 — the anchor the outbox pump reuses when it resumes this row.
      // Dropping it here would make the fake's queued text send unresumable and
      // the pump's text path untestable.
      eventNonce: nonce,
    );
    // Timing note: the fake sets the preview here, at record time, whereas the
    // real store sets it on success. That difference is deliberate (the fake has
    // no async success step) — but the **truncation** matches `store`'s 120, so
    // a fake-driven test cannot pass where the real one would not.
    _activityAt[messageId] = now;
    _touchConversation(conversation.id, now, truncatePreview(text));
    _events.add(MessageAdded(_messages[messageId]!));

    return SendHandle(
      messageId: messageId,
      conversationId: conversation.id,
      created: true,
    );
  }

  @override
  ChatMessage? recordIncomingText({
    required PeerDevice sender,
    required String text,
    required String nonce,
  }) {
    final now = _clock.nowUtc();
    final conversation = openActive(deviceFingerprint: sender.fingerprint);
    final messageId = 'in:${conversation.id}:$nonce';

    if (_messages.containsKey(messageId)) {
      return null;
    }

    final message = ChatMessage(
      id: messageId,
      conversationId: conversation.id,
      direction: MessageDirection.incoming,
      kind: MessageKind.text,
      textBody: text,
      createdAt: now,
      updatedAt: now,
      status: MessageStatus.done,
    );
    _messages[messageId] = message;
    _activityAt[messageId] = now;
    _touchConversation(conversation.id, now, truncatePreview(text));
    _events.add(MessageAdded(message));

    return message;
  }

  @override
  bool setStatus({
    required String messageId,
    required MessageStatus from,
    required MessageStatus to,
  }) {
    final message = _messages[messageId];
    if (message == null || message.status != from) {
      return false;
    }
    if (!_canTransition(from, to)) {
      throw StateError(
        'illegal message status transition: ${from.wire} -> ${to.wire}',
      );
    }
    _messages[messageId] = message.copyWith(
      status: to,
      updatedAt: _clock.nowUtc(),
    );
    _events.add(MessageStatusUpdated(messageId: messageId, from: from, to: to));
    return true;
  }

  @override
  void attachSession({
    required String fileId,
    required String sessionId,
    required String token,
  }) {
    _sessions[fileId] = sessionId;
    // `transfers.updated_at` is written by the store's `attachSession`, so this
    // is activity for the file's message.
    _bumpActivityForFile(fileId);
  }

  @override
  void markTransferProgress({required String fileId, required int bytesDone}) {
    progressWrites++;
    // ★ The heartbeat of a live send: the store writes `bytes_done` **and**
    // `updated_at` here, which is exactly what keeps a 200-file folder from ever
    // looking stalled while it is actually arriving.
    _bumpActivityForFile(fileId);
    final current = _transfers[fileId];
    if (current == null) {
      return;
    }
    _transfers[fileId] = TransferProgress(
      fileId: current.fileId,
      bytesDone: bytesDone,
      bytesTotal: current.bytesTotal,
      error: current.error,
    );
  }

  @override
  void markSendSucceeded({required String messageId}) {
    final message = _messages[messageId];
    if (message == null) {
      return;
    }
    final from = message.status;
    _messages[messageId] = message.copyWith(
      status: MessageStatus.done,
      updatedAt: _clock.nowUtc(),
    );
    for (final file in _files[messageId] ?? const <FileAttachment>[]) {
      final transfer = _transfers[file.id];
      if (transfer != null) {
        _transfers[file.id] = TransferProgress(
          fileId: transfer.fileId,
          bytesDone: transfer.bytesTotal,
          bytesTotal: transfer.bytesTotal,
        );
      }
    }
    _activityAt[messageId] = _clock.nowUtc();
    _events.add(
      MessageStatusUpdated(
        messageId: messageId,
        from: from,
        to: MessageStatus.done,
      ),
    );
  }

  @override
  void markSendFailed({required String messageId, required String error}) {
    final message = _messages[messageId];
    if (message == null) {
      return;
    }
    final from = message.status;
    _messages[messageId] = message.copyWith(
      status: MessageStatus.failed,
      updatedAt: _clock.nowUtc(),
    );
    for (final file in _files[messageId] ?? const <FileAttachment>[]) {
      final transfer = _transfers[file.id];
      if (transfer != null) {
        _transfers[file.id] = TransferProgress(
          fileId: transfer.fileId,
          bytesDone: transfer.bytesDone,
          bytesTotal: transfer.bytesTotal,
          error: error,
        );
      }
    }
    _activityAt[messageId] = _clock.nowUtc();
    _events.add(
      MessageStatusUpdated(
        messageId: messageId,
        from: from,
        to: MessageStatus.failed,
      ),
    );
  }

  @override
  bool deleteMessage(String messageId) {
    if (_messages.remove(messageId) == null) {
      return false;
    }
    // Mirror the real store's sub-tree delete (0.2.36): the attachments and
    // their transfer rows go with the message, so `filesOf` / `transferOf`
    // cannot answer for a message that no longer exists.
    final files = _files.remove(messageId) ?? const <FileAttachment>[];
    for (final file in files) {
      _transfers.remove(file.id);
      _fileMessage.remove(file.id);
    }
    _activityAt.remove(messageId);
    _inboundFolders.remove(messageId);
    _outboundFolders.remove(messageId);
    return true;
  }

  @override
  Conversation openActive({required String? deviceFingerprint}) {
    if (deviceFingerprint != null) {
      for (final conversation in _conversations.values) {
        if (!conversation.isArchived &&
            conversation.deviceFingerprint == deviceFingerprint) {
          return conversation;
        }
      }
    }
    return addConversation(deviceFingerprint: deviceFingerprint);
  }

  @override
  void archiveConversation(String conversationId) {
    final conversation = _conversations[conversationId];
    if (conversation == null) {
      return;
    }
    _conversations[conversationId] = Conversation(
      id: conversation.id,
      deviceFingerprint: conversation.deviceFingerprint,
      createdAt: conversation.createdAt,
      lastMessageAt: conversation.lastMessageAt,
      lastPreview: conversation.lastPreview,
      isArchived: true,
    );
  }

  @override
  int failInterruptedMessages() {
    var count = 0;
    for (final entry in _messages.entries.toList()) {
      final message = entry.value;
      if (message.status == MessageStatus.awaitingConfirm ||
          message.status == MessageStatus.transferring) {
        _messages[entry.key] = message.copyWith(
          status: MessageStatus.failed,
          updatedAt: _clock.nowUtc(),
        );
        _events.add(
          MessageStatusUpdated(
            messageId: entry.key,
            from: message.status,
            to: MessageStatus.failed,
          ),
        );
        count++;
      }
    }
    return count;
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _events.close();
  }

  /// Stamps the message that owns [fileId] as "active now".
  ///
  /// The real store derives [lastActivityAt] from `transfers.updated_at`, so
  /// every transfer-level write moves it without naming a message; the fake has
  /// to translate file → message through [_fileMessage] to say the same thing.
  /// An unknown file (no message, or a message already deleted) is a no-op — the
  /// store's join would simply have matched no row.
  void _bumpActivityForFile(String fileId) {
    final String? messageId = _fileMessage[fileId];
    if (messageId == null || !_messages.containsKey(messageId)) {
      return;
    }
    _activityAt[messageId] = _clock.nowUtc();
  }

  void _touchConversation(String id, DateTime at, String? preview) {
    final conversation = _conversations[id];
    if (conversation == null) {
      return;
    }
    _conversations[id] = Conversation(
      id: conversation.id,
      deviceFingerprint: conversation.deviceFingerprint,
      createdAt: conversation.createdAt,
      lastMessageAt: at,
      lastPreview: preview ?? conversation.lastPreview,
      isArchived: conversation.isArchived,
    );
  }

  String? _previewOf(List<OutgoingFile> files) =>
      files.isEmpty ? null : files.first.fileName;
}

/// The fourteen legal status edges, mirroring `store`'s state machine (M3
/// §5.5 + the two text `pending → done` / `pending → rejected` edges of
/// docs/13 §7.3). The fake keeps its own copy because it may not import
/// `lanlink_store`.
const Set<(MessageStatus, MessageStatus)> _legalEdges =
    <(MessageStatus, MessageStatus)>{
  (MessageStatus.pending, MessageStatus.awaitingConfirm),
  (MessageStatus.pending, MessageStatus.done),
  (MessageStatus.pending, MessageStatus.rejected),
  (MessageStatus.pending, MessageStatus.canceled),
  (MessageStatus.pending, MessageStatus.failed),
  (MessageStatus.awaitingConfirm, MessageStatus.transferring),
  (MessageStatus.awaitingConfirm, MessageStatus.rejected),
  (MessageStatus.awaitingConfirm, MessageStatus.failed),
  (MessageStatus.awaitingConfirm, MessageStatus.canceled),
  (MessageStatus.transferring, MessageStatus.done),
  (MessageStatus.transferring, MessageStatus.failed),
  (MessageStatus.transferring, MessageStatus.canceled),
  (MessageStatus.failed, MessageStatus.pending),
  (MessageStatus.failed, MessageStatus.canceled),
};

bool _canTransition(MessageStatus from, MessageStatus to) =>
    _legalEdges.contains((from, to));
