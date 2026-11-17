/// The single send/receive orchestration point (spec §5.2 / §5.3, O3).
///
/// Sending follows the M2 `_SendHistory` sequence verbatim (§1.4): record the
/// outgoing message as `pending` first (so a bubble appears before any network
/// work), then drive the status machine `pending → awaiting_confirm →
/// transferring → done`, with `rejected` for 403/413/503/204 and `failed` for
/// network errors. Receiving subscribes to [TransferService.received] (files)
/// and [TransferService.receivedText] (native text, docs/13 §7.3), recording
/// each into the repository; the repository then emits `MessageAdded`, which
/// the controllers turn into UI updates.
///
/// Layering (spec §8.1): controllers never import `lanlink_core` /
/// `lanlink_store` / `dart:io`.
library;

import 'dart:async';

import '../domain/clock.dart';
import '../domain/device_mapping.dart';
import '../domain/models.dart';
import '../domain/session_repository.dart';
import '../domain/transfer_service.dart';

/// How often in-flight progress may be **persisted** (not reported).
///
/// The upload callback fires once per MiB (`kUploadProgressStepBytes`) so the
/// rate probe can compute an instantaneous speed; persisting a row on every one
/// of those made a 1 GiB transfer do 1024 fsync-backed commits. The UI reads
/// progress once a second (the conversation ticker), so two writes a second is
/// all it can ever show.
///
/// 500 ms keeps a 256 MiB transfer at ~38 writes instead of 256, and costs
/// nothing in durability: every skipped update is superseded by the next one or
/// by the terminal write that always lands.
const Duration kProgressPersistInterval = Duration(milliseconds: 500);

/// How long a send may make **no byte progress at all** before it is declared
/// dead (0.2.22).
///
/// The reported failure it fixes: a peer that loses Wi-Fi without sending a RST
/// (a phone asleep, carried out of range, or a hotspot switched off) leaves the
/// TCP connection half-open. `await client.upload()` then hangs until the OS
/// keepalive gives up — minutes to hours — and `PeerClient` sets only a
/// *connection* timeout, so there is no read timeout to end it. While that
/// hangs, the bubble sits on 传输中 with a frozen percentage and 取消 does
/// nothing, which leaves "kill the app" as the user's only exit.
///
/// 30 s is chosen against the two bounds: it is far longer than any progress
/// stall a healthy link produces (progress is reported per MiB, and a 1 KiB/s
/// link — hopeless for a real file — still reports well inside it), and far
/// shorter than the minutes-long wait a user will tolerate before force-quitting.
const Duration kStallTimeout = Duration(seconds: 30);

/// How often the stall supervisor looks at the clock.
///
/// One second: the check is two clock reads and a comparison, and it bounds the
/// extra delay before 连接中断 appears to ≤ 1 s.
const Duration kStallCheckInterval = Duration(seconds: 1);

/// Creates a periodic timer.
///
/// Injected (like [Clock]) so a test can drive the stall supervisor without
/// waiting 30 real seconds: capture the callback, advance the [FixedClock] past
/// [kStallTimeout], then invoke it. The default is a plain [Timer.periodic].
typedef PeriodicTimerFactory = Timer Function(
  Duration interval,
  void Function(Timer timer) callback,
);

/// The production [PeriodicTimerFactory].
Timer _systemPeriodicTimer(
  Duration interval,
  void Function(Timer timer) callback,
) =>
    Timer.periodic(interval, callback);

/// Orchestrates one send, and records inbound files.
class TransferOrchestrator {
  /// Wires the orchestrator. Subscribes to [TransferService.received].
  ///
  /// [clock] timestamps the throttled progress writes **and** is the only source
  /// of elapsed time for the stall supervisor; [progressPersistInterval] is
  /// injectable so a test can prove the throttle is what reduces the write
  /// count (pass [Duration.zero] and every callback persists).
  ///
  /// [stallTimeout] / [stallCheckInterval] / [periodicTimer] exist so the
  /// "no progress for 30 s → 连接中断" path can be driven deterministically in a
  /// test ([FixedClock] + a captured timer callback) instead of by sleeping for
  /// half a minute; production uses the defaults.
  TransferOrchestrator({
    required SessionRepository repo,
    required TransferService transfer,
    Clock clock = const SystemClock(),
    this.progressPersistInterval = kProgressPersistInterval,
    this.stallTimeout = kStallTimeout,
    this.stallCheckInterval = kStallCheckInterval,
    PeriodicTimerFactory periodicTimer = _systemPeriodicTimer,
  })  : _repo = repo,
        _transfer = transfer,
        _clock = clock,
        _periodicTimer = periodicTimer {
    _receivedSub = _transfer.received.listen(_onReceived);
    // Same shape as the file subscription (docs/13 §7.3): the accept callback
    // surfaces as a stream and is recorded here.
    _textSub = _transfer.receivedText.listen(_onReceivedText);
  }

  /// Minimum gap between two persisted progress rows for one file.
  final Duration progressPersistInterval;

  /// How long a send may go without byte progress before it is declared dead.
  final Duration stallTimeout;

  /// How often the stall supervisor compares [Clock.nowUtc] to the last progress.
  final Duration stallCheckInterval;

  /// Creates the stall supervisor's timer (injectable; see [PeriodicTimerFactory]).
  final PeriodicTimerFactory _periodicTimer;

  final SessionRepository _repo;
  final TransferService _transfer;
  final Clock _clock;
  late final StreamSubscription<ReceivedTransfer> _receivedSub;
  late final StreamSubscription<ReceivedText> _textSub;

  /// The sends this orchestrator is **currently driving**, keyed by message id
  /// (0.2.22).
  ///
  /// It exists so a cancel can reach the live session: the message row carries
  /// no session id (`FileAttachment` has no such field, and `attachSession` only
  /// writes it to the transfer row inside the store), so the only place that
  /// knows "this message is streaming under session X right now" is here.
  ///
  /// One instance serves the whole app (a single shared [TransferOrchestrator],
  /// 0.2.12), so the registry survives the per-selection controller rebuild in
  /// `DetailPane` — a thread reopened mid-upload can still cancel it.
  final Map<String, _InFlightSend> _inFlight = <String, _InFlightSend>{};

  /// Whether [messageId] is being driven by this orchestrator right now.
  bool isInFlight(String messageId) => _inFlight.containsKey(messageId);

  /// Records a landed inbound file (§5.3). The repository emits `MessageAdded`.
  ///
  /// **Three arrival shapes, three record methods (0.2.51)** — decided here and
  /// nowhere else, because this is the only place that sees both the folder
  /// descriptor and the session id together:
  ///
  /// | arrival | method | result on screen |
  /// |---|---|---|
  /// | `folderName` set | [SessionRepository.recordIncomingFolderFile] | one folder card |
  /// | flat, `sessionId` set | [SessionRepository.recordIncomingSessionFile] | one bubble, N rows |
  /// | flat, no `sessionId` | [SessionRepository.recordIncoming] | one bubble, one row |
  ///
  /// **Layering (design §9.6):** this method calls the repository port only —
  /// no store, no core, no `dart:io`.
  ///
  /// [ReceivedTransfer.sender] is a live [DiscoveredPeer] (the sender just
  /// uploaded to us), while [SessionRepository.recordIncoming] persists a
  /// [PeerDevice] row; [deviceFromDiscovered] projects the former onto the
  /// latter using the §4.2 "in-memory wins while online" column rules.
  ///
  /// [ReceivedTransfer.publishError] is carried through verbatim (0.2.23): a
  /// file that arrived but could not be exported to the user-visible store must
  /// record *why*, otherwise the bubble says 已完成 and the user goes looking in
  /// 下载 for a file that is not there.
  void _onReceived(ReceivedTransfer transfer) {
    final String? folderName = transfer.folderName;
    // 0.2.38 — one `prepare` session is one folder message (`docs/22` §4.2).
    //
    // The branch is on the **descriptor**, not on `relativePath`. Membership of
    // a folder is a property of the batch; `relativePath` is a property of one
    // file, and a folder whose files all sit at its root is still a folder (its
    // files simply carry bare names). Branching on `relativePath` would send that
    // shape down the flat path and produce N messages for one folder.
    //
    // `sessionId` is required in the same breath: it is the aggregation anchor,
    // and calling the folder path without one would throw inside a stream
    // listener — which kills the receive subscription for every later file.
    // Core always mints a 16-byte session id on the success path, so the second
    // condition is unreachable in production; if it ever fires, a flat arrival
    // is the honest degradation (the bytes did land) rather than a dropped
    // stream.
    if (folderName != null && folderName.isNotEmpty &&
        transfer.sessionId.isNotEmpty) {
      _repo.recordIncomingFolderFile(
        sender: deviceFromDiscovered(transfer.sender),
        file: transfer.file,
        sessionId: transfer.sessionId,
        folderName: folderName,
        folderFiles: transfer.folderFiles,
        publishError: transfer.publishError,
      );
      return;
    }
    // 0.2.51 — a flat **multi-select** is one `prepare` carrying N files, and
    // every arrival already carries the receiver's session id, so the batch can
    // be one bubble with N rows exactly the way a folder is one bubble with a
    // folder card. Nothing about the wire changed: the sender always sent it
    // this way; only the store disaggregated it (one `fileId` anchor per file).
    //
    // The branch order is the contract, and it matters in both directions:
    //
    //  1. **folder first** — a folder arrival must keep its descriptor
    //     (`folder_name`, declared count, the browse page). If the batch branch
    //     came first, a folder would fall into it whenever `sessionId` was set,
    //     which is always;
    //  2. **then a live session** → aggregate;
    //  3. **last, the old flat path** — a single-file send, and every pre-0.2.38
    //     peer that carries no session id at all. One file, one message,
    //     unchanged, and it stays the honest degradation when `sessionId` is
    //     empty (the same rule the folder branch states above: the bytes landed,
    //     so record them rather than drop them).
    if (transfer.sessionId.isNotEmpty) {
      _repo.recordIncomingSessionFile(
        sender: deviceFromDiscovered(transfer.sender),
        file: transfer.file,
        sessionId: transfer.sessionId,
        // ★ 0.2.52 — **the one line the fix needed here.** `core` fills this
        // with the number of files the `prepare` declared (0 for a one-file
        // session), and it is the *only* input the 「N 个未收到」 judgement has:
        // without it a batch of 8 that delivered 3 is indistinguishable from a
        // batch of 3, which is what folding the batch into one message made
        // invisible. The repository writes the count into `folder_files` and
        // leaves `folder_name` NULL, so this is still a multi-row bubble and
        // never a folder card.
        folderFiles: transfer.folderFiles,
        publishError: transfer.publishError,
      );
      return;
    }
    _repo.recordIncoming(
      sender: deviceFromDiscovered(transfer.sender),
      file: transfer.file,
      publishError: transfer.publishError,
    );
  }

  /// Records an accepted inbound text frame (docs/13 §7.3).
  ///
  /// [ReceivedText.id] is the sender's nonce off the wire, used verbatim as the
  /// message's `event_nonce` — so a re-delivery of the same frame dedupes for
  /// free. [deviceFromDiscovered] projects the sender the same way as
  /// [_onReceived].
  void _onReceivedText(ReceivedText text) {
    _repo.recordIncomingText(
      sender: deviceFromDiscovered(text.sender),
      text: text.text,
      nonce: text.id,
    );
  }

  /// Records [files] as one outgoing message to [peer] and drives its delivery.
  ///
  /// Returns the terminal [SendOutcome]:
  /// - `queued` — reachable-but-offline / not dialable: the message stays
  ///   `pending` and no connection is opened (Q9). **This method does not retry**
  ///   — but since 0.2.40 the message is not stranded either: `OutboxPump` picks
  ///   it up when the peer comes online, and calls [resumeQueuedFiles] on it.
  /// - `rejected` — the peer refused (403/413/503/204).
  /// - `failed` — a network/IO error, or `lastPort == 0` (E6, the UI should have
  ///   disabled the entry).
  /// - `canceled` — aborted on this side: the user pressed 取消, or the stall
  ///   supervisor gave up (0.2.22). The terminal status is written by whoever
  ///   aborted, so this method writes none.
  /// - `delivered` — every file uploaded and the message moved to `done`.
  Future<SendOutcome> send({
    required PeerDevice peer,
    required List<OutgoingFile> files,
    FolderRef? folder,
  }) async {
    // E6 / A2-15: a peer with no inbound server (`lastPort == 0`) must never be
    // dialled. The UI disables the entry; if we are here anyway, record nothing
    // and report it as a failure rather than pretending it will ever send.
    if (!peer.canSend) {
      return const SendOutcome.failed('对方当前不可接收');
    }

    // [folder] goes to the repository **and** to prepare, and both are needed
    // (0.2.38): the row is what the bubble renders from after a restart, the
    // frame is what the receiver builds the directory tree from. Recording it
    // without sending it would show a folder that never existed on the other
    // side; sending it without recording it would leave a folder message the UI
    // cannot name.
    final SendHandle handle =
        _repo.recordOutgoing(peer: peer, files: files, folder: folder);

    // Q9: reachable-but-offline stays `pending` — do not dial.
    if (!peer.isDialable || !peer.isOnline) {
      return const SendOutcome.queued();
    }

    return _deliver(peer, files, handle.messageId, folder);
  }

  /// Resumes a **file** message that is sitting in `pending` (0.2.40).
  ///
  /// This is [send]'s second half without the half that creates a row: the
  /// message already exists (it was recorded when the user pressed 发送 and the
  /// peer turned out to be offline), so there is **nothing to record**. That is
  /// the whole reason the outbox pump can re-drive an existing `pending` row
  /// instead of minting a new message — `recordOutgoing` lives in [send], not in
  /// [_deliver], so one bubble stays one bubble.
  ///
  /// [files] must be the message's **own** attachments, rebuilt with their
  /// stored ids: the ids are the wire `fileId`s the receiver de-duplicates on,
  /// and `attachSession` is called per file id, so a fresh id would attach the
  /// session to a row nobody reads.
  ///
  /// The two guards are [send]'s, verbatim — `canSend` (a `lastPort == 0` peer
  /// must never be dialled) and online/dialable (a resume that runs while the
  /// peer has gone again must stay queued rather than fail). Returning
  /// `queued` is therefore a legitimate outcome here, and the pump leaves the
  /// row alone for the next online event.
  Future<SendOutcome> resumeQueuedFiles({
    required PeerDevice peer,
    required String messageId,
    required List<OutgoingFile> files,
    FolderRef? folder,
  }) async {
    if (!peer.canSend) {
      return const SendOutcome.failed('对方当前不可接收');
    }
    if (!peer.isDialable || !peer.isOnline) {
      return const SendOutcome.queued();
    }
    return _deliver(peer, files, messageId, folder);
  }

  /// Records [text] as one outgoing text message to [peer] and delivers it
  /// (docs/13 §7.3 — a text message is a single frame and one round-trip: there
  /// is **no** confirm/transfer stage).
  ///
  /// [nonce] is the event anchor, minted **once** by the caller (see
  /// `ConversationController.sendText`) and reused on every retry — that reuse
  /// is what keeps the message idempotent. It is persisted on the row by
  /// `recordOutgoingText`. **Since 0.2.40 the nonce is read back from the stored
  /// row** (`ChatMessage.eventNonce`) by [resumeQueuedText], which is what keeps
  /// a resumed text send idempotent.
  ///
  /// Outcomes mirror [send]: `queued` (offline / not dialable), `rejected` (the
  /// peer refused), `failed` (network error), `canceled` (the user cancelled
  /// while the frame was in flight — 0.2.22), `delivered` (`pending → done`).
  Future<SendOutcome> sendText({
    required PeerDevice peer,
    required String text,
    required String nonce,
  }) async {
    if (!peer.canSend) {
      return const SendOutcome.failed('对方当前不可接收');
    }

    final SendHandle handle =
        _repo.recordOutgoingText(peer: peer, text: text, nonce: nonce);

    // Q9: reachable-but-offline stays `pending` — do not dial.
    if (!peer.isDialable || !peer.isOnline) {
      return const SendOutcome.queued();
    }

    return _deliverText(peer, handle.messageId, text, nonce);
  }

  /// Resumes a **text** message that is sitting in `pending` (0.2.40).
  ///
  /// [sendText] without `recordOutgoingText`, exactly as [resumeQueuedFiles] is
  /// [send] without `recordOutgoing`. [nonce] **must** be the one already stored
  /// on the row (`ChatMessage.eventNonce`): a text frame is one round-trip with
  /// no session, so the nonce is the only thing the receiver de-duplicates on.
  /// Minting a new one here would turn "the frame landed but the ack was lost"
  /// into a second message on the other side.
  Future<SendOutcome> resumeQueuedText({
    required PeerDevice peer,
    required String messageId,
    required String text,
    required String nonce,
  }) async {
    if (!peer.canSend) {
      return const SendOutcome.failed('对方当前不可接收');
    }
    if (!peer.isDialable || !peer.isOnline) {
      return const SendOutcome.queued();
    }
    return _deliverText(peer, messageId, text, nonce);
  }

  /// The one-frame round trip of a text message, driven against an **existing**
  /// row (0.2.40).
  ///
  /// Extracted from [sendText] so the queued-resume path shares it instead of
  /// growing a second copy of the status machine — the `pending → rejected` and
  /// `pending → done` edges, the abandoned guard and the `_inFlight` registration
  /// are identical for a first send and a resume.
  Future<SendOutcome> _deliverText(
    PeerDevice peer,
    String messageId,
    String text,
    String nonce,
  ) async {
    // Registered even though a text frame has no session to abort: the round
    // trip can still be in flight when the user cancels, and the flag below is
    // what stops the terminal write from landing on an already-`canceled` row
    // (the store rejects `canceled → done`, so without this a cancel during a
    // slow text send would throw).
    final _InFlightSend entry = _InFlightSend(peer: peer);
    _inFlight[messageId] = entry;
    try {
      try {
        await _transfer.sendText(peer: peer, id: nonce, text: text);
      } on PeerRejectedException catch (error) {
        if (entry.abandoned) {
          return const SendOutcome.canceled();
        }
        // A text message has no `awaitingConfirm` stage, so a refusal moves it
        // straight to `rejected` via the `pending -> rejected` edge (docs/13
        // §7.3). A refusal is not a failure — the two states stay distinct, so
        // the UI can say "对方拒了你" rather than "网络出错".
        _repo.setStatus(
          messageId: messageId,
          from: MessageStatus.pending,
          to: MessageStatus.rejected,
        );
        return SendOutcome.rejected('HTTP ${error.statusCode}');
      } catch (error) {
        if (entry.abandoned) {
          return const SendOutcome.canceled();
        }
        _repo.markSendFailed(messageId: messageId, error: '$error');
        return SendOutcome.failed('$error');
      }

      if (entry.abandoned) {
        return const SendOutcome.canceled();
      }
      // One frame, acknowledged → done (the text `pending -> done` edge).
      _repo.markSendSucceeded(messageId: messageId);
      return const SendOutcome.delivered();
    } finally {
      _release(messageId, entry);
    }
  }

  /// Marks the in-flight send for [messageId] as **cancelled by the user** and
  /// aborts it (0.2.22).
  ///
  /// Returns a future that completes once the peer has been told; callers must
  /// **not** await it — a peer that just vanished is exactly the case this
  /// serves, and the local cancel must not wait on a 10 s connect timeout. A
  /// no-op (a completed future) when nothing is in flight for [messageId]: the
  /// caller has already moved the row to `canceled`, which is the whole job for
  /// a queued message.
  ///
  /// The `canceled` flag is set **synchronously**, before any await, so the
  /// concurrent `upload`'s error handler cannot slip a `failed` write in first.
  Future<void> cancelInFlight(String messageId) {
    final _InFlightSend? entry = _inFlight[messageId];
    if (entry == null) {
      return Future<void>.value();
    }
    entry.canceled = true;
    // The supervisor must stop *now*: a stall it declared a moment later would
    // write `failed` over the user's `canceled`.
    entry.supervisor?.stop();
    final String? sessionId = entry.sessionId;
    if (sessionId == null || sessionId.isEmpty) {
      return Future<void>.value();
    }
    return _abort(peer: entry.peer, sessionId: sessionId);
  }

  /// Tells the peer to drop [sessionId] and aborts the local stream, swallowing
  /// failures: the local state is already settled, and a dead peer means there is
  /// nobody left to tell.
  Future<void> _abort({
    required PeerDevice peer,
    required String sessionId,
  }) async {
    try {
      await _transfer.cancel(peer: peer, sessionId: sessionId);
    } catch (_) {
      // Best effort by design — see the doc on [cancelInFlight].
    }
  }

  /// Forgets [entry] — but only if it is still the registered send for
  /// [messageId], so a newer send of the same message is never unregistered by
  /// the tail of an older one.
  void _release(String messageId, _InFlightSend entry) {
    entry.supervisor?.stop();
    entry.supervisor = null;
    if (identical(_inFlight[messageId], entry)) {
      _inFlight.remove(messageId);
    }
  }

  /// The outcome for a send we abandoned ourselves (cancel or stall).
  SendOutcome _abandonedOutcome(_InFlightSend entry) => entry.stalled
      ? const SendOutcome.failed(kStalledError)
      : const SendOutcome.canceled();

  /// The online-and-dialable path: prepare → attach → upload → done.
  ///
  /// Takes a **message id**, not a [SendHandle] (0.2.40): the row may have been
  /// created moments ago by [send] or minutes ago by a queued send that the
  /// outbox pump is now resuming ([resumeQueuedFiles]). Only the id is ever read
  /// here, so requiring the whole handle would have forced the pump to build a
  /// fake one — a second, misleading source of truth about whether the row was
  /// "created".
  Future<SendOutcome> _deliver(
    PeerDevice peer,
    List<OutgoingFile> files,
    String messageId, [
    FolderRef? folder,
  ]) async {
    final _InFlightSend entry = _InFlightSend(peer: peer);
    _inFlight[messageId] = entry;
    try {
      return await _deliverRegistered(entry, files, messageId, folder);
    } finally {
      _release(messageId, entry);
    }
  }

  /// [_deliver]'s body, with [entry] already registered so a cancel can reach it.
  Future<SendOutcome> _deliverRegistered(
    _InFlightSend entry,
    List<OutgoingFile> files,
    String messageId, [
    FolderRef? folder,
  ]) async {
    final PeerDevice peer = entry.peer;
    // The return value matters now that a `pending` row can be older than this
    // call (0.2.40). It returns `false` when the row is no longer `pending` —
    // i.e. the user pressed 取消, or a first drain already took it. Continuing
    // would open a session for a message that is `canceled`/`transferring` and
    // then throw on the terminal write (`canceled → done` is an illegal edge).
    final bool claimed = _repo.setStatus(
      messageId: messageId,
      from: MessageStatus.pending,
      to: MessageStatus.awaitingConfirm,
    );
    if (!claimed) {
      // Nothing to report and nothing to write: whoever moved the row owns it.
      // `_abandonedOutcome` with neither flag set is `canceled`, which is the
      // honest "this send never happened" answer for the pump.
      return _abandonedOutcome(entry);
    }

    final PreparedUpload prepared;
    try {
      prepared = await _transfer.prepare(peer: peer, files: files, folder: folder);
    } on PeerRejectedException catch (error) {
      if (entry.abandoned) {
        return _abandonedOutcome(entry);
      }
      _repo.setStatus(
        messageId: messageId,
        from: MessageStatus.awaitingConfirm,
        to: MessageStatus.rejected,
      );
      return SendOutcome.rejected('HTTP ${error.statusCode}');
    } catch (error) {
      if (entry.abandoned) {
        return _abandonedOutcome(entry);
      }
      _repo.markSendFailed(messageId: messageId, error: '$error');
      return SendOutcome.failed('$error');
    }

    // Cancelled while the peer was confirming (`awaitingConfirm`): the row is
    // already `canceled`, so this must stop **before** `transferring` and before
    // any byte is offered. There was no session to announce yet — `prepared`
    // arrived after the cancel — so the peer drops the session on its own
    // timeout; a second `/cancel` here would race the first one.
    if (entry.abandoned) {
      return _abandonedOutcome(entry);
    }

    entry.sessionId = prepared.sessionId;
    for (final OutgoingFile file in files) {
      final String? token = prepared.tokens[file.id];
      if (token != null) {
        _repo.attachSession(
          fileId: file.id,
          sessionId: prepared.sessionId,
          token: token,
        );
      }
    }
    _repo.setStatus(
      messageId: messageId,
      from: MessageStatus.awaitingConfirm,
      to: MessageStatus.transferring,
    );

    for (final OutgoingFile file in files) {
      if (entry.abandoned) {
        return _abandonedOutcome(entry);
      }
      // Per-file throttle state: the first callback always persists (so the bar
      // leaves 0% immediately), then at most one write per interval.
      DateTime? lastPersist;
      // Per-file stall supervisor (0.2.22): one upload = one "no progress"
      // window. A cancel or a stall stops it in [cancelInFlight] / on stall, and
      // the `finally` below always stops it — a live timer per finished file
      // would be a leak that also keeps firing on a dead send.
      final _UploadSupervisor supervisor = _UploadSupervisor(
        clock: _clock,
        timeout: stallTimeout,
        interval: stallCheckInterval,
        createTimer: _periodicTimer,
        onStall: () => _onStalled(entry, messageId, prepared),
      );
      entry.supervisor = supervisor;
      try {
        final int sent = await _transfer.upload(
          peer: peer,
          prepared: prepared,
          file: file,
          // Live progress: the client reports the bytes that have actually left
          // (throttled to ~1 MiB), so the UI shows a moving percentage rather
          // than 0% until the very end. **Persisting** is throttled further
          // (kProgressPersistInterval) — the callback frequency itself is left
          // alone because the throughput probe reads it.
          onProgress: (int bytesSent) {
            // Any byte movement is a heartbeat: it is what the supervisor
            // measures, and it is deliberately fed **before** the persist
            // throttle below, so a link that is slow but alive (every callback
            // throttled out of a write) is never declared dead.
            supervisor.noteProgress();
            final DateTime now = _clock.nowUtc();
            final DateTime? last = lastPersist;
            if (last != null &&
                now.difference(last) < progressPersistInterval) {
              return;
            }

            lastPersist = now;
            _repo.markTransferProgress(
              fileId: file.id,
              bytesDone: bytesSent,
            );
          },
        );
        // Terminal value: always written, never throttled — and **not** after an
        // abort, where the row belongs to the supervisor / the canceller.
        if (!entry.abandoned) {
          _repo.markTransferProgress(fileId: file.id, bytesDone: sent);
        }
      } on TransferCanceledException {
        // Ours: the transport aborted on our own request, so the terminal status
        // is already written and only the outcome is left to report.
        return _abandonedOutcome(entry);
      } catch (error) {
        if (entry.abandoned) {
          // A `SocketException` from a forced close is the *expected* shape of
          // our own abort; reporting it as a failure would overwrite `canceled`.
          return _abandonedOutcome(entry);
        }
        _repo.markSendFailed(messageId: messageId, error: '$error');
        return SendOutcome.failed('$error');
      } finally {
        supervisor.stop();
        if (identical(entry.supervisor, supervisor)) {
          entry.supervisor = null;
        }
      }
    }

    if (entry.abandoned) {
      return _abandonedOutcome(entry);
    }
    _repo.markSendSucceeded(messageId: messageId);
    return const SendOutcome.delivered();
  }

  /// The stall supervisor gave up: no byte moved for [stallTimeout].
  ///
  /// Writes the `failed` status **here** rather than waiting for `upload` to
  /// throw: the whole point is that it may never throw (a half-open socket, a
  /// body written into a void). The transfer row's `error` doubles as the
  /// conversation ticker's "nothing live any more" flag, so persisting it also
  /// stops the 1 Hz poll instead of leaving it spinning for a dead send.
  void _onStalled(
    _InFlightSend entry,
    String messageId,
    PreparedUpload prepared,
  ) {
    if (entry.abandoned) {
      return;
    }
    entry.stalled = true;
    try {
      _repo.markSendFailed(
        messageId: messageId,
        error: kStalledError,
      );
    } catch (_) {
      // The only way this write fails is a row that already reached a terminal
      // state — and this runs inside a **timer callback**, where an uncaught
      // exception is an uncaught async error nobody can act on. The send is over
      // either way, and the abort below is still worth doing.
    }
    // Same abort as a user cancel: a body nobody will ever read must not keep
    // the socket busy (nor burn the CPU on a hash-free re-read loop).
    unawaited(_abort(peer: entry.peer, sessionId: prepared.sessionId));
  }

  /// Releases the inbound subscriptions (files and text) and stops every stall
  /// supervisor still running (0.2.22) — a timer that outlives the orchestrator
  /// would keep firing on a disposed repository.
  void dispose() {
    _receivedSub.cancel();
    _textSub.cancel();
    for (final _InFlightSend entry in _inFlight.values) {
      entry.supervisor?.stop();
      entry.supervisor = null;
      entry.canceled = true;
    }
    _inFlight.clear();
  }
}

/// One send this orchestrator is currently driving (0.2.22).
class _InFlightSend {
  /// Registers a send to [peer].
  _InFlightSend({required this.peer});

  /// The peer the bytes are going to — reused verbatim for the `/cancel` call,
  /// so the abort always targets the host that is actually streaming rather than
  /// whatever the widget's `peer` happens to be when the user taps.
  final PeerDevice peer;

  /// The peer-assigned session id, known from `prepare` onwards.
  String? sessionId;

  /// Set when the **user** cancelled: the terminal `canceled` status is theirs,
  /// so this send must write no status of its own.
  bool canceled = false;

  /// Set when the **stall supervisor** gave up: it already wrote `failed`.
  bool stalled = false;

  /// The supervisor watching the file that is uploading right now, or `null`.
  _UploadSupervisor? supervisor;

  /// Whether this send has been pulled out from under the transport.
  bool get abandoned => canceled || stalled;
}

/// Watches one file upload for "no byte progress for [timeout]" (0.2.22).
///
/// Time comes from the injected [Clock] and the periodic pulse from an injected
/// [PeriodicTimerFactory], so a test advances a [FixedClock] and fires the
/// captured callback instead of sleeping 30 seconds. [stop] is idempotent and is
/// called on every exit path (success, failure, cancel, stall, dispose).
class _UploadSupervisor {
  /// Starts supervising. [onStall] fires **once**, after [stop] has run.
  _UploadSupervisor({
    required Clock clock,
    required this.timeout,
    required Duration interval,
    required PeriodicTimerFactory createTimer,
    required void Function() onStall,
  })  : _clock = clock,
        _onStall = onStall,
        _lastProgressAt = clock.nowUtc() {
    _timer = createTimer(interval, (_) => _check());
  }

  /// How long without progress counts as dead.
  final Duration timeout;

  final Clock _clock;
  final void Function() _onStall;

  /// The moment of the last observed byte movement (or of the start).
  DateTime _lastProgressAt;

  Timer? _timer;
  bool _stopped = false;

  /// Records a heartbeat.
  void noteProgress() => _lastProgressAt = _clock.nowUtc();

  void _check() {
    if (_stopped) {
      return;
    }
    if (_clock.nowUtc().difference(_lastProgressAt) < timeout) {
      return;
    }
    stop();
    _onStall();
  }

  /// Stops the timer. Safe to call more than once, and from inside `_check`.
  void stop() {
    if (_stopped) {
      return;
    }
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }
}
