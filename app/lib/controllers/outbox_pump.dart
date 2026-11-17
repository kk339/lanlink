/// The offline queue's missing half: something that **takes messages out**
/// (0.2.40).
///
/// ## Why this file exists
///
/// Until 0.2.40 `TransferOrchestrator.send` recorded an outgoing message as
/// `pending` and then, when the peer was offline, returned
/// `SendOutcome.queued()` **without dialling** — and nothing ever looked at that
/// row again. `pending` was a state with a writer and no reader:
///
/// * `failInterruptedMessages` sweeps only `awaiting_confirm` / `transferring`,
///   so it deliberately skips `pending` (a queued send must survive a restart);
/// * `ConversationController.unsentMessages` counts only `failed` / `canceled`,
///   so the 未发送成功 banner never listed it;
/// * `ConversationController.canResend` refuses anything but `failed` /
///   `canceled`, so the bubble had no 重新发送 button either.
///
/// The only exit was 取消 (a `pending` row *is* cancellable) followed by
/// 重新发送 — which is a **new** message, because `canceled` is terminal. The
/// user found exactly that workaround, and reported it as a bug: *"对方在线了也
/// 没看到这个排队就开始传输了，就一直排队，得我取消重新发送才行"*.
///
/// The report was right, and the missing piece is small: the online signal
/// already exists end to end (`core` emits `PeerCameOnline` on the actual
/// state transition, `LanPeerDiscovery` forwards it, `PeerDiscovery.events`
/// carries it) — nobody consumed it. This class consumes it, and resumes the
/// queued rows through the **same** delivery path a first send uses.
///
/// ## What "resume" means, precisely
///
/// It is *not* a new message. `recordOutgoing` lives in
/// `TransferOrchestrator.send`, and `_deliver` takes only a message id, so a
/// resume drives the **existing** row from `pending` onwards. One bubble stays
/// one bubble — which is why the pump never mints a message id, never touches
/// `eventNonce` for files, and needs no "the old one was cancelled" lie in the
/// history.
///
/// ## The triggers (all of them, on purpose)
///
/// 1. **A discovery event whose peer is online.** Deliberately *not* matched by
///    event type: the registry is in-memory (`core`'s `PeerRegistry` keeps a
///    plain `Map`), so after a restart a live peer only ever produces
///    `PeerAppeared` — never `PeerCameOnline`; and a peer that comes back inside
///    the 60 s offline grace produces no transition at all. Gating on
///    `peer.isOnline` covers `PeerAppeared` / `PeerCameOnline` / `PeerUpdated`
///    with one rule and cannot drift.
/// 2. **The app returns to the foreground.** Multicast frames are dropped while
///    the process is suspended, so a peer that came online during that window
///    emitted nothing we could have heard.
/// 3. **After startup** ([start]). Subsumed by (1) in practice — discovery
///    announces each live peer, which is a `PeerAppeared` — but stated
///    explicitly so "queued it, closed the app" is answered by design rather
///    than by luck.
/// 4. **A low-frequency fallback scan** while anything is queued — because
///    (1)–(3) are all events, and the recovery the user actually meets ("对方
///    now accepts my connections") often emits none. See below.
///
/// ## Anti-amplification
///
/// A drain is **serial per peer** (a link that just recovered must not be asked
/// to carry N uploads at once — the same reason `resendUnsent` is serial) and
/// re-entrant calls are dropped while it runs. A failed attempt that leaves work
/// outstanding arms a short cooldown, so a peer that keeps announcing but is not
/// actually reachable cannot turn every announcement into a dial.
///
/// The cooldown is armed **only when work is left over**. That is what keeps it
/// from swallowing a legitimate wake-up: a successful drain leaves no `pending`
/// row, so the next two events in the same burst find nothing to do anyway.
///
/// ## Trigger ④ — the fallback scan, and why events alone are not enough (0.2.47)
///
/// Triggers ①–③ are all *events*, and the previous version of this file said so
/// out loud: "five seconds is the announcement interval, so the next real
/// announcement is the first thing allowed through". That premise is false, and
/// it was the bug: the registry announces a peer only when its **appearance /
/// online-ness / alias** changes (and, since 0.2.47, its **port**). A peer that
/// is reachable again in a way the registry cannot observe produces **no event
/// at all**:
///
/// * its firewall starts allowing our connections — nothing observable changed;
/// * it switched its receiver on — ditto;
/// * it kept announcing the whole time, so there is no offline→online edge.
///
/// So a `pending` row could sit at 排队中 until the user restarted this app, put
/// it in the background and back, or renamed a device — the same "a state with a
/// writer and no reader" bug [OutboxPump] exists to prevent, narrowed to the
/// recoveries that are silent.
///
/// The cure is one **low-frequency scan** ([kOutboxScanInterval], 30 s — six
/// announcement intervals, so it serves "eventually" and never "jitter"). Three
/// properties keep it from becoming the poller this file used to argue against:
///
/// 1. **It exists only while the queue is non-empty.** [_syncScanTimer] creates
///    it when at least one outgoing row is `pending` and cancels it the moment
///    there is none, so an idle app has no timer at all — no 1 Hz tick, no wake
///    on a device that has never queued anything.
/// 2. **It dials nothing itself.** Each tick calls [drainAll], i.e. the same
///    `_drain` a discovery event drives: `isOnline` / `isDialable` / `canSend`,
///    the per-peer re-entrancy guard and the cooldown all still apply. A peer
///    with no inbound server is skipped by the scan exactly like it is skipped
///    by an event.
/// 3. **It cannot amplify.** A tick that arrives while a drain for that peer is
///    running is dropped by `_draining`, and one that arrives inside the
///    cooldown is dropped by `_retryAfter`, so three wake-ups in 30 s are still
///    one dial.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../domain/clock.dart';
import '../domain/models.dart';
import '../domain/peer_discovery.dart';
import '../domain/platform_ports.dart';
import '../domain/selectors.dart';
import '../domain/session_repository.dart';
import '../domain/transfer_service.dart';
import 'transfer_orchestrator.dart';

/// How long a peer's outbox is left alone after an attempt that made no
/// progress (0.2.40).
///
/// Five seconds is the announcement interval (`LanPeerDiscovery`), so the next
/// real announcement is the first thing allowed through — the cooldown debounces
/// one burst, it does not delay recovery.
///
/// Note what this is **not** (0.2.47): it is not a promise that another wake-up
/// is coming. An announcement only produces an event when something observable
/// changed, so "the next announcement" may never arrive; the fallback scan
/// ([kOutboxScanInterval], 30 s) is what guarantees a retry, and it is six times
/// this cooldown precisely so the two never fight.
const Duration kOutboxCooldown = Duration(seconds: 5);

/// How often the outbox is re-examined when **nothing** wakes it (0.2.47).
///
/// Six announcement intervals, on purpose. This is the answer to "the peer
/// became reachable without anything observable changing" (a firewall rule, a
/// receiver switched on, a network that came back), so it does not have to be
/// fast — it has to be *certain*. A shorter period would only re-derive the
/// conclusion the last tick already reached, on a queue that is by definition
/// blocked on something outside this app.
///
/// It is not a poller: the timer this drives exists only while a `pending` row
/// does (see [_syncScanTimer]).
const Duration kOutboxScanInterval = Duration(seconds: 30);

/// Drives queued (`pending`) outgoing messages once their peer is reachable.
///
/// See the library doc for why the class exists and which triggers it answers.
class OutboxPump {
  /// Wires the pump.
  ///
  /// [clock] is injectable so the cooldown can be driven by a test's
  /// [FixedClock] instead of by sleeping; [cooldown] is injectable for the same
  /// reason. [scanInterval] is the fallback scan's period (trigger ④); tests
  /// shorten it, production keeps [kOutboxScanInterval].
  ///
  /// [platform] is here for **one** question (0.2.52): is the source file of a
  /// queued message still on disk? The answer decides whether a resume may dial
  /// at all — see [_resume]. It goes through the platform port rather than
  /// `dart:io` so this file stays pure (M4 §8.1) and so a test can state the
  /// answer instead of having to create a real file.
  OutboxPump({
    required SessionRepository repo,
    required PeerDiscovery discovery,
    required TransferOrchestrator orchestrator,
    required PlatformPorts platform,
    Clock clock = const SystemClock(),
    this.cooldown = kOutboxCooldown,
    this.scanInterval = kOutboxScanInterval,
    void Function(String message)? onLog,
  })  : _repo = repo,
        _discovery = discovery,
        _orchestrator = orchestrator,
        _platform = platform,
        _clock = clock,
        _onLog = onLog;

  /// How long a peer's outbox is left alone after an unproductive attempt.
  final Duration cooldown;

  /// Period of the fallback scan (trigger ④). See [kOutboxScanInterval].
  final Duration scanInterval;

  final SessionRepository _repo;
  final PeerDiscovery _discovery;
  final TransferOrchestrator _orchestrator;
  final PlatformPorts _platform;
  final Clock _clock;
  final void Function(String message)? _onLog;

  StreamSubscription<DiscoveryEvent>? _sub;
  StreamSubscription<RepoEvent>? _repoSub;
  _OutboxLifecycleObserver? _observer;
  bool _disposed = false;

  /// The fallback scan (trigger ④), or `null` when the queue is empty.
  ///
  /// Its **existence** is the invariant: non-null ⇔ at least one outgoing
  /// message is `pending`. Nothing else owns it, so an idle pump costs nothing.
  Timer? _scanTimer;

  /// How many fallback scans have fired (test convenience: "the periodic half
  /// still runs" is otherwise unobservable without waiting 30 real seconds).
  int scanTicks = 0;

  /// Fingerprints whose outbox a drain is walking right now.
  ///
  /// The re-entrancy guard. Two drains for one peer would race each other into
  /// `_deliver`; the orchestrator's `pending → awaitingConfirm` claim would make
  /// the loser a no-op, but the winner/loser order would be arbitrary — better
  /// not to start.
  final Set<String> _draining = <String>{};

  /// Per-peer "do not dial again before this instant" (armed only when an
  /// attempt left something `pending` — see the library doc).
  final Map<String, DateTime> _retryAfter = <String, DateTime>{};

  /// How many drains have actually run (test convenience: "the event did reach
  /// the pump" is otherwise unobservable).
  int drainRuns = 0;

  /// Whether the pump is watching discovery + the app lifecycle.
  bool get isStarted => _sub != null;

  /// Whether any lifecycle observer is attached (test convenience).
  bool get observesLifecycle => _observer != null;

  /// Whether the fallback scan (trigger ④) is running right now.
  ///
  /// `false` while nothing is queued — that is the judgement, not an aside: an
  /// app with an empty outbox must not own a timer at all.
  bool get isScanning => _scanTimer != null;

  /// Subscribes to discovery, the repository and (when a binding exists) the app
  /// lifecycle, then drains once so a message queued in an earlier process is
  /// not waited on.
  ///
  /// Must run **after** `WidgetsFlutterBinding.ensureInitialized()` — it
  /// registers a lifecycle observer. Production calls it from
  /// `create_deps_native`; a test calls it explicitly, which is also what keeps
  /// the wiring falsifiable.
  ///
  /// Idempotent: a second call is a no-op.
  void start() {
    if (_disposed || _sub != null) {
      return;
    }
    _sub = _discovery.events.listen(_onDiscoveryEvent);
    // Trigger ④'s arming condition. The scan's existence is derived from the
    // queue, so whoever writes a `pending` row has to be able to re-derive it —
    // and that is the repository, which already publishes exactly this. Without
    // this subscription the fallback would only ever arm for rows that existed
    // when some *other* drain ran, i.e. it would not cover "queued 发送 while the
    // app is already running".
    _repoSub = _repo.events.listen(_onRepoEvent);
    final _OutboxLifecycleObserver observer =
        _OutboxLifecycleObserver(onResumed: onAppResumed);
    _observer = observer;
    WidgetsBinding.instance.addObserver(observer);
    // Trigger ③: whatever was queued before this process started. In practice
    // the first `PeerAppeared` does this too, but a pump that only works because
    // discovery happens to announce is a pump that breaks the day it does not.
    // This drain also arms the scan when it leaves rows behind (`_drain`'s tail).
    unawaited(drainAll());
  }

  /// Trigger ① — one discovery event.
  ///
  /// The event **type** is not consulted (see the library doc): every shape is
  /// forwarded and the decision is `peer.isOnline`, because that is the only
  /// thing that actually matters to a send and the only thing the registry
  /// guarantees to be current.
  void _onDiscoveryEvent(DiscoveryEvent event) {
    final DiscoveredPeer? peer = switch (event) {
      PeerAppeared(:final DiscoveredPeer peer) => peer,
      PeerUpdated(:final DiscoveredPeer peer) => peer,
      PeerCameOnline(:final DiscoveredPeer peer) => peer,
      // Offline, or the discovery layer failed: nothing can be sent now. A
      // later online event will wake the queue — that is the whole design.
      PeerWentOffline() || DiscoveryFailed() => null,
    };
    if (peer == null || !peer.isOnline) {
      return;
    }
    unawaited(drainFor(peer.fingerprint));
  }

  /// Keeps trigger ④'s arming condition in step with the queue.
  ///
  /// Only the two shapes that can create or destroy a `pending` **outgoing** row
  /// are consulted. Anything else (an inbound message arriving, a transfer
  /// progressing, a delete, and since 0.2.51 an attachment appended to an
  /// existing folder message) is ignored on purpose: this listener runs for
  /// every repository event in the app, and a scan-timer decision per received
  /// file of a thousand-file folder would be real work for no answer.
  void _onRepoEvent(RepoEvent event) {
    if (_disposed) {
      return;
    }
    final bool relevant = switch (event) {
      // A send that could not dial is recorded `pending` immediately.
      MessageAdded(:final ChatMessage message) => message.direction ==
              MessageDirection.outgoing &&
          message.status == MessageStatus.pending,
      // …and a row leaves that state either into a transfer or into a terminal
      // status (cancel / fail), which is when the scan must stop.
      MessageStatusUpdated(:final MessageStatus from, :final MessageStatus to) =>
        from == MessageStatus.pending || to == MessageStatus.pending,
      // 0.2.51 — a folder's files 2…N landing on an existing message. The pump
      // exists to send **files we hold**, and an inbound append can neither
      // create nor destroy a `pending` outgoing row, so it is irrelevant here by
      // the same rule as a status change of an incoming message.
      MessageFilesAppended() => false,
    };
    if (!relevant) {
      return;
    }
    _syncScanTimer();
  }

  /// Trigger ② — the app came back to the foreground.
  ///
  /// Wired through `WidgetsBindingObserver` from [start]. Multicast frames are
  /// dropped while the process is suspended, so a peer that went away and came
  /// back during that window produced no event this process could hear.
  ///
  /// Public so a test can drive the outcome directly as well as through the real
  /// binding.
  void onAppResumed() {
    if (_disposed) {
      return;
    }
    unawaited(drainAll());
  }

  /// Trigger ④'s body: one fallback scan.
  ///
  /// It deliberately has **no logic of its own** — it re-runs the same drain a
  /// discovery event runs, so every rule (`isOnline`, `isDialable`, `canSend`,
  /// the per-peer guard, the cooldown) is applied exactly once, in one place.
  void _onScanTick() {
    if (_disposed) {
      _cancelScanTimer();
      return;
    }
    scanTicks += 1;
    unawaited(drainAll());
  }

  /// Creates or cancels the fallback scan so that "there is a timer" and "there
  /// is something queued" are always the same statement.
  ///
  /// Called from [start]'s drain (via `_drain`'s tail), from every drain, from
  /// [_onRepoEvent] when the queue gained or lost a `pending` row, and from
  /// [dispose]. Idempotent, so the callers cannot get it wrong between them.
  void _syncScanTimer() {
    if (_disposed) {
      _cancelScanTimer();
      return;
    }
    if (!_hasPendingOutgoing()) {
      _cancelScanTimer();
      return;
    }
    _scanTimer ??= Timer.periodic(scanInterval, (_) => _onScanTick());
  }

  /// Whether any outgoing message is `pending` right now.
  ///
  /// The same filter [_drain] applies, for the same reason: an incoming row is
  /// never something this class may drive.
  bool _hasPendingOutgoing() {
    for (final ChatMessage message
        in _repo.messagesByStatus(<MessageStatus>{MessageStatus.pending})) {
      if (message.direction == MessageDirection.outgoing) {
        return true;
      }
    }
    return false;
  }

  void _cancelScanTimer() {
    _scanTimer?.cancel();
    _scanTimer = null;
  }

  /// Drains every peer whose card is online and dialable.
  Future<void> drainAll() => _drain(const <String>{});

  /// Drains one peer's outbox. [fingerprint] is normalised the same way the home
  /// screen's merge key is, so a caller may pass the raw wire value.
  Future<void> drainFor(String fingerprint) {
    final String key = normalizeDeviceFingerprint(fingerprint);
    if (key.isEmpty) {
      return Future<void>.value();
    }
    return _drain(<String>{key});
  }

  /// The one drain implementation. [only] empty means "every peer".
  ///
  /// Wraps [_drainOnce] purely to re-derive trigger ④'s arming condition at the
  /// end of **every** pass — including the passes that return early — so the
  /// scan is cancelled as soon as the last queued row left `pending`, and armed
  /// as soon as a pass leaves one behind.
  Future<void> _drain(Set<String> only) async {
    try {
      await _drainOnce(only);
    } finally {
      _syncScanTimer();
    }
  }

  /// The drain itself: one merged snapshot of the device cards, one read of the
  /// queue, then one serial attempt per reachable peer.
  Future<void> _drainOnce(Set<String> only) async {
    if (_disposed) {
      return;
    }
    // The same merged view the home screen draws, so "is this peer reachable"
    // has exactly one answer in the app (`mergeDeviceCards` §4.2): the live
    // entry wins on `isOnline` / `lastPort` / `lastIp`.
    final List<PeerDevice> cards = mergeDeviceCards(
      online: _discovery.online,
      conversations: _repo.conversations(includeArchived: true),
      devices: _repo.devices(),
    );
    // Read once: the queue is small, and one read keeps every decision in this
    // pass consistent with itself.
    final List<ChatMessage> queued = <ChatMessage>[
      for (final ChatMessage message
          in _repo.messagesByStatus(<MessageStatus>{MessageStatus.pending}))
        if (message.direction == MessageDirection.outgoing) message,
    ];
    if (queued.isEmpty) {
      return;
    }

    for (final PeerDevice card in cards) {
      if (_disposed) {
        return;
      }
      final String? conversationId = card.conversationId;
      if (conversationId == null) {
        continue; // No thread, so nothing can be queued for it.
      }
      if (only.isNotEmpty && !only.contains(card.fingerprint)) {
        continue;
      }
      // Offline, or no inbound server: the message must **stay** `pending`. This
      // is the branch that keeps 判据 "still offline → prepare called 0 times"
      // true — a pump that ignored `isOnline` would dial an absent peer on every
      // announcement.
      if (!card.isOnline || !card.isDialable || !card.canSend) {
        continue;
      }
      final List<ChatMessage> mine = <ChatMessage>[
        for (final ChatMessage message in queued)
          if (message.conversationId == conversationId) message,
      ];
      if (mine.isEmpty) {
        continue;
      }
      if (_draining.contains(card.fingerprint)) {
        continue; // A drain for this peer is already walking the list.
      }
      final DateTime? retryAfter = _retryAfter[card.fingerprint];
      if (retryAfter != null &&
          _clock.nowUtc().isBefore(retryAfter)) {
        continue; // Cooldown from an attempt that made no progress.
      }

      _draining.add(card.fingerprint);
      drainRuns += 1;
      try {
        final int outstanding = await _drainOne(card, mine);
        if (outstanding > 0) {
          _retryAfter[card.fingerprint] = _clock.nowUtc().add(cooldown);
        } else {
          _retryAfter.remove(card.fingerprint);
        }
      } finally {
        _draining.remove(card.fingerprint);
      }
    }
  }

  /// Resumes [messages] to [peer], **one at a time**, and returns how many are
  /// still `pending` afterwards.
  ///
  /// Serial on purpose (`resendUnsent` makes the same choice for the same
  /// reason): a link that has just recovered should carry one upload, not N
  /// racing for it.
  Future<int> _drainOne(PeerDevice peer, List<ChatMessage> messages) async {
    int outstanding = 0;
    for (final ChatMessage message in messages) {
      if (_disposed) {
        break;
      }
      // A message the user is cancelling right now, or one a previous pass left
      // in flight: not ours to drive.
      if (_orchestrator.isInFlight(message.id)) {
        outstanding += 1;
        continue;
      }
      final SendOutcome? outcome = await _resume(peer, message);
      if (outcome == null) {
        // Could not start at all. `_resume` has already moved the row to
        // `failed` (with a reason the bubble can print — 0.2.52) in every case
        // it answers `null` for, so nothing of this message is left to outrun.
        outstanding += 1;
        continue;
      }
      _log('outbox: ${message.id} → ${_outcomeName(outcome)} '
          '(peer ${peer.fingerprint})');
      if (outcome.queued) {
        // The peer went away again between the event and this line. Leave it
        // `pending` — the next online event is the retry.
        outstanding += 1;
        continue;
      }
      // The two outcomes that report a reason but may not have written a status:
      // `canSend == false` returns `failed` without touching the row (in `send`
      // that is correct — no row exists yet). Here the row *does* exist, so
      // leaving it `pending` would recreate the very bug this class fixes.
      final String? error = outcome.error;
      if (error != null && _isStillPending(message.id)) {
        _repo.markSendFailed(messageId: message.id, error: error);
      }
    }
    return outstanding;
  }

  /// Drives one queued [message] through the orchestrator.
  ///
  /// Returns `null` when the message cannot be resumed at all — the honest cases
  /// are "the source file is gone" and "the text row has no anchor" — after
  /// moving it to `failed` so the user is offered 重新发送 instead of a bubble
  /// that will never move.
  Future<SendOutcome?> _resume(PeerDevice peer, ChatMessage message) async {
    if (message.kind == MessageKind.text) {
      final String? text = message.textBody;
      final String? nonce = message.eventNonce;
      if (text == null || text.isEmpty || nonce == null || nonce.isEmpty) {
        // Unreachable for rows this app wrote (the nonce is minted before the
        // row). If it ever fires, `failed` + 重新发送 is still the honest
        // answer — a text bubble that can never move is not.
        _repo.markSendFailed(
          messageId: message.id,
          error: '这条消息缺少重发所需的信息',
        );
        return null;
      }
      return _orchestrator.resumeQueuedText(
        peer: peer,
        messageId: message.id,
        text: text,
        nonce: nonce,
      );
    }

    final List<FileAttachment> attachments = _repo.filesOf(message.id);
    if (attachments.isEmpty) {
      _repo.markSendFailed(messageId: message.id, error: kSourceMissingError);
      return null;
    }
    final List<OutgoingFile> files = <OutgoingFile>[];
    for (final FileAttachment file in attachments) {
      final String? path = file.localPath;
      if (path == null || path.isEmpty) {
        _repo.markSendFailed(messageId: message.id, error: kSourceMissingError);
        return null;
      }
      // ★ 0.2.52 — **the file has to be there before we dial.**
      //
      // A queued message survives the process (`pending` is deliberately kept
      // across a restart), and its source is a copy in `cache/lanlink-picked/`.
      // Until 0.2.52 the launch sweep deleted that copy unconditionally, so this
      // loop was the first place to notice — and it noticed nothing: it only
      // checked that `localPath` was *non-empty*, which it always is. The result
      // was a dial that could only fail, an error nobody could read, and a
      // message the user had to cancel and re-send.
      //
      // A throwing `exists` counts as **present**: the port is asked once per
      // file on a path that used to work, and refusing to send because a host
      // could not answer would be worse than the dial it prevents (the same
      // judgement `SourceAvailability.probeFiles` makes).
      bool present;
      try {
        present = await _platform.exists(path);
      } on Object {
        present = true;
      }
      if (!present) {
        _log('outbox: ${message.id} 源文件已不在，立即失败：$path');
        _repo.markSendFailed(messageId: message.id, error: kSourceMissingError);
        return null;
      }
      // The **stored** id, never a fresh one: it is the wire `fileId` the
      // receiver de-duplicates on and the key `attachSession` writes the token
      // against (0.2.40 — `resend` mints new ids because it creates a new
      // message; a resume is the same message, so the ids must be the same).
      files.add(
        OutgoingFile(
          id: file.id,
          fileName: file.fileName,
          size: file.size,
          sha256: file.sha256 ?? '',
          localPath: path,
          mime: file.mime,
          relativePath: file.relativePath,
        ),
      );
    }
    // A folder message is one `prepare` session with its declared count
    // (0.2.38): resuming without it would deliver N loose files under a bubble
    // that still says 文件夹.
    final String? folderName = message.folderName;
    final FolderRef? folder = folderName == null
        ? null
        : FolderRef(name: folderName, count: message.folderFiles);
    return _orchestrator.resumeQueuedFiles(
      peer: peer,
      messageId: message.id,
      files: files,
      folder: folder,
    );
  }

  /// Whether [messageId] is still `pending` right now.
  ///
  /// The repository port has no single-row read, and the in-memory
  /// [ChatMessage] this pass started from may be stale by now, so the answer is
  /// taken from the store. Data volumes are personal-tool sized (the port's own
  /// doc says so), and this only runs on the outcome paths that carry an error.
  bool _isStillPending(String messageId) {
    for (final ChatMessage message
        in _repo.messagesByStatus(<MessageStatus>{MessageStatus.pending})) {
      if (message.id == messageId) {
        return true;
      }
    }
    return false;
  }

  /// One line of on-device diagnostics, or silence when no sink was wired.
  ///
  /// The pump is the answer to "why is this still 排队中", so it has to be able
  /// to say what it did: which message, which outcome, which peer. Wrapped so a
  /// throwing sink can never break a drain — the same rule every logging
  /// callback in this app follows.
  void _log(String message) {
    final void Function(String message)? sink = _onLog;
    if (sink == null) {
      return;
    }
    try {
      sink(message);
    } on Object {
      // Diagnostics never break a caller.
    }
  }

  /// [outcome]'s shape as one word, for the log line above.
  ///
  /// Plain `if`s rather than a pattern switch: the four categories are the
  /// class's own named constructors, and spelling them out keeps
  /// "`queued` is not `failed`" visible at the place that has to tell them apart.
  String _outcomeName(SendOutcome outcome) {
    if (outcome.queued) {
      return 'queued';
    }
    if (outcome.rejected) {
      return 'rejected(${outcome.error ?? '-'})';
    }
    if (outcome.canceled) {
      return 'canceled';
    }
    if (outcome.delivered) {
      return 'delivered';
    }
    return 'failed(${outcome.error ?? '-'})';
  }

  /// Releases the discovery subscription, the repository subscription, the
  /// lifecycle observer and the fallback scan.
  ///
  /// Every resource this class creates is released here, in particular the
  /// scan: a timer that outlived its pump would keep a disposed controller alive
  /// and (in a widget test) show up as "a Timer is still pending".
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _cancelScanTimer();
    _sub?.cancel();
    _sub = null;
    _repoSub?.cancel();
    _repoSub = null;
    final _OutboxLifecycleObserver? observer = _observer;
    _observer = null;
    if (observer != null) {
      WidgetsBinding.instance.removeObserver(observer);
    }
    _draining.clear();
    _retryAfter.clear();
  }
}

/// Forwards "the app is in the foreground again" to the pump (trigger ②).
///
/// Its own class, rather than `implements WidgetsBindingObserver` on
/// [OutboxPump], for the reason `conversation_controller.dart` documents: a
/// plain controller that also subscribes itself to a binding is harder to drive
/// from a test and impossible to un-wire. This way the observer exists exactly
/// as long as [OutboxPump.start]'s subscription does.
class _OutboxLifecycleObserver with WidgetsBindingObserver {
  _OutboxLifecycleObserver({required this.onResumed});

  final void Function() onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      onResumed();
    }
  }
}
