/// The conversation (thread) controller (spec §4.2 / §5.2).
///
/// Owns one conversation's history plus the local send actions. Status changes
/// are applied **in place** from `MessageStatusUpdated` (the event already
/// carries `from → to`, so no re-read is needed — §4.1); deletions/archives are
/// out of scope for M4.
///
/// Layering (spec §8.1): imports only `dart:async`, `package:flutter/foundation`
/// and this package's `domain/**`.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../domain/async_value.dart';
import '../domain/clock.dart';
import '../domain/draft_store.dart';
import '../domain/id_factory.dart';
import '../domain/models.dart';
import '../domain/picked_cache.dart';
import '../domain/platform_ports.dart';
import '../domain/session_repository.dart';
import '../domain/transfer_service.dart';
import '../domain/unsent_dismissal_store.dart';
import 'transfer_orchestrator.dart';

/// What the UI can show **while a picked file is being hashed**, before any
/// message row exists (0.2.14).
///
/// Hashing a 1 GiB file is ~10 s of CPU, and it has to finish *before* the
/// message can be recorded — the message id's content key contains the file's
/// `sha256` (`SessionStore.recordOutgoingFiles`), so the row cannot be created
/// first without making ids mutable. Until 0.2.14 the app therefore showed
/// **nothing at all** for that whole window (measured: tap → bubble 2.3 s on
/// 256 MiB, 11.5–15.5 s before the hash was made 5.5x faster), which reads as
/// "the button did nothing".
///
/// This is a pure view-model: it is never persisted, never sent, and never
/// becomes a message. It exists only between "the user chose files" and "the
/// hash finished".
class PreparingSend {
  /// Describes an in-flight preparation of [fileCount] files.
  const PreparingSend({required this.fileCount, this.firstName});

  /// How many files are being hashed (the label switches to a count above 1).
  final int fileCount;

  /// The first file's display name, or `null` when it cannot be derived.
  final String? firstName;

  /// What the thread shows: `正在准备 · a.png`, or `正在准备 3 个文件`.
  String get label => fileCount > 1
      ? '正在准备 $fileCount 个文件'
      : (firstName == null || firstName!.isEmpty)
          ? '正在准备…'
          : '正在准备 · $firstName';
}

/// How often the conversation ticker re-reads transfer progress (0.2.15).
///
/// One second is far coarser than anything that could jank the UI (it is a
/// handful of row reads) and is the rate a human reads a progress bar at.
///
/// It is also why the ticker alone can never be the whole answer: while the app
/// is `paused` the engine schedules **no frames** (`SchedulerBinding` ignores
/// `scheduleFrame` when `framesEnabled` is false) and the OS may defer — or
/// freeze outright — a 1 Hz timer, so no tick is guaranteed to follow a return
/// to the foreground. See [ConversationController.onAppResumed].
const Duration kProgressTickInterval = Duration(seconds: 1);

/// What a cancel attempt did, plus the one sentence the UI shows for it (0.2.22).
///
/// The old `bool` return was the defect: `conversation_thread` threw it away, so
/// every "no" was silent — the button looked dead. Every outcome now carries
/// copy, and `null` is not in the vocabulary: a tap always answers.
class CancelResult {
  /// The cancel was applied. The bubble leaves 传输中 / 等待对方确认 / 排队中 and
  /// the status chip reads 已取消.
  const CancelResult.canceled()
      : wasCanceled = true,
        notice = '已取消';

  /// Nothing was canceled; [notice] says why (never a silent no).
  const CancelResult.refused(this.notice) : wasCanceled = false;

  /// Whether the message actually moved to `canceled`.
  final bool wasCanceled;

  /// The sentence to show the user.
  final String notice;

  @override
  String toString() => 'CancelResult($wasCanceled, $notice)';
}

/// What one message deletion did, plus the one sentence the UI shows for it
/// (0.2.36).
///
/// Same shape as [CancelResult], and for the same reason: the button used to be
/// the whole story and every refusal was silent, so a tap that changed nothing
/// looked broken. A delete has **three** possible answers and all of them get
/// copy — the success, the "still sending" refusal, and the "it was already
/// gone" race (a frame painted a row that a repository event has just removed).
class DeleteResult {
  /// The row is gone from local history.
  const DeleteResult.deleted()
      : wasDeleted = true,
        notice = '已删除';

  /// Nothing was deleted; [notice] says why (never a silent no).
  const DeleteResult.refused(this.notice) : wasDeleted = false;

  /// Whether the message was actually removed from the store.
  final bool wasDeleted;

  /// The sentence to show the user.
  final String notice;

  @override
  String toString() => 'DeleteResult($wasDeleted, $notice)';
}

/// What one **batch delete** did (0.2.41).
///
/// Two counters and not one boolean: a batch can half-succeed (a row removed by a
/// repository event between the tap and the delete), and "删了 3 条，2 条没删掉"
/// is the honest sentence. Silently reporting success for a partial run is the
/// failure this shape exists to prevent.
class DeleteSelectionResult {
  /// Creates a result.
  const DeleteSelectionResult({
    required this.deleted,
    required this.failures,
  });

  /// How many messages left the local history.
  final int deleted;

  /// The notices of the rows that were **not** deleted (one sentence each).
  final List<String> failures;

  /// One line for the notice bar.
  String get notice {
    if (failures.isEmpty) {
      return deleted == 0 ? '没有可删除的消息' : '已删除 $deleted 条';
    }
    return '已删除 $deleted 条，${failures.length} 条没删掉（${failures.first}）';
  }
}

/// One row that could not be forwarded, and why (0.2.41).
class ForwardFailure {
  /// Creates a failure.
  const ForwardFailure({required this.label, required this.reason});

  /// What the row was: `文字「…」` / `文件「…」` / `文件夹「…」`.
  final String label;

  /// Why it did not go (`源文件已不在本地，无法转发`, `对方当前不可接收`, …).
  final String reason;

  @override
  String toString() => '$label：$reason';
}

/// What one **forward** run did (0.2.41).
///
/// Per-row, not one status: the user picked N messages and some of them may be
/// gone from disk. "转发失败" alone would leave them guessing which, and retrying
/// all of them would re-send the ones that already arrived.
class ForwardReport {
  /// Creates a report.
  const ForwardReport({
    required this.targetAlias,
    required this.sent,
    required this.failures,
  });

  /// The device the batch went to (its alias, for the sentence).
  final String targetAlias;

  /// How many messages were sent (or queued — both are `ok`).
  final int sent;

  /// The rows that did not go, with their reasons.
  final List<ForwardFailure> failures;

  /// Whether every picked row went.
  bool get allSent => failures.isEmpty;

  /// One line for the notice bar.
  String get notice {
    if (failures.isEmpty) {
      return '已转发 $sent 条给「$targetAlias」';
    }
    final String reasons = failures
        .map((ForwardFailure f) => f.reason)
        .toSet()
        .join('、');
    final String head =
        sent == 0 ? '转发失败' : '已转发 $sent 条给「$targetAlias」，${failures.length} 条没发出去';
    return '$head：$reasons';
  }
}

/// What forwarding **one** batch of messages to **one** device did, plus the one
/// word that device earned (0.2.46).
///
/// [ForwardReport] answers "did the rows go"; this answers the question a
/// **multi-device** forward has to answer per device: 成功, 排队 or 失败. The two
/// are separate types because the fan-out needs a per-device verdict and the
/// single-device path has been reporting the same way since 0.2.41 — folding the
/// verdict into [ForwardReport] would have changed a sentence nobody asked to
/// change.
///
/// **`sent` counts queued messages too.** A queued send is `ok` (the outbox pump
/// delivers it when the device comes back, Q9), so it is not a failure — but it
/// is also not "成功", which is exactly why [queued] exists and why the sentence
/// distinguishes the two. Reporting a queued send as 失败 would be a lie the user
/// would act on (re-forwarding, or hunting for a network problem that isn't
/// there); reporting it as 成功 would hide that nothing has left the machine yet.
class ForwardTargetResult {
  /// Creates a per-device result.
  const ForwardTargetResult({
    required this.targetAlias,
    required this.sent,
    required this.queued,
    required this.failures,
  });

  /// The device, as the picker named it (alias, or the fingerprint when blank).
  final String targetAlias;

  /// How many messages were accepted for delivery — **delivered or queued**.
  final int sent;

  /// How many of [sent] are waiting in the outbox (`pending`, peer offline).
  final int queued;

  /// The rows that did not go, with their reasons.
  final List<ForwardFailure> failures;

  /// Whether every forwarded row was accepted (queued counts as accepted).
  bool get allSent => failures.isEmpty;

  /// Whether **nothing** has left the machine: every row is waiting in the queue.
  bool get allQueued => allSent && sent > 0 && queued == sent;

  /// The verdict for this device, as one short phrase.
  ///
  /// Never a bare 失败: the reason travels with it, because "转发失败" alone is
  /// the exact copy this app keeps banning (docs/18 §8.2). The row count only
  /// appears when there is more than one row — `成功` reads better than `成功（1 条）`,
  /// and a batch of five forwarded as one line has to say five.
  String get statusLabel {
    if (!allSent) {
      final String reason = failures.first.reason;
      if (sent == 0) {
        return '失败（$reason）';
      }
      return '部分成功（发出去 $sent 条，${failures.length} 条没发出去：$reason）';
    }
    if (sent == 0) {
      return '没有可转发的内容';
    }
    final String counted = sent > 1 ? '（$sent 条）' : '';
    if (allQueued) {
      return '排队$counted';
    }
    if (queued == 0) {
      return '成功$counted';
    }
    return '成功（$queued 条排队）';
  }

  /// `台式机 成功` — one device's line in the notice.
  String get summary => '$targetAlias $statusLabel';

  @override
  String toString() => 'ForwardTargetResult($summary, sent: $sent, queued: $queued)';
}

/// What one **multi-device** forward did (0.2.46).
///
/// 「会话 = 设备」, so "forward to 3 devices" is 3 real sends, one at a time, and
/// the user has to learn the result of **each**: one device may have taken the
/// message, another may have queued it (offline), a third may have failed on a
/// source file that is gone. A single boolean — or a single 转发失败 — would
/// throw that away, and the next action the user takes (retry? wait? check
/// Wi-Fi?) depends on which device is in which state.
class ForwardBatchReport {
  /// Creates a batch report. An **empty** [results] is a valid report: it is what
  /// "nothing was selected" produces, and it must never be confused with "all
  /// sent" (that shape of bug is criterion 4 of the 0.2.46 change).
  const ForwardBatchReport({required this.results});

  /// One entry per target, **in the order they were attempted**.
  final List<ForwardTargetResult> results;

  /// Whether no device was attempted at all.
  bool get isEmpty => results.isEmpty;

  /// Whether every device took every message.
  bool get allSent => results.every((ForwardTargetResult r) => r.allSent);

  /// Whether at least one message reached (or was queued for) every device.
  bool get nothingSent =>
      results.every((ForwardTargetResult r) => r.sent == 0);

  /// One line for the notice bar: `台式机 成功 · 笔记本 排队`.
  String get notice {
    if (results.isEmpty) {
      return '没有选择设备，什么都没有转发';
    }
    return results.map((ForwardTargetResult r) => r.summary).join(' · ');
  }

  @override
  String toString() => 'ForwardBatchReport($notice)';
}

/// What one 全部重试 run did, plus the one sentence the UI shows for it (0.2.24).
///
/// The three counters are **disjoint** and always add up to what the run looked
/// at, so no message can be counted twice:
/// * [sent] — a **new** message was recorded for it (the old row is untouched,
///   exactly like a single 重新发送);
/// * [skipped] — nothing was sent because a source file is gone (`canResend`
///   false). Not an error: it is the same judgement the bubble's own 重新发送
///   makes, only counted instead of silent;
/// * [failed] — a send was attempted and did not deliver (`failed` / `rejected`
///   / `canceled` outcome, or the send threw).
///
/// [refused] is the fourth answer and it is **not** an accident: it says a run
/// was already in progress, so this call did nothing at all. That is what makes
/// a double tap on 全部重试 harmless (0.2.24 criterion 4) — the button is also
/// disabled while a run is live, but the guard has to hold in the controller
/// too, because the disabled style lands one frame later.
class BulkResendResult {
  /// A completed run with [sent] / [skipped] / [failed] outcomes.
  const BulkResendResult({
    this.sent = 0,
    this.skipped = 0,
    this.failed = 0,
    this.refused = false,
  });

  /// A run was already in progress; this call sent nothing.
  const BulkResendResult.refused()
      : sent = 0,
        skipped = 0,
        failed = 0,
        refused = true;

  /// How many messages got a brand-new outgoing message.
  final int sent;

  /// How many were left alone because a source file is gone.
  final int skipped;

  /// How many were attempted and still did not go through.
  final int failed;

  /// Whether this call was a no-op because another run was already going.
  final bool refused;

  /// Nothing was even looked at (no candidate messages).
  bool get isEmpty => !refused && sent == 0 && skipped == 0 && failed == 0;

  /// The sentence the UI shows once the run is over (0.2.24).
  ///
  /// Three shapes, in the order the user cares about:
  /// 1. anything still failing comes **first** — that is the part needing an
  ///    action;
  /// 2. then what was left alone, naming the reason (源文件已不在), because
  ///    "we skipped it" without a reason reads like a bug;
  /// 3. otherwise the plain success sentence.
  ///
  /// [refused] carries copy as well, so no caller can end up with an empty
  /// string to show. The thread itself stays **silent** for a refused result —
  /// its button is already disabled, and a snackbar for a tap on a disabled
  /// button would be noise.
  String get notice {
    if (refused) {
      return '正在重新发送，请稍候';
    }
    if (isEmpty) {
      return '没有需要重发的消息';
    }
    if (failed > 0) {
      final String base = '$sent 条已重发，$failed 条仍失败';
      return skipped > 0 ? '$base，跳过 $skipped 条（源文件已不在）' : base;
    }
    if (skipped > 0) {
      return '已重新发送 $sent 条，跳过 $skipped 条（源文件已不在）';
    }
    return '已重新发送 $sent 条';
  }

  @override
  String toString() => 'BulkResendResult(sent: $sent, skipped: $skipped, '
      'failed: $failed, refused: $refused)';
}

/// Drives one conversation thread.
class ConversationController extends ChangeNotifier {
  /// Wires the controller for [conversationId].
  ///
  /// [pickedCache] is the app's temporary-copy cleaner (0.2.23). It is optional
  /// and defaults to [NoopPickedCache] so the many existing tests (and the Web
  /// preview) compile unchanged; production always passes the real one from
  /// `AppDeps`, which is what stops `cache/lanlink-picked/` from growing by one
  /// full copy of every file the user ever sends.
  ///
  /// [drafts] is the **process-wide** composer-draft store (0.2.27). It is
  /// optional and defaults to [ComposerDraftStore.shared] for the same reason:
  /// this controller is created **per conversation selection**
  /// (`DetailPane._reconcileConversation`), so a draft cannot live on it — the
  /// un-sent text has to survive the controller's own death. A test passes its
  /// own instance to get isolation.
  ///
  /// [dismissals] is the same shape of thing for the 未发送成功 banner (0.2.30):
  /// which messages this conversation's banner has been told to stop counting —
  /// dismissed with the ✕, or already re-sent by a 全部重试. It used to be a `Set`
  /// field **on this controller**, which is why 退出会话再进来 brought the banner
  /// back — the controller that held the ids is disposed on the way out and a
  /// brand-new one is built on the way in. Defaults to
  /// [UnsentDismissalStore.shared]; a test passes its own instance. Since 0.2.33
  /// that shared instance is **persisted** (wired in `create_deps_native.dart`),
  /// so what it holds also survives a restart.
  ConversationController({
    required SessionRepository repo,
    required TransferOrchestrator orchestrator,
    required PlatformPorts platform,
    required IdFactory ids,
    required Clock clock,
    required String conversationId,
    PickedCachePort pickedCache = const NoopPickedCache(),
    ComposerDraftStore? drafts,
    UnsentDismissalStore? dismissals,
  })  : _repo = repo,
        _orchestrator = orchestrator,
        _platform = platform,
        _ids = ids,
        _clock = clock,
        _conversationId = conversationId,
        _pickedCache = pickedCache,
        _drafts = drafts ?? ComposerDraftStore.shared,
        _dismissals = dismissals ?? UnsentDismissalStore.shared {
    _sub = _repo.events.listen(_onEvent);
  }

  final SessionRepository _repo;
  final TransferOrchestrator _orchestrator;
  final PlatformPorts _platform;
  final IdFactory _ids;
  final Clock _clock;
  final String _conversationId;
  final PickedCachePort _pickedCache;

  /// Where this conversation's un-sent composer text lives (0.2.27).
  ///
  /// Shared across conversations on purpose: that is the whole feature (see
  /// [ComposerDraftStore]).
  final ComposerDraftStore _drafts;

  /// Where this conversation's 未发送成功 dismissals live (0.2.30).
  ///
  /// Process-wide for the same reason [ComposerDraftStore] is — this controller
  /// is rebuilt for every conversation selection, so anything that must outlive a
  /// visit cannot be a field on it (see [UnsentDismissalStore]).
  final UnsentDismissalStore _dismissals;

  late final StreamSubscription<RepoEvent> _sub;
  bool _disposed = false;

  /// A 「滚到这条消息」 request the timeline has not consumed yet (0.2.59).
  ///
  /// ★ **Why it is a field on the controller and not on the timeline's State.**
  /// The 消息 / 文件 tab switch destroys and re-creates `ConversationThread`, so a
  /// request parked in its `State` would be lost whenever the user is on 文件 when
  /// they pick 「转到消息」. The controller outlives both tabs (it is keyed by the
  /// *selection*, and switching tabs does not change it), which is exactly the
  /// lifetime this request needs.
  ///
  /// It does **not** need to outlive a conversation switch: the request is created
  /// and consumed inside one visit (device page → pop → timeline), and both ends
  /// live under the same selection.
  String? _pendingRevealId;

  /// The message id the timeline should scroll to, or `null` (0.2.59).
  String? get pendingRevealId => _pendingRevealId;

  /// Asks the timeline to scroll [messageId] into view (0.2.59).
  ///
  /// Only records the request — **the timeline decides how to get there**, and it
  /// is the only place that knows the rows. Purely a UI intent: nothing is
  /// persisted, nothing goes over the wire, and no message changes.
  void requestReveal(String messageId) {
    if (_disposed) {
      return;
    }
    _pendingRevealId = messageId;
    notifyListeners();
  }

  /// Hands the request to the timeline **once** (0.2.59).
  String? takeRevealRequest() {
    final String? id = _pendingRevealId;
    _pendingRevealId = null;
    return id;
  }

  /// Ticks while an upload is in flight so the progress bar actually moves.
  Timer? _progressTicker;

  /// Non-null only while picked files are being hashed; see [PreparingSend].
  PreparingSend? _preparing;

  /// Whether a [resendUnsent] run is walking its list right now (0.2.24).
  bool _bulkResending = false;

  /// Ids a **bulk** 全部重试 already re-sent successfully (0.2.24).
  ///
  /// This is what lets the 未发送成功 banner go away while the old rows stay
  /// `failed` — re-sending deliberately creates a **new** message and leaves the
  /// old one alone (§4.2 P1-4 / Q3), so a purely status-based count would keep
  /// reporting the same messages the user just retried, forever.
  ///
  /// A message whose retry *failed* is deliberately **not** recorded: it is still
  /// outstanding, so it is counted again and the user can bulk-retry the
  /// remainder.
  ///
  /// **0.2.33: these ids live in [_dismissals] now, so they survive a restart.**
  /// They used to be a per-controller `Set`, and the 0.2.24 note called losing
  /// them on re-open "harmless" — the user disagreed about exactly this class of
  /// state: ignore the batch *or* retry it, and the next launch offered it again
  /// ("退出软件重新进还是有的"). A successful batch retry is the same statement
  /// as the ✕ — "these old rows are dealt with" — so it is remembered the same
  /// way, in the same document. See [UnsentDismissalStore.markHandled].

  // The ✕'s dismissed ids used to be a `Set` field right here (0.2.26). They now
  // live in [_dismissals], a process-wide store — see that field, and
  // [UnsentDismissalStore] for the report that forced the move ("退出这个会话界面
  // 重新进来，还是会显示全部重试"): this controller is disposed on the way out of a
  // conversation, taking any field with it.

  AsyncValue<List<ChatMessage>> _messages = const Loading<List<ChatMessage>>();

  /// The thread id this controller is bound to.
  String get conversationId => _conversationId;

  /// The un-sent composer text of this conversation, or `''` (0.2.27).
  ///
  /// Read once when a thread is mounted, to fill its composer back in — see
  /// [ComposerDraftStore]. It is **not** a `ChangeNotifier` value: restoring a
  /// draft is a `initState`-time fill, not a live binding.
  String get draftText => _drafts.draftFor(_conversationId);

  /// Whether this conversation has un-sent composer text worth restoring.
  bool get hasDraft => _drafts.hasDraft(_conversationId);

  /// Records what the user has typed so far, **silently** (0.2.27).
  ///
  /// Called from the composer's `TextEditingController` listener on **every**
  /// keystroke, which is why it must never notify: a `notifyListeners()` here
  /// would rebuild the entire thread (timeline, banners, progress rows) once per
  /// character, to repaint a `TextField` that is already drawing itself. The
  /// store write is the whole job.
  ///
  /// A whitespace-only value **removes** the draft instead of storing it, so an
  /// emptied composer comes back empty (see [ComposerDraftStore.save]).
  void updateDraft(String text) {
    if (_disposed) {
      return;
    }
    _drafts.save(conversationId: _conversationId, text: text);
  }

  /// Forgets this conversation's draft (0.2.27).
  ///
  /// Public because a caller may need it without sending (nothing in the app
  /// does today); [sendText] is the path that matters.
  void discardDraft() => _drafts.clear(_conversationId);

  /// What is being hashed right now, or `null` when nothing is.
  ///
  /// Read-only on purpose: the UI only renders it, and nothing outside the send
  /// paths may put the thread into this state.
  PreparingSend? get preparing => _preparing;

  /// The message list, `createdAt` ascending. `Loading` until [load] runs.
  AsyncValue<List<ChatMessage>> get messages => _messages;

  /// Reads the conversation history into [messages].
  Future<void> load() async {
    try {
      _messages = Data<List<ChatMessage>>(_repo.history(_conversationId));
    } catch (error) {
      _messages = Failure<List<ChatMessage>>(error);
    }
    // The history has just answered "is anything in flight?" — a thread opened
    // (or re-opened) in the middle of a big upload must start polling here, and
    // a stale poll must stop here (0.2.15).
    syncProgressTicker();
    _pruneDismissals();
    _notify();
  }

  /// Drops remembered suppressions whose message is no longer a failure
  /// (0.2.33).
  ///
  /// This is the **only** way the persisted record shrinks, and it is deliberately
  /// narrow: an id is dropped when its message left the history or is no longer
  /// `failed` / `canceled`, i.e. when it can never appear in the banner again
  /// anyway. Suppressions of *still-failing* rows are kept — forgetting those is
  /// precisely the "退出再进来/重启，条又回来了" bug this whole store exists to fix.
  ///
  /// Cheap (one walk of the already-loaded history) and safe to run on every
  /// [load]; it is a no-op when the history could not be read.
  void _pruneDismissals() {
    final List<ChatMessage>? history = _messages.valueOrNull;
    if (history == null) {
      return;
    }
    final Set<String> stillFailing = <String>{
      for (final ChatMessage message in history)
        if (message.direction == MessageDirection.outgoing &&
            message.kind == MessageKind.file &&
            (message.status == MessageStatus.failed ||
                message.status == MessageStatus.canceled))
          message.id,
    };
    // Fire-and-forget: pruning is housekeeping, and the write it may trigger is
    // asynchronous by design (see `UnsentDismissalStore._requestSave`).
    unawaited(
      _dismissals.pruneConversation(
        _conversationId,
        relevant: stillFailing,
      ),
    );
  }

  /// The attachments of [messageId] (delegates to the repository).
  List<FileAttachment> filesOf(String messageId) => _repo.filesOf(messageId);

  /// How many attachments have been **appended** to each message of this
  /// conversation since this controller was created (0.2.51).
  ///
  /// Keyed by message id, not a single counter, because the one consumer is a
  /// per-message question: "which message grew, so that the new attachment can be
  /// judged against the disk?" A folder's files 2…N and a batch's files 2…N both
  /// arrive this way (the same `MessageFilesAppended` event, `folder_name` or
  /// not), so one map covers both shapes — the growth is a property of the
  /// **event**, never of `isFolder`.
  ///
  /// `ConversationThread` keeps its own copy of these counts and probes only the
  /// ids that moved; nothing else reads it. Exported read-only (a listener may
  /// not poke the state it is listening to), and it never shrinks, so a message
  /// that grew ten times still answers `10` and a late listener can tell "I have
  /// not looked at this message since its second file" from "I have".
  Map<String, int> get grownMessages =>
      UnmodifiableMapView<String, int>(_grownMessages);
  final Map<String, int> _grownMessages = <String, int>{};

  /// The transfer progress of [fileId] (delegates to the repository).
  TransferProgress? transferOf(String fileId) => _repo.transferOf(fileId);

  /// Starts the progress poll unless it is already running (idempotent).
  ///
  /// The ticker exists so the bar actually moves: the store emits **nothing** on
  /// a progress write — it would flood the event stream with hundreds of events
  /// per file — so nothing would ever repaint as `bytesDone` grows and the user
  /// would see 0% until the upload ends. One tick a second is far coarser than
  /// anything that could jank the UI (it re-reads a handful of rows).
  ///
  /// **0.2.15:** the ticker is no longer only a bracket around a send. It is
  /// owned by [syncProgressTicker] / [_tickProgress], which keep it in step with
  /// what is on screen — see the doc on [syncProgressTicker].
  void _ensureProgressTicker() {
    if (_disposed || _progressTicker != null) {
      return;
    }
    _progressTicker =
        Timer.periodic(kProgressTickInterval, (_) => _tickProgress());
  }

  void _tickProgress() {
    if (_disposed) {
      _stopProgressTicker();
      return;
    }
    if (!_hasLiveTransfer()) {
      // Nothing in flight any more — the poll has nothing left to report.
      //
      // **This must never be a one-way door (0.2.15).** It used to be: the stop
      // had no counterpart anywhere, so one tick that found "not live" — even
      // when the truth was merely *unknown* (`Loading`/`Failure` have no value,
      // `_hasLiveTransfer` reads that as "none") — silenced the bar for the rest
      // of the controller's life, which is the "进度条像卡住" report. Every path
      // that can change the answer now re-arms it: [load], each repository event
      // ([_onEvent]), a (re)mounted thread and [onAppResumed].
      _stopProgressTicker();
    }
    // One repaint per tick: the moving bar while a transfer is live, and the
    // final value as the ticker stops.
    notifyListeners();
  }

  void _stopProgressTicker() {
    _progressTicker?.cancel();
    _progressTicker = null;
  }

  /// Re-aligns the ticker with what is actually on screen, **silently**.
  ///
  /// The ticker exists for one job: turn progress *writes* into repaints. A
  /// progress write emits no repository event, so nothing else would ever see
  /// it — but progress writes can only make a transfer *more* live, never less.
  /// The reverse transition (a transfer stops being live) is always accompanied
  /// by a repository event (`done` / `failed` / `canceled`) or by a [load], and
  /// **all of those call this method**. That is the invariant that makes
  /// "stop when nothing is live" safe, and it is exactly what 0.2.15 restores.
  ///
  /// Why it was needed (0.2.15 — the "退到后台再回来进度条不动" report):
  /// 1. the ticker used to be started **only** by the three send brackets, so a
  ///    controller that merely *read* a thread with a transfer already in flight
  ///    never polled at all. Entering a conversation does exactly that:
  ///    `DetailPane._reconcileConversation` builds a **new** controller per
  ///    selection and calls `load()`. That is the reported "重新进会话，进度往前
  ///    跳了一大截，然后又像卡住": the jump is `load()` reading fresh
  ///    `bytes_done`, the freeze is the missing ticker.
  /// 2. one tick that found "not live" stopped it permanently (see
  ///    [_tickProgress]), and nothing could restart it.
  void syncProgressTicker() {
    if (_disposed) {
      return;
    }
    if (_hasLiveTransfer()) {
      _ensureProgressTicker();
      return;
    }
    _stopProgressTicker();
  }

  /// The app came back to the foreground: re-arm the ticker and repaint **now**.
  ///
  /// While the app is `paused` the engine stops scheduling frames and the OS may
  /// defer or freeze the 1 Hz ticker, so the last painted frame can be minutes
  /// old and there is no guarantee that a tick follows the return. Waiting for
  /// one would leave the bar showing a stale number until then — or forever, if
  /// no ticker was running. This repaints the current `bytes_done` on the very
  /// first frame after the return, and restarts the poll if a transfer is still
  /// live.
  ///
  /// Wired from `ConversationThread`'s `WidgetsBindingObserver` (this class is a
  /// plain `ChangeNotifier` and holds no `Widget`, so it must not touch
  /// `WidgetsBinding` itself).
  void onAppResumed() {
    if (_disposed) {
      return;
    }
    syncProgressTicker();
    _notify();
  }

  /// Whether any visible message still has a transfer short of its total.
  ///
  /// **A terminal message never counts**, however many bytes its transfer row
  /// still claims (0.2.22). A cancel moves the *message* to `canceled` and
  /// deliberately leaves the transfer row alone (there is no "canceled" byte
  /// count to write: the row is not the state machine), so a purely
  /// progress-based answer kept the 1 Hz poll running forever after every
  /// cancelled send — the same shape as a `rejected` message whose row sits at
  /// `0 / total` with no error.
  ///
  /// **`pending` does not count either (0.2.40).** It is the one non-terminal
  /// state that means *nothing is running*: the message was queued for an
  /// offline peer (Q9) and no byte has been offered. Its transfer row sits at
  /// `0 / total` with `error == null`, which is byte-for-byte
  /// indistinguishable from a live upload — so the answer used to be "live" and
  /// the poll ticked once a second for as long as the peer stayed away, on a
  /// bubble that draws no progress bar at all. The outbox pump is what moves a
  /// `pending` row to `awaitingConfirm`/`transferring`, and that transition is a
  /// repository event, so [_onEvent] re-arms the ticker the moment the send
  /// actually starts — excluding `pending` can never silence a live bar.
  bool _hasLiveTransfer() {
    final List<ChatMessage> list =
        _messages.valueOrNull ?? const <ChatMessage>[];
    for (final ChatMessage message in list) {
      if (message.status.isTerminal ||
          message.status == MessageStatus.pending) {
        continue;
      }
      for (final FileAttachment file in _repo.filesOf(message.id)) {
        final TransferProgress? progress = _repo.transferOf(file.id);
        if (progress != null &&
            progress.error == null &&
            progress.bytesDone < progress.bytesTotal) {
          return true;
        }
      }
    }
    return false;
  }

  /// Enters — and immediately announces — the "preparing" state.
  ///
  /// Returns the token the matching [_endPreparing] must pass back: if two sends
  /// overlap, the first one to finish must not clear the second one's state, so
  /// the clear only happens while the *same* token is still current.
  PreparingSend _beginPreparing(List<String> paths) {
    final PreparingSend preparing = PreparingSend(
      fileCount: paths.length,
      firstName: _baseName(paths.first),
    );
    _preparing = preparing;
    // Announced before the first `await` of the hash loop, so the thread can
    // repaint on the next frame instead of after the whole hash.
    _notify();
    return preparing;
  }

  void _endPreparing(PreparingSend mine) {
    if (!identical(_preparing, mine)) {
      return;
    }
    _preparing = null;
    _notify();
  }

  /// Returns `null` when the picker was dismissed / nothing was chosen, so the
  /// page can no-op. A `lastPort == 0` peer must be disabled by the UI (E6).
  Future<SendOutcome?> pickAndSend({
    required PeerDevice peer,
    required FileKind kind,
  }) async {
    final List<String> paths = await _platform.pickFiles(kind);
    return _sendPickedPaths(peer, paths);
  }

  /// 「照片」 (0.2.53): pick from the **system gallery** and send, then behave
  /// exactly like [pickAndSend].
  ///
  /// The only difference between the two doors is which picker opened. Once the
  /// paths are in hand the road is shared by construction — [_sendPickedPaths]
  /// is the single implementation, so "the photo button must not grow a second
  /// send path" is enforced by the code shape rather than by care. A cancelled
  /// pick answers an empty list, which returns `null` here: no message, no
  /// error, nothing left in the preparing state.
  Future<SendOutcome?> pickAndSendMedia({required PeerDevice peer}) async {
    final List<String> paths = await _platform.pickMedia();
    return _sendPickedPaths(peer, paths);
  }

  /// Hashes [paths] and sends them as **one** message with N attachments.
  ///
  /// The shared tail of [pickAndSend] and [pickAndSendMedia]: an empty [paths]
  /// is "the user cancelled" and answers `null` before any state is touched.
  Future<SendOutcome?> _sendPickedPaths(
    PeerDevice peer,
    List<String> paths,
  ) async {
    if (paths.isEmpty) {
      return null;
    }
    final List<OutgoingFile> files = <OutgoingFile>[];
    final PreparingSend preparing = _beginPreparing(paths);
    try {
      for (final String path in paths) {
        final int size = await _platform.length(path);
        final String sha256 = await _platform.sha256Hex(path);
        files.add(
          OutgoingFile(
            id: _ids.newId(),
            fileName: _baseName(path),
            size: size,
            sha256: sha256,
            localPath: path,
          ),
        );
      }
    } finally {
      // Cleared even when a hash throws: the hint must never outlive the work.
      _endPreparing(preparing);
    }
    // Start the poll before the send: the message row — and with it the live
    // transfer — does not exist until `recordOutgoing` runs inside `send`, so
    // `syncProgressTicker` here would find nothing to poll yet. Unconditional for
    // the same reason a de-duplicated re-send needs it: no `MessageAdded` event.
    _ensureProgressTicker();
    try {
      final SendOutcome outcome =
          await _orchestrator.send(peer: peer, files: files);
      await _discardPickedCopies(paths, outcome);
      return outcome;
    } finally {
      // Re-align rather than hard-stop (0.2.15): the last live transfer stops the
      // poll exactly as before, but an overlapping send is no longer silenced by
      // whoever finished first.
      syncProgressTicker();
    }
  }

  /// Sends files the user **dropped** onto the conversation (docs/19 §9.8).
  ///
  /// The same path as [pickAndSend] minus the picker: the drop already handed us
  /// real paths. The caller filters folders out first — this method trusts what
  /// it is given, and every path is stat-ed here for size and hash.
  ///
  /// [discardPickedCopies] is `true` for a **user's own send** and `false` for a
  /// **forward** (0.2.46). The difference matters on Android, where a picked /
  /// shared file was copied into `<temp>/lanlink-picked/<uuid>/` and the copy is
  /// all the message row has: dropping it after a successful upload is right for
  /// a one-shot send (the row is new, the user is done, the cache must not grow)
  /// but wrong for a forward, because the message being forwarded **still names
  /// that path** — the second device in the same fan-out would be refused with
  /// 源文件已不在本地, and the source bubble would go on to claim its file is
  /// gone. A forward is "send these bytes again from where they are", so it
  /// leaves the source where it is; the launch sweep (`PickedCachePort.clear`)
  /// is still what reclaims the space.
  Future<SendOutcome?> sendPaths({
    required PeerDevice peer,
    required List<String> paths,
    List<String>? relativePaths,
    String? folderName,
    bool discardPickedCopies = true,
  }) async {
    if (paths.isEmpty) {
      return null;
    }
    // ★ **Before anything else** — before the `preparing` state, before a single
    // byte is hashed or sent (criterion d2). A list of the wrong length does not
    // mean "no hierarchy", it means the caller has a bug, and pairing
    // `paths[i]` with the wrong `relativePaths[i]` would deliver file A under
    // file B's name. Storing the mistake would be far worse than refusing it,
    // so this throws instead of degrading — and it throws *here*, where nothing
    // has happened yet.
    if (relativePaths != null && relativePaths.length != paths.length) {
      throw ArgumentError.value(
        relativePaths.length,
        'relativePaths',
        'must have the same length as paths (${paths.length})',
      );
    }
    final List<OutgoingFile> files = <OutgoingFile>[];
    final PreparingSend preparing = _beginPreparing(paths);
    try {
      for (int index = 0; index < paths.length; index++) {
        final String path = paths[index];
        final int size = await _platform.length(path);
        final String sha256 = await _platform.sha256Hex(path);
        files.add(
          OutgoingFile(
            id: _ids.newId(),
            fileName: _baseName(path),
            size: size,
            sha256: sha256,
            localPath: path,
            // `null` — never `''` — for a flat send: the receiver tests "is
            // there a value" to decide whether a file has a level, and the wire
            // key is omitted entirely (docs/22 §3.6 / §4.3).
            relativePath: relativePaths?[index],
          ),
        );
      }
    } finally {
      _endPreparing(preparing);
    }
    // The folder is only declared when every file has a position: a folder
    // message whose files all lack `path` is refused by the receiver as a
    // self-contradicting frame (`_handlePrepareUpload`), so announcing one
    // without a usable hierarchy would turn a working flat send into a `400`.
    final FolderRef? folder = folderName == null || relativePaths == null
        ? null
        : FolderRef(name: folderName, count: files.length);
    // Same bracket as [pickAndSend] — started unconditionally (no message row
    // exists yet), re-aligned in the `finally` instead of hard-stopped (0.2.15).
    _ensureProgressTicker();
    try {
      final SendOutcome outcome =
          await _orchestrator.send(peer: peer, files: files, folder: folder);
      if (discardPickedCopies) {
        await _discardPickedCopies(paths, outcome);
      }
      return outcome;
    } finally {
      syncProgressTicker();
    }
  }

  /// Sends [text] to [peer] as one native text message (docs/13 §7.3).
  ///
  /// The nonce is minted **once here** — the text analogue of [pickAndSend]
  /// minting each `OutgoingFile.id` — and is reused across retries of this same
  /// logical send (that reuse is exactly what keeps the message idempotent).
  ///
  /// **The draft is dropped once the dispatch has answered (0.2.48).** Whatever
  /// the outcome, this text is no longer "something I typed and did not send":
  /// `sendText` records a message row *before* it dials
  /// (`TransferOrchestrator.sendText`), so even a `failed` outcome leaves a bubble
  /// in the timeline. Keeping the draft would put the same sentence back in the
  /// composer and invite sending it twice — the user would be looking at one
  /// 未发送成功 bubble and an identical draft.
  ///
  /// **It used to be cleared *before* the dial, and that ate typed text.** An
  /// exception out of the dispatch (`recordOutgoingText` on a store that cannot
  /// write, a `finalize` that throws after the frame left) exits **before** any
  /// row exists — but the draft was already gone, and the caller
  /// (`ConversationThread._sendText`) had already emptied its field too. A
  /// paragraph disappeared with nothing on screen to explain it. Moving the clear
  /// after the `await` is what makes the failure survivable: the row-and-draft pair
  /// is now either "both there" (any real outcome) or "neither touched" (a throw),
  /// and the UI restores the composer from whichever it finds.
  Future<SendOutcome> sendText({
    required PeerDevice peer,
    required String text,
  }) async {
    final SendOutcome outcome =
        await _orchestrator.sendText(peer: peer, text: text, nonce: _ids.newId());
    _drafts.clear(_conversationId);
    return outcome;
  }

  // ── multi-select (0.2.41) ────────────────────────────────────────────────
  //
  // The selection lives **here**, not in the page's `State`, for three reasons:
  // * the thread is re-created for every conversation switch (`DetailPane` keys it
  //   per id) while this controller is what survives that switch — a selection
  //   must not silently follow the user into another conversation;
  // * the entry point is the conversation's ⋯ menu, which is in `DetailPane` and
  //   already holds this controller — so 「多选」 is a method call, not a callback
  //   threaded through two widgets;
  // * deleting a batch has to go through the repository, which only this class
  //   owns. A page-state selection would have to call back into the controller for
  //   every row anyway.

  bool _selecting = false;
  final Set<String> _selected = <String>{};

  /// Whether the timeline is in multi-select mode.
  bool get selecting => _selecting;

  /// The picked message ids, in insertion order (unmodifiable).
  Set<String> get selectedIds => Set<String>.unmodifiable(_selected);

  /// How many messages are picked — the number in the top bar.
  int get selectedCount => _selected.length;

  /// Whether [messageId] is picked.
  bool isSelected(String messageId) => _selected.contains(messageId);

  /// Whether [message] may be picked at all.
  ///
  /// **The same rule as 「删除消息」** (0.2.36): a message that cannot be deleted
  /// (`pending` / `awaitingConfirm` / `transferring`) gets **no checkbox** — the
  /// project's rule is that an affordance which cannot work is not drawn, and a
  /// ring that ignores taps would be exactly that.
  bool canSelect(ChatMessage message) => canDelete(message);

  /// Enters multi-select with nothing picked.
  void startSelecting() {
    if (_disposed || _selecting) {
      return;
    }
    _selecting = true;
    _selected.clear();
    notifyListeners();
  }

  /// Leaves multi-select and drops the selection.
  void cancelSelecting() {
    if (_disposed || !_selecting) {
      return;
    }
    _selecting = false;
    _selected.clear();
    notifyListeners();
  }

  /// Picks [message] if it is not picked, unpicks it if it is. Ignored for a
  /// message that cannot be picked at all.
  void toggleSelected(ChatMessage message) {
    if (_disposed || !_selecting || !canSelect(message)) {
      return;
    }
    if (!_selected.remove(message.id)) {
      _selected.add(message.id);
    }
    notifyListeners();
  }

  /// Picks every message that *can* be picked.
  void selectAll() {
    if (_disposed || !_selecting) {
      return;
    }
    _selected
      ..clear()
      ..addAll(
        (messages.valueOrNull ?? const <ChatMessage>[])
            .where(canSelect)
            .map((ChatMessage m) => m.id),
      );
    notifyListeners();
  }

  /// The picked messages, oldest first (the order the timeline shows them in).
  List<ChatMessage> get selectedMessages => <ChatMessage>[
        for (final ChatMessage m in messages.valueOrNull ?? const <ChatMessage>[])
          if (_selected.contains(m.id)) m,
      ];

  /// Deletes every picked message through the **existing** local-delete path
  /// (`deleteMessage`, whose store call is the three-table cascade) — no second
  /// SQL anywhere.
  ///
  /// Returns what happened per row so the UI can say "删了 3 条，2 条没删掉"：
  /// a silent partial delete is the failure mode this avoids. Leaves multi-select
  /// afterwards, successful or not: the selection no longer describes anything
  /// once rows are gone.
  DeleteSelectionResult deleteSelected() {
    if (_disposed || !_selecting) {
      return const DeleteSelectionResult(deleted: 0, failures: <String>[]);
    }
    final List<ChatMessage> targets = selectedMessages.reversed.toList();
    int deleted = 0;
    final List<String> failures = <String>[];
    for (final ChatMessage message in targets) {
      final DeleteResult result = deleteMessage(message);
      if (result.wasDeleted) {
        deleted += 1;
      } else {
        failures.add(result.notice);
      }
    }
    cancelSelecting();
    return DeleteSelectionResult(deleted: deleted, failures: failures);
  }

  /// Sends every picked message to [target] as **new** content (0.2.41).
  ///
  /// 「会话 = 设备」, so forwarding is "send this again to that device", not a copy
  /// of the record: each message goes through the same send path the composer
  /// uses, and the new rows land in *that* device's conversation.
  ///
  /// Per message:
  /// * **text** → `TransferOrchestrator.sendText` (the composer's path, minus
  ///   `sendText`'s draft clearing — forwarding must not eat what the user is
  ///   typing);
  /// * **files** (a file message) → `sendPaths` with the stored `localPath`s;
  /// * **a folder** → `sendPaths` **with the folder descriptor** (`folderName` +
  ///   every file's position, from [_positionOf]). Still **not** `resend()`:
  ///   forwarding writes rows into *another* device's conversation, while a
  ///   re-send belongs to the failed message's own conversation — and `resend`
  ///   reuses the stored `sha256` where a forward must stat the live source.
  ///   Both paths now declare the folder the same way (0.2.42; before that
  ///   `resend` dropped the descriptor and this method avoided it for that
  ///   reason).
  ///
  /// A message whose source file is **gone** fails loudly and sends nothing (no
  /// empty message, no silent skip); a mixed batch reports per-row counts.
  Future<ForwardReport> forwardSelectedTo(PeerDevice target) async {
    final List<ChatMessage> targets = selectedMessages;
    if (_disposed || !_selecting || targets.isEmpty) {
      return ForwardReport(targetAlias: target.alias, sent: 0, failures: const <ForwardFailure>[]);
    }
    final ForwardTargetResult result =
        await _forwardMessagesToTarget(targets, target);
    if (!_disposed && result.allSent) {
      // Everything went: the selection has done its job. A partial batch keeps it,
      // so the user can retry only what is left.
      cancelSelecting();
    } else if (!_disposed) {
      notifyListeners();
    }
    return ForwardReport(
      targetAlias: target.alias,
      sent: result.sent,
      failures: result.failures,
    );
  }

  /// Forwards **every picked message** to **every device** in [targets]
  /// (0.2.46) — the same selection, fanned out.
  ///
  /// This is the multi-target twin of [forwardSelectedTo], and it exists because
  /// the user's request was one gesture ("右键一条消息就能转发") and one ability
  /// ("一次发给好几台"). [forwardSelectedTo] stays — it is the single-target
  /// shape the 0.2.41 tests pin, and it is still what a caller with one device
  /// should use — but both now run through the same private core
  /// ([_forwardMessagesToTarget]), so the two cannot disagree about what a
  /// forward *is* (folder descriptor, gone-source refusal, no empty message).
  ///
  /// **Serial, target by target, message by message.** Deliberately not
  /// `Future.wait`:
  ///
  /// * the send path is **not** concurrency-safe by design — `sendPaths` hashes
  ///   the source and then uploads while holding a `preparing` state and the
  ///   progress ticker bracket, and N parallel rounds would interleave those,
  ///   turning the composer's "正在准备 · a.png" into noise;
  /// * a fan-out is a handful of devices on a LAN (the slow part is the bytes,
  ///   not the loop), so serial costs nothing a user can perceive;
  /// * errors stay attributable: with `Future.wait` the first throw cancels the
  ///   rest and one dead device would hide the fact that two others succeeded.
  ///
  /// An empty [targets] or an empty [messages] sends **nothing** and returns an
  /// empty report — "the user closed the picker without picking" must never be
  /// read as "send to everyone" (0.2.46 criterion 4).
  Future<ForwardBatchReport> forwardMessagesTo({
    required List<ChatMessage> messages,
    required List<PeerDevice> targets,
  }) async {
    if (_disposed || messages.isEmpty || targets.isEmpty) {
      return const ForwardBatchReport(results: <ForwardTargetResult>[]);
    }
    final List<ForwardTargetResult> results = <ForwardTargetResult>[];
    for (final PeerDevice target in targets) {
      if (_disposed) {
        break;
      }
      results.add(await _forwardMessagesToTarget(messages, target));
    }
    if (!_disposed) {
      // The notices the target conversations gained are new rows; a listener that
      // only redraws on the *source* conversation's events would not see them.
      notifyListeners();
    }
    return ForwardBatchReport(results: results);
  }

  /// [forwardMessagesTo] over the **current multi-select**, leaving the mode when
  /// every device took every row (0.2.46).
  ///
  /// The selection is only cleared when **all** targets succeeded: a partial
  /// fan-out keeps it, so the user can retry just the rows that did not go —
  /// exactly the rule [forwardSelectedTo] already had for one device.
  Future<ForwardBatchReport> forwardSelectedToMany(
    List<PeerDevice> targets,
  ) async {
    final List<ChatMessage> messages = selectedMessages;
    if (_disposed || !_selecting || messages.isEmpty || targets.isEmpty) {
      return const ForwardBatchReport(results: <ForwardTargetResult>[]);
    }
    final ForwardBatchReport report = await forwardMessagesTo(
      messages: messages,
      targets: targets,
    );
    if (_disposed) {
      return report;
    }
    if (report.allSent && !report.isEmpty) {
      cancelSelecting();
    } else {
      notifyListeners();
    }
    return report;
  }

  /// Sends [messages] to **one** device, oldest first, and returns that device's
  /// verdict.
  ///
  /// One message's failure never stops the rest: the loop is per row because
  /// "3 of the 5 rows the user picked are gone from disk" is a state they have to
  /// be told about, not a reason to abandon the two that would have gone.
  Future<ForwardTargetResult> _forwardMessagesToTarget(
    List<ChatMessage> messages,
    PeerDevice target,
  ) async {
    int sent = 0;
    int queued = 0;
    final List<ForwardFailure> failures = <ForwardFailure>[];
    for (final ChatMessage message in messages) {
      final String label = _forwardLabel(message);
      try {
        final SendOutcome? outcome = await _forwardOne(message, target);
        if (outcome != null && outcome.ok) {
          sent += 1;
          // Q9: a queued send is `ok` but nothing has gone out yet. Counted, not
          // failed — see [ForwardTargetResult].
          if (outcome.queued) {
            queued += 1;
          }
        } else {
          failures.add(ForwardFailure(label: label, reason: _outcomeReason(outcome)));
        }
      } on Object catch (error) {
        failures.add(ForwardFailure(label: label, reason: '$error'));
      }
    }
    return ForwardTargetResult(
      // The picker names a device by alias, falling back to the fingerprint when
      // the alias is blank; the notice must say the same thing the row said, or
      // the user cannot map the result back to what they tapped.
      targetAlias: target.alias.isEmpty ? target.fingerprint : target.alias,
      sent: sent,
      queued: queued,
      failures: failures,
    );
  }

  /// Sends one message to [target]; `null` means "nothing to send".
  Future<SendOutcome?> _forwardOne(ChatMessage message, PeerDevice target) async {
    if (message.kind == MessageKind.text) {
      final String body = message.textBody ?? '';
      if (body.isEmpty) {
        return const SendOutcome.failed('没有可转发的文字');
      }
      return _orchestrator.sendText(
        peer: target,
        text: body,
        nonce: _ids.newId(),
      );
    }
    final List<FileAttachment> files = _repo.filesOf(message.id);
    if (files.isEmpty) {
      return const SendOutcome.failed('没有可转发的文件');
    }
    final List<String> paths = <String>[];
    for (final FileAttachment file in files) {
      final String? path = file.localPath;
      // ★ A source that is no longer on disk fails the **whole message**: sending
      // the remaining files would deliver a batch the sender never chose, and
      // sending none of them while reporting success would be a lie.
      if (path == null || path.isEmpty || !await _platform.exists(path)) {
        return const SendOutcome.failed('源文件已不在本地，无法转发');
      }
      paths.add(path);
    }
    // A folder keeps its descriptor, using the **same** rule a re-send uses
    // ([_positionOf]): a row with no stored position falls back to its own file
    // name — a valid single segment at the folder root — instead of `null`.
    //
    // The rule here used to be "keep the hierarchy only when every file has one,
    // otherwise send a flat batch", which made one missing value change the
    // *kind* of message the peer receives (N bubbles instead of one folder).
    // `resend` (0.2.42) does the opposite, and two send paths disagreeing about
    // the same fact is exactly the shape of bug that cannot be reproduced from a
    // report ("sometimes a folder, sometimes not"). One rule now covers both:
    // a folder message stays a folder message; only that one file's nesting is
    // lost, and it lands at the root where a flat send would have put it anyway.
    String? folderName;
    List<String>? relativePaths;
    final String? storedFolderName = message.folderName;
    if (storedFolderName != null && storedFolderName.isNotEmpty) {
      folderName = storedFolderName;
      // Same order as [paths] — both are built from [files], and `paths` was
      // built by the loop above without any re-sorting.
      relativePaths = <String>[
        for (final FileAttachment file in files) _positionOf(file),
      ];
    }
    return sendPaths(
      peer: target,
      paths: paths,
      relativePaths: relativePaths,
      folderName: folderName,
      // ★ 0.2.46 — a forward must not eat the source. `discardPickedCopies` is
      // right for a fresh send and wrong here: the row being forwarded still
      // names these paths, so discarding after the first device succeeded would
      // fail the **second** device in the same fan-out with 源文件已不在本地 and
      // leave the source bubble pointing at a file the app just deleted.
      discardPickedCopies: false,
    );
  }

  /// A short, human label for one forwarded row ("文字「…」" / "3 个文件").
  String _forwardLabel(ChatMessage message) {
    if (message.kind == MessageKind.text) {
      final String body = (message.textBody ?? '').trim();
      final String short = body.length <= 8 ? body : '${body.substring(0, 8)}…';
      return '文字「$short」';
    }
    if (message.isFolder) {
      return '文件夹「${message.folderName}」';
    }
    final List<FileAttachment> files = _repo.filesOf(message.id);
    if (files.length == 1) {
      return '文件「${files.single.fileName}」';
    }
    return '${files.length} 个文件';
  }

  String _outcomeReason(SendOutcome? outcome) {
    if (outcome == null) {
      return '没有可转发的内容';
    }
    return outcome.error ?? '发送未完成';
  }

  /// Whether [message] can be re-sent (P1-4 / Q3 / A2-18, widened in 0.2.22).
  ///
  /// True when the message is `failed` — or `canceled`, because "I cancelled it,
  /// now send it again" is the same intent and refusing it left the user with a
  /// dead bubble and no way forward — has at least one attachment, and **every**
  /// source path still exists on disk. "Re-send" is a **new** send (new `fileId`
  /// → new message) — never a retry of the same `fileId` (Q3).
  Future<bool> canResend(ChatMessage message) async {
    if (message.status != MessageStatus.failed &&
        message.status != MessageStatus.canceled) {
      return false;
    }
    final List<FileAttachment> files = _repo.filesOf(message.id);
    if (files.isEmpty) {
      return false;
    }
    for (final FileAttachment file in files) {
      final String? path = file.localPath;
      if (path == null || !await _platform.exists(path)) {
        return false;
      }
    }
    return true;
  }

  /// Re-sends a failed (or cancelled) [message] as a brand-new send
  /// (§4.2 P1-4 / Q3).
  ///
  /// Deliberately **does not** enter the [preparing] state, unlike
  /// [pickAndSend] / [sendPaths]: a re-send reuses the `sha256` already stored on
  /// the attachment (`file.sha256`), so there is no hash to wait for and the
  /// bubble is recorded on the very next frame. A hint here would be set and
  /// cleared within the same frame — invisible at best, a flicker at worst.
  ///
  /// Returns `null` when [canResend] is false (nothing is sent).
  ///
  /// **A folder keeps its descriptor (0.2.42).** The re-send declares `folder`
  /// and every file's `relativePath`, so the receiver still folds the batch into
  /// one folder message instead of N flat bubbles — the receiver decides that
  /// from the descriptor alone (docs/22 §4.2). A flat message declares neither.
  /// [canResend] remains the only gate: it already refuses a message **any** of
  /// whose sources is gone, which is the "no partial folder" rule this path
  /// needs (a folder that lost a file fails as a whole and can be retried),
  /// and no new degradation path was added for it.
  Future<SendOutcome?> resend({
    required PeerDevice peer,
    required ChatMessage message,
  }) async {
    if (!await canResend(message)) {
      return null;
    }
    // ★ A folder re-send must still be **one** folder message (0.2.42).
    //
    // The receiver decides "one message or N" from the presence of `folder` in
    // the `prepare` frame (docs/22 §4.2), not from the file count. This method
    // used to rebuild only the attachments, so a re-sent folder arrived as N
    // loose bubbles while the very same send had produced one — the message took
    // one shape when it happened to work the first time and another when it did
    // not. The descriptor and the per-file positions therefore travel with the
    // files, in the shape [sendPaths] and `OutboxPump.resumeQueuedFiles` already
    // use: `FolderRef(name, count)` + `OutgoingFile.relativePath`.
    //
    // Both lists are built in **one** pass over `_repo.filesOf`, never through a
    // map or a set: `paths[i]` and `relativePaths[i]` describe the same file, and
    // any re-ordering between the two would deliver file A under file B's name.
    final List<FileAttachment> attachments = _repo.filesOf(message.id);
    final String? folderName = message.folderName;
    final bool declaresFolder = folderName != null && folderName.isNotEmpty;
    final List<OutgoingFile> outgoing = <OutgoingFile>[];
    for (final FileAttachment file in attachments) {
      outgoing.add(
        OutgoingFile(
          id: _ids.newId(),
          fileName: file.fileName,
          size: file.size,
          sha256: file.sha256 ?? '',
          localPath: file.localPath!,
          mime: file.mime,
          // `null` — never `''` — for a flat message: a `path` without a `folder`
          // is a frame that contradicts itself and the receiver answers 400
          // (docs/22 §4.3), so a flat re-send must not smuggle a position in
          // from a stored row.
          relativePath: declaresFolder ? _positionOf(file) : null,
        ),
      );
    }
    // `count` is the **declared** total stored on the message, not
    // `outgoing.length`: the two only differ for a row that never got all of its
    // files, and there "the sender declared 3" is the honest answer — the
    // receiver then shows `2/3` instead of reporting a complete folder, and the
    // bug the user is retrying stays visible. It is also exactly what
    // `OutboxPump` declares when it re-delivers this same message
    // (`count: message.folderFiles`), so a re-sent folder and a resumed one say
    // the same thing. A non-positive stored count cannot go on the wire
    // (docs/22 §1.1: `count > 0`) and is unreachable through
    // `recordOutgoingFiles`, which writes `files.length`; the fallback keeps a
    // corrupt row from producing a frame the peer has to interpret.
    final FolderRef? folder = !declaresFolder
        ? null
        : FolderRef(
            name: folderName,
            count: message.folderFiles > 0
                ? message.folderFiles
                : outgoing.length,
          );
    // Same ticker bracket as [pickAndSend] / [sendPaths] (0.2.12): without it a
    // re-send showed a frozen 0% for the whole upload, because the store emits
    // nothing on a progress write and the ticker is the only thing that turns
    // those writes into a repaint. The `finally` re-aligns rather than hard
    // stopping (0.2.15).
    _ensureProgressTicker();
    try {
      final SendOutcome outcome = await _orchestrator.send(
        peer: peer,
        files: outgoing,
        folder: folder,
      );
      // A re-sent file's source may itself be a picked copy (a share draft that
      // failed once and was resent), so the same rule applies (0.2.23).
      await _discardPickedCopies(
        outgoing.map((OutgoingFile file) => file.localPath).toList(),
        outcome,
      );
      return outcome;
    } finally {
      syncProgressTicker();
    }
  }

  /// Where [file] sits inside the folder a re-send is about to declare.
  ///
  /// Normally the stored `files.relative_path` — the name the file actually
  /// landed under, which is what the receiver rebuilds its tree from
  /// (docs/22 §2.3). A row written without one still gets a **valid single
  /// segment**, its own [FileAttachment.fileName], instead of `null`: a `null`
  /// here would make the frame contradict itself (`folder` declared, one file
  /// positionless), the peer would answer `400`, and a re-send of a folder would
  /// come back as a refusal instead of a folder. The file lands at the folder
  /// root in that case — the nesting of one corrupt row is lost, the message
  /// stays one folder, which is the part the user can see.
  String _positionOf(FileAttachment file) {
    final String? relative = file.relativePath;
    if (relative == null || relative.isEmpty) {
      return file.fileName;
    }
    return relative;
  }

  /// Whether a [resendUnsent] run is in progress (0.2.24).
  ///
  /// The thread reads it for two things: to disable 全部重试 (no double tap) and
  /// to keep the banner on screen **while** the run is going, even though the
  /// count it was showing has already dropped below the ≥ 2 threshold.
  bool get bulkResending => _bulkResending;

  /// Whether any visible message is mid-send right now (0.2.24).
  ///
  /// Used to keep the 未发送成功 banner out of the way while something is
  /// actually moving: offering "retry all" next to a live upload is noise, and
  /// a bulk run started on top of an in-flight send would queue behind it.
  ///
  /// It answers from the **status**, not from byte progress: a `transferring`
  /// (or `awaitingConfirm`) row *is* a send in progress even in the first frame,
  /// before any byte has been reported — and `pending` does **not** count, since
  /// that is a queued message waiting for an offline peer, which is exactly the
  /// case where "重发一遍" is still a sensible thing to offer.
  bool get hasActiveSend {
    for (final ChatMessage message
        in _messages.valueOrNull ?? const <ChatMessage>[]) {
      if (message.status == MessageStatus.transferring ||
          message.status == MessageStatus.awaitingConfirm) {
        return true;
      }
    }
    return false;
  }

  /// The messages 全部重试 would work on, oldest first (0.2.24, narrowed 0.2.26).
  ///
  /// "没有发送成功" is the user's own reading of the timeline: an **outgoing**
  /// message sitting in `failed` (`取消` — 0.2.22 offers 重新发送 for those too),
  /// that is not a text message (there is no re-send path for text yet), and that
  /// is not already suppressed — neither dismissed with the banner's ✕ nor
  /// already re-sent by a bulk run ([_dismissals]: process-wide since 0.2.30 so it
  /// survives a conversation switch, **persisted** since 0.2.33 so it survives a
  /// restart).
  ///
  /// **Deliberately status-based, not `canResend`-based.** `canResend` is
  /// `false` for a message whose source file is gone, and such a message is
  /// still one of the "5 条没有发送成功" the user is looking at. Counting only
  /// the re-sendable ones would also make [resendUnsent]'s skip counter
  /// unreachable, i.e. the "跳过 M 条（源文件已不在）" answer could never happen —
  /// the exact opposite of what a partial run has to be able to say.
  ///
  /// This getter is the **single** source of the banner's count *and* of the
  /// batch 全部重试 sends, so "what the number says" and "what a tap does" can
  /// never drift apart: a dismissed message is neither counted nor re-sent.
  List<ChatMessage> get unsentMessages => <ChatMessage>[
        for (final ChatMessage message
            in _messages.valueOrNull ?? const <ChatMessage>[])
          if (_countsAsUnsent(message)) message,
      ];

  /// Whether [message] belongs in the 未发送成功 count (see [unsentMessages]).
  bool _countsAsUnsent(ChatMessage message) =>
      message.direction == MessageDirection.outgoing &&
      message.kind == MessageKind.file &&
      (message.status == MessageStatus.failed ||
          message.status == MessageStatus.canceled) &&
      // Both provenances in one question (0.2.33): "the ✕ hid it" and "a 全部重试
      // already re-sent it" both mean *do not count this row*.
      !_dismissals.suppresses(
        conversationId: _conversationId,
        messageId: message.id,
      );

  /// Dismisses exactly the messages the banner is showing right now (0.2.26).
  ///
  /// The banner's ✕ is the "取消" the user asked for ("只有全部重试没有取消按钮").
  /// It closes **this batch**: every id the banner currently counts is recorded in
  /// [_dismissals], so the count drops to 0 and the row disappears — while the
  /// messages themselves stay in the timeline, untouched.
  ///
  /// Nothing else is dismissed, and that is the point: a failure that arrives
  /// *after* this call is a different id, so it counts again and brings the
  /// banner back. "Ignore the five I can see" must never mean "ignore the link
  /// dying again in ten minutes".
  ///
  /// **0.2.30 — the dismissal outlives this controller.** It is written to the
  /// process-wide [UnsentDismissalStore] (keyed by this conversation id), so
  /// leaving the conversation and coming back — which disposes this object and
  /// builds a new one — still hides the banner.
  ///
  /// **0.2.33 — and it outlives the process.** 0.2.30 called "restart brings the
  /// banner back" acceptable; the user did not (*"我退出软件重新进还是有的"*), and he
  /// was right: the messages are still in the history, so the judgement about them
  /// has no reason to expire. The store now persists (asynchronously, fire and
  /// forget — a tap repaints on the next frame, never after a disk round-trip).
  ///
  /// Returns how many were dismissed — `0` when the banner had nothing to hide
  /// (a stale frame painted a row that a repository event has just emptied).
  /// No-ops notify nothing, so a rebuilt-but-identical tree does not churn.
  int dismissUnsent() {
    final List<ChatMessage> targets = unsentMessages;
    if (targets.isEmpty) {
      return 0;
    }
    _dismissals.dismiss(
      conversationId: _conversationId,
      messageIds: targets.map((ChatMessage message) => message.id),
    );
    _notify();
    return targets.length;
  }

  /// Re-sends every message in [unsentMessages] to [peer], **one at a time**
  /// (0.2.24).
  ///
  /// This is the batch entry the "断一次 WiFi 留下 5 条 failed，只能一条条点" report
  /// asked for. It reuses [resend] verbatim — no new send path — and the serial
  /// order is the `await` inside the loop: the next message is not even probed
  /// until the previous `resend` future has completed, so the peer never sees
  /// N uploads racing for one link (a concurrent burst on a just-recovered Wi-Fi
  /// link is how the first one stalls the rest).
  ///
  /// Per message, in this order:
  /// 1. [canResend] — the **same** judgement `_probeSources` / the bubble's own
  ///    重新发送 make, so "why did it skip" has one answer everywhere. A `false`
  ///    (or a probe that throws) counts as [BulkResendResult.skipped];
  /// 2. [resend], which returns `null` if the file vanished between the probe and
  ///    the send — that race is a skip too, not a failure;
  /// 3. the outcome: `ok` counts as sent and records the id as **handled** in
  ///    [_dismissals] so the banner stops counting it (across restarts too,
  ///    0.2.33); anything else is a failure and stays outstanding. A **throw**
  ///    from one message never aborts the rest.
  ///
  /// `ok` deliberately includes a **queued** send (the peer went offline while
  /// the user was looking at the list): nothing went wrong, a new message was
  /// recorded, and the bubbles say 排队中 — which is the durable, honest state.
  /// Reporting it as 仍失败 would tell the user to try again, when trying again
  /// cannot help until the peer is reachable.
  ///
  /// **Nothing here is automatic.** There is no retry timer, no backoff, no
  /// background worker: this only ever runs because the user pressed 全部重试.
  ///
  /// Returns [BulkResendResult.refused] if a run is already in progress (so a
  /// double tap cannot double the message count) and an empty result if there is
  /// nothing to do.
  Future<BulkResendResult> resendUnsent({required PeerDevice peer}) async {
    if (_disposed || _bulkResending) {
      return const BulkResendResult.refused();
    }
    // Snapshot first: the list grows while the run proceeds (each re-send adds a
    // message), and iterating the live getter would re-send the very messages
    // this run just created.
    final List<ChatMessage> targets = unsentMessages;
    if (targets.isEmpty) {
      return const BulkResendResult();
    }
    _bulkResending = true;
    _notify();
    int sent = 0;
    int skipped = 0;
    int failed = 0;
    try {
      for (final ChatMessage message in targets) {
        if (_disposed) {
          break;
        }
        bool retryable;
        try {
          retryable = await canResend(message);
        } catch (_) {
          // A probe that cannot answer is not a reason to send blind.
          retryable = false;
        }
        if (!retryable) {
          skipped++;
          continue;
        }
        try {
          final SendOutcome? outcome =
              await resend(peer: peer, message: message);
          if (outcome == null) {
            // The source went away between the probe and the send.
            skipped++;
            continue;
          }
          if (outcome.ok) {
            sent++;
            // 0.2.33: recorded in the persisted store, not in a controller field —
            // a batch retry that succeeded must stay settled after a restart too.
            // (The store coalesces writes, so twenty ids do not mean twenty files.)
            _dismissals.markHandled(
              conversationId: _conversationId,
              messageIds: <String>[message.id],
            );
          } else {
            failed++;
          }
        } catch (_) {
          // One message's exception must not abandon the other four: count it
          // and move on — the failures stay outstanding for a further attempt.
          failed++;
        }
      }
    } finally {
      _bulkResending = false;
      _notify();
    }
    return BulkResendResult(sent: sent, skipped: skipped, failed: failed);
  }

  /// Frees the app's temporary copies of [paths] once the send has actually
  /// delivered them (0.2.23).
  ///
  /// **Only on [SendOutcome.delivered].** Everything else still needs the local
  /// file: a `failed` (or `canceled`) message offers 重新发送, which re-reads the
  /// very path this would delete; a `queued` send was never attempted; a
  /// `rejected` one the user may still want to open locally. Deleting in any of
  /// those cases would turn a retryable bubble into a permanent 源文件已不在.
  ///
  /// **It can only ever delete our own copies.** `PickedCachePort.discard` skips
  /// every path outside `<temp>/lanlink-picked/`, so a file the user picked on
  /// the desktop (picked in place, no copy) or dropped into the window is never
  /// touched — the judgement lives in `PickedFileCache.owningDirectory`, not
  /// here, so there is exactly one place that decides "is this ours".
  ///
  /// **★ 0.2.49 — and it now remembers whose doing the disappearance was.** These
  /// paths stop existing *because we deleted them*, which is the opposite of the
  /// user losing a file, and the two must not look the same on screen. The
  /// timeline asks [discardedByUs] before drawing a warning, so a successful
  /// Android send stops being accused of having lost its own cache copy
  /// (*"发送成功后，已完成旁边却会显示离线的那个红色图标"*). Nothing is persisted —
  /// see [discardedByUs] for how the answer survives a restart.
  Future<void> _discardPickedCopies(
    Iterable<String> paths,
    SendOutcome outcome,
  ) async {
    if (!outcome.delivered) {
      return;
    }
    // Materialised once: the port takes an `Iterable`, and the same list is
    // recorded afterwards — a lazy iterable would be drained by the first use.
    final List<String> copies = paths.toList();
    await _pickedCache.discard(copies);
    _discardedCopies.addAll(copies);
  }

  /// Paths **this app deleted itself** — the post-send cleanup of its own
  /// temporary copies (0.2.49). Insertion-ordered and process-local.
  ///
  /// Why it is not persisted: the copies themselves are not. Restarting the app
  /// cannot resurrect them, so a persisted list would only grow forever. What
  /// survives a restart instead is *recognition* rather than memory —
  /// `isPickedCachePath`, applied by the timeline to a delivered message's path
  /// (see [discardedByUs]).
  final Set<String> _discardedCopies = <String>{};

  /// Whether [path] is one of the temporary copies **this process watched itself
  /// delete** — direct evidence for "who removed this file" (0.2.49).
  ///
  /// The UI asks it before turning a missing attachment into a warning
  /// (`MessageBubble.sourceCleanedByUs`). This is *evidence*, not a guess: the path
  /// was in [the cleanup call][_discardPickedCopies] after a delivered send.
  ///
  /// It is deliberately **not** derived from the message's status, and it is not a
  /// statement about the disk either (`SourceAvailability` owns that). A `done`
  /// message whose file the user deleted on the desktop is a real loss and must
  /// still be reported; a `failed` one whose picked copy is gone is a dead end the
  /// user must be told about — neither of those ever passed through the cleanup,
  /// so neither is "ours" here.
  ///
  /// **Empty after a restart**, by design: nothing is persisted, because the
  /// copies are not either. The cross-restart half of the same question is an
  /// *inference* the timeline makes for itself — a path under `lanlink-picked/`
  /// that vanished from a **delivered** message can only have been freed by us
  /// (`isPickedCachePath`, `conversation_thread.dart::_bubble`).
  bool discardedByUs(String? path) =>
      path != null && path.isNotEmpty && _discardedCopies.contains(path);

  /// Cancels [message] in any state the user is allowed to cancel it from
  /// (0.2.22).
  ///
  /// Before 0.2.22 this returned `false` for everything except `pending` — while
  /// the bubble offered 取消 on **three** states and the thread threw the result
  /// away. So 取消 on a 传输中 message did nothing at all, said nothing, and left
  /// "kill the app" as the only exit (a half-open socket hangs `upload` until the
  /// OS keepalive gives up).
  ///
  /// Now, in order:
  /// 1. refuse out loud unless the status is in [kCancelableStatuses];
  /// 2. flag the in-flight send **first** (synchronously), so the transport's
  ///    error handler cannot write `failed` over the `canceled` that is about to
  ///    land — the store rejects that edge outright;
  /// 3. move the row to `canceled` locally, which is what makes the bubble leave
  ///    传输中 on the next frame — the user never waits for a network round trip;
  /// 4. *then* tell the peer, best effort and unawaited (a peer that just
  ///    vanished is exactly the case this exists for).
  ///
  /// Always returns copy for the UI: no path is silent ([CancelResult.notice]).
  Future<CancelResult> cancel(ChatMessage message) async {
    final MessageStatus status = message.status;
    if (!kCancelableStatuses.contains(status)) {
      return CancelResult.refused(_notCancelableNotice(status));
    }

    final bool inFlight = _orchestrator.isInFlight(message.id);
    final bool moved = _repo.setStatus(
      messageId: message.id,
      from: status,
      to: MessageStatus.canceled,
    );
    if (!moved) {
      // Lost the race: the send reached a terminal state between the frame the
      // user was looking at and the tap. Nothing was cancelled — say so.
      return const CancelResult.refused('这条消息刚刚已经结束，不能取消');
    }

    if (inFlight) {
      // Not awaited on purpose: `/cancel` on a dead peer costs up to the 10 s
      // connect timeout, and the local cancel has already happened.
      unawaited(_orchestrator.cancelInFlight(message.id));
    }
    return const CancelResult.canceled();
  }

  /// Why [status] cannot be cancelled, in words the user can act on.
  ///
  /// An exhaustive switch on purpose: adding a [MessageStatus] is a compile
  /// error here until it is given an answer, and the three cancellable states
  /// are listed explicitly so the "should be unreachable" case cannot become the
  /// silent fallback.
  String _notCancelableNotice(MessageStatus status) => switch (status) {
        MessageStatus.done => '已经发送完成，不能取消',
        MessageStatus.rejected => '对方已经拒收，不能取消',
        MessageStatus.canceled => '这条消息已经取消了',
        MessageStatus.failed => '发送已经失败，可以用「重新发送」',
        // Unreachable: `cancel()` returns above for these three.
        MessageStatus.pending ||
        MessageStatus.awaitingConfirm ||
        MessageStatus.transferring =>
          '这条消息正在发送，不能取消',
      };

  /// Whether [message] may be deleted from the local history right now
  /// (0.2.36).
  ///
  /// **A send that is still happening may not be deleted.** `pending` /
  /// `awaitingConfirm` / `transferring` (exactly [kCancelableStatuses]) all
  /// describe a transfer that is still running, and removing the row underneath
  /// it would leave "the record is gone, the upload is not" — with nothing left
  /// on screen to cancel it with. Those three are refused; every other status
  /// (`done`, `failed`, `canceled`, `rejected`) means the transfer is over, so
  /// the record is all that is left and deleting it is purely local.
  ///
  /// This is the **single** predicate: `ui/panes/conversation_thread.dart` uses
  /// it to decide whether the 「删除消息」/「删除」 row exists at all (a row that is
  /// not built cannot be tapped), and [deleteMessage] re-checks it because a
  /// stale frame can still deliver a tap.
  bool canDelete(ChatMessage message) =>
      !kCancelableStatuses.contains(message.status);

  /// Deletes [message] from the local history (0.2.36).
  ///
  /// **Scope, deliberately narrow:** the store row sub-tree goes (message, its
  /// files, their transfers); the peer keeps its copy (the protocol has no
  /// delete frame) and **no file on disk is touched** — a received file stays
  /// in 下载, because the user may still want the file after deciding the bubble
  /// has no further use. There is no undo.
  ///
  /// The in-memory list is updated **only after** the store said it removed a
  /// row: a bubble that vanished from the timeline while the database still
  /// held it would come back on the next [load] — the "重启后它又回来了" shape
  /// that is worse than not deleting at all.
  ///
  /// Always returns copy for the UI ([DeleteResult.notice]); no path is silent.
  DeleteResult deleteMessage(ChatMessage message) {
    if (_disposed) {
      return const DeleteResult.refused('会话已关闭，请重新进入');
    }
    if (!canDelete(message)) {
      return const DeleteResult.refused('这条消息正在发送，不能删除');
    }
    if (!_repo.deleteMessage(message.id)) {
      // Already gone (a double tap on a menu that outlived a repository event).
      // Drop it from the visible list too, so the frame and the store agree.
      _removeLocally(message.id);
      return const DeleteResult.refused('这条消息已经不在了');
    }
    _removeLocally(message.id);
    return const DeleteResult.deleted();
  }

  /// Drops [messageId] from the visible timeline and repaints. Returns whether
  /// the list changed.
  ///
  /// `_messages` may legitimately be `Loading` / `Failure` (nothing loaded yet,
  /// or the history read failed) — there is then nothing to remove, and the
  /// store deletion still stands, so this is a no-op rather than an error.
  bool _removeLocally(String messageId) {
    final List<ChatMessage>? list = _messages.valueOrNull;
    if (list == null) {
      return false;
    }
    final List<ChatMessage> kept = <ChatMessage>[
      for (final ChatMessage message in list)
        if (message.id != messageId) message,
    ];
    if (kept.length == list.length) {
      return false;
    }
    _messages = Data<List<ChatMessage>>(kept);
    // A deleted message can no longer be "in flight", so this can only ever stop
    // a poll that was running for a row which has just been removed from view.
    syncProgressTicker();
    _notify();
    return true;
  }

  // ── repository events → in-place UI updates (§4.1) ─────────────────────
  void _onEvent(RepoEvent event) {
    if (_disposed) {
      return;
    }
    bool touchedThisThread = false;
    if (event is MessageAdded) {
      touchedThisThread = _onAdded(event.message);
    } else if (event is MessageFilesAppended) {
      touchedThisThread = _onFilesAppended(event.messageId);
    } else if (event is MessageStatusUpdated) {
      touchedThisThread = _onStatusUpdated(event.messageId, event.to);
    }
    // A transfer can *start* (a new outgoing message, `pending → transferring`)
    // and *end* (`done` / `failed`) through an event, so this is where a poll
    // that had stopped for lack of work is picked up again (0.2.15) — the "next
    // transfer must restart the ticker" half of the fix.
    //
    // Guarded on relevance on purpose: this stream carries **every** repository
    // event of the app, and `syncProgressTicker` walks the whole visible history
    // (two store reads per file). An event about another conversation cannot
    // change what this thread shows, so it cannot change the answer either.
    if (touchedThisThread) {
      syncProgressTicker();
    }
  }

  /// Applies [message] in place. Returns whether the visible list changed.
  bool _onAdded(ChatMessage message) {
    if (message.conversationId != _conversationId) {
      return false;
    }
    final List<ChatMessage> list =
        List<ChatMessage>.of(_messages.valueOrNull ?? const <ChatMessage>[]);
    if (list.any((ChatMessage m) => m.id == message.id)) {
      return false; // de-duplicated replay never re-adds (M3 §5.6)
    }
    list.add(message);
    list.sort(_byCreatedAsc);
    _messages = Data<List<ChatMessage>>(list);
    _notify();
    return true;
  }

  /// Applies an **appended attachment** in place. Returns whether anything this
  /// thread shows could have changed.
  ///
  /// The event carries no payload on purpose (`MessageFilesAppended` has only a
  /// message id): the rows are already in the store, and every reader —
  /// `filesOf` for the bubble's 「已收到 n/N」, the 文件 tab, the folder page —
  /// re-reads them. So the whole job here is to make them read again, which is
  /// what [_notify] does; the message list itself does **not** change shape
  /// (files 2…N land on the message file 1 created, docs/22 §4.2), which is
  /// exactly why this event is needed at all.
  ///
  /// [`_grownMessages`] is bumped so a listener that only reacts to *counts*
  /// (the timeline's scroll / disk-probe decision, `conversation_thread.dart`)
  /// can notice a change it would otherwise miss **and know which message it
  /// belongs to**: the message count is identical before and after this event,
  /// and the timeline may only spend a disk read on the rows that actually grew.
  ///
  /// Deliberately does **not** ask for a progress tick (the caller's
  /// `syncProgressTicker`): the only writer of this event is the inbound folder
  /// path, whose files are already `done` — there is no in-flight transfer to
  /// poll for, and a tick walks the whole visible history at two store reads per
  /// file.
  bool _onFilesAppended(String messageId) {
    final List<ChatMessage>? list = _messages.valueOrNull;
    if (list == null) {
      return false;
    }
    if (!list.any((ChatMessage m) => m.id == messageId)) {
      // Another conversation's message, or a thread that has not loaded yet.
      return false;
    }
    _grownMessages.update(messageId, (int seen) => seen + 1, ifAbsent: () => 1);
    _notify();
    return false;
  }

  /// Applies a status change in place. Returns whether the visible list changed.
  bool _onStatusUpdated(String messageId, MessageStatus to) {
    final List<ChatMessage>? list = _messages.valueOrNull;
    if (list == null) {
      return false;
    }
    final int index = list.indexWhere((ChatMessage m) => m.id == messageId);
    if (index < 0) {
      return false;
    }
    final List<ChatMessage> updated = List<ChatMessage>.of(list);
    updated[index] = updated[index].copyWith(
      status: to,
      updatedAt: _clock.nowUtc(),
    );
    _messages = Data<List<ChatMessage>>(updated);
    _notify();
    return true;
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopProgressTicker();
    _sub.cancel();
    super.dispose();
  }
}

/// `createdAt` ascending, ties broken by id (stable timeline order, E4).
int _byCreatedAsc(ChatMessage a, ChatMessage b) {
  final int byTime = a.createdAt.compareTo(b.createdAt);
  return byTime != 0 ? byTime : a.id.compareTo(b.id);
}

/// The last path segment, handling both separators (no `path` package, §7).
String _baseName(String path) {
  final int slash = path.lastIndexOf('/');
  final int backslash = path.lastIndexOf(r'\');
  final int cut = slash > backslash ? slash : backslash;
  return cut >= 0 ? path.substring(cut + 1) : path;
}
