/// Transfer port (spec §3.2): the resident receiver + outbound
/// `prepare` / `upload` / `cancel`.
///
/// **Layering (M4 §8.1):** pure Dart — imports only this package's `domain/`.
/// The native adapter (`data/real/lan_transfer_service.dart`) wraps the
/// resident `PeerServer` (start/stop/rebuild, §1.5) and `PeerClient`
/// (prepare/upload/cancel); the fake is a controllable in-memory double.
///
/// Status changes are **not** made here — they are driven by the
/// `TransferOrchestrator` (repo + this port), matching the M2 CLI sequence
/// (spec §1.4 / §4.4).
library;

import 'models.dart';

/// The peer's response to `prepare-upload` (spec §3.2).
class PreparedUpload {
  /// Creates a prepared upload.
  const PreparedUpload({required this.sessionId, required this.tokens});

  /// The peer-assigned session id.
  final String sessionId;

  /// Per-file upload tokens: `fileId -> token`.
  final Map<String, String> tokens;
}

/// Thrown when the peer refuses a `prepare` (HTTP `204/403/413/503`).
class PeerRejectedException implements Exception {
  /// Creates the exception.
  PeerRejectedException(this.statusCode, this.message);

  /// The HTTP status code that caused the refusal.
  final int statusCode;

  /// A human-readable reason.
  final String message;

  @override
  String toString() => 'PeerRejectedException($statusCode): $message';
}

/// Thrown by [TransferService.upload] when the transfer was **aborted on this
/// side** — a user cancel, or the stall supervisor giving up — rather than by a
/// network or peer failure (0.2.22).
///
/// The distinction matters because the two land in different message states
/// (`canceled` vs `failed`), and because a local abort has usually **already**
/// written the terminal status by the time the exception surfaces: the
/// orchestrator must not write a second one (the store rejects an illegal edge
/// such as `canceled → failed`).
class TransferCanceledException implements Exception {
  /// Creates the exception.
  const TransferCanceledException([this.reason = 'canceled locally']);

  /// Why the transfer was aborted; diagnostic only.
  final String reason;

  @override
  String toString() => 'TransferCanceledException: $reason';
}

/// The user-facing reason recorded when the stall supervisor declared a send
/// dead (0.2.22).
///
/// It lives in `domain/` so the **writer** (the orchestrator) and the **reader**
/// (`ui/format.dart` / `conversation_thread`) spell it the same way: a second
/// hand-written copy is how a stored `error` silently stops matching the copy the
/// UI looks for, and the bubble then shows no reason at all.
const String kStalledError = '连接中断';

/// The user-facing reason recorded when a queued send could not be resumed
/// because its **source file is no longer on disk** (0.2.52).
///
/// A copy of a picked / shared file lives in `cache/lanlink-picked/<uuid>/`, and
/// until 0.2.52 the launch sweep deleted that directory unconditionally — while
/// a `pending` (queued) message is deliberately kept across a restart. So the
/// row went on saying 排队中 for a file **we** had removed, the resume dialled
/// anyway, and the eventual failure was a raw exception string the timeline
/// refuses to print (see `_failureNote`): the user was told 「失败」 and nothing
/// else.
///
/// Two rules follow from that, and this constant is both of them:
///
/// * the writer (the outbox pump) and the reader (`_failureNote`) must spell it
///   the same way — a second hand-written copy is how a stored `error` silently
///   stops matching the copy the UI looks for ([kStalledError]'s rule);
/// * the text itself must be **actionable on screen**, because it is also what
///   the user reads in the bubble: it names the cause (the original is gone) and
///   the next move (重新发送). The wording stays honest about *who* removed it —
///   the sweep is the usual culprit, but on the desktop the user may have moved
///   the file, and neither case is knowable here.
const String kSourceMissingError = '原文件已被系统清理，请重新发送';

/// Thrown when the receive directory could not be switched to a usable one
/// (0.2.23).
///
/// It exists so "保存位置改不了" is a **visible** outcome with a reason, and so
/// the caller can be sure the *previous* directory is still in force: the
/// adapter probes the new path and restores the old receiver before this
/// escapes. Silently keeping the old directory while the settings page shows the
/// new one is precisely the defect this replaces.
class SaveDirectoryException implements Exception {
  /// Creates the exception.
  const SaveDirectoryException(this.directory, this.reason);

  /// The directory that was refused.
  final String directory;

  /// Why it cannot be used (short and concrete, shown to the user).
  final String reason;

  @override
  String toString() => 'SaveDirectoryException($directory): $reason';
}

/// The result of one send (spec §3.2 / §4.5).
class SendOutcome {
  /// Delivered to the peer.
  const SendOutcome.delivered()
      : queued = false,
        rejected = false,
        canceled = false,
        error = null;

  /// Queued: the peer is offline/undialable, so nothing was sent (Q9).
  const SendOutcome.queued()
      : queued = true,
        rejected = false,
        canceled = false,
        error = null;

  /// Refused by the peer ([error] optional detail).
  const SendOutcome.rejected([this.error])
      : queued = false,
        rejected = true,
        canceled = false;

  /// **Aborted on this side** (0.2.22): the user cancelled, or the stall
  /// supervisor gave up on a link that stopped moving. Nothing is delivered and
  /// nothing failed — the message's terminal state was written by whoever
  /// pulled the plug, so the orchestrator writes no status of its own.
  const SendOutcome.canceled()
      : queued = false,
        rejected = false,
        canceled = true,
        error = null;

  /// Failed with [error].
  const SendOutcome.failed(this.error)
      : queued = false,
        rejected = false,
        canceled = false;

  /// True when the send was queued (peer offline/undialable).
  final bool queued;

  /// True when the peer refused (403/413/503/204).
  final bool rejected;

  /// True when the send was aborted locally (user cancel / stall supervisor).
  final bool canceled;

  /// Failure detail, or `null`.
  final String? error;

  /// Whether nothing went wrong (neither rejected, canceled nor failed).
  bool get ok => !rejected && !canceled && error == null;

  /// Whether the bytes actually reached the peer (0.2.23).
  ///
  /// Stricter than [ok]: a **queued** send is `ok` (nothing went wrong, it simply
  /// was not attempted) but nothing was delivered, so callers that may only act
  /// on a completed transfer — e.g. deleting the local temporary copy of a picked
  /// file — must ask this instead.
  bool get delivered => ok && !queued;
}

/// The send/receive side of transfer: a resident receiver plus the outbound
/// handshake and byte transfer (spec §3.2).
abstract interface class TransferService {
  // ── Resident receiver (P0-8 / P0-7) ────────────────────────────────────

  /// Starts the resident receiver.
  Future<void> startReceiver();

  /// Stops the resident receiver.
  Future<void> stopReceiver();

  /// Rebuilds the receiver to toggle accepting (spec §1.5). On failure the old
  /// receiver must be restored and the error surfaced — never fail silently.
  Future<void> setAccepting(bool value);

  /// Whether the receiver currently accepts uploads.
  bool get accepting;

  /// The receiver's actual TCP port (`> 0` means peers can dial back), or
  /// `null` when it is not running (P0-8).
  int? get localPort;

  /// Rebuilds the receiver to advertise a new [alias] (spec §1.5).
  Future<void> setAlias(String alias);

  /// Rebuilds the receiver so accepted files land in [directory] (0.2.23).
  ///
  /// **It must take effect on the next receive, without a restart.** Until
  /// 0.2.23 the directory was read once when the service was constructed and
  /// stored in a `final` field, so changing it persisted a setting the running
  /// receiver never read: the settings page showed the new path while every
  /// subsequent file went to the old one until the app was restarted. (The same
  /// class of defect `setAccepting` / `setAlias` already avoid by rebuilding.)
  ///
  /// A directory that cannot be used — not creatable, not a directory, not
  /// writable — must be **refused**, not adopted: throw [SaveDirectoryException]
  /// and leave the previous directory in force, so the caller can report a
  /// visible error and roll the setting back instead of showing a path that is
  /// not the one in effect.
  Future<void> setSaveDirectory(String directory);

  /// The directory accepted files are written to **right now**.
  ///
  /// This is the value the receiver is actually using, not what was last asked
  /// for, which is what lets a caller (and a test) tell a refused change from an
  /// applied one.
  String get saveDirectory;

  /// Fires once per verified file that finished landing on disk
  /// (`onUploadFinished` → `ReceivedTransfer`).
  Stream<ReceivedTransfer> get received;

  /// Fires once per accepted native text frame (docs/13 §7.3): the core
  /// server's `onTextReceived` callback, exposed as a stream.
  ///
  /// Same shape as [received] (`ReceivedText.id` carries the sender's nonce);
  /// the orchestrator maps each event onto `recordIncomingText`.
  Stream<ReceivedText> get receivedText;

  /// Fires once per inbound request this receiver **refused** (P0-7 follow-up),
  /// so the app can show a trace instead of failing silently while the sender
  /// sees "对方拒绝了请求". Same shape as [received]: the native adapter turns
  /// the core server's `onUploadRejected` callback into this stream — the core
  /// layer speaks callbacks, this layer speaks streams.
  Stream<UploadRejected> get uploadRejected;

  /// Fires whenever this device is in live contact with a peer, so discovery
  /// can keep its registry entry fresh. Two sources feed it:
  ///
  /// * every inbound `/register` (and, since the keep-alive fix, `/prepare`,
  ///   `/text` and each chunk of a `/put`) — the peer just reached us;
  /// * every **outbound** exchange we initiate (`prepare` / `upload` /
  ///   `sendText`, re-fired periodically during a long upload) — we just
  ///   reached the peer.
  ///
  /// Both are needed because the registry's only other liveness source is the
  /// peer's 5s UDP announcement; without this a purely-TCP transfer would let a
  /// healthy peer time out as offline mid-stream (docs/13 §4).
  Stream<DiscoveredPeer> get registrations;

  // ── Outbound (handshake/transfer; status persists via TransferOrchestrator)

  /// POST `prepare-upload`; throws [PeerRejectedException] on 204/403/413/503.
  ///
  /// [folder] groups [files] into one folder message (0.2.38, `docs/22` §1.1):
  /// it puts the optional `folder` object on the frame, and each file's
  /// [OutgoingFile.relativePath] becomes its own `path`. `null` — the default,
  /// and what every multi-select / drag-and-drop send passes — produces the
  /// pre-0.2.38 frame byte for byte. A 0.2.37 receiver ignores both keys and
  /// collects the same N files flat, which is why the two ends do not have to
  /// upgrade together.
  Future<PreparedUpload> prepare({
    required PeerDevice peer,
    required List<OutgoingFile> files,
    FolderRef? folder,
  });

  /// POST `upload`; returns the number of bytes sent.
  ///
  /// Throws a [TransferCanceledException] when the transfer was aborted locally
  /// (a [cancel] for the same session, or a local watchdog): the implementation
  /// must therefore abort its own stream, not only tell the peer.
  Future<int> upload({
    required PeerDevice peer,
    required PreparedUpload prepared,
    required OutgoingFile file,
    void Function(int bytesSent)? onProgress,
  });

  /// POST `text` (docs/13 §7.3): sends one native text frame — no
  /// prepare/upload handshake.
  ///
  /// [id] is the sender-minted, retry-stable nonce (the frame's `id`, which the
  /// receiver stores as its `event_nonce` for de-duplication). A refusal
  /// (`403` receiving off / `413` too large) is a [PeerRejectedException]; any
  /// other error propagates and the orchestrator maps it to `failed`.
  Future<void> sendText({
    required PeerDevice peer,
    required String id,
    required String text,
  });

  /// Cancels the in-flight session [sessionId] with [peer].
  ///
  /// **This must stop the bytes, not just announce the intent** (0.2.22). Until
  /// 0.2.22 the adapter only POSTed `/cancel` to the peer and returned, so the
  /// local `upload` kept streaming into a socket nobody was reading any more —
  /// which is why "取消" looked broken: the bubble stayed on 传输中 forever.
  /// A correct implementation aborts the local stream (and therefore makes the
  /// concurrent [upload] complete with a [TransferCanceledException]), *and*
  /// tells the peer best-effort.
  Future<void> cancel({required PeerDevice peer, required String sessionId});
}
