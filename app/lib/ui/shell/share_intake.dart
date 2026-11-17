/// The inbound-share intake (0.2.18): "把分享进来的文件接住".
///
/// It sits between the platform port ([ShareInboxPort], implemented on Android
/// by `data/real/android_share_inbox.dart`) and the shell, and it owns the one
/// rule the feature must never break:
///
/// > **绝不自动发送。** A shared file is placed in a **draft** and the user
/// > presses 发送. Sharing from the gallery is an explicit "I want to send this
/// > somewhere", but *where* is a decision the user still has to make — silently
/// > beaming a photo to whatever conversation happened to be open would be a
/// > privacy bug, not a convenience.
///
/// So the flow is:
///
///  1. a share arrives (launch intent, or `onShare` while running);
///  2. its URIs are copied into app storage **by the platform** (streaming);
///  3. a [ShareDraft] is created **with no destination** — always, even when a
///     conversation happens to be open (0.2.62) — and [takeTargetRequest]
///     raises a one-shot signal so the shell asks 「把 N 个文件发给谁」;
///  4. the user answers: picking a device in that sheet (or tapping a device in
///     the conversation list) binds the draft via [attachTo]; 取消 binds
///     nothing and leaves the draft waiting in the list;
///  5. the thread shows the draft above the composer, and only a tap on 发送
///     calls the existing `ConversationController.sendPaths`;
///  6. if that answer was wrong, the row's 「改发到…」 moves the **same** draft to
///     another device ([retarget], 0.2.63) — still without sending anything.
///
/// **0.2.62 — "先问发给谁".** Through 0.2.61 step 3 bound the draft to
/// `shell.selectedConversationId` whenever *anything* was open. A share then
/// landed in whatever thread was on screen, with 「待发送」 sitting in a
/// conversation the user never picked — and it could not be moved afterwards,
/// because `attachTo` only ever binds an unattached draft. Dropping that
/// auto-attach is the whole of this release: the destination is now always a
/// question, never an inference.
///
/// **0.2.63 — 「改发到…」.** 0.2.62 made the destination a question, but an
/// answer, once given, was final: the row offered only 发送 and 取消, so a user
/// who picked the wrong device had to cancel and share the file all over again
/// (the copies survive a 取消, but the share intent is gone). [retarget] is the
/// way back, and it is **not** a loosening of the bind-once rule: [attachTo]
/// stays bind-once for *inferred* destinations, while [retarget] is only ever
/// reached from a button drawn on the row that already names its target —
/// an explicit "move **this** draft **there**". Nothing is re-copied and
/// nothing is sent: the draft is the same path list with a different
/// `conversationId`.
///
/// **Layering (design §9.6):** imports `package:flutter/foundation` and this
/// package's `domain/**` + sibling `ui/shell/**` only — never `dart:io` /
/// `dart:ffi`. The `dart:io` part of the feature lives behind the port.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/picked_cache.dart';
import '../../domain/share_inbox.dart';
import 'shell_controller.dart';
import 'shell_module.dart';

/// Files that arrived from another app and are **waiting for the user to send**.
///
/// [conversationId] is `null` while the draft has no destination yet. Since
/// 0.2.62 a draft is **always** created that way — the user chooses the target
/// first (see `ShareIntake.takeTargetRequest`) and [ShareIntake.attachTo] binds
/// it. The value is therefore not `const`-fixed.
@immutable
class ShareDraft {
  /// Creates a draft.
  const ShareDraft({required this.paths, this.conversationId});

  /// Local, app-private paths — already copied, ready to hash and send.
  final List<String> paths;

  /// The conversation this draft is bound to, or `null` when unattached.
  final String? conversationId;

  /// How many files are waiting.
  int get count => paths.length;

  /// Whether there is nothing to send.
  bool get isEmpty => paths.isEmpty;

  /// The same draft, bound to [conversationId].
  ShareDraft attachTo(String conversationId) =>
      ShareDraft(paths: paths, conversationId: conversationId);

  /// The same draft with [more] paths appended (**order kept**: existing first).
  ///
  /// Appending rather than replacing matters when the user shares twice in a
  /// row: the second share must not silently discard the first, unsent draft.
  /// The destination is carried over untouched, so a draft the user has already
  /// pointed at a device does not lose it (nor ask again) on the second share.
  ShareDraft plus(List<String> more) => ShareDraft(
        paths: <String>[...paths, ...more],
        conversationId: conversationId,
      );

  @override
  String toString() => 'ShareDraft(${paths.length} file(s), '
      'conversation=$conversationId)';
}

/// Turns inbound shares into an unsent [ShareDraft] plus a short notice.
class ShareIntake extends ChangeNotifier {
  /// Creates the intake.
  ///
  /// [onLog] receives one line per event: received share, per-URI import
  /// failure, empty import. A failure is **never** silent — it is logged *and*
  /// shown in the notice text.
  ///
  /// [pickedCache] deletes the temporary copies behind a **discarded** draft
  /// (0.2.23). Optional and defaulting to [NoopPickedCache] so the existing
  /// tests and the Web preview keep compiling; production passes the real one
  /// from `AppDeps`.
  ShareIntake({
    required ShareInboxPort inbox,
    required ShellController shell,
    void Function(String message)? onLog,
    PickedCachePort pickedCache = const NoopPickedCache(),
  })  : _inbox = inbox,
        _shell = shell,
        _onLog = onLog,
        _pickedCache = pickedCache;

  final ShareInboxPort _inbox;
  final ShellController _shell;
  final void Function(String message)? _onLog;
  final PickedCachePort _pickedCache;

  StreamSubscription<SharedPayload>? _sub;
  ShareDraft? _draft;
  String? _notice;
  bool _importing = false;
  bool _started = false;
  bool _disposed = false;

  /// A "choose the destination for the new draft" request the shell has not
  /// taken yet (0.2.62).
  ///
  /// **One-shot on purpose.** [needsTarget] stays true for as long as the draft
  /// is unattached, and the intake notifies several times in that window (the
  /// import finishing, a failed URI being logged, …). A shell that reacted to
  /// the *state* would stack a sheet per notification; reacting to the
  /// *request* shows exactly one.
  bool _targetRequested = false;

  /// `true` while [ShareIntake] itself is moving the shell's selection.
  ///
  /// [_onShellChanged] binds an unattached draft to whatever conversation the
  /// shell selects — but the module switch in [_import] notifies the shell too,
  /// and a draft that just arrived must **not** be bound by our own call. That
  /// is what keeps [_import]'s "always unattached" promise true even when a
  /// conversation is already open.
  bool _suppressAutoBind = false;

  /// Whether this platform can receive shares at all.
  bool get isSupported => _inbox.isSupported;

  /// Whether a share's files are being copied into app storage right now.
  ///
  /// Exposed so the shell can say "正在准备分享的文件…" instead of leaving a
  /// several-hundred-megabyte copy invisible.
  bool get importing => _importing;

  /// The draft waiting to be sent, or `null` when there is none.
  ShareDraft? get draft => _draft;

  /// Whether the draft still has **no destination** — the user has to say who.
  ///
  /// This is the state 0.2.62 is about: a share never resolves its own
  /// recipient, so a freshly received draft always answers `true` here. It is
  /// observable on purpose — the widget tests assert on it (directly through the
  /// intake, and end-to-end through the chooser the shell shows for it).
  bool get needsTarget => _draft != null && _draft!.conversationId == null;

  /// The draft, but only when it is bound to [conversationId].
  ///
  /// The thread must never show another conversation's draft: selecting a
  /// different device would otherwise offer to send files that were staged for
  /// someone else.
  ShareDraft? draftFor(String? conversationId) =>
      (_draft != null && _draft!.conversationId == conversationId)
          ? _draft
          : null;

  /// Starts listening: the launch share first, then every later one.
  ///
  /// Idempotent, and a no-op on platforms without the capability (Web, desktop,
  /// tests) — so `ShellPage` can call it unconditionally.
  Future<void> start() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    if (!_inbox.isSupported) {
      return;
    }
    _shell.addListener(_onShellChanged);
    // Subscribe BEFORE asking for the initial share: a share that arrives while
    // the request is in flight must be delivered, and the host guarantees it goes
    // down exactly one of the two paths (see `MainActivity.handleShareIntent`).
    _sub = _inbox.incoming.listen((SharedPayload payload) {
      unawaited(_import(payload));
    });
    final SharedPayload? initial = await _inbox.takeInitial();
    if (initial != null && !_disposed) {
      await _import(initial);
    }
  }

  /// Takes the pending notice, clearing it (`null` when there is none).
  ///
  /// Take-and-clear on purpose: the shell shows it in a `SnackBar`, and a notice
  /// that survives a rebuild would re-appear on every subsequent frame.
  String? takeNotice() {
    final String? notice = _notice;
    _notice = null;
    return notice;
  }

  /// Takes the **"ask the user who this goes to"** request, clearing it
  /// (0.2.62).
  ///
  /// `true` exactly once per unattached draft: the shell answers it by showing
  /// the target picker. Cancelling the picker does not re-raise it — the draft
  /// simply stays unattached ([needsTarget] is still `true`) and the existing
  /// "tap a device row" path binds it instead.
  bool takeTargetRequest() {
    final bool requested = _targetRequested;
    _targetRequested = false;
    return requested;
  }

  /// Binds the waiting draft to [conversationId] — the user answered 「发给谁」.
  ///
  /// Bind-once, deliberately: a draft that already has a destination is not
  /// re-pointed, so files staged for one device can never be silently moved to
  /// another (that immovability was a complaint about 0.2.61's behaviour, but
  /// only because the *initial* binding was guessed; now it is chosen).
  ///
  /// A **user-initiated** move is [retarget], which is the only door that may
  /// cross this rule.
  void attachTo(String conversationId) {
    final ShareDraft? current = _draft;
    if (current == null || current.conversationId != null) {
      return;
    }
    _draft = current.attachTo(conversationId);
    _targetRequested = false;
    _notify();
  }

  /// Moves the waiting draft to [conversationId] — the user pressed 「改发到…」
  /// on the row (0.2.63).
  ///
  /// **Unconditional, unlike [attachTo].** That asymmetry is the whole point:
  /// [attachTo] answers "who was this meant for?" and must never overwrite an
  /// answer, while this one *is* a second answer to the same question, given by
  /// the user from the row that spelled out the first one. It is an explicit
  /// re-point, not an automatic binding, so it may cross the bind-once rule.
  ///
  /// What it must **not** do:
  ///
  ///  * send anything — the target changed, so the user has to look at the new
  ///    thread and press 发送 there (rule 1 at the top of this file);
  ///  * touch the copies — the paths are the same files, only the destination
  ///    moves, so `PickedCachePort` is not involved at all;
  ///  * re-raise [takeTargetRequest] — that one-shot signal belongs to a *new,
  ///    unattached* draft, and firing it here would pop the chooser again on a
  ///    draft the user has just finished pointing.
  void retarget(String conversationId) {
    final ShareDraft? current = _draft;
    if (current == null) {
      return;
    }
    // Cleared even when the target is unchanged: the chooser has been answered
    // by hand, so nothing may ask again for this draft.
    _targetRequested = false;
    if (current.conversationId == conversationId) {
      return;
    }
    _draft = ShareDraft(paths: current.paths, conversationId: conversationId);
    _notify();
  }

  /// Drops the draft **without sending** (the user pressed 取消) — and frees the
  /// temporary copies behind it (0.2.23).
  ///
  /// This is the one place the copies are certainly not needed any more: the
  /// user said no, so nobody will send them. They are ours to delete, and before
  /// 0.2.23 nothing did — a 1 GB video shared into lanlink and then cancelled
  /// stayed in the app cache forever. `PickedCachePort.discard` deletes only
  /// paths under the app's own `<temp>/lanlink-picked/`, so a share whose URI is
  /// still the other app's file is unaffected (it was never ours to begin with).
  void discardDraft() {
    final ShareDraft? dropped = _draft;
    if (dropped == null) {
      return;
    }
    _draft = null;
    _targetRequested = false;
    _notify();
    unawaited(_pickedCache.discard(dropped.paths));
  }

  /// Marks the draft as sent, so the row disappears.
  ///
  /// **Deliberately does not delete the copies.** Whether they may go depends on
  /// what the send actually did, and that answer lives in
  /// `ConversationController` (`SendOutcome.delivered`): a 发送 that failed or
  /// was queued still needs the local file for 重新发送, and deleting it here
  /// would silently break the retry. `consumeDraft` therefore only clears the
  /// row — the same split the 取消 path would need if it ever grew an undo.
  void consumeDraft() {
    if (_draft == null) {
      return;
    }
    _draft = null;
    _targetRequested = false;
    _notify();
  }

  // ── internals ────────────────────────────────────────────────────────────

  /// Copies [payload] into app storage and turns it into a draft + a notice.
  Future<void> _import(SharedPayload payload) async {
    if (_disposed) {
      return;
    }
    _importing = true;
    _notify();
    ShareImport imported;
    try {
      imported = await _inbox.materialize(payload);
    } on Object catch (error) {
      // The port is supposed to answer instead of throwing; if it ever does
      // throw, the user still gets a report rather than a silent no-op.
      imported = ShareImport(
        paths: const <String>[],
        failures: <ShareImportFailure>[
          for (final String uri in payload.uris)
            ShareImportFailure(uri: uri, reason: '$error'),
        ],
      );
    }
    if (_disposed) {
      return;
    }
    _importing = false;
    for (final ShareImportFailure failure in imported.failures) {
      _log('导入失败 ${failure.uri}：${failure.reason}');
    }
    if (!imported.hasFiles) {
      _notice = imported.failures.isEmpty
          ? '分享里没有可接收的文件'
          : '没能接收分享的文件（${imported.failures.length} 个失败）';
      _notify();
      return;
    }

    final ShareDraft? existing = _draft;
    // ★ 0.2.62 — the one line this release exists for. `ShareDraft` is built
    // **without** a `conversationId`: the destination is no longer read off
    // `_shell.selectedConversationId`, so a share cannot land in whichever
    // thread happened to be open. `_suppressAutoBind` keeps the listener below
    // from filling it in behind our back while we switch the module.
    _draft = existing != null
        ? existing.plus(imported.paths)
        : ShareDraft(paths: imported.paths);
    // A draft the user already pointed at a device keeps that device (the
    // `plus` above carries it) — the question was answered once and is not asked
    // again for the same, still-unsent draft.
    final bool bound = _draft!.conversationId != null;
    _targetRequested = !bound;

    if (!bound) {
      // Show the conversation list under the chooser: 取消 must leave the user
      // where the choice can still be made (a device row tap binds the draft,
      // see [_onShellChanged]), and nothing may jump into a conversation first.
      _suppressAutoBind = true;
      try {
        _shell.selectModule(ShellModule.conversations);
        // On a phone the detail pane is the visible half; a share must land the
        // user on the **list** — that is where the choice is — not inside
        // whichever thread happened to be open.
        _shell.closeDetail();
      } finally {
        _suppressAutoBind = false;
      }
    }
    final int failed = imported.failures.length;
    final String suffix = failed == 0 ? '' : '（$failed 个失败）';
    _notice = bound
        ? '已收到 ${imported.paths.length} 个文件$suffix，点「发送」发出去'
        : '已收到 ${imported.paths.length} 个文件$suffix，选择要发给谁';
    _log('收到分享 ${imported.paths.length} 个文件，失败 $failed');
    _notify();
  }

  /// Binds an unattached draft to the conversation the user just selected.
  ///
  /// This is the **second** half of "先问发给谁": if the chooser was cancelled,
  /// tapping a device in the list is an equally explicit answer, so it binds.
  /// It never fires for a draft our own module switch produced
  /// ([_suppressAutoBind]) — that would resurrect the 0.2.61 bug.
  void _onShellChanged() {
    if (_disposed || _suppressAutoBind) {
      return;
    }
    final String? id = _shell.selectedConversationId;
    final ShareDraft? current = _draft;
    if (current == null || current.conversationId != null || id == null) {
      return;
    }
    _draft = current.attachTo(id);
    _targetRequested = false;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _log(String message) {
    _onLog?.call('SHARE $message');
  }

  @override
  void dispose() {
    _disposed = true;
    if (_started && _inbox.isSupported) {
      _shell.removeListener(_onShellChanged);
    }
    unawaited(_sub?.cancel());
    _sub = null;
    super.dispose();
  }
}
