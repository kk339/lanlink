/// The `SessionStore` facade — the single place that opens a transaction and
/// the single entry point the CLI/UI uses to read and write conversation
/// history (spec §5.4).
///
/// Design rules enforced here:
///
/// * every write use-case runs **inside one transaction**, so a failure rolls
///   the whole thing back (spec §9.5);
/// * `now` and the [IdGenerator] are injected — the store never reads the clock
///   (spec §5.10), which keeps every test deterministic;
/// * the DAOs are single-table and never open their own transaction; the facade
///   is the only transaction owner (spec §5.4);
/// * the message id is the pure `computeMessageId` result and is **not**
///   injected, so it is recomputable and regression-testable (spec §5.6).
library;

import 'dart:async';

import 'package:lanlink_core/lanlink_core.dart';

import '../dao/conversations_dao.dart';
import '../dao/devices_dao.dart';
import '../dao/files_dao.dart';
import '../dao/messages_dao.dart';
import '../dao/transfers_dao.dart';
import '../db/lanlink_database.dart';
import '../db/time_codec.dart';
import '../errors/store_errors.dart';
import '../ids/ids.dart';
import '../ids/message_id.dart';
import '../models/conversation_record.dart';
import '../models/device_record.dart';
import '../models/message_file_record.dart';
import '../models/message_record.dart';
import '../models/transfer_record.dart';
import 'store_events.dart';

/// Longest conversation preview stored for a text message, in Unicode code
/// points. A text message's preview is its body (docs/13 §7.3); one named
/// constant so the length is tuned in a single place.
const int kPreviewMaxChars = 120;

/// The folder a group of files was sent as (docs/22 §2.3 / §6·T02).
///
/// A folder send is **one** message with N attachments, so it needs exactly the
/// two facts the sender alone knows: the display name and the **declared** file
/// count. What has actually arrived is counted from `files`, never stored
/// (docs/22 §2.5).
///
/// Kept as a small value object at this boundary (rather than reusing core's
/// wire `FolderDescriptor`) for two reasons: this layer writes **database
/// rows**, and it is imported with a `store.` prefix by the app's data layer,
/// so the name `FolderRef` cannot collide with the UI's own domain type of the
/// same shape.
class FolderRef {
  /// Creates a folder reference.
  const FolderRef({required this.name, required this.count});

  /// Display name of the folder — a single path segment, already sanitised by
  /// the layer that owns the filesystem (never `null`, never `/`-joined).
  final String name;

  /// The number of files the sender declared for this folder; `> 0`.
  final int count;

  /// Whether this reference carries anything worth storing.
  ///
  /// An unnamed folder is treated as "not a folder" by the write paths below,
  /// which keeps a blank name from producing a message that renders as a folder
  /// with no title.
  bool get isUsable => name.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is FolderRef && other.name == name && other.count == count;

  @override
  int get hashCode => Object.hash(name, count);

  @override
  String toString() => 'FolderRef($name, count: $count)';
}

/// The caller's description of one file to send (spec §5.4).
class OutgoingFileSpec {
  /// Creates a spec.
  const OutgoingFileSpec({
    required this.id,
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.localPath,
    this.mime,
    this.chunkSize,
    this.relativePath,
  });

  /// The wire `fileId`. Minted once per send and **reused on every retry**
  /// (spec §5.6) — regenerating it would change the idempotent message id.
  final String id;

  /// The file's name on the wire.
  final String fileName;

  /// Size in bytes; `-1` means unknown.
  final int size;

  /// Uppercase-hex SHA-256, already computed by the M2 send path.
  final String sha256;

  /// Absolute path of the source file on this machine.
  final String localPath;

  /// MIME type, or `null`.
  final String? mime;

  /// Negotiated chunk size, or `null`.
  final int? chunkSize;

  /// Where this file sits inside the folder being sent, or `null` for a flat
  /// send (docs/22 §2.3).
  ///
  /// Relative to the folder root, `/`-separated, folder name **not** included —
  /// the name lives once on [FolderRef.name]. `null` (never `''`) for an
  /// ordinary drag-and-drop / multi-select send, so `relativePath != null`
  /// means "this attachment has a level".
  final String? relativePath;
}

/// The caller's description of one verified incoming file (spec §5.4).
class IncomingFileSpec {
  /// Creates a spec.
  const IncomingFileSpec({
    required this.fileId,
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.savedPath,
    this.mime,
    this.publishError,
    this.relativePath,
  });

  /// Builds a spec from a core [ReceivedFile].
  ///
  /// By the time a [ReceivedFile] exists the hash has already been verified on
  /// the success path, so nothing else is needed here.
  factory IncomingFileSpec.fromReceivedFile(ReceivedFile file) =>
      IncomingFileSpec(
        fileId: file.fileId,
        fileName: file.fileName,
        size: file.size,
        sha256: file.sha256,
        savedPath: file.savedPath,
        relativePath: file.relativePath,
      );

  /// Sender-assigned wire file id.
  final String fileId;

  /// Sanitised name that was actually written to disk.
  final String fileName;

  /// Number of bytes received; `-1` means unknown.
  final int size;

  /// Uppercase-hex SHA-256 computed while streaming.
  final String sha256;

  /// Absolute path where the file was written.
  final String savedPath;

  /// MIME type, or `null`.
  final String? mime;

  /// Why exporting the file to the user-visible store failed, or `null`
  /// (0.2.23).
  ///
  /// The receive **succeeded** — the bytes are on disk and hash-verified — but
  /// the file stayed in the app's private directory instead of landing in
  /// `下载`. Stored on the transfer row (the only column that already exists for
  /// "what went wrong with this delivery"), so the reason survives a restart
  /// and the bubble can keep saying "已收到，但没能导出" forever rather than
  /// losing the explanation the first time the app is killed.
  final String? publishError;

  /// Where this file was actually written inside its folder, or `null` when it
  /// landed flat (docs/22 §2.3 / §4.3).
  ///
  /// Relative to the folder root, `/`-separated, folder name not included. It
  /// is the path **as written** — a de-duplicating rename (`x.dll` →
  /// `x (1).dll`) appears here in its renamed form, because the database row is
  /// what the UI later opens.
  final String? relativePath;
}

/// A facade over the five DAOs: the only transaction owner in the data layer.
class SessionStore {
  /// Creates a store over [db], minting non-message ids from [ids].
  SessionStore({required LanlinkDatabase db, required IdGenerator ids})
      : _db = db,
        _ids = ids,
        _devices = DevicesDao(db),
        _conversations = ConversationsDao(db, ids),
        _messages = MessagesDao(db),
        _files = FilesDao(db),
        _transfers = TransfersDao(db);

  final LanlinkDatabase _db;
  final IdGenerator _ids;
  final DevicesDao _devices;
  final ConversationsDao _conversations;
  final MessagesDao _messages;
  final FilesDao _files;
  final TransfersDao _transfers;

  final StreamController<StoreEvent> _events =
      StreamController<StoreEvent>.broadcast();

  bool _closed = false;

  /// Broadcast stream of store changes, in the order they happened.
  Stream<StoreEvent> get events => _events.stream;

  // ── write use-cases (each in one transaction) ──────────────────────

  /// Records one outgoing send: ensures the device + conversation, inserts the
  /// message (`status = pending`), then its files and their transfers.
  ///
  /// A re-delivery of the same event (same fingerprint, direction, `fileId`s)
  /// de-duplicates on `ux_messages_event`: `created` is `false` and **nothing**
  /// else is touched — in particular files/transfers are not re-inserted, which
  /// their strict inserts would reject.
  ///
  /// [folder] is the folder this send represents, or `null` for a flat send
  /// (drag-and-drop / multi-select). It is written to `folder_name` /
  /// `folder_files` on the message row and **not** elsewhere; each attachment's
  /// level comes from [OutgoingFileSpec.relativePath] (docs/22 §2.3 / §3.6).
  ({String messageId, String conversationId, bool created})
      recordOutgoingFiles({
    required DeviceInfo peer,
    required List<OutgoingFileSpec> files,
    FolderRef? folder,
    required DateTime now,
  }) {
    _ensureOpen();
    final fingerprint = _requireFingerprint(peer);
    // An empty folder name is "not a folder": storing it would render a folder
    // card with no title, and `isFolder` must stay a single, unambiguous test.
    final FolderRef? usableFolder =
        folder != null && folder.isUsable ? folder : null;
    final folderName = usableFolder?.name;
    final folderFiles = usableFolder?.count;
    final result = _db.transaction<
        ({String messageId, String conversationId, MessageRecord? inserted})>(
      () {
        final existing = _devices.byFingerprint(fingerprint);
        final device = _devices.upsert(
          _deviceFromInfo(peer, lastIp: existing?.lastIp, now: now),
          now: now,
        );
        final conversation = _conversations.openActive(
          deviceFingerprint: device.fingerprint,
          now: now,
        );
        final eventNonce = eventNonceForFiles(files.map((file) => file.id));
        final contentKey = contentKeyForFiles(
          files.map(
            (file) => FileContentKey(
              fileName: file.fileName,
              size: file.size,
              sha256: file.sha256,
            ),
          ),
        );
        final message = MessageRecord(
          id: computeMessageId(
            fingerprint: device.fingerprint,
            direction: MessageDirection.outgoing,
            kind: MessageKind.file,
            eventNonce: eventNonce,
            contentKey: contentKey,
          ),
          conversationId: conversation.id,
          direction: MessageDirection.outgoing,
          kind: MessageKind.file,
          createdAt: now,
          updatedAt: now,
          status: MessageStatus.pending,
          eventNonce: eventNonce,
          folderName: folderName,
          folderFiles: folderFiles,
        );
        final inserted = _messages.insertIfAbsent(message);
        if (!inserted.created) {
          return (
            messageId: inserted.id,
            conversationId: conversation.id,
            inserted: null,
          );
        }
        for (final file in files) {
          _files.insert(
            MessageFileRecord(
              id: file.id,
              messageId: inserted.id,
              fileName: file.fileName,
              size: file.size,
              mime: file.mime,
              sha256: file.sha256,
              localPath: file.localPath,
              relativePath: file.relativePath,
            ),
          );
          _transfers.insert(
            TransferRecord(
              id: _ids.newId(),
              fileId: file.id,
              bytesTotal: file.size,
              chunkSize: file.chunkSize,
              updatedAt: now,
            ),
          );
        }
        return (
          messageId: inserted.id,
          conversationId: conversation.id,
          inserted: message,
        );
      },
    );

    final inserted = result.inserted;
    if (inserted != null) {
      _emit(MessageInserted(inserted));
    }
    return (
      messageId: result.messageId,
      conversationId: result.conversationId,
      created: inserted != null,
    );
  }

  /// Records one outgoing **text** message (docs/13 §7.3): ensures the device +
  /// conversation, then inserts a single `kind = text` message
  /// (`status = pending`).
  ///
  /// This is the text mirror of [recordOutgoingFiles] **without** the
  /// files/transfers loop — a text message has no attachments.
  ///
  /// [eventNonce] is the event anchor, supplied by the caller exactly as the
  /// file path takes it from the caller's `fileId`s: it is minted **once per
  /// logical send** and **reused on every retry** (spec §5.6.2). That reuse is
  /// what lets a re-delivery de-duplicate on `ux_messages_event`; a nonce
  /// regenerated per call would defeat the guard (two calls would insert two
  /// rows). The `contentKey` is `SHA-256(text_body)`, so the message id still
  /// reflects the body.
  ({String messageId, String conversationId, bool created}) recordOutgoingText({
    required DeviceInfo peer,
    required String text,
    required String eventNonce,
    required DateTime now,
  }) {
    _ensureOpen();
    final fingerprint = _requireFingerprint(peer);
    final result = _db.transaction<
        ({String messageId, String conversationId, MessageRecord? inserted})>(
      () {
        final existing = _devices.byFingerprint(fingerprint);
        final device = _devices.upsert(
          _deviceFromInfo(peer, lastIp: existing?.lastIp, now: now),
          now: now,
        );
        final conversation = _conversations.openActive(
          deviceFingerprint: device.fingerprint,
          now: now,
        );
        final message = MessageRecord(
          id: computeMessageId(
            fingerprint: device.fingerprint,
            direction: MessageDirection.outgoing,
            kind: MessageKind.text,
            eventNonce: eventNonce,
            contentKey: contentKeyForText(text),
          ),
          conversationId: conversation.id,
          direction: MessageDirection.outgoing,
          kind: MessageKind.text,
          textBody: text,
          createdAt: now,
          updatedAt: now,
          status: MessageStatus.pending,
          eventNonce: eventNonce,
        );
        final inserted = _messages.insertIfAbsent(message);
        return (
          messageId: inserted.id,
          conversationId: conversation.id,
          inserted: inserted.created ? message : null,
        );
      },
    );

    final inserted = result.inserted;
    if (inserted != null) {
      _emit(MessageInserted(inserted));
    }
    return (
      messageId: result.messageId,
      conversationId: result.conversationId,
      created: inserted != null,
    );
  }

  /// Records one completed incoming file as a single `inbound` message that is
  /// already `done` (spec §6.3 — M3 keeps no inbound `pending`/`transferring`
  /// state, and on the **flat** path one [ReceivedFile] is one message).
  ///
  /// This is the **single-file** path only, and it is unchanged. Two other
  /// shapes aggregate N arrivals into one message and must not come here:
  ///
  /// * a folder send → [recordIncomingFolderFile] (`folder_name` set, folder
  ///   card, declared count);
  /// * a flat multi-select → [recordIncomingSessionFile] (0.2.51: same session,
  ///   `folder_name` NULL, one row per attachment in one bubble).
  ///
  /// The caller decides by `ReceivedFile.folderName` and `sessionId`
  /// (`transfer_orchestrator.dart`), and the anchor here stays
  /// [eventNonceForFiles] over the single `fileId` — so a one-file send keeps
  /// producing exactly the row it produced before either aggregation existed.
  ({String messageId, bool created}) recordIncomingFile({
    required DeviceInfo sender,
    required IncomingFileSpec file,
    required DateTime now,
  }) {
    _ensureOpen();
    final fingerprint = _requireFingerprint(sender);
    final result =
        _db.transaction<({String messageId, MessageRecord? inserted})>(
      () {
        final existing = _devices.byFingerprint(fingerprint);
        final device = _devices.upsert(
          _deviceFromInfo(sender, lastIp: existing?.lastIp, now: now),
          now: now,
        );
        final conversation = _conversations.openActive(
          deviceFingerprint: device.fingerprint,
          now: now,
        );
        final eventNonce = eventNonceForFiles(<String>[file.fileId]);
        final contentKey = contentKeyForFiles(<FileContentKey>[
          FileContentKey(
            fileName: file.fileName,
            size: file.size,
            sha256: file.sha256,
          ),
        ]);
        final message = MessageRecord(
          id: computeMessageId(
            fingerprint: device.fingerprint,
            direction: MessageDirection.incoming,
            kind: MessageKind.file,
            eventNonce: eventNonce,
            contentKey: contentKey,
          ),
          conversationId: conversation.id,
          direction: MessageDirection.incoming,
          kind: MessageKind.file,
          createdAt: now,
          updatedAt: now,
          status: MessageStatus.done,
          eventNonce: eventNonce,
        );
        final inserted = _messages.insertIfAbsent(message);
        if (!inserted.created) {
          return (messageId: inserted.id, inserted: null);
        }
        _files.insert(
          MessageFileRecord(
            id: file.fileId,
            messageId: inserted.id,
            fileName: file.fileName,
            size: file.size,
            mime: file.mime,
            sha256: file.sha256,
            localPath: file.savedPath,
          ),
        );
        _transfers.insert(
          TransferRecord(
            id: _ids.newId(),
            fileId: file.fileId,
            bytesTotal: file.size,
            bytesDone: file.size,
            // 0.2.23: a failed export to the user-visible store is recorded here
            // — the message itself stays `done` (the file *did* arrive), and this
            // is the note that keeps 「已收到」 from claiming the file is in 下载.
            error: file.publishError,
            updatedAt: now,
          ),
        );
        _conversations.touchLastMessage(
          conversationId: conversation.id,
          now: now,
          preview: file.fileName,
        );
        return (messageId: inserted.id, inserted: message);
      },
    );

    final inserted = result.inserted;
    if (inserted != null) {
      _emit(MessageInserted(inserted));
    }
    return (messageId: result.messageId, created: inserted != null);
  }

  /// Records one arriving file of a **folder** send, folding the whole
  /// `prepare` session into a single `inbound` message (docs/22 §4.2).
  ///
  /// [recordIncomingFile] is still exactly what a **single-file** arrival uses
  /// (one file really is one message there). What changed in 0.2.51 is the
  /// *other* flat shape: a multi-select send is also one `prepare` with N files,
  /// so it goes through [recordIncomingSessionFile] — same aggregation, no folder
  /// descriptor — and the two aggregating methods share [_recordAggregated].
  /// This use-case is the folder path, and its whole point is that the **N**
  /// calls of one session produce **one** message with N attachments.
  ///
  /// [sessionId] is the receiving peer's own per-`prepare` session id (all files
  /// of one session carry the same value, and it equals the id in the
  /// `prepare` reply), so it is used as the event anchor through
  /// [eventNonceForFolderSession] and
  /// `ux_messages_event(conversation_id, direction, event_nonce)` does the
  /// de-duplication — no new table, no in-memory "session → message id" map
  /// (which would be lost on restart).
  ///
  /// Order inside the transaction, which must not be rearranged:
  ///
  /// 1. device + conversation (as every other write path does);
  /// 2. look the anchor up with [MessagesDao.byEventNonce] — a hit means "this
  ///    session's message already exists", so only the attachment is appended;
  /// 2b. when the anchor is **new**, ask whether the attachment is
  ///    [FilesDao.byId] already present. `files.id` is the wire `fileId`, so an
  ///    id that is already taken means this arrival — and this whole message —
  ///    has nothing new to say, and no message is created at all (CR-2 ③);
  /// 3. append: [FilesDao.insertIfAbsent] (a re-delivery of a file that already
  ///    landed is a normal shape here, unlike on the send path), then one
  ///    `transfers` row **only when the file row was actually new**;
  /// 4. first arrival: create the message (`kind = file`, `status = done`,
  ///    `folder_name` / `folder_files` set) and bump the conversation preview to
  ///    the folder name.
  ///
  /// Step **2b** is what keeps a zero-attachment message out of the database.
  /// The shape it catches is narrow but real: `OutboxPump` re-sends with the
  /// original `fileId` after a send was answered but never recorded
  /// (`outbox_pump.dart`), the receiver's second `prepare` mints a **new**
  /// session id, so `ux_messages_event` sees a new event while `files.id` is
  /// still taken. Creating the message first and letting `INSERT OR IGNORE`
  /// swallow the attachment left a message with no attachments whose only
  /// visible effect was `touchLastMessage` pushing it to the end of the
  /// conversation. Deciding *before* the insert is deliberate: nothing is
  /// written and then undone, so there is no state in which the empty message
  /// exists at all — not even inside the transaction's own snapshot.
  ///
  /// A `null` anchor still means "message, please": step 2b asks about the
  /// **file**, not the session, so a genuinely new file of a re-prepared session
  /// creates its message exactly as before (one folder send whose first file was
  /// duplicated therefore shows up as two messages; the alternative would be a
  /// session → message map, which is the thing this design exists to avoid).
  ///
  /// Returned flags: [createdMessage] is `true` for exactly one call per
  /// session — the caller emits `MessageInserted` only then, otherwise a
  /// 200-file folder would push 200 "message inserted" events at the UI.
  /// [createdFile] is `true` when this call added the attachment. The
  /// step-2b answer is `(messageId: <the message that owns the file>,
  /// createdMessage: false, createdFile: false)` — the id a caller stores or
  /// logs points at a message that actually exists.
  ///
  /// **Events (0.2.51).** One `MessageInserted` for the call that creates the
  /// message, and one `MessageFilesAppended` for every later call that actually
  /// added a file ([createdFile] `true` on an existing message) — an append is a
  /// visible change even though the message count does not move, and it was the
  /// silent half of "发一个文件夹，对面那张卡片不会从 1 个刷到 2 个".
  ///
  /// Throws `ArgumentError` for an empty [sessionId] (an empty anchor would
  /// alias every such session into one message) or an empty [folderName] (call
  /// [recordIncomingFile] for a flat transfer instead).
  ({
    String messageId,
    bool createdMessage,
    bool createdFile,
  }) recordIncomingFolderFile({
    required DeviceInfo sender,
    required IncomingFileSpec file,
    required String sessionId,
    required String folderName,
    required int folderFiles,
    required DateTime now,
  }) {
    _ensureOpen();
    if (sessionId.isEmpty) {
      throw ArgumentError.value(
        sessionId,
        'sessionId',
        'a folder session needs a non-empty id — it is the event anchor',
      );
    }
    if (folderName.isEmpty) {
      throw ArgumentError.value(
        folderName,
        'folderName',
        'an empty folder name is a flat transfer; use recordIncomingFile',
      );
    }
    return _recordAggregated(
      sender: sender,
      file: file,
      eventNonce: eventNonceForFolderSession(sessionId),
      // A folder's content key is its declared identity, **not** a set of
      // per-file keys: the files arrive one at a time in arrival order, so a key
      // built from "the files seen so far" would change between the first and
      // the second call and give the same event two different ids. The session
      // nonce is what de-duplicates; this only has to be stable, which
      // `name + count` is (every file of one session carries the same
      // descriptor).
      contentKey: contentKeyForText('$folderName\u001f$folderFiles'),
      preview: folderName,
      now: now,
      folderName: folderName,
      folderFiles: folderFiles,
    );
  }

  /// Records one arriving file of a **flat, multi-select** send, folding the
  /// whole `prepare` session into one `inbound` message (0.2.51).
  ///
  /// Why this exists: the sender has always encoded a multi-select as **one
  /// `prepare` carrying N files plus N `put`s** — no protocol change was needed
  /// to see that, and the receiver already stamps every `ReceivedFile` with the
  /// session id (`peer_server.dart`). Only the last step disaggregated the
  /// batch: with `folderName == null` the orchestrator called
  /// [recordIncomingFile], whose anchor is `eventNonceForFiles([fileId])` — one
  /// anchor per **file** — so 5 selected files arrived as 5 bubbles.
  ///
  /// So this is [recordIncomingFolderFile]'s sibling with the descriptor left
  /// out, and the difference is exactly one column:
  ///
  /// * `folder_name` stays **NULL** ⇒ `isFolder` is `false`, so the bubble draws
  ///   one row per attachment (a multi-select is not a folder) and the folder
  ///   browse page / 打开文件夹 menu are not offered;
  /// * `folder_files` is the **sender's declared count** for this session when
  ///   the caller has one — 0.2.52: `core` fills `ReceivedFile.folderFiles` with
  ///   the number of files the `prepare` declared, so a batch of 8 that
  ///   delivered 3 can say 「5 个未收到」. It is written to the column that
  ///   already exists (no schema change), and `null` when the caller declares
  ///   nothing ([folderFiles] `<= 0`: a single-file send, or a pre-0.2.52
  ///   record) — writing `0` there would be a number nobody sent.
  ///
  /// **The two columns are independent on purpose.** `folder_files` alone is a
  /// *count*, not a descriptor: `isFolder` reads `folder_name`, so a batch with a
  /// declared count keeps drawing attachment rows, keeps its 转发到… menu and
  /// never grows a folder card or a directory page.
  ///
  /// The aggregation anchor is [eventNonceForBatchSession] — a third, disjoint
  /// nonce family — so a batch can never alias a folder message nor a bare
  /// single-file arrival. [recordIncomingFile] is **unchanged and still right**
  /// for a genuinely single-file send: one file, one message, one anchor.
  ///
  /// Returns which rows this call actually created, with the same meaning as
  /// [recordIncomingFolderFile]: [createdMessage] is `true` for exactly one call
  /// per session, [createdFile] for every call that added an attachment (a
  /// re-delivered file is a no-op, not an error).
  ///
  /// Throws `ArgumentError` for an empty [sessionId]: without an anchor every
  /// arrival would need its own message, and an empty anchor would alias all of
  /// them into one.
  ({
    String messageId,
    bool createdMessage,
    bool createdFile,
  }) recordIncomingSessionFile({
    required DeviceInfo sender,
    required IncomingFileSpec file,
    required String sessionId,
    required DateTime now,
    int folderFiles = 0,
  }) {
    _ensureOpen();
    if (sessionId.isEmpty) {
      throw ArgumentError.value(
        sessionId,
        'sessionId',
        'a batch session needs a non-empty id — it is the event anchor',
      );
    }
    return _recordAggregated(
      sender: sender,
      file: file,
      eventNonce: eventNonceForBatchSession(sessionId),
      contentKey: contentKeyForBatchSession(sessionId),
      // No folder descriptor to preview: a flat batch's conversation line names
      // the file that opened it, exactly as a single flat arrival does.
      preview: file.fileName,
      now: now,
      // Defaulted rather than required so every existing caller (and every
      // record written before 0.2.52) keeps landing at `NULL`, which is what
      // "no declared count" has always meant in this column.
      folderFiles: folderFiles > 0 ? folderFiles : null,
    );
  }

  /// The one transaction behind **both** aggregating paths (folder, and 0.2.51's
  /// flat batch): device → conversation → "does this session's message exist?"
  /// → append the attachment → (first arrival only) create the message.
  ///
  /// [folderName] / [folderFiles] are the **only** difference between the two
  /// callers and are written to the row as given: `null` for a batch (a plain
  /// multi-attachment message, or one whose caller declared no count),
  /// non-null for a folder (a card with a title and a declared count) — and, since
  /// 0.2.52, `folderFiles` **alone** for a batch whose `prepare` declared N>1
  /// files: a count with no descriptor, which is what lets 「5 个未收到」 be
  /// printed on a multi-attachment bubble without it becoming a folder.
  /// [eventNonce] and [contentKey] are computed by the caller
  /// because they are what makes the two families distinguishable — see
  /// `ids/message_id.dart`.
  ///
  /// [preview] is the conversation's `last_preview` text, written only when this
  /// call created the message (a later file of the same session must not replace
  /// the preview with its own name).
  ///
  /// Emission is the same rule for both callers, and it is **outside** the
  /// transaction: `MessageInserted` for the creating call, `MessageFilesAppended`
  /// for every later call that actually appended a file. That second event is
  /// what keeps a growing message from freezing on screen — for a folder and for
  /// a batch alike.
  ({
    String messageId,
    bool createdMessage,
    bool createdFile,
  }) _recordAggregated({
    required DeviceInfo sender,
    required IncomingFileSpec file,
    required String eventNonce,
    required String contentKey,
    required String preview,
    required DateTime now,
    String? folderName,
    int? folderFiles,
  }) {
    final fingerprint = _requireFingerprint(sender);
    final result = _db.transaction<
        ({
          String messageId,
          MessageRecord? inserted,
          bool createdFile,
        })>(() {
      final existing = _devices.byFingerprint(fingerprint);
      final device = _devices.upsert(
        _deviceFromInfo(sender, lastIp: existing?.lastIp, now: now),
        now: now,
      );
      final conversation = _conversations.openActive(
        deviceFingerprint: device.fingerprint,
        now: now,
      );

      final existingMessage = _messages.byEventNonce(
        conversationId: conversation.id,
        direction: MessageDirection.incoming,
        eventNonce: eventNonce,
      );

      // CR-2 ③ — a **new** anchor with an **old** attachment is not a new event.
      // `files.id` is the wire `fileId`, minted once per send and reused on every
      // retry, so "the row is already there" means this arrival adds nothing:
      // creating the message first would leave one with zero attachments (the
      // `INSERT OR IGNORE` further down is what used to hide that). See the doc
      // comment above for the exact shape and why this is decided, not undone.
      if (existingMessage == null) {
        final MessageFileRecord? alreadyLanded = _files.byId(file.fileId);
        if (alreadyLanded != null) {
          return (
            messageId: alreadyLanded.messageId,
            inserted: null,
            createdFile: false,
          );
        }
      }

      final String messageId;
      MessageRecord? inserted;
      if (existingMessage != null) {
        messageId = existingMessage.id;
      } else {
        final message = MessageRecord(
          id: computeMessageId(
            fingerprint: device.fingerprint,
            direction: MessageDirection.incoming,
            kind: MessageKind.file,
            eventNonce: eventNonce,
            contentKey: contentKey,
          ),
          conversationId: conversation.id,
          direction: MessageDirection.incoming,
          kind: MessageKind.file,
          createdAt: now,
          updatedAt: now,
          status: MessageStatus.done,
          eventNonce: eventNonce,
          folderName: folderName,
          folderFiles: folderFiles,
        );
        final written = _messages.insertIfAbsent(message);
        messageId = written.id;
        inserted = written.created ? message : null;
      }

      final writtenFile = _files.insertIfAbsent(
        MessageFileRecord(
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
      if (writtenFile.created) {
        _transfers.insert(
          TransferRecord(
            id: _ids.newId(),
            fileId: file.fileId,
            bytesTotal: file.size,
            bytesDone: file.size,
            // Same 0.2.23 note as recordIncomingFile: the bytes arrived, the
            // export to 下载 failed, and this is where that reason survives.
            error: file.publishError,
            updatedAt: now,
          ),
        );
      }
      if (inserted != null) {
        _conversations.touchLastMessage(
          conversationId: conversation.id,
          now: now,
          preview: preview,
        );
      }
      return (
        messageId: messageId,
        inserted: inserted,
        createdFile: writtenFile.created,
      );
    });

    final inserted = result.inserted;
    if (inserted != null) {
      _emit(MessageInserted(inserted));
    } else if (result.createdFile) {
      // 0.2.51 — **the message was already on screen and just got a file.**
      //
      // Files 2…N of a `prepare` session append to the message file 1 created
      // (this method's whole design, docs/22 §4.2), and every listener that
      // refreshes on "a message arrived" was blind to that: the row count does
      // not change, only its attachment count does. The store wrote the file,
      // the transfer row and the activity instant, then told nobody — so the
      // timeline kept drawing 「已收到 1/3」 until some *other* message happened
      // to arrive and drag the whole thread through a read.
      //
      // Emitted **outside** the transaction (the same rule as `MessageInserted`
      // above: never announce work that could still roll back) and guarded on
      // `inserted == null` so the creating arrival is announced exactly once:
      // a 3-file batch is one `MessageInserted` + two `MessageFilesAppended`,
      // never three of either. A re-delivered file leaves `createdFile` false —
      // `insertIfAbsent` wrote nothing — so it announces nothing.
      _emit(MessageFilesAppended(messageId: result.messageId));
    }
    return (
      messageId: result.messageId,
      createdMessage: inserted != null,
      createdFile: result.createdFile,
    );
  }

  /// Records one incoming **text** message as an `inbound` message that is
  /// already `done` — the text mirror of [recordIncomingFile] minus the
  /// files/transfers loop (spec §6.3 keeps no inbound `pending` state).
  ///
  /// [eventNonce] is the **sender's** nonce carried by the wire frame (the
  /// `TextMessage.id` of docs/13 §7.3). A re-delivery of the same frame reuses
  /// it, so the message de-duplicates on `ux_messages_event` instead of being
  /// stored twice.
  ({String messageId, bool created}) recordIncomingText({
    required DeviceInfo sender,
    required String text,
    required String eventNonce,
    required DateTime now,
  }) {
    _ensureOpen();
    final fingerprint = _requireFingerprint(sender);
    final result =
        _db.transaction<({String messageId, MessageRecord? inserted})>(
      () {
        final existing = _devices.byFingerprint(fingerprint);
        final device = _devices.upsert(
          _deviceFromInfo(sender, lastIp: existing?.lastIp, now: now),
          now: now,
        );
        final conversation = _conversations.openActive(
          deviceFingerprint: device.fingerprint,
          now: now,
        );
        final message = MessageRecord(
          id: computeMessageId(
            fingerprint: device.fingerprint,
            direction: MessageDirection.incoming,
            kind: MessageKind.text,
            eventNonce: eventNonce,
            contentKey: contentKeyForText(text),
          ),
          conversationId: conversation.id,
          direction: MessageDirection.incoming,
          kind: MessageKind.text,
          textBody: text,
          createdAt: now,
          updatedAt: now,
          status: MessageStatus.done,
          eventNonce: eventNonce,
        );
        final inserted = _messages.insertIfAbsent(message);
        if (!inserted.created) {
          return (messageId: inserted.id, inserted: null);
        }
        _conversations.touchLastMessage(
          conversationId: conversation.id,
          now: now,
          preview: _previewText(text),
        );
        return (messageId: inserted.id, inserted: message);
      },
    );

    final inserted = result.inserted;
    if (inserted != null) {
      _emit(MessageInserted(inserted));
    }
    return (messageId: result.messageId, created: inserted != null);
  }

  /// Applies an optimistic status change and emits [MessageStatusChanged] on
  /// success.
  ///
  /// Returns `false` (leaving the row untouched) when the stored status is not
  /// [from]; throws `InvalidStatusTransition` when the edge `from -> to` is
  /// itself illegal.
  bool setStatus({
    required String messageId,
    required MessageStatus from,
    required MessageStatus to,
    required DateTime now,
  }) {
    _ensureOpen();
    final moved = _db.transaction<bool>(
      () => _messages.updateStatus(
        id: messageId,
        from: from,
        to: to,
        now: now,
      ),
    );
    if (moved) {
      _emit(MessageStatusChanged(messageId: messageId, from: from, to: to));
    }
    return moved;
  }

  /// Records bytes sent so far **within the current attempt** (never a resume
  /// offset — spec §5.9). Throws [RowNotFound] when the file has no transfer.
  void markTransferProgress({
    required String fileId,
    required int bytesDone,
    required DateTime now,
  }) {
    _ensureOpen();
    final transfer = _transfers.byFileId(fileId);
    if (transfer == null) {
      throw RowNotFound(fileId);
    }
    _transfers.updateProgress(id: transfer.id, bytesDone: bytesDone, now: now);
  }

  /// Stores the peer's fresh `sessionId` / `token` for the current attempt.
  /// Throws [RowNotFound] when the file has no transfer.
  void attachSession({
    required String fileId,
    required String sessionId,
    required String token,
    required DateTime now,
  }) {
    _ensureOpen();
    final transfer = _transfers.byFileId(fileId);
    if (transfer == null) {
      throw RowNotFound(fileId);
    }
    _transfers.attachSession(
      id: transfer.id,
      sessionId: sessionId,
      token: token,
      now: now,
    );
  }

  /// Marks a successful send: the message becomes `done`, every one of its
  /// transfers is completed (`bytes_done = bytes_total`, retry cleared) and the
  /// conversation's `last_message_at` / `last_preview` are bumped (spec §6.1).
  ///
  /// Idempotent when the message is already `done`. Throws [RowNotFound] when
  /// the message does not exist and `InvalidStatusTransition` when the current
  /// status cannot legally reach `done`.
  void markSendSucceeded({required String messageId, required DateTime now}) {
    _ensureOpen();
    final from = _db.transaction<MessageStatus?>(() {
      final message = _messages.byId(messageId);
      if (message == null) {
        throw RowNotFound(messageId);
      }
      if (message.status == MessageStatus.done) {
        return null;
      }
      _messages.updateStatus(
        id: messageId,
        from: message.status,
        to: MessageStatus.done,
        now: now,
      );
      final names = <String>[];
      for (final file in _files.forMessage(messageId)) {
        names.add(file.fileName);
        final transfer = _transfers.byFileId(file.id);
        if (transfer != null) {
          _transfers.markDone(id: transfer.id, now: now);
        }
      }
      _conversations.touchLastMessage(
        conversationId: message.conversationId,
        now: now,
        // A text message carries no file, so its preview is its (truncated)
        // body; a folder message is previewed by its own name (docs/22 §6·T02
        // (f)); a flat file message keeps the file-name preview
        // (docs/13 §7.3).
        preview: message.kind == MessageKind.text
            ? _previewText(message.textBody ?? '')
            : _previewOf(names, folderName: message.folderName),
      );
      return message.status;
    });

    if (from != null) {
      _emit(
        MessageStatusChanged(
          messageId: messageId,
          from: from,
          to: MessageStatus.done,
        ),
      );
    }
  }

  /// Marks a failed send: the message becomes `failed` and every transfer of it
  /// records the error, increments `retry_count` and schedules the next attempt
  /// at `now + retryIn` (`null` clears the schedule) — spec §6.1.
  ///
  /// Throws [RowNotFound] when the message does not exist, and
  /// `InvalidStatusTransition` when the current status cannot legally reach
  /// `failed`.
  void markSendFailed({
    required String messageId,
    required String error,
    Duration? retryIn,
    required DateTime now,
  }) {
    _ensureOpen();
    final from = _db.transaction<MessageStatus>(() {
      final message = _messages.byId(messageId);
      if (message == null) {
        throw RowNotFound(messageId);
      }
      _messages.updateStatus(
        id: messageId,
        from: message.status,
        to: MessageStatus.failed,
        now: now,
      );
      final nextAttemptAt = retryIn == null ? null : now.add(retryIn);
      for (final file in _files.forMessage(messageId)) {
        final transfer = _transfers.byFileId(file.id);
        if (transfer != null) {
          _transfers.markFailed(
            id: transfer.id,
            error: error,
            nextAttemptAt: nextAttemptAt,
            now: now,
          );
        }
      }
      return message.status;
    });

    _emit(
      MessageStatusChanged(
        messageId: messageId,
        from: from,
        to: MessageStatus.failed,
      ),
    );
  }

  /// Deletes [messageId] from the local history — the whole sub-tree: its
  /// `transfers` rows, its `files` rows, then the `messages` row (0.2.36).
  ///
  /// **Local only.** The protocol has no delete frame, so the peer keeps its
  /// copy; and nothing on disk is touched — a received file stays exactly where
  /// it was written (§5.6), because the user may still want the file after
  /// deciding the *bubble* has no further use.
  ///
  /// Returns `true` when a row was removed and `false` when there was nothing
  /// to remove (an id that never existed, or one already deleted) — a second
  /// call is therefore a harmless no-op rather than an error.
  ///
  /// **Order matters.** `transfers.file_id → files.id → messages.id` is
  /// children-first. The schema also declares `ON DELETE CASCADE` on both edges
  /// and this connection turns `foreign_keys` on (`LanlinkDatabase._configure`),
  /// so a bare `DELETE FROM messages` *would* cascade — but the deletes are
  /// issued explicitly anyway: the row counts stay observable, and the
  /// behaviour does not silently depend on a per-connection PRAGMA.
  ///
  /// No [StoreEvent] is emitted: every listener of this store is a synchronous
  /// in-memory view of the same data (see `store_events.dart`), and the caller
  /// that asked for the delete is the one that knows which thread to repaint.
  bool deleteMessage({required String messageId}) {
    _ensureOpen();
    return _db.transaction<bool>(() {
      if (_messages.byId(messageId) == null) {
        return false;
      }
      for (final file in _files.forMessage(messageId)) {
        _transfers.deleteByFileId(file.id);
      }
      _files.deleteForMessage(messageId);
      return _messages.deleteById(messageId);
    });
  }

  // ── read use-cases ─────────────────────────────────────────────────
  /// Conversations, most recent activity first (`last_message_at` descending).
  List<ConversationRecord> conversations({bool includeArchived = false}) {
    _ensureOpen();
    return _conversations.all(includeArchived: includeArchived);
  }

  /// The messages of [conversationId], newest first, capped at [limit].
  List<MessageRecord> history(String conversationId, {int? limit}) {
    _ensureOpen();
    return _messages.forConversation(conversationId, limit: limit);
  }

  /// The files attached to [messageId], in the order they were added.
  List<MessageFileRecord> filesOf(String messageId) {
    _ensureOpen();
    return _files.forMessage(messageId);
  }

  /// The transfer delivering [fileId], or `null`.
  TransferRecord? transferOf(String fileId) {
    _ensureOpen();
    return _transfers.byFileId(fileId);
  }

  /// When [messageId] last had **activity**: the newest `transfers.updated_at`
  /// over its files, falling back to the message's own `created_at`, or `null`
  /// when the message does not exist (docs/22 §4.4, revised).
  ///
  /// **Why this exists instead of bumping `messages.updated_at`.** A folder
  /// arrives one file at a time, so the UI needs "has anything happened lately?"
  /// to tell "still arriving" from "this folder stalled with N files missing".
  /// The cheapest answer would be to write the message row on every arrival —
  /// but `messages.updated_at` means *when the status last changed*, and every
  /// other reader of it (ordering, display, cleanup, debugging) would silently
  /// start getting a different meaning. So the activity signal is **derived on
  /// read** from the transfer rows, and `messages` keeps a single unambiguous
  /// `updated_at`. No column, no trigger, no write amplification.
  ///
  /// `transfers.updated_at` is the right column: every attempt-related write
  /// touches it — `updateProgress`, `attachSession`, `markDone`, `markFailed`
  /// (see [TransfersDao]) — so an in-flight file keeps it moving and a stalled
  /// one lets it go stale. That is exactly the "有动静" the caller wants to
  /// measure.
  ///
  /// Cross-table by nature (messages → files → transfers), which is why it is
  /// one statement here in the facade rather than a DAO method: the DAOs are
  /// deliberately single-table (spec §5.4). Both hops are indexed
  /// (`ix_files_message`, `ix_transfers_file`), so this is two index lookups,
  /// not a scan, even for a 200-file folder.
  ///
  /// Returned in UTC like every other timestamp in this layer. Read-only: it
  /// opens no transaction and writes nothing.
  DateTime? lastActivityAt(String messageId) {
    _ensureOpen();
    final row = _db.selectOne(
      'SELECT '
      '  (SELECT created_at FROM messages WHERE id = ?) AS created_at, '
      '  (SELECT MAX(t.updated_at) FROM transfers t '
      '     JOIN files f ON f.id = t.file_id '
      '    WHERE f.message_id = ?) AS last_transfer_at',
      <Object?>[messageId, messageId],
    );
    if (row == null) {
      return null;
    }
    // A transfer wins when there is one; otherwise the message itself is the
    // only activity that ever happened (a text message, or a file whose
    // transfers row is gone). `null` in both columns = no such message.
    final lastTransferAt = row['last_transfer_at'] as int?;
    if (lastTransferAt != null) {
      return fromEpochMillis(lastTransferAt);
    }
    final createdAt = row['created_at'] as int?;
    return createdAt == null ? null : fromEpochMillis(createdAt);
  }

  /// The device row for [fingerprint], or `null`. Read-only pass-through to
  /// [DevicesDao.byFingerprint] (which normalises its argument); added in M4 so
  /// the UI gets device data through the single facade entry point (M4 §3.3).
  DeviceRecord? device(String fingerprint) {
    _ensureOpen();
    return _devices.byFingerprint(fingerprint);
  }

  /// Every device row, most recently seen first. Read-only (M4 §3.3).
  List<DeviceRecord> devices() {
    _ensureOpen();
    return _devices.all();
  }

  /// The messages whose status is in [statuses] (`created_at ASC`). Read-only
  /// pass-through to [MessagesDao.byStatus]; used by M4 startup zombie cleanup
  /// (M4 §3.3). An empty [statuses] yields an empty list.
  List<MessageRecord> messagesByStatus(Set<MessageStatus> statuses) {
    _ensureOpen();
    return _messages.byStatus(statuses);
  }

  /// Resets the thread for [fingerprint] when a peer reinstalls (spec §5.8):
  /// archives the currently active conversation and opens a fresh one, so the
  /// history is kept but the new thread is clean.
  ///
  /// A `devices` row is created for [fingerprint] when none exists yet (the
  /// conversation's foreign key requires one).
  ConversationRecord reopenForNewFingerprint({
    required String fingerprint,
    required DateTime now,
  }) {
    _ensureOpen();
    final normalized = normalizeFingerprint(fingerprint);
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        fingerprint,
        'fingerprint',
        'must not be empty',
      );
    }
    return _db.transaction<ConversationRecord>(() {
      _conversations.archiveAllForDevice(normalized, now: now);
      if (_devices.byFingerprint(normalized) == null) {
        _devices.upsert(
          DeviceRecord(fingerprint: normalized, alias: normalized),
          now: now,
        );
      }
      return _conversations.openActive(
        deviceFingerprint: normalized,
        now: now,
      );
    });
  }

  /// Closes the event stream and the underlying database and marks the store
  /// closed. Idempotent; afterwards every method throws [StoreClosedException].
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    if (!_events.isClosed) {
      _events.close();
    }
    _db.close();
  }

  void _ensureOpen() {
    if (_closed) {
      throw StoreClosedException();
    }
  }

  void _emit(StoreEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  /// Builds a [DeviceRecord] from a peer's [DeviceInfo].
  ///
  /// The facade has no address parameter, so [lastIp] is passed through (the
  /// caller supplies the device's current value) rather than being cleared — a
  /// send must not wipe an address learned from discovery.
  DeviceRecord _deviceFromInfo(
    DeviceInfo info, {
    required String? lastIp,
    required DateTime now,
  }) =>
      DeviceRecord(
        fingerprint: normalizeFingerprint(info.fingerprint),
        alias: info.alias,
        deviceType: info.deviceType.wire,
        model: info.deviceModel,
        lastIp: lastIp,
        lastPort: info.port,
        lastSeenAt: now,
      );

  /// Returns the normalised fingerprint of [info], throwing when it is empty
  /// (an unidentifiable peer cannot own a device row).
  String _requireFingerprint(DeviceInfo info) {
    final fingerprint = normalizeFingerprint(info.fingerprint);
    if (fingerprint.isEmpty) {
      throw ArgumentError.value(
        info.fingerprint,
        'info.fingerprint',
        'a peer without a fingerprint cannot be recorded',
      );
    }
    return fingerprint;
  }

  /// Truncates [text] to [kPreviewMaxChars] code points for a preview, so a
  /// long message never bloats the conversation row (docs/13 §7.3). Counting
  /// `runes` (not UTF-16 units) keeps a truncation from splitting a surrogate
  /// pair.
  String _previewText(String text) {
    final runes = text.runes;
    if (runes.length <= kPreviewMaxChars) {
      return text;
    }
    return String.fromCharCodes(runes.take(kPreviewMaxChars));
  }

  /// A short conversation preview for a message carrying [names].
  ///
  /// [folderName] wins when the message is a folder: the same N files are one
  /// folder, and "12 files" would say less than the folder's own name
  /// (docs/22 §6·T02 (f)). Otherwise one file shows its name and several files
  /// show a count.
  String? _previewOf(List<String> names, {String? folderName}) {
    final folder = folderName;
    if (folder != null && folder.isNotEmpty) {
      return _previewText(folder);
    }
    if (names.isEmpty) {
      return null;
    }
    if (names.length == 1) {
      return names.first;
    }
    return '${names.length} files';
  }
}
