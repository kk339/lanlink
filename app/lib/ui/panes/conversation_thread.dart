/// The right pane's `消息` tab (design §1.4 — rewritten from
/// `conversation_page`'s timeline + composer).
///
/// A timeline of [MessageBubble]s with **local-day separators** and the bottom
/// composer: a **disabled** text field (there is no text-channel or write path
/// yet, PRD §3.4-⑧), a single `[附件]` entry (the desktop picker is one
/// unrestricted dialog — PRD §1.4) and a **drawn-but-disabled** send button
/// whose tooltip says `文字消息 V1 不做` (PRD §9-Q3: honest, never a coloured
/// button that does nothing).
///
/// The controller is owned by `DetailPane` (design §2.5) and handed down; this
/// widget only reads it. It owns the A2-18 "is the outgoing source file gone?"
/// probe, which is why it is stateful.
///
/// **Composer drafts (0.2.27).** The composer's text is *not* this State's
/// private property any more: it is saved per conversation, on every keystroke,
/// into the process-wide draft store owned by [ConversationController] (see
/// `domain/draft_store.dart`), and filled back in here when the thread mounts
/// ([_restoreDraft]). That is what keeps "type something, switch conversation,
/// come back" from losing the text — the alternative (holding it in this
/// `State`) is exactly what lost it, because `DetailPane` re-keys the thread per
/// conversation.
///
/// It is also the thread's **lifecycle observer** (0.2.15): a return to the
/// foreground goes through [ConversationController.onAppResumed], so the progress
/// bar repaints the current `bytes_done` on the first frame after the return
/// instead of waiting for — or forever missing — the next 1 Hz tick. The
/// controller cannot do this itself: it is a plain `ChangeNotifier` that must not
/// touch `WidgetsBinding`.
///
/// **Layering (design §9.6):** imports only `package:flutter/**`, this package's
/// `domain/**`, `controllers/**` and sibling `ui/**` — never `dart:io` /
/// `dart:ffi` / `lanlink_core` / `lanlink_store`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
// `SelectedContent` — the payload `SelectionArea.onSelectionChanged` hands back
// (0.2.36). It is declared in `rendering/selection.dart`, which `material.dart`
// does not re-export, so the narrow import comes first.
// `RenderAbstractViewport` / `RevealedOffset` (0.2.59) come from the same library
// and are what turns "this built row is over there" into a scroll offset — the
// call `Scrollable.ensureVisible` makes internally, reused so the reveal's own
// arithmetic agrees with it to the pixel.
import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, RevealedOffset, SelectedContent;
// `HardwareKeyboard` / `KeyEvent` / `LogicalKeyboardKey` for the composer's
// desktop Enter rule (0.2.35). `material.dart` does not re-export these.
import 'package:flutter/services.dart';

import '../../controllers/conversation_controller.dart';
import '../../domain/async_value.dart';
import '../../domain/clock.dart';
import '../../domain/drag_out.dart';
import '../../domain/folder_send.dart';
import '../../domain/models.dart';
import '../../domain/picked_cache.dart';
import '../../domain/platform_ports.dart';
import '../../domain/selectors.dart';
import '../../domain/source_availability.dart';
import '../../domain/text_limits.dart';
import '../../domain/transfer_service.dart';
import '../format.dart';
import '../notices.dart';
import '../scope.dart';
import '../theme.dart';
import '../widgets/attachment_menu.dart';
import '../widgets/forward_target_picker.dart';
import '../widgets/device_row.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_banner.dart';
import '../widgets/fade_in.dart';
import '../widgets/loading_state.dart';
import '../widgets/message_bubble.dart';
import '../widgets/missing_files_note.dart';
import '../widgets/open_local_path.dart';
import 'folder_browse_page.dart';

/// Height of the 待发送 row's 「改发到…」 button (0.2.63).
///
/// Deliberately smaller than a [TextButton]'s 48dp tap box: it is a secondary
/// escape hatch next to the two primary actions on the line above, and giving it
/// a full-height tap target would make the row read as three equal buttons **and**
/// grow the strip by another 16dp. 32dp is the measured painted height (the
/// `minimumSize` below, with `shrinkWrap` so the default padded tap box does not
/// inflate the layout); the button is 70dp wide, so the target is 70×32.
/// A named constant rather than a literal so the geometry test can assert
/// against the same number the widget uses.
const double kShareDraftRetargetHeight = 32;

/// Font size of 「改发到…」 — 12sp, a notch above `labelSmall`'s 11: the row's
/// own text is `bodySmall` (12sp), so the button reads as the same size class as
/// the sentence it belongs to instead of shrinking below it.
const double kShareDraftRetargetFontSize = 12;

/// One conversation's message timeline plus its composer.
class ConversationThread extends StatefulWidget {
  /// Creates the thread.
  ///
  /// [peer] drives the composer's enabled state ([PeerDevice.canSend]) and the
  /// send / resend calls.
  const ConversationThread({
    super.key,
    required this.controller,
    required this.peer,
    this.sharedPaths = const <String>[],
    this.onSharedSent,
    this.onSharedDiscarded,
    this.onRetargetDraft,
    this.clock,
  });

  /// The single-conversation controller (owned by `DetailPane`).
  final ConversationController controller;

  /// The counterparty of the conversation.
  final PeerDevice peer;

  /// Files another app shared **into** lanlink, staged for this conversation and
  /// still **unsent** (0.2.18). Empty in the normal case.
  ///
  /// The thread never sends them on its own: sharing a photo from the gallery is
  /// "I want to send this", not "send this to whoever is open" — so the files
  /// sit in the 待发送 row until the user presses 发送, which goes through the
  /// existing `ConversationController.sendPaths`.
  final List<String> sharedPaths;

  /// Called once a `sharedPaths` send has been dispatched (clears the draft).
  final VoidCallback? onSharedSent;

  /// Called when the user drops the draft with 取消.
  final VoidCallback? onSharedDiscarded;

  /// Called when the user asks to send the staged draft to **another** device
  /// (0.2.63) — the 「改发到…」 button under the 待发送 row.
  ///
  /// The thread does not know how to ask: who the draft may be moved to is a
  /// device-list question only the shell can answer (it owns the picker and the
  /// selection). So this is a plain callback, and `null` — the default, and what
  /// every test that mounts a thread on its own gets — simply means "this host
  /// has no way to re-point a draft", in which case the button is not drawn at
  /// all rather than drawn dead.
  final VoidCallback? onRetargetDraft;

  /// Where this thread reads "now" from when it has to judge **silence** — the
  /// folder card's 「N 个未收到」 line (0.2.42).
  ///
  /// Injected, and it is the only time source the thread touches, so the 90-second
  /// quiet rule (`kFolderQuietPeriod`) is reproducible: a test pins a [FixedClock]
  /// and asks for "30 秒前" or "200 秒前" instead of waiting.
  ///
  /// `null` (the production default) means **`context.deps.clock`** — the
  /// container's own [Clock], which is `SystemClock` on a device
  /// (`DateTime.now().toUtc()`) and the deterministic `FixedClock` in every test
  /// container. That default is deliberate rather than `DateTime.now` inline:
  /// the app's rule is that controllers and UI never call the system clock
  /// directly (`domain/clock.dart`), and taking it from the container is what
  /// keeps a widget test from becoming a wall-clock-dependent test.
  final Clock? clock;

  @override
  State<ConversationThread> createState() => _ConversationThreadState();
}

class _ConversationThreadState extends State<ConversationThread>
    with WidgetsBindingObserver {
  /// messageId → whether its outgoing source file is gone (A2-18).
  ///
  /// **0.2.48 — one record, one rule, and it is no longer this `State`'s
  /// private opinion.** Until this release the timeline kept *two* fields here:
  /// this map, filled by [_probeSources] (which only ever asked about
  /// `failed` / `canceled` messages, through `canResend`), and a second
  /// `Set<String> _draggedAway` for files a drag-out had moved — because the
  /// next probe would have quietly dropped a `done` row's flag.
  ///
  /// Both are gone. [SourceAvailability] owns the judgement (the same one the
  /// 文件 tab and the 最近文件 page now read), and the flag survives a `State`
  /// rebuild for free: `DetailPane` re-creates this thread on every tab switch
  /// (`ValueKey('messages-$id')`), and the re-created thread simply probes the
  /// disk again — which is where the truth was all along. That is the fix for
  /// the defect where 拖出 a file, switch to the 文件 tab and back, and the row
  /// came back looking normal and un-clickable.
  ///
  /// **0.2.49 — what this object is *not*.** It answers "is the file on disk?",
  /// and that is all it is asked (`anyUnavailable`). Turning that answer into a
  /// warning is a separate judgement, made in `_bubble` from **who removed the
  /// file** (`ConversationController.discardedByUs`) and drawn by the bubble: on
  /// Android a *successful* send deletes its picked cache copy, so the disk answer
  /// for a delivered message is always "gone", and treating that as a loss put a
  /// red broken-link icon and a greyed-out 重新发送 on every file the user had ever
  /// sent.
  final SourceAvailability _sources = SourceAvailability();

  /// Every attachment path this thread has **already** handed to [_sources]
  /// (0.2.50).
  ///
  /// The defect this answers: *多选发送 30–80 个文件给电脑，电脑端明显卡顿*.
  /// [_probeSources] used to re-walk **every message of the conversation** on
  /// **every arrival** — one `filesOf` and one `exists` per attachment per
  /// arriving file — so a batch of N files onto K history messages cost
  /// O(N × (K + N)) disk stats (measured: 455 for 10 arrivals, 2 420 for 40,
  /// **6 440** for 80, over a 40-message thread) plus the same number of
  /// `filesOf` reads and a second `setState` of the whole timeline each time.
  /// That is the 卡顿, and it is quadratic in the batch — not a frame-budget
  /// problem inside Flutter.
  ///
  /// With this cache the same batch costs **K + N** (`10 → 10`, `40 → 40`,
  /// `80 → 80` measured in `test/widget/batch_arrival_cost_test.dart`): the
  /// history is probed once, when the thread appears, and each arriving file
  /// costs exactly one stat for its own path.
  ///
  /// **Why a field on this `State` and not a process-wide singleton.** The rule
  /// this cache holds is "we already asked the disk about this path **from this
  /// thread**", and a shared cache would let one page's answer (or a previous
  /// test's, in the same process) answer for another — the same reason
  /// [SourceAvailability] itself is instantiated per surface and not shared
  /// (see its library doc). It dies with the `State`, which is exactly right:
  /// `DetailPane` re-creates the thread per conversation and per tab switch
  /// (`ValueKey('messages-$id')`), so a fresh visit probes the disk afresh —
  /// the property 0.2.48 relies on for the 拖出 mark.
  final Set<String> _probedPaths = <String>{};

  /// messageId → how many of its attachments [_probeSources] has judged.
  ///
  /// Counted rather than flagged because one message can **grow**: the folder
  /// path writes every arriving file onto the same message id (docs/22 §4.2),
  /// so "this id was seen" alone would silently stop judging a folder after its
  /// first file — new files would keep the default "on disk" answer and a
  /// missing one would stay clickable. See [_unjudgedFiles].
  final Map<String, int> _probedAttachments = <String, int>{};

  /// Whether the thread's first fill has been positioned. The first fill lands
  /// instantly; later arrivals animate (see [_onThreadChanged]).
  bool _didInitialFill = false;

  /// The composer's text (docs/13 §7.3); clearing it after a send is the only
  /// write the widget makes to it. Named `...Controller` (matching
  /// `settings_body.dart`) so it does not collide with the `_composer(...)`
  /// builder method.
  final TextEditingController _composerController = TextEditingController();

  bool _probed = false;

  /// Whether the composer holds non-whitespace text (enables the send button).
  bool _hasText = false;

  /// Whether the composer exceeds [kMaxTextBytes] (shown as a human message).
  bool _overLimit = false;

  /// Set while the OS picker (and, on Android, the streamed cache copy) runs, so
  /// a long wait is never silent.
  bool _preparing = false;

  /// The caption shown while a **folder** is being picked / walked / copied
  /// (0.2.33). `null` during an ordinary file pick, which keeps its own
  /// byte-progress caption. Without this the composer would sit silent for the
  /// seconds Android spends copying a folder's files into the cache — the
  /// "frozen, nothing happened" look this project keeps removing.
  String? _folderNote;

  /// Byte progress of an in-flight pick, or `null` while not preparing.
  FilePickProgress? _pickProgress;

  /// Set once the platform has finished **copying** the picked file.
  ///
  /// `_preparing` spans the whole send — pick, copy, hash (seconds for a big
  /// video) and dispatch — so the "正在准备…" lines must not be tied to it, or
  /// they sit at 100% long after the copy is done and read as a hang.
  bool _copyDone = false;

  /// The last pick/send failure, shown under the composer (never swallowed).
  String? _sendError;

  /// Set while a **text** send is in flight (0.2.48).
  ///
  /// The composer's text field is only cleared **after** the dispatch answers
  /// (see [_sendText]), so for the span of one round trip the field still holds
  /// the text that was just sent: without this flag a second `Enter` — or a
  /// second tap on a button that is still enabled — would send the same sentence
  /// twice. One press, one message.
  bool _sendingText = false;

  StreamSubscription<FilePickProgress>? _pickProgressSub;

  /// Drives the timeline; auto-scrolled to the newest message (M5c §1).
  final ScrollController _scroll = ScrollController();

  /// The last observed keyboard inset, so a *rising* inset (keyboard opening)
  /// scrolls the newest message back into view (M5c §1).
  double _lastViewInset = 0;

  /// The last observed message count, so a NEW message scrolls to the bottom but
  /// a mere status change does not (M5c §1).
  int _lastMessageCount = -1;

  /// The controller's append count **per message**, as this thread last acted on
  /// it (0.2.51).
  ///
  /// The count above is **not** the only thing that can move: the folder path and
  /// (since 0.2.51) the flat batch path append files 2…N to a message that
  /// already exists (`docs/22` §4.2), so the timeline can change while
  /// `messages.length` stays exactly the same. Nothing here needs to *rebuild*
  /// for that — the rows re-read their attachments on every build (`_bubble`
  /// calls `filesOf`), and this listener is not what paints them — but the disk
  /// judgement does: [_probeSources] only ever runs from this method, and without
  /// it an appended attachment is never probed, so a file that is not on disk
  /// keeps the default "available" answer and its row stays clickable while
  /// doing nothing when tapped.
  ///
  /// A map rather than one counter because the growth is per message: a batch
  /// bubble that grew must not make the thread re-walk the other K messages of
  /// the conversation (0.2.50's rule). Only the ids whose count moved are probed,
  /// and only their attachments.
  final Map<String, int> _judgedGrowth = <String, int>{};

  /// The id of the **text** message whose bubble last received a pointer down
  /// (0.2.36) — i.e. the message a right click on a selection is about.
  ///
  /// The selection layer is **one** region above the whole `ListView` (0.2.30),
  /// so `SelectableRegion` knows the selected *text* but not which bubble it came
  /// from. `SelectionArea.contextMenuBuilder` therefore has to be told, and the
  /// only gesture the app may observe here is a raw pointer event: a
  /// [Listener] sits **outside** the gesture arena, so — unlike the
  /// `GestureDetector` that 0.2.27 hung on the card and 0.2.31 had to remove — it
  /// cannot take the right click away from the selection layer
  /// (`desktop_mouse_selection_test.dart` case D keeps asserting exactly that).
  ///
  /// A drag that starts in one bubble and runs into the next records the
  /// **first** one: 「删除消息」 then means "delete the message this selection
  /// started in", which is the bubble the right click landed on.
  String? _selectionMessageId;

  /// Where the last press **anywhere in the timeline** came down, in global
  /// coordinates (0.2.48).
  ///
  /// Recorded by a [Listener] wrapped around the whole timeline, which is the only
  /// place that sees a press landing on **empty space** as well as on a bubble.
  /// [_selectionMessageId] alone was not enough: it is only written when a text
  /// bubble is pressed and is never cleared, so a right click on empty space — or
  /// on a day divider — reused the id of whatever bubble had been pressed last and
  /// opened **that message's** menu. On a desktop that menu's 「删除消息」 really
  /// deleted that message, which is how a right click on nothing became data loss.
  ///
  /// [_pressIsInside] is what closes it: the id is only acted on when this
  /// position fell inside that bubble's box. Recording it above the region (not in
  /// each bubble) is what makes it press-wide rather than per-bubble — the two
  /// listeners both fire for a press inside a bubble, and neither has to know
  /// about the other's ordering.
  Offset? _selectionPointerDown;

  /// The bubble each text message's pointer [Listener] is keyed with, so
  /// [_pressIsInside] can ask the layout where that bubble is.
  ///
  /// Only text bubbles are registered (a file bubble has its own menu), and only
  /// while they are built — a row that is scrolled out of the lazy list has no
  /// `RenderObject`, and a right click cannot reach it either.
  final Map<String, GlobalKey> _selectionBoxes = <String, GlobalKey>{};

  /// The plain text of the current timeline selection, or `''` when there is
  /// none (0.2.36).
  ///
  /// Kept because a right click with **nothing** selected must not offer
  /// 「删除消息」: on Windows a right click that lands outside the selection
  /// collapses it (`SelectableRegion._handleRightClickDown`), and Flutter's own
  /// toolbar then stops offering 复制 for the same reason. One rule — "a
  /// selection exists" — decides both, so the menu can never promise a delete
  /// for a range the user does not have.
  String _selectionText = '';

  // ── 「转到消息」: scroll one message into view (0.2.59) ────────────────────

  /// How many rounds the reveal below may spend looking for its row.
  ///
  /// Eight because the two estimators it has are each worth one attempt per
  /// frame: the proportional guess gets the row **built**, the neighbour
  /// correction then gets it **centred**. Bounded on purpose — a reveal must end
  /// as a notice, never as a loop (`_scrollToBottom` is bounded for the same
  /// reason, at five).
  static const int _kRevealAttempts = 8;

  /// The message id the thread is currently scrolling to, or `null` (0.2.59).
  ///
  /// Non-null means "a reveal owns the viewport": [_scheduleScrollToBottom] does
  /// nothing while it is set, which is what keeps an arriving message from
  /// dragging the viewport to the bottom and undoing the gesture the user just
  /// made. Cleared the moment the reveal finishes **or gives up**, so the
  /// ordinary "a new message scrolls into view" behaviour is never changed, only
  /// suspended for the length of one reveal.
  String? _revealingId;

  /// Bumped by every new request, so a superseded reveal stops quietly (0.2.59).
  ///
  /// Without it, a request arriving while another is mid-flight would leave two
  /// loops fighting over one `ScrollController`, and the earlier one would clear
  /// [_revealingId] on its way out — re-enabling auto-scroll in the middle of the
  /// newer reveal.
  int _revealGeneration = 0;

  /// messageId → that message's index in the timeline's `children` (0.2.59).
  ///
  /// ★ **Built in the same loop that builds the children** ([_timeline]), never
  /// by a second function walking the same rules again. A message's position in
  /// `children` is not the message's index: every day boundary inserts a
  /// separator and every ≥ 5-minute gap inserts an `HH:mm` label
  /// (`docs/19` §9-B), so the two numbers drift apart the moment a conversation
  /// spans a day — and a re-implementation of those rules would eventually
  /// disagree with the list it is describing.
  final Map<String, int> _childIndexOf = <String, int>{};

  /// How many children the last assembled timeline had (0.2.59) — the
  /// denominator of the first, purely proportional estimate.
  int _timelineChildCount = 0;

  /// Whether the last build actually assembled a timeline (0.2.59).
  ///
  /// The difference between "this id is not in the conversation" (a notice worth
  /// showing) and "the history is still loading / the thread is empty" (nothing
  /// to say) — see [_revealMessage].
  bool _timelineAssembled = false;

  /// messageId → the `GlobalKey` on that message's row (0.2.59).
  ///
  /// Needed because `Scrollable.ensureVisible` takes a `BuildContext`, and a row
  /// that is scrolled out of view **has none**: `ListView(children: ...)` inflates
  /// lazily, so the row has to be reached by dead reckoning first and only then
  /// centred properly. Same shape — and same limitation — as [_selectionBoxes]:
  /// only rows that are built can be asked about, which is exactly what the
  /// reveal loop tests for.
  ///
  /// Entries for ids that are no longer in the conversation are pruned on every
  /// build, so the map stays the size of the conversation.
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    // ★ Before the listener is attached (0.2.27): restoring a draft is a plain
    // field assignment, not an "the user typed" event — going through
    // `_onComposerChanged` here would `setState` during the very build that
    // mounts this State. [_restoreDraft] computes the derived flags itself and
    // the first `build` reads them straight after.
    _restoreDraft();
    _composerController.addListener(_onComposerChanged);
    widget.controller.addListener(_onThreadChanged);
    // The thread can be mounted onto a controller that is **already** carrying a
    // live transfer — switching back from the 文件 tab re-creates this State, and
    // `DetailPane` hands the same controller over; or the conversation was just
    // loaded while a big upload was running. Without this the bar would sit on
    // whatever `load()` read and never move again (0.2.15, the "进度条像卡住"
    // report). Silent — the thread builds from scratch right after this anyway.
    widget.controller.syncProgressTicker();
    // Returning to the foreground must repaint the progress itself: while the app
    // is paused the engine schedules no frames and the OS may defer the 1 Hz
    // ticker, so no repaint is guaranteed to follow the return (0.2.15).
    WidgetsBinding.instance.addObserver(this);
    // ★ 0.2.59 — **the request may predate this widget.** 「转到消息」 is picked on
    // the 文件 tab, which destroys the thread; `DetailPane` builds a fresh one when
    // the user comes back, and the request has been waiting on the controller the
    // whole time (see `ConversationController.pendingRevealId`). One frame is
    // enough: the timeline's children — and therefore the row keys and the index
    // this scroll needs — only exist after the first build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumeRevealRequest());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only `resumed` matters: it is the moment the user can see the bar again,
    // and the moment the engine starts drawing frames again.
    if (state != AppLifecycleState.resumed || !mounted) {
      return;
    }
    widget.controller.onAppResumed();
  }

  /// Keeps the subscriptions on the **current** controller.
  ///
  /// `DetailPane` keys this widget per conversation, so a controller is never
  /// swapped under a live `State` — but if a future caller ever did, the old
  /// listener would keep a dead controller alive and the bar would never move
  /// again (the 0.2.15 defect class). Cheaper to guard than to rediscover.
  @override
  void didUpdateWidget(ConversationThread oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) {
      return;
    }
    oldWidget.controller.removeListener(_onThreadChanged);
    widget.controller.addListener(_onThreadChanged);
    widget.controller.syncProgressTicker();
    // A different controller means a different conversation (0.2.27): the
    // composer must answer with **that** conversation's draft. Detached first so
    // the swap does not look like a keystroke (and does not `setState` mid-build).
    _composerController.removeListener(_onComposerChanged);
    _restoreDraft();
    _composerController.addListener(_onComposerChanged);
    // 0.2.50: the probe cache is about **that** conversation's disk answers.
    // Message ids are globally unique, so nothing here could be *wrong*, but
    // keeping it would be dead weight for the life of the app — and `_probed`
    // would keep the new conversation from being probed at all. Cleared and
    // re-probed: a fresh conversation is a fresh set of paths to judge.
    _probedPaths.clear();
    _probedAttachments.clear();
    // …and the growth ledger belongs to the old controller's events (0.2.51).
    // The new conversation starts with an empty map, so clearing keeps the two in
    // step instead of leaving counts that no later event will ever match.
    _judgedGrowth.clear();
    _probed = false;
    unawaited(_probeSources());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onThreadChanged);
    _scroll.dispose();
    unawaited(_pickProgressSub?.cancel());
    _composerController
      ..removeListener(_onComposerChanged)
      ..dispose();
    super.dispose();
  }

  /// A message arrived / was sent (the list length changed): keep the newest in
  /// view. A pure status change does not move the list (the user may be reading).
  ///
  /// 0.2.48 — a **new** message also means new attachment paths to judge, and the
  /// first fill can arrive after `didChangeDependencies` ran (the thread mounts
  /// while `load()` is still reading): without the probe below, a conversation
  /// opened during that window would never have its sources checked. The probe is
  /// tied to the *count* and not to every notification on purpose — the progress
  /// ticker notifies once a second, and a disk stat per attachment per tick is a
  /// cost the timeline does not need.
  void _onThreadChanged() {
    // ★ 0.2.59 — `requestReveal` notifies, so this is the third place a reveal can
    // come from (with [initState]'s first frame and [didChangeDependencies]).
    // Taken **before** the count branch below, because the same notification may
    // also be a new message: the reveal must be in flight before that branch
    // decides whether to scroll.
    _consumeRevealRequest();
    final int count = widget.controller.messages.valueOrNull?.length ?? 0;
    if (count != _lastMessageCount) {
      _lastMessageCount = count;
      // The count branch probes everything unseen, so the growth counts are
      // current from here on: a later append is the only thing that may move them
      // again.
      _judgedGrowth.addAll(widget.controller.grownMessages);
      unawaited(_probeSources());
      // ★ The FIRST fill is not "a new message arrived" — it is the thread
      // appearing. Animating that is what the user saw as "只要打开会话就迅速下滑到
      // 最底部 … 每次都是这样": land on the newest **instantly**, and animate only for
      // messages that arrive afterwards (where the motion is useful).
      final bool firstFill = !_didInitialFill && count > 0;
      _didInitialFill = true;
      _scheduleScrollToBottom(animate: !firstFill);
      return;
    }
    // 0.2.51 — **the same message, one more attachment.** A folder's files 2…N
    // (and, since 0.2.51, a flat batch's) arrive on the id file 1 created, so the
    // branch above cannot fire: nothing is added to the list, and before this the
    // timeline took no action at all. It does not have to scroll (the message is
    // already on screen) and it does not have to repaint (the bubble re-reads
    // `filesOf` whenever it builds, and the controller notified); what it must do
    // is judge the new path — see [_probeAppended].
    //
    // Which messages grew comes from the controller, which learns it from the
    // `MessageFilesAppended` event: **one rule for a folder and for a batch**,
    // because the growth is the event, not `isFolder`. [_unjudgedFiles] keeps its
    // older "declared > judged" folder heuristic; it is a fallback for a message
    // that may still be arriving without this thread having seen an event (it is
    // mounted mid-batch, or re-mounted on a message that grew while it was gone).
    // The two cannot double-probe: [_probedPaths] is a set of paths.
    final List<String> grew = <String>[
      for (final MapEntry<String, int> entry
          in widget.controller.grownMessages.entries)
        if (_judgedGrowth[entry.key] != entry.value) entry.key,
    ];
    if (grew.isEmpty) {
      return;
    }
    _judgedGrowth.addAll(widget.controller.grownMessages);
    unawaited(_probeAppended(grew));
  }

  /// Judges the attachments of the messages that just grew, and **only** those
  /// (0.2.51).
  ///
  /// The targeted counterpart of [_probeSources]: that one answers "what has never
  /// been looked at?" for the whole visible history, which is the right question
  /// when the thread appears and the wrong one for an append — there, the answer
  /// is known (`[messageIds]`), and walking the conversation again is exactly the
  /// O(K) work per arrival 0.2.50 removed.
  ///
  /// It reads each grown message's attachments, records how many have been judged
  /// (so [_unjudgedFiles] does not re-do it) and probes the paths it has not asked
  /// about before — one `filesOf` plus one `exists` for the file that arrived.
  Future<void> _probeAppended(List<String> messageIds) async {
    final Set<String> wanted = messageIds.toSet();
    final PlatformPorts platform = context.deps.platform;
    final List<ChatMessage> messages =
        widget.controller.messages.valueOrNull ?? const <ChatMessage>[];
    final List<FileAttachment> fresh = <FileAttachment>[];
    for (final ChatMessage message in messages) {
      if (!wanted.contains(message.id)) {
        continue;
      }
      final List<FileAttachment> files = widget.controller.filesOf(message.id);
      _probedAttachments[message.id] = files.length;
      for (final FileAttachment file in files) {
        final String? path = file.localPath;
        if (path == null || path.isEmpty) {
          continue;
        }
        if (_probedPaths.add(path)) {
          fresh.add(file);
        }
      }
    }
    if (fresh.isEmpty) {
      return;
    }
    await _sources.probeFiles(fresh, platform);
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  /// Brings the newest message into view (M5c §1), after the next frame.
  ///
  /// A lazy list's `maxScrollExtent` is an **estimate** that grows as more rows
  /// lay out, so a single scroll stops short of the true end — step to it over a
  /// bounded number of frames. Each `animateTo` is short and bounded, so
  /// `pumpAndSettle` still settles (never an open-ended loop).
  void _scheduleScrollToBottom({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // ★ 0.2.59 — **the one place that suspends auto-scroll.** A reveal is the
      // user's own destination; an arrival nudging the viewport towards the bottom
      // would drag him away from the message he asked for and make 「转到消息」 look
      // broken. Checked here (not only at the call sites) so the `endOfFrame` the
      // reveal spends animating cannot be followed by a callback queued a frame
      // earlier, and checked only while a reveal is in flight — the ordinary
      // "a new message scrolls into view" behaviour is untouched at all other
      // times, including immediately after a reveal ends.
      if (_revealingId != null) {
        return;
      }
      unawaited(_scrollToBottom(animate: animate));
    });
  }

  Future<void> _scrollToBottom({required bool animate}) async {
    for (int attempt = 0; attempt < 5; attempt++) {
      // A reveal that started while this loop was waiting for the next frame owns
      // the viewport from that moment on (0.2.59); the remaining attempts would
      // otherwise spend themselves dragging the list back to the bottom.
      if (_revealingId != null) {
        return;
      }
      if (!mounted || !_scroll.hasClients) {
        return;
      }
      final double target = _scroll.position.maxScrollExtent;
      if ((_scroll.offset - target).abs() < 0.5) {
        return;
      }
      if (animate) {
        await _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      } else {
        // The first fill: no motion at all.
        _scroll.jumpTo(target);
      }
      if (!mounted || !_scroll.hasClients) {
        return;
      }
      // Let the list lay out the rows the scroll just revealed before re-reading
      // the (now larger) extent.
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  // ── 「转到消息」 — scroll ONE message to the middle of the viewport (0.2.59) ──

  /// Takes a pending 「滚到这条消息」 request and starts acting on it.
  ///
  /// **The single entry point.** Three moments can find a request waiting, and
  /// all three call this instead of each doing their own thing:
  ///
  ///  * [initState]'s first frame — the request may **predate** this widget: the
  ///    消息 / 文件 tab switch destroys the thread, so a 「转到消息」 picked on the
  ///    文件 tab lands on `ConversationController` while no thread exists;
  ///  * [didChangeDependencies] — the ordinary "the thread just appeared" moment;
  ///  * the controller listener ([_onThreadChanged]) — `requestReveal` notifies.
  ///
  /// Consumption goes through `takeRevealRequest()`, which **clears** the request:
  /// running this three times for one gesture is normal and harmless (the second
  /// and third calls get `null`), but acting on the same request twice would mean
  /// two animations for one tap.
  void _consumeRevealRequest() {
    if (!mounted) {
      return;
    }
    final String? messageId = widget.controller.takeRevealRequest();
    if (messageId == null) {
      return;
    }
    // A newer request supersedes a running one (see [_revealGeneration]); the
    // older loop aborts on its next tick without touching the field.
    final int generation = ++_revealGeneration;
    _revealingId = messageId;
    // One frame first: [_childIndexOf] and [_rowKeys] are filled by the build, and
    // `didChangeDependencies` runs *before* it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // ★ **One microtask later, not here.** The loop's first `await` is
      // `WidgetsBinding.instance.endOfFrame`, and a frame-end completer created
      // *inside* the post-frame phase never completes: `handleDrawFrame` iterates a
      // copy of the post-frame list and then clears it, so the callback that
      // `endOfFrame` has just registered is dropped, no frame is scheduled (the
      // phase is not `idle`), and the reveal waits forever — with the request
      // already taken, so nothing could retry it. A microtask runs once the frame
      // has finished, where `endOfFrame` schedules its own frame.
      scheduleMicrotask(() => unawaited(_revealMessage(messageId, generation)));
    });
  }

  /// Scrolls [messageId]'s row into the middle of the viewport, or says it is not
  /// there (0.2.59).
  ///
  /// **Shaped after [_scrollToBottom]** — measure, wait a frame, measure again,
  /// correct — because this list has the same problem that one has: a lazy
  /// `ListView`'s `maxScrollExtent` is an estimate that only becomes exact once
  /// the rows *around the target* have laid out. Two differences, and both come
  /// from one fact: **the row being aimed at usually does not exist yet.**
  ///
  ///  * `Scrollable.ensureVisible` needs a `BuildContext`, and a row outside the
  ///    viewport has none. So each round either *has* the row (and finishes
  ///    exactly, aligned to 0.5) or has to get closer by dead reckoning
  ///    ([_estimateOffsetFor]) and let the list build what the jump revealed;
  ///  * the dead reckoning is **corrected by a built neighbour** from the second
  ///    round on, because a proportional guess is only right when every child has
  ///    the same height — and this timeline mixes bubbles with one-line day
  ///    separators and `HH:mm` labels.
  ///
  /// Bounded at [_kRevealAttempts] rounds: an id that is genuinely absent (deleted
  /// while the request was in flight, or from another conversation) ends as a
  /// notice, never as a spin.
  Future<void> _revealMessage(String messageId, int generation) async {
    // Captured before the first `await` — the notice must not reach for a
    // `BuildContext` that may already be gone (the rule `open_local_path.dart`
    // and `attachment_menu.dart` follow).
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    for (int attempt = 0; attempt < _kRevealAttempts; attempt++) {
      if (!mounted || generation != _revealGeneration) {
        return;
      }
      final BuildContext? row = _rowKeys[messageId]?.currentContext;
      // `row.mounted` and not only the `State`'s: this context belongs to a row
      // that may have been unmounted by the rebuild the estimate triggered.
      if (row != null && row.mounted) {
        // ★ The goal, and it is exact: a built row is measured, not estimated.
        await Scrollable.ensureVisible(
          row,
          alignment: 0.5,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        if (!mounted || generation != _revealGeneration) {
          return;
        }
        _revealingId = null;
        return;
      }
      final double? offset = _estimateOffsetFor(messageId);
      if (offset != null) {
        _scroll.jumpTo(offset);
      }
      // Let the list lay out whatever the jump just revealed before asking again —
      // this is the frame that turns a guess into a real row.
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted || generation != _revealGeneration) {
      return;
    }
    _revealingId = null;
    // Only an **assembled** timeline can claim a message is missing: on a thread
    // that is still loading (or holds no messages at all) there was never a row to
    // look for, and saying 「没有找到这条消息」 there would be a lie about data the
    // user never saw.
    if (!_timelineAssembled) {
      return;
    }
    showTransientNoticeOn(
      messenger,
      '没有找到这条消息',
      bottomInset: kComposerNoticeInset,
    );
  }

  /// Where to jump to get closer to [messageId]'s row, or `null` when there is
  /// nothing to aim at (0.2.59).
  ///
  /// Round 1 has no measurement to lean on, so it uses the only thing it knows:
  /// the target's **fraction** of the children, times the scroll range —
  ///
  ///     offset = maxScrollExtent * index / (childCount - 1)
  ///
  /// From round 2 the nearest **built** row b supplies a real measurement
  /// ([_measureRow]), and the estimate becomes a dead reckoning **from b** rather
  /// than from the viewport:
  ///
  ///     offset = top(b) + (index - b.index) * averageRowHeight - viewportExtent / 2
  ///
  /// where `top(b)` is the scroll offset at which b sits flush with the viewport's
  /// leading edge (`RenderAbstractViewport.getOffsetToReveal(box, 0)`) — i.e. b's
  /// exact position in scroll coordinates, not an approximation of it. Every step
  /// of `(index - b.index)` is therefore worth one *measured* row height, and the
  /// `- viewportExtent / 2` term puts the result where [_revealMessage] wants the
  /// target: the middle, so the row is built on the very next frame.
  ///
  /// Why this converges where the ratio alone does not: the ratio's error is
  /// proportional to `index` (it is wrong by "everything the variable-height rows
  /// above/below me got wrong"), so a target 150 rows away can land a whole screen
  /// off and *stay* there, since the rows it lands on are equally far from the
  /// truth. The neighbour's error, by contrast, shrinks with every round — each
  /// round the nearest built row is closer to the target, and a row one or two
  /// steps away mis-estimates by at most one row's height.
  double? _estimateOffsetFor(String messageId) {
    if (!_scroll.hasClients) {
      return null;
    }
    final int? index = _childIndexOf[messageId];
    if (index == null) {
      return null;
    }
    final ScrollPosition position = _scroll.position;
    final double maxExtent = position.maxScrollExtent;
    // A list that fits (or has not been laid out) cannot be scrolled: `jumpTo`
    // into a zero/NaN extent is how a reveal would throw instead of finishing.
    if (!maxExtent.isFinite || !position.hasContentDimensions || maxExtent <= 0) {
      return null;
    }
    final int lastIndex = _timelineChildCount - 1;
    if (lastIndex <= 0) {
      return null;
    }
    final _MeasuredRow? neighbour = _nearestBuiltRow(index);
    final double target;
    if (neighbour == null) {
      target = maxExtent * index / lastIndex;
    } else {
      final double rowHeight = _averageRowHeight();
      target = neighbour.topOffset +
          (index - neighbour.index) * rowHeight -
          position.viewportDimension / 2;
    }
    if (!target.isFinite) {
      return null;
    }
    return target.clamp(0.0, maxExtent).toDouble();
  }

  /// The built row whose timeline index is closest to [target] (0.2.59),
  /// together with the two measurements [_estimateOffsetFor] needs.
  ///
  /// "Built" is the whole filter: a `GlobalKey`'s `currentContext` is `null` for a
  /// row the lazy list has not inflated, and such a row has no box to measure — the
  /// same limitation [_selectionBoxes] documents.
  _MeasuredRow? _nearestBuiltRow(int target) {
    _MeasuredRow? best;
    int bestDistance = 1 << 30;
    for (final MapEntry<String, GlobalKey> entry in _rowKeys.entries) {
      final int? index = _childIndexOf[entry.key];
      if (index == null) {
        continue;
      }
      final int distance = (index - target).abs();
      if (distance >= bestDistance) {
        continue;
      }
      final RenderObject? object = entry.value.currentContext?.findRenderObject();
      if (object is! RenderBox || !object.attached || !object.hasSize) {
        continue;
      }
      // The row is inside this thread's `ListView`, so a viewport ancestor always
      // exists; `getOffsetToReveal` is the same call `Scrollable.ensureVisible`
      // makes, which is why the two agree about what "row b's position" means.
      final RevealedOffset revealed =
          RenderAbstractViewport.of(object).getOffsetToReveal(object, 0);
      if (!revealed.offset.isFinite) {
        continue;
      }
      best = _MeasuredRow(index: index, topOffset: revealed.offset);
      bestDistance = distance;
    }
    return best;
  }

  /// The mean height of the rows that are currently built (0.2.59) — the unit
  /// [_estimateOffsetFor] converts "how many children away" into pixels.
  ///
  /// Measured rather than assumed: rows are message bubbles here, whose height is
  /// one to N lines of text, and a hard-coded number would be wrong for exactly the
  /// conversations this feature exists for (long histories). Falls back to `0`,
  /// which turns the neighbour correction into "b's own position" — still a better
  /// guess than the ratio, and the loop will correct from there.
  double _averageRowHeight() {
    double total = 0;
    int count = 0;
    for (final GlobalKey key in _rowKeys.values) {
      final RenderObject? object = key.currentContext?.findRenderObject();
      if (object is RenderBox && object.attached && object.hasSize) {
        total += object.size.height;
        count++;
      }
    }
    return count == 0 ? 0 : total / count;
  }

  /// Fills the composer with **this conversation's** un-sent draft (0.2.27).
  ///
  /// The defect it answers: *"我输入了一些东西但是没点发送，换到下一个会话再回来，输入
  /// 的东西就没了"*. The `TextEditingController` used to be the only copy of the
  /// text, and it dies with this `State` — which is re-created for every
  /// conversation switch (`DetailPane` keys the thread per conversation id). The
  /// text now lives in [ConversationController]'s process-wide draft store, and
  /// this is where it comes back.
  ///
  /// Two details that are not incidental:
  /// * the caret is placed **at the end** — a restored draft the user cannot
  ///   continue typing into (caret at 0, or no selection at all) is only half
  ///   restored;
  /// * the send button's state is derived here rather than by letting the
  ///   listener fire, because [initState] runs inside the first build, where a
  ///   `setState` is illegal. `build` reads [_hasText] / [_overLimit] right
  ///   after this returns, so the button is already correct on the first frame.
  void _restoreDraft() {
    final String draft = widget.controller.draftText;
    if (draft.isEmpty) {
      _hasText = false;
      _overLimit = false;
      // `clear()` rather than "leave it": this State's controller is fresh in
      // `initState` but **reused** across a controller swap.
      _composerController.clear();
      return;
    }
    _composerController.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: draft.length),
    );
    _hasText = draft.trim().isNotEmpty;
    _overLimit = utf8.encode(draft).length > kMaxTextBytes;
  }

  void _onComposerChanged() {
    final String text = _composerController.text;
    // 0.2.27: every keystroke updates **this conversation's** draft, silently.
    // No `setState` and no `notifyListeners` on the controller here beyond the
    // two flags below — the store write must not repaint the timeline for a
    // character the text field is already drawing.
    widget.controller.updateDraft(text);
    final bool hasText = text.trim().isNotEmpty;
    final bool overLimit = utf8.encode(text).length > kMaxTextBytes;
    if (hasText != _hasText || overLimit != _overLimit) {
      setState(() {
        _hasText = hasText;
        _overLimit = overLimit;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ★ 0.2.59 — **before** the first-fill jump at the bottom of this method: a
    // thread mounted *for* a reveal (coming back from the 文件 tab) must not land
    // on the newest message first and then scroll away from it — that would be two
    // visible jumps for one gesture.
    _consumeRevealRequest();
    // The picker's byte progress (Android copies the chosen file into app
    // storage, which takes time for a large file).
    _pickProgressSub ??=
        context.deps.platform.pickProgress.listen((FilePickProgress value) {
      if (mounted) {
        setState(() {
          _pickProgress = value;
          // The copy is finished: retire the "preparing" lines even though the
          // rest of the send (hashing a big file, dialling) is still running.
          final double? fraction = value.fraction;
          if (fraction != null && fraction >= 1.0) {
            _copyDone = true;
          }
        });
      }
    });
    if (!_probed) {
      _probed = true;
      unawaited(_probeSources());
    }
    // First time we see the history, bring the newest message into view (M5c §1).
    // This also covers the common case where `load()` already finished before
    // this widget subscribed, so `_onThreadChanged` never sees a count change.
    if (_lastMessageCount < 0) {
      _lastMessageCount = widget.controller.messages.valueOrNull?.length ?? 0;
      // Same case as the first fill in `_onThreadChanged`: the thread is
      // appearing, so it lands instantly and counts as positioned.
      _didInitialFill = true;
      // …unless a reveal owns the viewport (0.2.59): [_scheduleScrollToBottom] is
      // a no-op then, and saying so here keeps the two intents in one place.
      _scheduleScrollToBottom(animate: false);
    }
    // Keyboard opening (the inset grows) → bring the newest message into view,
    // so a send is never hidden behind the keyboard (M5c §1).
    final double inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset > _lastViewInset) {
      // The keyboard rising is its own moment (not the reported defect): keep the
      // existing smooth follow, which is what "a send is never hidden" wants.
      _scheduleScrollToBottom(animate: true);
    }
    _lastViewInset = inset;
  }

  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final Widget body = _threadBody(context);
    // Dropping is a desktop gesture — a phone has nothing to drag from, so the
    // target is not even mounted there (no dead surface).
    if (context.deps.platform.isMobile) {
      return body;
    }
    return DropTarget(
      onDragEntered: (DropEventDetails _) => _setDragging(true),
      onDragExited: (DropEventDetails _) => _setDragging(false),
      onDragDone: (DropDoneDetails details) => unawaited(_dropFiles(details)),
      child: Stack(
        children: <Widget>[
          body,
          if (_dragging) Positioned.fill(child: _dropOverlay(context)),
        ],
      ),
    );
  }

  void _setDragging(bool value) {
    if (_dragging == value || !mounted) {
      return;
    }
    setState(() => _dragging = value);
  }

  /// Sends whatever was dropped (docs/19 §9.8).
  ///
  /// **A dropped folder is no longer refused** (0.2.36): *"拖文件夹被拒"*. 0.2.33
  /// gave the app a way to send a whole folder from the attach menu, and the drop
  /// path simply never caught up — it counted directories and said 「不能直接发送
  /// 文件夹，请拖入里面的文件」, which by then was a lie. It now goes through the
  /// **same** flow as that menu item ([_sendDroppedFolder] → the one
  /// [_runFolderSend]), so the walk, the limits, the confirmation sheet and the
  /// wording exist once.
  ///
  /// Mixed drops (folders + loose files) do both: every folder is offered with
  /// its confirmation, then the loose files are sent as one batch. **Cancelling a
  /// folder's confirmation** drops that folder and stays silent — it is the same
  /// "I changed my mind" as cancelling the picker — while the loose files of the
  /// same drop still go, because they were a separate, explicit part of it.
  ///
  /// One confirmation per folder rather than one for the whole drop: a folder is
  /// about to become **one message** (the next change to folder semantics), so
  /// "one folder, one decision" is the shape that survives it.
  Future<void> _dropFiles(DropDoneDetails details) async {
    _setDragging(false);
    final PlatformPorts platform = context.deps.platform;
    final List<String> paths = <String>[];
    final List<String> folders = <String>[];
    for (final file in details.files) {
      if (await platform.isDirectory(file.path)) {
        folders.add(file.path);
      } else {
        paths.add(file.path);
      }
    }
    if (!mounted) {
      return;
    }
    for (final String folder in folders) {
      await _sendDroppedFolder(folder);
      if (!mounted) {
        return;
      }
    }
    if (paths.isEmpty) {
      return;
    }
    await widget.controller.sendPaths(peer: widget.peer, paths: paths);
  }

  /// The "drop here" board: the whole conversation turns into a target, with the
  /// file count and total size, so the decision happens **before** release.
  Widget _dropOverlay(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.06),
          border: Border.all(color: theme.colorScheme.primary, width: 2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.download_outlined,
                  size: 28, color: theme.colorScheme.primary),
              const SizedBox(height: 8),
              Text('松开，即发送给 ${widget.peer.alias}',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.primary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _threadBody(BuildContext context) {
    // [FadeIn] turns a conversation / tab switch into a short fade instead of a
    // hard cut (PRD §2.5). The transparent [Material] hosts the bubble rows'
    // hover / action ink above this pane's opaque surface colour.
    return FadeIn(
      child: Material(
        type: MaterialType.transparency,
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (BuildContext context, Widget? child) {
            final PreparingSend? preparing = widget.controller.preparing;
            final int unsent = widget.controller.unsentMessages.length;
            final bool retrying = widget.controller.bulkResending;
            // Everything the 未发送成功 banner must not compete with for the
            // strip of space above the composer (0.2.24): a hash in progress,
            // an OS pick / cache copy in progress, or any row actually sending.
            final bool sending = preparing != null ||
                _preparing ||
                widget.controller.hasActiveSend;
            // `retrying` first on purpose: while a run is going the count has
            // already fallen below 2 (the messages it just re-sent stop
            // counting), and hiding the banner mid-run would hide the only
            // "进行中" feedback and the disabled button with it.
            final bool showUnsent = retrying || (unsent >= 2 && !sending);
            // 0.2.41 — multi-select owns two strips of this pane while it is on:
            // a bar at the top (取消 / 已选 N 条 / 全选) and, at the bottom, the
            // 删除 / 转发 toolbar **in place of** the composer. Both are part of
            // the thread rather than the shell's AppBar so the whole mode is one
            // widget's state, and so it looks the same in the phone shell and in
            // the desktop's right pane.
            final bool selecting = widget.controller.selecting;
            return Column(
              children: <Widget>[
                if (selecting) ...<Widget>[
                  _selectionBar(context),
                  const Divider(height: 1, thickness: 1),
                ],
                Expanded(child: _timeline(context)),
                if (preparing != null) _preparingRow(context, preparing),
                // ★ 0.2.48 — **both of these act on the whole conversation, so
                // neither may be on screen while a batch is being picked.** The
                // wording of 全部重试 is "N 条没有发送成功" and it re-sends every
                // one of them (`ConversationController.resendUnsent`); ticking 5
                // bubbles and then pressing it sent the other 12 as well. The
                // rows are hidden rather than re-labelled: the multi-select bar
                // already owns the top of the pane and the toolbar owns the
                // bottom, and a second scope ("only the ticked ones") would need
                // a retry that does not exist — `retry` is per message on the
                // bubble, and that stays reachable the moment the mode ends.
                if (!selecting && widget.sharedPaths.isNotEmpty)
                  _shareDraftRow(context),
                // Bottom-most of the auxiliary rows, i.e. directly above the
                // composer — "输入框上方" without pushing the timeline up by a
                // fixed amount: it is a sibling in this `Column`, so it only
                // takes height while it is shown.
                if (!selecting && showUnsent)
                  _unsentRow(context, count: unsent, retrying: retrying),
                const Divider(height: 1, thickness: 1),
                // 0.2.41: while selecting, the composer gives way to the batch
                // toolbar — one bottom strip either way, so the timeline does not
                // jump by a composer's height when the mode is entered.
                if (selecting)
                  _selectionToolbar(context)
                else
                  _composer(context),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _timeline(BuildContext context) {
    // ★ 0.2.59 — **the reveal index is rebuilt from this build's own assembly**,
    // and cleared here first so that an early return below (loading / failure /
    // empty) can never leave an index pointing at a child that no longer exists.
    // Declared before anything can return on purpose: the failure and empty
    // branches are exactly the moments when a stale index would be a silent lie
    // waiting for the next 「转到消息」.
    _childIndexOf.clear();
    _timelineChildCount = 0;
    _timelineAssembled = false;
    final AsyncValue<List<ChatMessage>> value = widget.controller.messages;
    if (value.isLoading) {
      return const LoadingState();
    }
    if (value.hasError) {
      // A failed history read must LOOK different from "no messages" — three
      // states that look alike are a silent failure (M5c §4). The banner names
      // the failure and offers a retry.
      final Object error = (value as Failure<List<ChatMessage>>).error;
      return ListView(
        padding: const EdgeInsets.all(24),
        children: <Widget>[
          ErrorBanner(
            message: '读取会话记录失败：$error',
            onRetry: () => unawaited(widget.controller.load()),
          ),
        ],
      );
    }
    final List<ChatMessage> messages =
        value.valueOrNull ?? const <ChatMessage>[];
    if (messages.isEmpty) {
      return const EmptyState.messages();
    }
    final DateTime now = context.deps.clock.nowUtc();
    final List<Widget> children = <Widget>[];
    String? lastDay;
    DateTime? lastAt;
    for (final ChatMessage message in messages) {
      final String day = localDateKey(message.createdAt);
      if (day != lastDay) {
        children.add(
          // 0.2.32: 今天 / 昨天 / 日期 is a divider, not message content — a drag
          // that crosses a day boundary must not paste it (`SelectionContainer
          // .disabled` unregisters the subtree from the region, see the bubble).
          SelectionContainer.disabled(
            child: _DateSeparator(
                label: dateSeparatorText(now, message.createdAt)),
          ),
        );
        lastDay = day;
        lastAt = null; // a new day always re-states the time
      }
      // docs/19 §9-B: one `HH:mm` above the bubble, and only where it carries
      // information — the first message of a day, or after a 5-minute gap.
      // (A label on *every* message would be the noise we just removed.)
      if (lastAt == null ||
          message.createdAt.difference(lastAt).inMinutes >= 5) {
        // 0.2.32: likewise a timestamp — it sits *between* two bubbles, so a
        // cross-bubble drag would otherwise paste `20:00` in the middle.
        children.add(
          SelectionContainer.disabled(
            child: _TimeLabel(
              label: timeText(message.createdAt),
              outgoing: message.direction == MessageDirection.outgoing,
            ),
          ),
        );
      }
      lastAt = message.createdAt;
      // ★ 0.2.59 — **the index and the row key are recorded right here, in the one
      // pass that decides what the children are.** A message's index in `children`
      // is not its index in `messages`: the two `if`s above insert a day separator
      // and an `HH:mm` label, so the numbers diverge on the first day boundary of
      // any real conversation. Computing the map afterwards would mean writing
      // those two rules a second time, and two copies of a rule drift — the reveal
      // would then scroll to whatever the *other* rule believed.
      _childIndexOf[message.id] = children.length;
      children.add(
        // The `GlobalKey` is what lets the reveal loop find this row's
        // `BuildContext` **while it is built** and hand it to
        // `Scrollable.ensureVisible`; a row the lazy list has not inflated has no
        // context, and the loop's estimate is what gets it inflated. `KeyedSubtree`
        // because it adds no element of its own geometry — the row keeps the exact
        // layout it had before 0.2.59.
        KeyedSubtree(
          key: _rowKeys.putIfAbsent(
            message.id,
            () => GlobalKey(debugLabel: 'reveal-row:${message.id}'),
          ),
          child: _bubble(context, message,
              isLast: message.id == messages.last.id),
        ),
      );
    }
    _timelineChildCount = children.length;
    _timelineAssembled = children.isNotEmpty;
    // Rows that are no longer in the conversation are forgotten, so the map stays
    // the size of the conversation instead of growing for the life of the visit.
    final Set<String> liveIds = <String>{
      for (final ChatMessage message in messages) message.id,
    };
    _rowKeys.removeWhere((String id, GlobalKey _) => !liveIds.contains(id));
    // ★ **One** selection region for the whole timeline, mounted **above** the
    // `ListView` (0.2.30) — *"手机上倒是可以选择文字，电脑上反而不行"*.
    //
    // Two reasons, and only one of them is about the phone:
    // * a `SelectableRegion` competes for a drag only when the pointer came down
    //   **inside its own box**. Mounted per bubble (0.2.28) that box is one
    //   paragraph inside a scrollable, so a mouse drag that started on the card's
    //   padding, or ran past the bubble it started in, was a drag on nothing (or
    //   a drag on one bubble alone) — while a finger's long press, which nothing
    //   competes for, kept working. That is exactly the desktop/phone split the
    //   user reported;
    // * a per-row region also puts a **second** pan recognizer in the arena of
    //   every row, under the scrollable, which is what Flutter's own docs warn
    //   about for text inside a list.
    //
    // The region is above the `ListView` and **below** the composer: the
    // composer's `TextField` is a `Column` sibling, so it keeps its own editing
    // selection, and its caret/selection are untouched by this change.
    //
    // The bubbles are told `selectableText: false` (see `MessageBubble`) so the
    // thread holds **exactly one** region; nesting two would hand the gesture to
    // the inner one (recognizers are added deepest-first) and change nothing.
    //
    // ★ 0.2.31 → 0.2.35: the region's own **context menu** is what a right click
    // opens on a dragged selection — 「复制」 for *that range*. It is Flutter's
    // menu (built by `SelectableRegion` from its own selection geometry, so it is
    // present exactly when there is something to copy), and its labels come from
    // `MaterialLocalizations`. 0.2.31 hand-translated the three labels *here*
    // because the app declared no `localizationsDelegates` and the default ones
    // are English. 0.2.35 declares the real delegates
    // (`lib/ui/localization.dart`, wired in both `MaterialApp`s), so the menu is
    // Chinese **without this file doing anything** — there is no
    // `contextMenuBuilder` below, and the default toolbar — placement, platform
    // shape, which entries exist, what they say — is Flutter's alone.
    //
    // ★ 0.2.36: that is no longer literally true — `_selectionContextMenu` now
    // supplies a builder. It is **Flutter's own list, plus one row**: the items
    // handed to `AdaptiveTextSelectionToolbar.buttonItems` are exactly
    // `state.contextMenuButtonItems`, so 复制 / 全选 keep their platform-
    // localized labels, their order and their behaviour, and only 「删除消息」 is
    // appended. The alternative — a `GestureDetector` on the bubble — is precisely
    // what 0.2.31 removed, because it starved this region of right clicks.
    return Listener(
      // ★ 0.2.48 — **where** the press came down, recorded for the whole region.
      //
      // This is the only listener that also sees a press on empty space (or on a
      // day divider), which is exactly the case `_selectionMessageId` cannot
      // answer: it is written by the bubbles only, so without this a right click
      // on nothing reused the last bubble's id and opened its menu. A `Listener`
      // never joins the gesture arena, so nothing here can steal the right click
      // from the region below it — the same property that makes the per-bubble
      // listener safe.
      onPointerDown: (PointerDownEvent event) {
        _selectionPointerDown = event.position;
      },
      child: SelectionArea(
        contextMenuBuilder: _selectionContextMenu,
        onSelectionChanged: _onSelectionChanged,
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: children,
        ),
      ),
    );
  }

  /// The current instant, in **UTC** — the injected [ConversationThread.clock]
  /// when a caller supplied one, otherwise the container's clock
  /// (`context.deps.clock`, `SystemClock` in production).
  ///
  /// UTC on purpose: every timestamp the repository answers with is UTC
  /// (`SessionStore` writes epoch milliseconds), so comparing them must not
  /// involve a local-time offset. `DateTime.difference` is instant-based anyway,
  /// but keeping both sides UTC means a logged value is readable next to the
  /// row it came from.
  DateTime _nowUtc(BuildContext context) =>
      (widget.clock ?? context.deps.clock).nowUtc();

  Widget _bubble(BuildContext context, ChatMessage message,
      {required bool isLast}) {
    final List<FileAttachment> files = widget.controller.filesOf(message.id);
    // ★ 0.2.49 — **the message's progress, not the first attachment's.**
    //
    // This used to be one line:
    //
    //     files.isEmpty ? null : controller.transferOf(files.first.id)
    //
    // A multi-select is **one** message with N attachments, and `filesOf` is
    // `ORDER BY rowid ASC` = selection order = upload order, so `files.first` is
    // the file the orchestrator uploads **first**. The moment it finished, the
    // number handed to the bubble was a frozen `100 %` while files 2…N were still
    // going — 「只显示某一个视频的传输过程，然后就一直呆在那」. The transfer was
    // never at fault (`transfer_orchestrator.dart` walks the same list serially
    // and writes every file's progress; the 1 Hz poll keeps re-reading all of
    // them), only this lookup was.
    //
    // `MessageTransferProgress.of` is now the **single** message-level
    // aggregate — a one-file message, a flat multi-select and a folder all come
    // through it, so there is no branch here to get the answer wrong in. For one
    // attachment it returns that attachment's own row untouched, which is what
    // keeps today's behaviour of every single-file bubble identical.
    final MessageTransferProgress transfer = MessageTransferProgress.of(
      files,
      progressOf: widget.controller.transferOf,
    );
    final TransferProgress? progress = transfer.bar;
    // 0.2.42 — **the honest 「N 个未收到」**. A folder arrives one file at a time
    // and the protocol has no "batch finished" frame (`docs/22` §4.4), so the
    // only proof that a file is not coming is **silence**: the store's
    // `lastActivityAt` (the newest `transfers.updated_at` over this message's
    // files) older than `kFolderQuietPeriod`. Both numbers — declared and
    // arrived — and the instant are handed to `missingFolderFiles`, which owns
    // the rule, so the bubble prints nothing at all unless the folder is
    // provably stalled:
    //
    // * 30 s quiet, 5 declared / 2 arrived → 0, **no line** (the peer may still
    //   be sending; saying 「3 个未收到」 here would be a lie that a later file
    //   disproves);
    // * 200 s quiet, same data → 3, and the card says 「3 个未收到」.
    //
    // ★ 0.2.52 — **the same rule now covers a flat multi-select batch**, and for
    // the same reason. 0.2.51 folded "one multi-select" into one message, which
    // was right, but the fold also swallowed the evidence: 8 selected files that
    // delivered 3 became one bubble that looked exactly like a batch of 3. The
    // declared count was never missing from the wire — `core` now stamps every
    // `ReceivedFile` of a session with how many files that `prepare` declared —
    // so the judgement is *identical* for both shapes and only the **surface**
    // differs (a folder card prints it inside the card; a batch has no card, so
    // it is drawn under the bubble, see [MissingFilesNote]).
    //
    // The query still runs **only** when there is something to ask about
    // (`declared > arrived`), so a plain one-file bubble — declared `0`, which is
    // what a single send stores — costs no `lastActivityAt` read at all.
    final int declaredFiles = message.folderFiles;
    final int missingFiles = declaredFiles > files.length
        ? missingFolderFiles(
            declaredCount: declaredFiles,
            arrivedCount: files.length,
            lastActivityAt: context.deps.repo.lastActivityAt(message.id),
            // Never `DateTime.now()` here: the decision's clock is injected
            // (see `ConversationThread.clock`), so it is testable.
            now: _nowUtc(context),
          )
        : 0;
    final FolderSummary? folderSummary = message.isFolder
        ? FolderSummary.of(
            message,
            files,
            progressOf: widget.controller.transferOf,
            missing: missingFiles,
          )
        : null;
    // ★ 0.2.49 — **the fact, and then whose doing it was.**
    //
    // `_sources` answers one question ("is this attachment's file still on disk?")
    // and it stays the shared answer for the four surfaces that need it. But a
    // file that is gone for a *different reason* must not look the same:
    //
    //  * on Android the picked/shared file is a **cache copy**, and
    //    `ConversationController._discardPickedCopies` deletes it the moment the
    //    send succeeds — so for **every delivered file** the disk answer is
    //    "gone", and drawing a warning there accused a successful transfer of
    //    having lost its own file (*"发送成功后，已完成旁边却会显示离线的那个红色图标"*);
    //  * on the desktop the same answer means the user deleted or moved **their own
    //    source** — a real loss that must still be reported.
    //
    // The two are told apart by *who removed the file*, never by the message's
    // status (a `done` message can be either, and keying on status silences the
    // real loss). `MessageBubble` consults the second flag only to suppress the
    // marks for files we cleaned up ourselves — one verdict for the marker, the
    // row and the thumbnail alike.
    //
    // Two kinds of evidence, in order of strength:
    //
    //  1. **we watched ourselves delete it** — `discardedByUs`, recorded by
    //     `_discardPickedCopies` right after a delivered send. Direct.
    //  2. **it can only have been us** — a path under `lanlink-picked/` that is
    //     gone from a **delivered** message. That is an inference, and it is what
    //     keeps the answer right *after a restart*, when (1) is empty again while
    //     every Android send of the past still names a copy that no longer exists.
    //     Status enters only here, as a **precondition of the inference** — we free
    //     a copy *only* once the send succeeded — and never as the reason itself:
    //     a `failed` message whose picked copy is gone still reports it, because
    //     the retry it offers cannot read that file any more.
    final bool sourceGone = _sources.anyUnavailable(files);
    final bool sourceGoneIsOurs = sourceGone &&
        files.every((FileAttachment file) {
          if (_sources.isOnDisk(file.localPath)) {
            return true;
          }
          if (widget.controller.discardedByUs(file.localPath)) {
            return true;
          }
          return message.status == MessageStatus.done &&
              isPickedCachePath(file.localPath ?? '');
        });
    final Widget bubble = MessageBubble(
      message: message,
      files: files,
      progress: progress,
      // ★ 0.2.49 — 「第 k/N 个」, the caption the bar was missing. A batch's byte
      // percentage sits at 97 % for minutes while the last video trickles in, so
      // it cannot say "this moved on"; without the numbers the user's only live
      // signal was a percentage, and a percentage that stops moving looks exactly
      // like a dead link. `null` for a one-file message and for a batch with
      // nothing in flight (see `MessageTransferProgress.ordinal`).
      progressOrdinal: transfer.ordinal,
      // A2-18 / 0.2.48: the **shared** disk judgement (`SourceAvailability`, the
      // same one the 文件 tab and the 最近文件 page use) instead of a per-`State`
      // map, asked about every message — the file being gone is a fact about the
      // disk, and re-reading it is what lets the answer survive a tab switch.
      //
      // ★ 0.2.49 — the fact is handed over **unconditionally** (`sourceGone`) and
      // is not the same thing as the warning; see the block above. A caller that
      // turned "gone" into "warn" is exactly what 0.2.48 did, and it marked every
      // completed file message on Android.
      sourceUnavailable: sourceGone,
      // …and *we* may be the ones who deleted it, in which case the bubble draws
      // nothing at all: no red icon, no 源文件不可用, no 重新发送.
      sourceCleanedByUs: sourceGoneIsOurs,
      // docs/19 §9-A: 「已完成」only on the newest bubble.
      isLastInThread: isLast,
      // On a phone a thumbnail is tap-to-open (M5 §D); desktop unchanged.
      isMobile: context.deps.platform.isMobile,
      // 0.2.30: the **timeline** owns the one `SelectionArea` (see
      // [_timeline]); a region per bubble would compete with it and lose.
      selectableText: false,
      // docs/19 §8-⑥: the desktop draws a round avatar **outside** an incoming
      // bubble. The bubble cannot know the peer, so the thread (which already
      // owns [peer] for its header) supplies it.
      incomingAvatar: CircleAvatar(
        radius: kMessageAvatar / 2,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(
          deviceKindIcon(widget.peer.kind),
          size: kMessageAvatar * 0.55,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      onResend: () => unawaited(_resend(message)),
      // 0.2.22: the result used to be dropped on the floor, so a cancel the
      // controller refused said nothing at all. Every outcome now answers.
      onCancel: () => unawaited(_cancel(message)),
      // Why a send died, when we can name it (0.2.22). See [_failureNote].
      // 0.2.52: …including "the original file is gone" — the reason the offline
      // queue used to lose silently (`sourceGone` is the judgement computed above).
      failureNote: _failureNote(message, progress, sourceGone: sourceGone),
      // "Received, but the export to 下载 failed" (0.2.23). See [_publishNote].
      publishNote: _publishNote(message, progress),
      onOpenFile: _openFile,
      // 0.2.38 / T05: a folder message draws **one card** instead of N rows, and
      // the numbers on it are computed here — once — by `summarizeFolder`. The
      // bubble is deliberately not allowed to count `files` itself, or the card
      // and the directory page would answer `12/20` differently.
      // 0.2.42: …including `missing`, which is the one number that needs the
      // clock (see `folderSummary` above).
      folder: folderSummary,
      onOpenFolder: message.isFolder ? () => _openFolder(message) : null,
      // docs/19 §9.6: right-click (desktop) / long-press (phone) on a card.
      //
      // 0.2.36: the menu gains 「删除」 **only when the message may be deleted**
      // (`ConversationController.canDelete`). Passing `null` makes
      // `showAttachmentMenu` not build the row at all — the menu's own rule (an
      // entry that cannot work is not drawn, rather than drawn greyed out) — so
      // an in-flight bubble offers no 删除 to tap.
      onShowAttachmentMenu: (FileAttachment file, Offset position) => unawaited(
        showAttachmentMenu(
          context,
          file: file,
          position: position,
          onDelete: widget.controller.canDelete(message)
              ? () => _delete(message)
              : null,
          // 0.2.46: 转发 from the file bubble's own menu — one message, whatever
          // devices the picker returns. The bubble/file split is unchanged: this
          // menu still belongs to the card the user right-clicked.
          onForward: () => unawaited(_forwardMessage(message)),
        ),
      ),
      // 0.2.46 — a **folder** card draws one card and never reaches the
      // attachment menu, so its message-level menu is its own (转发到… / 删除).
      // It had no secondary tap at all before this release.
      onShowFolderMenu: message.isFolder
          ? (Offset position) => unawaited(
                showFolderMessageMenu(
                  context,
                  position: position,
                  onForward: () => unawaited(_forwardMessage(message)),
                  onDelete: widget.controller.canDelete(message)
                      ? () => _delete(message)
                      : null,
                ),
              )
          : null,
      // 0.2.31: 「复制」 is the button under a text bubble now, **not** the
      // bubble's right click. The right button belongs to the selection layer
      // this thread mounts above its `ListView`: that is the only way 右键 can
      // mean "copy the range I just dragged", which is what the user asked for
      // (*"选中右键就没法单独复制我选中的那部分了"*). Copying the **whole**
      // body — still the fastest way to get one line out — lives here, on the
      // button, where no gesture competes with it: the clipboard write and the
      // 已复制 confirmation stay next to the attachment menu that already works
      // that way.
      onCopyText: () => unawaited(
        copyMessageText(context, text: message.textBody ?? ''),
      ),
      // 0.2.45: dragging an attachment **out** of the app. Wired only where the
      // platform can really do it (`supportsDragOut` — Windows' OLE drag source);
      // everywhere else this is `null`, and the bubble adds no gesture at all.
      onDragOut: context.deps.platform.supportsDragOut
          ? (List<FileAttachment> files) =>
              unawaited(_dragOutFiles(message, files))
          : null,
    );
    final Widget? note = _pendingNote(context, message);
    // ★ 0.2.52 — a **flat batch** has no folder card to print the shortfall on,
    // so it is drawn as an under-bubble note: exactly the slot `_pendingNote`
    // uses, and exactly the sentence/style the folder card uses
    // (`MissingFilesNote` exists so the two cannot drift). It sits **outside**
    // the bubble on purpose — the bubble is the message, and this is a remark on
    // it, the same way 「对方离线，排队等待上传」 is. A folder is unaffected: it
    // keeps printing the line inside its card ([folderSummary]).
    final Widget? missingNote = !message.isFolder && missingFiles > 0
        ? MissingFilesNote(count: missingFiles)
        : null;
    final Widget body = Column(
      crossAxisAlignment: message.direction == MessageDirection.outgoing
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _withSelectionTracking(message, bubble),
        if (note != null) ...<Widget>[
          const SizedBox(height: 4),
          // 0.2.32: 「对方离线，排队等待上传」 explains the bubble; it is not part
          // of anything the user typed.
          SelectionContainer.disabled(child: note),
        ],
        if (missingNote != null) ...<Widget>[
          const SizedBox(height: 4),
          // The widget already disables selection inside itself.
          missingNote,
        ],
      ],
    );
    // 0.2.41 — multi-select puts a ring **left of the bubble on both sides**, so
    // the rings of consecutive rows form one vertical line instead of zig-zagging
    // with the in/out alignment. Nothing else about the row changes; when the mode
    // is off this returns [body] untouched, which is what keeps every geometry
    // baseline in the suite byte-identical.
    final Widget row = _withSelectionRing(message, body);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: row,
    );
  }

  /// Wraps one message row for multi-select: the ring, and "a tap means pick".
  ///
  /// **Why the tap is taken away from the bubble instead of handled inside it.**
  /// In this mode a tap may not open a file, may not open a thumbnail and may not
  /// raise the right-click menu — those are the app's real behaviours and the user
  /// is not asking for any of them. `IgnorePointer` removes the whole interactive
  /// subtree in one statement (no per-widget `enabled` flags to forget), and the
  /// `GestureDetector` above it becomes the only thing that can be hit.
  ///
  /// A message that cannot be deleted (`canSelect` false) gets **no ring** and its
  /// tap does nothing: an affordance that cannot work is not drawn, and a ring that
  /// ignored taps would be worse than no ring.
  Widget _withSelectionRing(ChatMessage message, Widget child) {
    if (!widget.controller.selecting) {
      return child;
    }
    final bool selectable = widget.controller.canSelect(message);
    final bool selected = widget.controller.isSelected(message.id);
    final ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        SizedBox(
          width: 32,
          child: selectable
              ? IconButton(
                  key: ValueKey<String>('select-ring-${message.id}'),
                  tooltip: selected ? '取消选择' : '选择',
                  padding: EdgeInsets.zero,
                  iconSize: 22,
                  onPressed: () => widget.controller.toggleSelected(message),
                  icon: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                )
              : const SizedBox.shrink(),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: selectable
                ? () => widget.controller.toggleSelected(message)
                : null,
            child: IgnorePointer(child: child),
          ),
        ),
      ],
    );
  }

  /// Wraps a **text** bubble in the raw-pointer listener that remembers which
  /// message a selection belongs to (0.2.36).
  ///
  /// Only a text bubble is wrapped, and only for its own id: a file bubble has no
  /// selection, gets its 「删除」 from the attachment menu instead
  /// ([_bubble]'s `onShowAttachmentMenu`), and must not overwrite the id this
  /// listener exists to record.
  ///
  /// A [Listener] is **not** a gesture recognizer — it never joins the arena, so
  /// it cannot compete with the `SelectableRegion` that 0.2.30 mounted above the
  /// `ListView`. It only records "the pointer came down here", which is the one
  /// fact the selection layer cannot report (it knows the selected text, not
  /// which bubble it came from). `HitTestBehavior.deferToChild` is the default
  /// and is what we want: the event is observed only where the bubble actually
  /// was hit.
  Widget _withSelectionTracking(ChatMessage message, Widget child) {
    if (message.kind != MessageKind.text) {
      return child;
    }
    // 0.2.48: the box is recorded too, not only the id — see
    // [_selectionPointerDown] and [_pressIsInside].
    final GlobalKey box =
        _selectionBoxes.putIfAbsent(message.id, () => GlobalKey());
    return Listener(
      key: box,
      onPointerDown: (PointerDownEvent event) {
        _selectionMessageId = message.id;
      },
      child: child,
    );
  }

  /// Records the current selection so the context menu can decide whether
  /// 「删除消息」 applies (0.2.36).
  ///
  /// Deliberately does **not** `setState`: nothing in the tree is painted from
  /// this value (the toolbar is built by Flutter when — and only when — it is
  /// shown), and a rebuild per dragged character would be a repaint storm for a
  /// private field.
  void _onSelectionChanged(SelectedContent? content) {
    _selectionText = content?.plainText ?? '';
  }

  /// The timeline's right-click menu — **two menus in one builder**, split by one
  /// fact: is there a selection? (0.2.36, extended 0.2.38.)
  ///
  /// The reference app splits these jobs, and so do we now:
  ///
  /// | what the user right-clicked | what they get |
  /// |---|---|
  /// | a **text bubble**, nothing selected | 「复制文字」 / 「删除消息」 — the *message's* menu |
  /// | **selected text** | Flutter's toolbar: 复制 / 全选, plus 删除消息 |
  /// | a **file bubble** | nothing here — its own attachment menu (`MenuBubble` rule) |
  ///
  /// **Why one builder and not a second `GestureDetector`.** 0.2.28 shipped exactly
  /// that second detector and the right click went silently dead: a recognizer
  /// inside the bubble wins the arena against the `SelectableRegion` above it, so
  /// the selection toolbar never appeared — tests were green and the click did
  /// nothing. 0.2.31 removed it. This builder is *inside* the region's own path
  /// (Flutter calls it when — and only when — it is about to show the toolbar), so
  /// there is no arena, no second menu, and no way for the two to appear together.
  /// The only gesture involved is the raw-pointer [Listener] that records *which*
  /// bubble was right-clicked ([_withSelectionTracking]) — and a `Listener` never
  /// joins the arena.
  ///
  /// 「删除消息」 is built only when `ConversationController.canDelete` says the
  /// message can be acted on (no in-flight / pending / awaiting-confirm rows) —
  /// the project rule is that an entry which cannot work is not drawn at all.
  Widget _selectionContextMenu(
    BuildContext context,
    SelectableRegionState state,
  ) {
    final ChatMessage? target = _findMessage(_selectionMessageId);

    // ── no selection: the whole message is the subject ────────────────────
    if (_selectionText.isEmpty) {
      // Not on a text bubble (empty space, a file card, a date separator): there
      // is no message menu to show. Returning an empty box also suppresses
      // Flutter's 「全选」, which for a chat timeline is a command about nothing —
      // a file card opens its own attachment menu instead.
      //
      // ★ 0.2.48 — **`_selectionMessageId` alone does not mean "the user
      // right-clicked that message".** It is recorded on every pointer down
      // inside a text bubble and never cleared, so a right click on empty space
      // (or on a day divider) used to build the menu of the *last* bubble that
      // had been pressed — 「删除消息」 included, which deleted that message. The
      // check below binds the id to *this* press: the recorded pointer-down has
      // to fall inside that bubble's box. When it does not, the id is dropped so
      // the stale value cannot be reused by the next menu either.
      if (target == null ||
          target.kind != MessageKind.text ||
          !_pressIsInside(target)) {
        _selectionMessageId = null;
        _selectionPointerDown = null;
        return const SizedBox.shrink();
      }
      final String body = target.textBody ?? '';
      return AdaptiveTextSelectionToolbar.buttonItems(
        anchors: state.contextMenuAnchors,
        buttonItems: <ContextMenuButtonItem>[
          if (body.isNotEmpty)
            ContextMenuButtonItem(
              label: '复制文字',
              onPressed: () {
                // Flutter's overlay, so Flutter closes it: a menu left hanging
                // over what it just acted on is a menu about nothing.
                ContextMenuController.removeAny();
                unawaited(copyMessageText(context, text: body));
              },
            ),
          // 0.2.46 — **one gesture, one message, every device.** Until this
          // release forwarding was only reachable through 「⋯ → 多选 → 勾选 →
          // 转发」, so the cheapest way to send one line to a second machine was
          // a four-tap detour through a mode the user did not want. The entry is
          // here — the message's own menu — because that is exactly the subject:
          // *this* message, to devices the picker then asks about.
          //
          // Only drawn when there is a body: an empty text row has nothing to
          // forward, and the project rule is that an affordance which cannot
          // work is not drawn.
          if (body.isNotEmpty)
            ContextMenuButtonItem(
              label: '转发到…',
              onPressed: () {
                ContextMenuController.removeAny();
                unawaited(_forwardMessage(target));
              },
            ),
          if (widget.controller.canDelete(target))
            ContextMenuButtonItem(
              label: '删除消息',
              onPressed: () {
                ContextMenuController.removeAny();
                _delete(target);
              },
            ),
          // 0.2.41 — the desktop's way into multi-select. It lives here because a
          // desktop has no ⋯ menu on the bubble, and this menu is already "the
          // message's own menu" (0.2.38).
          ContextMenuButtonItem(
            label: '多选',
            onPressed: () {
              ContextMenuController.removeAny();
              widget.controller.startSelecting();
            },
          ),
        ],
      );
    }

    // ── a selection exists: Flutter's toolbar, plus our one extra row ─────
    final List<ContextMenuButtonItem> items =
        List<ContextMenuButtonItem>.of(state.contextMenuButtonItems);
    if (target != null && widget.controller.canDelete(target)) {
      items.add(
        ContextMenuButtonItem(
          label: '删除消息',
          onPressed: () {
            ContextMenuController.removeAny();
            _delete(target);
          },
        ),
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: items,
    );
  }

  /// The visible message with [messageId], or `null`.
  ///
  /// The toolbar is built from a stored id, and the row it names may already be
  /// gone (a repository event, or a delete that a second right click raced).
  /// Reading the **current** list is what makes that impossible to get wrong.
  ChatMessage? _findMessage(String? messageId) {
    if (messageId == null) {
      return null;
    }
    for (final ChatMessage message
        in widget.controller.messages.valueOrNull ?? const <ChatMessage>[]) {
      if (message.id == messageId) {
        return message;
      }
    }
    return null;
  }

  /// Whether the last recorded pointer down fell **inside** [message]'s bubble.
  ///
  /// The missing half of "which message is this menu about" (0.2.48). The id is
  /// recorded by a [Listener] on the bubble, which only fires where the bubble
  /// was really hit — but the id outlives the click, so on its own it answers
  /// "which bubble was pressed **last**", not "which one was pressed **now**".
  /// Comparing the press position with the bubble's current box turns the stale
  /// record into a per-press fact.
  ///
  /// `false` when the bubble has no `RenderObject` (scrolled out of the lazy
  /// list), which is safe: a row that is not laid out cannot have been clicked.
  bool _pressIsInside(ChatMessage message) {
    final Offset? at = _selectionPointerDown;
    if (at == null) {
      return false;
    }
    final BuildContext? boxContext = _selectionBoxes[message.id]?.currentContext;
    final RenderObject? render = boxContext?.findRenderObject();
    if (render is! RenderBox || !render.hasSize) {
      return false;
    }
    return (Offset.zero & render.size).contains(render.globalToLocal(at));
  }

  /// Deletes [message] from the local history and says what happened (0.2.36).
  ///
  /// Local only: the peer keeps its copy (no delete frame exists) and no file on
  /// disk is removed — the received file stays in 下载. The controller owns both
  /// the refusal (an in-flight send) and the store write; this method only
  /// reports the answer, through the same 2 s floating notice as every other
  /// one-line confirmation in the app (0.2.36's `notices.dart`).
  ///
  /// The messenger is captured **before** the delete so the notice cannot be
  /// built from a `BuildContext` that a rebuild may have invalidated.
  void _delete(ChatMessage message) {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final DeleteResult result = widget.controller.deleteMessage(message);
    showTransientNoticeOn(
      messenger,
      result.notice,
      bottomInset: kComposerNoticeInset,
    );
  }

  /// Q9: a queued message says **why** it is waiting, not just "排队中".
  ///
  /// **0.2.40 — the note must survive the peer coming online.** The old
  /// condition was `status == pending && !peer.isOnline`, so the moment the peer
  /// reappeared this line vanished and the bubble was left showing a bare
  /// 「排队中」 with no explanation and no button (`_actions` draws 重新发送 only
  /// for `failed`/`canceled`) — literally the "就一直排队" the user reported,
  /// made worse by the explanation disappearing. The queue is now drained
  /// automatically, so a `pending` message whose peer *is* reachable is one the
  /// pump is about to drive: say that instead of saying nothing.
  ///
  /// **★ 0.2.48 — "online" is not the same as "the pump will pick this up".**
  /// [`OutboxPump`] deliberately skips a card whose `isDialable` / `canSend` is
  /// false (`lastPort` `null` or `0`), so a queued message for a device that is
  /// **visible but has no inbound server** stayed `pending` forever — while this
  /// line promised 「即将发送…」, next to a composer that said 「对方当前不可接收」.
  /// Two sentences about one peer, and the one on the bubble could never happen.
  ///
  /// There are three states, not two, and each now says something it can keep:
  ///
  /// | peer | what the app will really do | the line |
  /// |---|---|---|
  /// | offline | nothing until it reappears | 对方离线，排队等待上传 |
  /// | online **+** dialable | the pump drives it now | 即将发送… |
  /// | online, **not** dialable | nothing, ever, until it accepts again | 对方暂时收不了，等它可接收后再发 |
  ///
  /// The third one is not a fourth wording for the same fact — it is a different
  /// fact, and it is the one that used to be printed as a promise.
  Widget? _pendingNote(BuildContext context, ChatMessage message) {
    final bool waiting = message.direction == MessageDirection.outgoing &&
        message.status == MessageStatus.pending;
    if (!waiting) {
      return null;
    }
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        _pendingNoteText(),
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  /// The sentence for the three states above — see [_pendingNote].
  ///
  /// The dialability test is the pump's own (`PeerDevice.isDialable`, and
  /// `OutboxPump._pass` line for the same `lastPort > 0` rule): if this condition
  /// ever drifts from the pump's, the promise comes back. It reads `canSend` too,
  /// because `lastPort == 0` also disables the composer, and the two lines must
  /// not contradict each other.
  String _pendingNoteText() {
    if (!widget.peer.isOnline) {
      return '对方离线，排队等待上传';
    }
    if (widget.peer.canSend && widget.peer.isDialable) {
      return '即将发送…';
    }
    return '对方暂时收不了，等它可接收后再发';
  }

  /// The "正在准备" line shown while picked files are being hashed (0.2.14).
  ///
  /// It exists because the message row **cannot** be created first: the id's
  /// content key contains the file's `sha256` (`SessionStore.recordOutgoingFiles`
  /// → `contentKeyForFiles`), so the hash must finish before there is an id at
  /// all. Without this row a 256 MiB send showed nothing for ~2.3 s (11.5–15.5 s
  /// before 0.2.12 made hashing 5.5x faster) and the tap looked ignored.
  ///
  /// One small row above the composer, built only from existing theme tokens, so
  /// it adds no colour and does not touch the three-pane geometry. `liveRegion`
  /// announces it once for screen readers instead of leaving them silent.
  Widget _preparingRow(BuildContext context, PreparingSend preparing) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Semantics(
          liveRegion: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  preparing.label,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The 待发送 row: files another app shared into lanlink, waiting for a tap on
  /// 发送 (0.2.18).
  ///
  /// **Nothing here is sent automatically.** The row is the whole point of the
  /// inbound-share feature's interaction rule: a shared file is *staged*, the
  /// user keeps the final say. Sending reuses the ordinary path
  /// ([ConversationController.sendPaths]), so the 正在准备 hint, the progress bar
  /// and the failure reporting are exactly the same as for a picked file.
  ///
  /// **0.2.63 — two lines, and the first one names the target.** The row used to
  /// read 「待发送 · 3 个文件」, which answered "what" but not "to whom": once the
  /// user had answered the chooser (0.2.62) the destination was nowhere on
  /// screen, so a wrong pick looked exactly like a right one. The first line now
  /// starts with 「发到 <设备名>」 (⇄ + text + 发送 / 取消, all in the old
  /// place), and a second, right-aligned 「改发到…」 appears **only when this host
  /// can actually re-point the draft** ([onRetargetDraft] != null) — and stays
  /// disabled while a send is being prepared, because the target must not move
  /// out from under an in-flight send (`canSend` is the same guard 发送 uses).
  ///
  /// Kept to existing theme tokens and compact controls, so the row adds no
  /// colour and does not disturb the composer geometry beyond its own height.
  Widget _shareDraftRow(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<String> paths = widget.sharedPaths;
    final bool canSend = widget.peer.canSend && !_preparing;
    final VoidCallback? onRetarget = widget.onRetargetDraft;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.swap_horiz,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _shareDraftLabel(paths),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              TextButton(
                onPressed: canSend ? () => unawaited(_sendShared()) : null,
                child: const Text('发送'),
              ),
              TextButton(
                onPressed:
                    canSend ? () => widget.onSharedDiscarded?.call() : null,
                child: const Text('取消'),
              ),
            ],
          ),
          if (onRetarget != null)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 4),
                child: OutlinedButton(
                  key: const ValueKey<String>('share-draft-retarget'),
                  // Same guard as 发送 / 取消: while a send is being prepared the
                  // draft is already being read, so its target may not change.
                  onPressed: canSend ? onRetarget : null,
                  style: OutlinedButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: const Size(0, kShareDraftRetargetHeight),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    side: BorderSide(color: theme.colorScheme.outlineVariant),
                    foregroundColor: theme.colorScheme.onSurfaceVariant,
                    textStyle: theme.textTheme.labelSmall
                        ?.copyWith(fontSize: kShareDraftRetargetFontSize),
                  ),
                  child: const Text('改发到…'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// What the 待发送 row says: `发到 手机 · clip.mp4`, or `发到 手机 · 3 个文件`.
  ///
  /// The destination is part of the sentence now (0.2.63): the user already
  /// answered 「发给谁」, and the row is the only place that answer is visible
  /// before pressing 发送.
  ///
  /// The single-file case names the file on purpose — the user just picked it in
  /// the gallery, and seeing the name is how they confirm the right thing came
  /// through.
  String _shareDraftLabel(List<String> paths) {
    final String target = _shareTargetName();
    if (paths.length == 1) {
      return '发到 $target · ${_baseNameOf(paths.first)}';
    }
    return '发到 $target · ${paths.length} 个文件';
  }

  /// The device name shown in the 待发送 row — this conversation's counterparty.
  ///
  /// No lookup on purpose: the row only ever draws for the draft bound to **this**
  /// conversation (`ShareIntake.draftFor`), so `widget.peer` *is* the target and
  /// the name is already in hand. The empty-alias fallback is the app's existing
  /// rule for naming a device (`detail_pane._peerName`: a fingerprint shortened
  /// the same way the rail shows it), not a second naming scheme.
  String _shareTargetName() {
    final String alias = widget.peer.alias;
    return alias.isEmpty ? shortFingerprint(widget.peer.fingerprint) : alias;
  }

  /// Sends the staged share through the normal path, then clears the draft.
  ///
  /// Guarded by the same `_preparing` flag the composer uses, so a double tap
  /// cannot start two sends of the same files.
  Future<void> _sendShared() async {
    final List<String> paths = widget.sharedPaths;
    if (paths.isEmpty || _preparing) {
      return;
    }
    setState(() {
      _preparing = true;
      _pickProgress = null;
      _copyDone = true; // the copy already happened before the draft existed
      _sendError = null;
    });
    try {
      await widget.controller.sendPaths(peer: widget.peer, paths: paths);
      widget.onSharedSent?.call();
      if (!mounted) {
        return;
      }
      await _probeSources();
    } catch (error) {
      if (mounted) {
        setState(() => _sendError = '发送失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _preparing = false;
          _pickProgress = null;
        });
      }
    }
  }

  /// The 未发送成功 banner above the composer, with 全部重试 and 忽略 (0.2.24 /
  /// 0.2.26).
  ///
  /// The defect it answers: one Wi-Fi drop leaves five `failed` bubbles, and the
  /// only way to clear them was five separate taps on each bubble's 重新发送.
  ///
  /// **0.2.26 — and it must be closable.** The first version offered 全部重试 and
  /// nothing else, which the user read as a bar that could only ever be obeyed
  /// ("只有全部重试没有取消按钮，我觉得这个不太好"). The ✕ is the 取消: it hides
  /// **this batch** and touches no message ([ConversationController
  /// .dismissUnsent]) — a failure that arrives later counts again and the bar
  /// comes back, so this is not a "never remind me" switch.
  ///
  /// **One line only**, built from existing theme tokens, so it adds no colour
  /// and does not disturb the composer geometry:
  /// `[16px icon] [label ……] [全部重试] [✕]`, where the label is the only
  /// flexible child (`Expanded` + ellipsis) so the two controls keep their full
  /// tap targets instead of being squeezed — measured from 320 dp up in
  /// `test/widget/retry_all_test.dart`. The ✕ is an `IconButton` rather than a
  /// second text button on purpose: 48 dp of glyph instead of ~80 dp of words is
  /// what keeps the narrow-phone row comfortable.
  ///
  /// While the run is live the label becomes 正在重新发送… with a small spinner
  /// and **both** controls go disabled: that is the "no double tap" half of the
  /// 0.2.24 fix, and it also stops a dismissal from racing the very batch it
  /// would be hiding.
  Widget _unsentRow(
    BuildContext context, {
    required int count,
    required bool retrying,
  }) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
      child: Row(
        children: <Widget>[
          // Same footprint either way (16 px), so the label does not jump
          // sideways when the run starts.
          SizedBox(
            width: 16,
            height: 16,
            child: retrying
                ? const Padding(
                    padding: EdgeInsets.all(2),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    Icons.error_outline,
                    size: 16,
                    color: theme.colorScheme.error,
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              retrying ? '正在重新发送…' : '$count 条没有发送成功',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          TextButton(
            // `null` disables the button *and* the ink, which is what makes a
            // second tap in the same frame a genuine no-op.
            onPressed: retrying ? null : () => unawaited(_retryAll()),
            child: const Text('全部重试'),
          ),
          IconButton(
            tooltip: '忽略',
            icon: const Icon(Icons.close),
            iconSize: 20,
            // No `VisualDensity.compact` on purpose: the density adjustment
            // shrinks the box below Material's 48 dp floor, and a 320 dp phone
            // is exactly where a 40 dp ✕ gets missed. The default 48×48 costs
            // the label ~10 dp of width and nothing else (measured in
            // `test/widget/retry_all_test.dart`, criterion 4).
            onPressed: retrying ? null : _dismissUnsent,
          ),
        ],
      ),
    );
  }

  /// Hides the banner for the batch it is currently showing (0.2.26).
  ///
  /// Deliberately silent — no snackbar: the row disappearing *is* the feedback,
  /// nothing was deleted (so there is nothing to warn about), and every message
  /// it was counting still carries its own 重新发送 in the timeline. A toast here
  /// would be a second voice saying the same thing.
  void _dismissUnsent() {
    widget.controller.dismissUnsent();
  }

  /// Re-sends every 未发送成功 message, then says what happened (0.2.24).
  ///
  /// The batch itself lives in the controller — `ConversationController
  /// .resendUnsent` — because it owns the serial loop, the skip judgement and
  /// the counters. This method only turns the result into one sentence, because
  /// the alternative (a silent button) is the defect class docs/18 §8.2 rules
  /// out: the user must learn whether the taps worked, and what was left behind.
  ///
  /// A **refused** result (another run was already going) says nothing at all:
  /// the button was disabled when it was tapped, and a snackbar for a tap on a
  /// disabled button is noise on top of noise.
  Future<void> _retryAll() async {
    final BulkResendResult result =
        await widget.controller.resendUnsent(peer: widget.peer);
    if (!mounted || result.refused) {
      return;
    }
    // The sources may have gone away mid-run (that is exactly the skip case),
    // so the bubbles' 源文件已不在 flags have to be re-read — the same probe the
    // single-message 重新发送 already runs.
    await _probeSources();
    if (!mounted) {
      return;
    }
    _toast(result.notice);
  }

  // ── multi-select UI (0.2.41) ─────────────────────────────────────────────

  /// The bar that replaces the top of the timeline while selecting:
  /// `取消 / 已选 N 条 / 全选`.
  ///
  /// It lives **inside the thread** instead of the shell's `AppBar`, so the mode
  /// is one widget's state and looks identical on a phone (where the thread is the
  /// whole body) and on the desktop (where it is the right pane). 取消 is on the
  /// left because that is the only thing there is to "go back" to.
  Widget _selectionBar(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int count = widget.controller.selectedCount;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: <Widget>[
          TextButton(
            key: const ValueKey<String>('selection-cancel'),
            onPressed: widget.controller.cancelSelecting,
            child: const Text('取消'),
          ),
          Expanded(
            child: Center(
              child: Text(
                '已选 $count 条',
                key: const ValueKey<String>('selection-count'),
                style: theme.textTheme.titleSmall,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey<String>('selection-all'),
            // Always enabled: 全选 with everything already picked is harmless, and a
            // disabled 全选 on an empty thread reads as a broken button.
            onPressed: widget.controller.selectAll,
            child: const Text('全选'),
          ),
        ],
      ),
    );
  }

  /// The batch toolbar that takes the composer's place while selecting.
  ///
  /// Two entries, exactly: 删除 (the error colour — it is the only destructive one)
  /// and 转发. Both are disabled at 0 picked messages rather than hidden, so the bar
  /// does not change height as the user picks and unpicks.
  Widget _selectionToolbar(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool enabled = widget.controller.selectedCount > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: FilledButton.tonalIcon(
              key: const ValueKey<String>('selection-delete'),
              onPressed: enabled ? () => _deleteSelected(context) : null,
              icon: const Icon(Icons.delete_outline, size: 20),
              label: const Text('删除'),
              style: FilledButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.tonalIcon(
              key: const ValueKey<String>('selection-forward'),
              onPressed: enabled ? () => _forwardSelected(context) : null,
              icon: const Icon(Icons.forward, size: 20),
              label: const Text('转发'),
            ),
          ),
        ],
      ),
    );
  }

  /// 删除 for the picked messages: the existing local delete, once per row.
  void _deleteSelected(BuildContext context) {
    final DeleteSelectionResult result = widget.controller.deleteSelected();
    _toast(result.notice);
  }

  /// 转发 for the picked messages: pick the devices, then re-send everything
  /// picked to each of them (0.2.41, **multi-device** since 0.2.46).
  ///
  /// The fan-out itself lives in the controller
  /// (`ConversationController.forwardSelectedToMany`) because it owns the serial
  /// loop and the per-device verdicts; this method only turns the report into one
  /// sentence. A dismissed picker returns an **empty** list, and that is a
  /// `return`, not a "forward to everybody" (criterion 4 of the 0.2.46 change).
  Future<void> _forwardSelected(BuildContext context) async {
    final List<ChatMessage> picked = widget.controller.selectedMessages;
    if (picked.isEmpty) {
      return;
    }
    final List<PeerDevice> targets = await showForwardTargetPicker(context);
    if (targets.isEmpty || !mounted) {
      return;
    }
    final ForwardBatchReport report =
        await widget.controller.forwardSelectedToMany(targets);
    if (!mounted) {
      return;
    }
    _toast(report.notice);
  }

  /// 转发到… for **one** message, straight from its own menu (0.2.46).
  ///
  /// Same three steps as [_forwardSelected] minus the multi-select detour: ask
  /// which devices (the picker is the same one, so a row means the same thing in
  /// both doors), fan out through the controller, say what each device did.
  ///
  /// Deliberately **not** routed through the selection: entering multi-select to
  /// forward one message would replace the timeline's chrome (the composer
  /// becomes 删除 / 转发) for an action that belongs to a single bubble, and it
  /// would leave the user in a mode they never asked for if the send failed. The
  /// two entries share the controller method instead of the mode.
  ///
  /// No source re-probe afterwards: a forward does not touch the local rows, and
  /// the only way it can affect this conversation is by discarding an Android
  /// temporary copy it just finished uploading — which is the same "the copy is
  /// gone, the message stays" state the bubble already reads on the next load.
  Future<void> _forwardMessage(ChatMessage message) async {
    final List<PeerDevice> targets = await showForwardTargetPicker(context);
    if (targets.isEmpty || !mounted) {
      return;
    }
    final ForwardBatchReport report = await widget.controller.forwardMessagesTo(
      messages: <ChatMessage>[message],
      targets: targets,
    );
    if (!mounted) {
      return;
    }
    _toast(report.notice);
  }

  /// The bottom composer (design §1.4 / PRD §1.4).
  ///
  /// The text field and the send button are **live** since docs/13 §7.3: the
  /// button is enabled exactly when the peer accepts and the composer holds
  /// non-whitespace text. A body over [kMaxTextBytes] shows a plain-language
  /// message and is never sent — honest, never a silent truncation.
  Widget _composer(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool canSend = widget.peer.canSend;
    // **One rule for "there is something to send"** (0.2.35): the 发送 button, the
    // desktop `Enter` and `_sendText`'s own guard all read [_canSubmit], so they
    // cannot drift apart. It reads the controller (not the cached [_hasText]),
    // because a key handler runs outside `build` and must see the current text.
    final bool canSubmit = _canSubmit;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (!canSend)
            // E6 / A2-15: a peer with no inbound server can never be sent to.
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Text(
                '对方当前不可接收',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          if (_overLimit)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Text(
                '文字过长（超过 ${kMaxTextBytes ~/ 1024}KB），请缩短后再发送',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          if (_preparing && _folderNote != null)
            // 0.2.33 — a folder send has no byte progress to show (the native
            // side copies N files and answers once), so it gets a plain
            // "working" line instead of a bar that would never move.
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Row(
                children: <Widget>[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _folderNote!,
                      style: theme.textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          if (_preparing && !_copyDone && _folderNote == null)
            // Android copies the picked file into app storage; a large video
            // takes seconds, so the wait is shown rather than silently frozen.
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Row(
                children: <Widget>[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _preparingLabel(),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          if (_preparing &&
              !_copyDone &&
              _folderNote == null &&
              (_pickProgress?.isLarge ?? false))
            // A heads-up, not a refusal: big files are allowed, just slow.
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Text(
                '文件较大（约 ${_megabytes(_pickProgress!.total)} MB），'
                '准备可能需要一会儿，请稍候',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          if (_sendError != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Text(
                _sendError!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          Row(
            children: <Widget>[
              // Still **one** attachment entry, not three icons: two of the old
              // three doors (image / video / file) were the same room with a
              // different filter (PRD §1.4 / user feedback). 0.2.33 adds a
              // genuinely different action — 「发送文件夹」 — so the single button
              // now opens a two-row menu instead of a second icon appearing on
              // the composer. One extra tap on the common path is the price of
              // not growing the composer again; the folder row only exists where
              // the platform can actually do it (no dead entry on Web).
              _attachMenu(canSend: canSend),
              // 「照片」 (0.2.53) — the gallery picker, one tap, right next to
              // the file door and **identical in size and shape** (both are plain
              // `IconButton`s: same 48 dp box, same icon slot). It is a second
              // button rather than a third row in the attachment menu because
              // photos are the one thing a phone sends constantly and the file
              // browser is the worst place to find them.
              //
              // **Built only where the platform has the bridge**
              // (`supportsPickMedia` — Android only, the same rule as
              // `supportsViewInDownloads`): the desktop entry point wires no
              // gallery channel, so building the button there would put a tap
              // that does nothing on the one screen this release must not touch.
              if (context.deps.platform.supportsPickMedia)
                _photoButton(canSend: canSend),
              Expanded(
                child: _composerKeys(
                  isMobile: context.deps.platform.isMobile,
                  child: TextField(
                    controller: _composerController,
                    enabled: canSend,
                    // A long message grows instead of hiding on one line
                    // (M5c §6). **A phone keeps `newline`**: its soft keyboard
                    // Enter still breaks the line and the 发送 button sends —
                    // 0.2.35 changes the desktop only.
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: '说点什么…',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(kRadiusInput),
                      ),
                    ),
                  ),
                ),
              ),
              // Live now: enabled exactly when the peer accepts and there is
              // text to send (blank / whitespace-only stays greyed out).
              IconButton(
                tooltip: '发送',
                icon: const Icon(Icons.send),
                onPressed: canSubmit ? () => unawaited(_sendText()) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Whether the text field currently holds something sendable: the peer accepts
  /// and the body is not blank/whitespace-only (0.2.35 — see [_composer]).
  bool get _canSubmit =>
      widget.peer.canSend && _composerController.text.trim().isNotEmpty;

  /// Desktop-only keyboard layer for the composer (0.2.35): **`Enter` sends,
  /// `Shift+Enter` breaks the line** — *"电脑上在输入框打字按 enter 是回车不是发送"*.
  ///
  /// **On a phone this returns [child] untouched**, so nothing about the mobile
  /// composer changes: the soft keyboard's Enter is still a newline and the 发送
  /// button is still the only way to send.
  ///
  /// **Why `Focus(onKeyEvent:)` and not `Shortcuts` + `Actions`.** The
  /// requirement that decides it is the **IME**. While a Chinese/Japanese
  /// composition is open, `Enter` belongs to the input method — it commits the
  /// candidate — so it has to reach the field. A `Shortcuts` mapping consumes the
  /// key *before* its action runs and an `Action` cannot un-consume it, so the
  /// commit would be swallowed and a half-typed message sent instead. Here the
  /// handler can answer `KeyEventResult.ignored`, which means "not mine — carry
  /// on down the chain", so the field, the IME and the platform behave exactly as
  /// they do today. That same "ignored" is what keeps `Shift+Enter` a newline.
  ///
  /// The node is `canRequestFocus: false`: it exists only to see key events on
  /// their way past. The text field still owns the focus, and still takes it on
  /// tap — this wrapper cannot be focused itself.
  Widget _composerKeys({required bool isMobile, required Widget child}) {
    if (isMobile) {
      return child;
    }
    return Focus(
      canRequestFocus: false,
      onKeyEvent: _handleComposerKey,
      child: child,
    );
  }

  /// The desktop composer's `Enter` rule — see [_composerKeys].
  ///
  /// The order of the three exits is the point:
  /// 1. **组词中 → ignored.** `TextEditingValue.composing.isValid` means an IME
  ///    composition is open, and Enter is how a Chinese user commits it. Sending
  ///    here would eat the commit *and* send a half-typed word — the exact bug
  ///    this guard exists to prevent;
  /// 2. **Shift+Enter → ignored**, i.e. the newline the user asked for;
  /// 3. **otherwise `Enter` is ours** → send once, on the press. `KeyRepeatEvent`
  ///    (a held key) is swallowed without sending again, and `KeyUpEvent` is
  ///    ignored — one press, one message.
  ///
  /// A blank/whitespace-only body still answers `handled`: pressing Enter there
  /// must do **nothing at all**, and "handled" is what stops the platform from
  /// leaving an empty line behind.
  KeyEventResult _handleComposerKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    // 1. The IME owns Enter while a composition is open.
    if (_composerController.value.composing.isValid) {
      return KeyEventResult.ignored;
    }
    // 2. Shift+Enter = 换行, handled by the field/platform as before.
    if (HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    // 3. Enter is the send key now. `Ctrl/Cmd+Enter` lands here too, which is a
    //    convenience rather than a promise.
    if (event is KeyDownEvent && _canSubmit) {
      unawaited(_sendText());
    }
    // Nothing to send (blank/whitespace) ⇒ swallow the key so it cannot insert
    // an empty line; the send above already cleared the field.
    return KeyEventResult.handled;
  }

  /// The attachment button: a menu with 「发送文件」 and, where supported,
  /// 「发送文件夹…」 (0.2.33).
  Widget _attachMenu({required bool canSend}) {
    final bool enabled = canSend && !_preparing;
    final bool supportsFolder = context.deps.platform.supportsSendFolder;
    return MenuAnchor(
      menuChildren: <Widget>[
        MenuItemButton(
          leadingIcon: const Icon(Icons.insert_drive_file_outlined, size: 18),
          onPressed: enabled ? () => unawaited(_send(FileKind.any)) : null,
          child: const Text('发送文件'),
        ),
        if (supportsFolder)
          MenuItemButton(
            leadingIcon: const Icon(Icons.folder_outlined, size: 18),
            onPressed: enabled ? () => unawaited(_sendFolder()) : null,
            child: const Text('发送文件夹…'),
          ),
      ],
      builder: (BuildContext context, MenuController controller, Widget? child) {
        return IconButton(
          tooltip: '发送附件',
          icon: const Icon(Icons.attach_file),
          onPressed: enabled
              ? () => controller.isOpen ? controller.close() : controller.open()
              : null,
        );
      },
    );
  }

  /// The 「照片」 button (0.2.53) — open the system **gallery** picker and send
  /// what comes back.
  ///
  /// Enabled on exactly the same terms as the attachment button ([canSend] and
  /// not already preparing), because the two doors end in the same place: while
  /// a send is being hashed or copied, a second picker would only queue a second
  /// send against the same peer.
  ///
  /// The `tooltip` is the label: on a phone it is the long-press hint, and it is
  /// also what a screen reader announces (an `IconButton` with no text child has
  /// no other name).
  Widget _photoButton({required bool canSend}) {
    final bool enabled = canSend && !_preparing;
    return IconButton(
      tooltip: '照片',
      icon: const Icon(Icons.photo_library_outlined),
      onPressed: enabled ? () => unawaited(_sendMedia()) : null,
    );
  }

  /// 「发送文件夹」 (0.2.33): pick a folder, show **what will be sent**, then send.
  ///
  /// The confirmation is not ceremony. A folder is the first affordance in this
  /// app that can move hundreds of files with one tap, and the numbers (how
  /// many, how big, what was skipped) are exactly what the user needs *before*
  /// the receiver starts buzzing. The pick itself can also be slow — Android
  /// copies every file into the app cache before answering — so `_folderNote`
  /// keeps a caption on screen for that whole span.
  ///
  /// Every failure ends **without sending and without changing anything**:
  /// cancelled is silent, and the other four outcomes say what happened.
  ///
  /// This is the **attach-menu door**; a dropped folder is the second one
  /// ([_sendDroppedFolder]). Both end in [_runFolderSend] — the only place a
  /// folder is confirmed and sent (0.2.36).
  Future<void> _sendFolder() => _runFolderSend(
        obtain: () => context.deps.platform.pickFolderForSending(),
      );

  /// A folder **dropped on the conversation** (0.2.36) — the second door into
  /// [_runFolderSend].
  ///
  /// Only the way the path arrives differs: here the app already has it, so the
  /// platform is asked to describe *that* directory
  /// ([PlatformPorts.describeFolderForSending]) instead of opening a chooser.
  /// The walk and its limits are the same code, which is the whole reason the
  /// port method exists.
  Future<void> _sendDroppedFolder(String path) => _runFolderSend(
        obtain: () => context.deps.platform.describeFolderForSending(path),
      );

  /// **One folder send**: obtain the selection, confirm it, send it — shared by
  /// the attach menu and by a drop (0.2.36).
  ///
  /// [obtain] is the only thing that differs between the two doors, and it is a
  /// callback rather than a boolean so nothing here has to know which door it
  /// came from.
  Future<void> _runFolderSend({
    required Future<SendFolderSelection> Function() obtain,
  }) async {
    if (_preparing) {
      return;
    }
    setState(() {
      _preparing = true;
      _pickProgress = null;
      _copyDone = true; // no byte-progress bar: the note below replaces it
      _folderNote = '正在读取文件夹…';
      _sendError = null;
    });
    try {
      final SendFolderSelection selection = await obtain();
      if (!mounted) {
        return;
      }
      switch (selection.outcome) {
        case PickSendFolderOutcome.cancelled:
          // Same rule as cancelling a file pick: the user changing their mind is
          // not something to announce.
          return;
        case PickSendFolderOutcome.unsupported:
          _toast('这个系统不能选择文件夹');
          return;
        case PickSendFolderOutcome.empty:
          _toast(_emptyFolderMessage(selection));
          return;
        case PickSendFolderOutcome.tooMany:
          _toast(_tooManyFilesMessage(selection));
          return;
        case PickSendFolderOutcome.failed:
          _toast('选择文件夹失败：${selection.reason ?? '未知原因'}');
          return;
        case PickSendFolderOutcome.picked:
          setState(() => _folderNote = null);
          final bool confirmed = await _confirmFolderSend(selection);
          if (!confirmed || !mounted) {
            return;
          }
          setState(() {
            _copyDone = false;
            _folderNote = '正在发送 ${selection.fileCount} 个文件…';
          });
          await widget.controller.sendPaths(
            peer: widget.peer,
            paths: selection.paths,
            // 0.2.38 — the two optional parameters, and the **only** place in the
            // UI that passes them (`:491` drag-in and `:1034` share-import stay
            // untouched, which is what keeps an ordinary multi-select a flat
            // send). `relativePaths` is `null` when the platform could not
            // determine positions; `sendPaths` then sends flat and declares no
            // folder, so a degraded pick still delivers every file.
            relativePaths: selection.relativePaths,
            folderName: selection.folderName,
          );
          if (!mounted) {
            return;
          }
          await _probeSources();
      }
    } catch (error) {
      if (mounted) {
        setState(() => _sendError = '发送失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _preparing = false;
          _pickProgress = null;
          _folderNote = null;
        });
      }
    }
  }

  /// The confirmation sheet: **how many, how big, what was skipped**.
  ///
  /// Skipped counts are shown only when non-zero: a line of zeroes is noise, and
  /// a quiet "跳过 0 个" would make the real skips less noticeable.
  Future<bool> _confirmFolderSend(SendFolderSelection selection) async {
    if (!mounted) {
      return false;
    }
    final List<String> notes = <String>[
      if (selection.skippedHidden > 0) '跳过 ${selection.skippedHidden} 个隐藏项',
      if (selection.skippedEmpty > 0) '跳过 ${selection.skippedEmpty} 个空文件',
      if (selection.skippedTooDeep > 0)
        '另有 ${selection.skippedTooDeep} 个更深层的文件夹没有展开',
      // CR-2 ② — the one skip that used to be invisible *and* fatal: a path the
      // receiver cannot place used to make it answer `400` for the whole batch,
      // so nothing was sent and nothing was explained. Now the file is dropped
      // here and the reason is on screen, next to the number it cost.
      if (selection.skippedPathTooLong > 0)
        '跳过 ${selection.skippedPathTooLong} 个文件（路径太长，对方存不下）',
      if (selection.failedCopies > 0)
        '其中 ${selection.failedCopies} 个文件没能读取，已跳过',
    ];
    final String? name = selection.folderName;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(name == null ? '发送整个文件夹？' : '发送「$name」？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '将发送 ${selection.fileCount} 个文件，'
              '共 ${_sizeText(selection.totalBytes)}',
            ),
            for (final String note in notes)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  note,
                  style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                        color: Theme.of(dialogContext)
                            .colorScheme
                            .onSurfaceVariant,
                      ),
                ),
              ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// 「这个文件夹里有 N 个文件，超过一次发送的上限」 — and **nothing is sent**.
  ///
  /// No truncation on purpose: sending 200 of 300 without saying so would look
  /// exactly like "everything arrived", and the user would only discover the gap
  /// on the other side.
  String _tooManyFilesMessage(SendFolderSelection selection) {
    final String count =
        '${selection.availableCount}${selection.countCapped ? '+' : ''}';
    return '这个文件夹里有 $count 个文件，'
        '超过一次发送的上限（$kFolderSendMaxFiles 个），请分几次发送';
  }

  /// 「这个文件夹里没有可发送的文件」 — with the skip counts, when there are any.
  String _emptyFolderMessage(SendFolderSelection selection) {
    final List<String> skips = <String>[
      if (selection.skippedHidden > 0) '${selection.skippedHidden} 个隐藏项',
      if (selection.skippedEmpty > 0) '${selection.skippedEmpty} 个空文件',
      // The whole folder can be empty *because* every path was too long for the
      // receiver. Saying only "nothing to send" would describe the symptom.
      if (selection.skippedPathTooLong > 0)
        '${selection.skippedPathTooLong} 个文件路径太长',
    ];
    final String base = '这个文件夹里没有可发送的文件';
    return skips.isEmpty ? base : '$base（已跳过 ${skips.join('、')}）';
  }

  /// A short notice for the outcomes that need one.
  ///
  /// It goes through [showTransientNotice] (0.2.36) like every other notice in the
  /// app, and passes [kComposerNoticeInset] because this is the one surface where
  /// a bottom-anchored snackbar used to land **on the composer**.
  void _toast(String message) {
    if (!mounted) {
      return;
    }
    showTransientNotice(
      context,
      message,
      bottomInset: kComposerNoticeInset,
    );
  }

  /// `34.5 MB` / `820 KB` / `512 B` — sizes here are folder totals, so whole
  /// megabytes would round a 3-photo folder to "0 MB".
  String _sizeText(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).round()} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Sends the composer's text (docs/13 §7.3). A blank body is a no-op; an
  /// over-limit body is refused here too (the hint is already on screen) so a
  /// too-long message is never truncated or sent.
  ///
  /// **★ 0.2.48 — a failed send must not eat what the user typed.** This method
  /// used to be
  ///
  /// ```dart
  /// _composerController.clear();                       // first
  /// await widget.controller.sendText(...);             // may throw
  /// ```
  ///
  /// called through `unawaited(...)`, so any exception from the dispatch
  /// (`recordOutgoingText` on a broken database, a store write that throws after
  /// the frame left) became an **unhandled async error**: the field was already
  /// empty, the draft had already been cleared inside the controller, no bubble
  /// existed — and the user's paragraph was simply gone, with nothing on screen
  /// to say so. File sends never had this shape (they `try`/`catch` and put the
  /// reason in [_sendError]); this is the text path catching up.
  ///
  /// The order is therefore inverted, and both halves are needed:
  ///  * the text is only cleared **after** the dispatch succeeded — so on a throw
  ///    the field still holds it (and the controller no longer clears the draft
  ///    before dialling, see `ConversationController.sendText`), which is also
  ///    what keeps 「换个会话再回来」 from losing it;
  ///  * it is only cleared when the field **still holds exactly what was sent**.
  ///    The round trip takes time and the composer stays editable during it, so a
  ///    blanket `clear()` after the `await` would delete whatever the user typed
  ///    meanwhile — trading one swallowed message for another.
  ///
  /// [_sendingText] covers the third consequence of the inversion: with the text
  /// still in the field, `_canSubmit` is still true, and a second `Enter` would
  /// send the same sentence again.
  Future<void> _sendText() async {
    if (_sendingText) {
      return;
    }
    final String text = _composerController.text;
    if (text.trim().isEmpty) {
      return;
    }
    if (utf8.encode(text).length > kMaxTextBytes) {
      return;
    }
    _sendingText = true;
    try {
      await widget.controller.sendText(peer: widget.peer, text: text);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      // The field was never cleared, so there is nothing to put back — say what
      // happened and leave the caret where the user left it.
      setState(() => _sendError = '发送失败：$error');
      return;
    } finally {
      _sendingText = false;
    }
    if (!mounted) {
      return;
    }
    if (_composerController.text == text) {
      _composerController.clear();
    }
    if (_sendError != null) {
      setState(() => _sendError = null);
    }
  }

  /// The composer's caption while a picked file is being prepared.
  String _preparingLabel() {
    final FilePickProgress? progress = _pickProgress;
    if (progress == null) {
      return '正在准备选中的文件…';
    }
    final double? fraction = progress.fraction;
    final String percent =
        fraction == null ? '' : ' ${(fraction * 100).round()}%';
    final String size =
        progress.total > 0 ? '（约 ${_megabytes(progress.total)} MB）' : '';
    return '正在准备选中的文件…$percent$size';
  }

  /// Whole megabytes of [bytes], for a human label.
  int _megabytes(int bytes) => (bytes / (1024 * 1024)).round();

  Future<void> _send(FileKind kind) => _runPickSend(
        () => widget.controller.pickAndSend(peer: widget.peer, kind: kind),
      );

  /// 「照片」 (0.2.53) — the gallery door.
  ///
  /// The **same** wrapper as [_send]: the caption, the progress, the error and
  /// the cleanup after a send are not copied here, they are shared, so a photo
  /// batch can never behave differently from a file batch.
  Future<void> _sendMedia() => _runPickSend(
        () => widget.controller.pickAndSendMedia(peer: widget.peer),
      );

  /// Runs one picker→send flow behind the composer's preparing state (0.2.53 —
  /// extracted from [_send] so both doors share it verbatim).
  ///
  /// [send] is the controller call; everything around it is the same for both:
  /// * a second tap while one is running is ignored (`_preparing`);
  /// * a cancelled pick (`null`) still comes back through the `finally`, so the
  ///   preparing caption disappears and nothing is left on screen;
  /// * a failed pick **says why** ([FilePickException]) instead of looking like a
  ///   dead button.
  Future<void> _runPickSend(Future<SendOutcome?> Function() send) async {
    if (_preparing) {
      return;
    }
    setState(() {
      _preparing = true;
      _pickProgress = null;
      _copyDone = false;
      _sendError = null;
    });
    try {
      await send();
      if (!mounted) {
        return;
      }
      await _probeSources();
    } on FilePickException catch (error) {
      // A failed pick must say so — never look like "nothing happened".
      if (mounted) {
        setState(() => _sendError = error.message);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _sendError = '发送失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _preparing = false;
          _pickProgress = null;
        });
      }
    }
  }

  Future<void> _resend(ChatMessage message) async {
    await widget.controller.resend(peer: widget.peer, message: message);
    if (!mounted) {
      return;
    }
    await _probeSources();
  }

  /// Cancels [message] and says what happened (0.2.22).
  ///
  /// The bubble already turns into 已取消 on success (the status chip), so the
  /// snackbar is aimed at the **other** outcome: a tap that could not be acted
  /// on now explains itself instead of looking like a dead button — and it is
  /// brief on purpose, because on success the status chip is the durable record.
  Future<void> _cancel(ChatMessage message) async {
    final CancelResult result = await widget.controller.cancel(message);
    if (!mounted) {
      return;
    }
    _toast(result.notice);
  }

  /// The one-line reason under a failed bubble, or `null` (0.2.22).
  ///
  /// Only a cause this app can **name** is shown. A stored `error` is usually a
  /// raw exception string (`SocketException: Connection reset by peer…`) — that
  /// is a diagnostic for the log, not an answer for the user, and the status chip
  /// already says 失败. 连接中断 is the case worth naming out loud: nothing is
  /// wrong with the file or the peer's answer, the link simply went away, and the
  /// right next move (walk closer, wake the phone, retry) is different.
  ///
  /// ★ 0.2.52 — **a vanished source file is the second nameable cause, and the
  /// one that had no copy at all.** A queued message is kept across a restart on
  /// purpose; until 0.2.52 the launch sweep deleted its copy in
  /// `cache/lanlink-picked/` at the very next boot, so the resume could only fail
  /// — and it failed with a raw `FileSystemException` string, which this function
  /// deliberately refuses to print. The bubble therefore said 「失败」 and nothing
  /// else about a message **we** had made unsendable.
  ///
  /// [sourceGone] is that cause, and it is the **shared disk judgement** the
  /// bubble already draws its red icon from (`SourceAvailability`, computed once
  /// per message in `_buildItem`) rather than a second `exists` call here — one
  /// answer, one rule. It is consulted only for a `failed` message, so a delivered
  /// one whose copy we cleaned up after sending is untouched (that is
  /// `sourceCleanedByUs`'s business, and it draws nothing).
  String? _failureNote(
    ChatMessage message,
    TransferProgress? progress, {
    required bool sourceGone,
  }) {
    if (message.status != MessageStatus.failed) {
      return null;
    }
    if (progress?.error == kStalledError) {
      return '连接中断，对方一直没有回应';
    }
    // The pump's own reason (0.2.52) — read from the stored row when a transfer
    // row exists, and from the disk judgement when it does not (`markSendFailed`
    // can only write the reason into transfer rows that already exist, so a
    // queued message that never started has none).
    if (progress?.error == kSourceMissingError || sourceGone) {
      return '原文件已被清理，无法发送 — 请重新发送';
    }
    return null;
  }

  /// The sentence under a **received** file that could not be exported, or
  /// `null` (0.2.23).
  ///
  /// Before this, a failed export to `下载` was invisible: `publishTransfer`
  /// only replaced the recorded path, the row still landed at `done`, and the
  /// bubble said 已完成 — so on Android the user was told the file had arrived in
  /// 下载 while it was actually in the app's private directory. The record now
  /// carries the reason ([ReceivedTransfer.publishError] → the transfer row's
  /// `error`, see `SessionStore.recordIncomingFile`), and this is the one place
  /// it is turned into copy.
  ///
  /// It has to say **three** things at once, because all three are true and any
  /// one of them missing leaves the user stuck: the file *was* received; it is
  /// **not** in 下载; and 分享 still gets it out of the app.
  ///
  /// Deliberately scoped to `done` + `incoming`: a failed **send** has its own
  /// note ([_failureNote]), and an outgoing message never carries a
  /// `publishError` at all.
  String? _publishNote(ChatMessage message, TransferProgress? progress) {
    if (message.direction != MessageDirection.incoming ||
        message.status != MessageStatus.done) {
      return null;
    }
    if (progress?.error == null) {
      return null;
    }
    return '已收到，但没能导出到「下载」— 文件在应用内部，可用分享取出';
  }

  /// The timeline's entry point for 「打开」 one attachment.
  void _openFile(FileAttachment file) => unawaited(_openAttachment(file));

  /// Opens one attachment — and **answers when it cannot** (0.2.48).
  ///
  /// The defect it answers: this used to be three lines that called
  /// `context.deps.platform.openFile(path)` through `unawaited(...)`, with no
  /// `exists` pre-check and no `try`. A tap on a file that was no longer there
  /// therefore did **nothing visible on either platform**:
  ///  * Android's bridge answers `result.error("open_missing", …)` for a path it
  ///    cannot open, and the Dart side of that channel only swallows
  ///    `MissingPluginException` — so the error lands in the zone and nowhere
  ///    else;
  ///  * Windows runs `explorer <path>` with a path that does not exist: no
  ///    exception, no window, no complaint.
  ///
  /// And this is **not an edge case**: on Android a picked/shared file is a
  /// *cache copy* that is deleted once the send succeeds
  /// (`PlatformPorts.discardPickedCopy`), while the attachment row keeps pointing
  /// at it — so every successfully sent file is in this state.
  ///
  /// The behaviour matches the attachment menu (`attachment_menu.dart`), which has
  /// always greyed 「打开」 out and reported a failure out loud: a file we can prove
  /// is missing is **marked** (the row dims to 「源文件不可用」 through the shared
  /// [SourceAvailability]) and the tap says why; a file that is there opens exactly
  /// as before, and a platform that refuses is reported instead of vanishing.
  /// Nothing here decides *whether* a file exists — [SourceAvailability] does.
  ///
  /// **0.2.59 — the body is now the one shared implementation**
  /// (`ui/widgets/open_local_path.dart`), because the 文件 tab and the 设备墙 need
  /// the same three answers and a second copy of them is how the wording and the
  /// `markGone` write would drift. What stays here is what is genuinely this
  /// surface's: **which** `SourceAvailability` is written (this thread's) and how
  /// to repaint it (this `State`). The three sentences are unchanged.
  Future<void> _openAttachment(FileAttachment file) => openLocalPath(
        context,
        path: file.localPath,
        sources: _sources,
        onRepaint: () => setState(() {}),
      );

  /// 0.2.45 — hands [files] to the OS as a **copy-only** drag, then re-checks
  /// them (criterion: 拖出去之后源文件还在).
  ///
  /// Four steps, and the order is the whole design:
  ///
  /// 1. **Only the files that are still on disk become the payload.** A path the
  ///    shell cannot read is a drag the user performs and nothing happens — worse
  ///    than no drag at all, because he has no way to tell that from "the other
  ///    program refused it". If *none* of them is left, the drag is not started and
  ///    the reason is said out loud.
  /// 2. **The platform runs the drag.** It blocks until he lets go (`DoDragDrop`'s
  ///    modal loop), which is why this is a callback and not a build-time call.
  /// 3. **The paths are probed again.** We asked for a copy only, but the *target*
  ///    decides what it does with the files it was given, and a moved file breaks
  ///    every action this row still offers (打开 / 打开所在位置 / 重新发送). The one
  ///    thing we can do about it is notice: the path is recorded in the shared
  ///    judgement ([SourceAvailability.markGone], so re-entering the thread
  ///    re-reads the disk and the 文件 tab / 最近文件 page reach the same verdict),
  ///    and the row itself falls back to 「源文件不可用」 **where that is news**
  ///    (0.2.49 — `MessageBubble._sourceWarning`: the file is gone and *we* are not
  ///    the ones who removed it; a cache copy this app freed after a successful
  ///    send is not a loss, and the desktop's "the user deleted their source" is).
  /// 4. **The effect is read exhaustively** through `parseDragOutEffect`: `copy`
  ///    and `none` / `canceled` are silent (the user saw what happened), and
  ///    anything else — a `move` the runner should never produce, an unregistered
  ///    channel, a failed OLE init — is reported as **failure**, never folded into
  ///    "nothing happened".
  Future<void> _dragOutFiles(
    ChatMessage message,
    List<FileAttachment> files,
  ) async {
    final PlatformPorts platform = context.deps.platform;
    // Captured before the first `await`: the drag can outlive this frame, and
    // `ScaffoldMessenger.of(context)` on a dead element throws.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    final List<String> paths = <String>[];
    for (final FileAttachment file in files) {
      final String? path = file.localPath;
      if (path == null || path.isEmpty) {
        continue;
      }
      if (await platform.exists(path)) {
        paths.add(path);
      }
    }
    if (!mounted) {
      return;
    }
    if (paths.isEmpty) {
      // Step 1's dead end: nothing to drag. Say so — silently doing nothing is
      // exactly the "拖不动的拖动" this guard exists to prevent.
      showTransientNoticeOn(
        messenger,
        '源文件已不在本地，无法拖出',
        bottomInset: kComposerNoticeInset,
      );
      return;
    }

    // Step 2 and 4: the platform's answer, held as a value so the exhaustive
    // switch at the end is the only place that reads it.
    DragOutEffect? effect;
    String? notice;
    try {
      effect = await platform.startDrag(paths);
    } on DragOutException catch (error) {
      // A `move` answer, a missing channel, a failed OLE init: a **failure**, and
      // never folded into "nothing happened". The exception's message names the
      // cause ("只允许复制，系统却报告了 move"); the prefix says what it means.
      notice = '拖出失败：${error.message}';
    } on Object catch (error) {
      notice = '拖出失败：$error';
    }
    if (!mounted) {
      return;
    }

    final List<String> vanished = <String>[];
    for (final String path in paths) {
      if (!await platform.exists(path)) {
        vanished.add(path);
      }
    }
    if (!mounted) {
      return;
    }
    if (vanished.isNotEmpty) {
      // The target did what we asked it not to. Nothing here can undo it, but the
      // row must stop claiming the file is there — and so must every other
      // surface, which is why this marks the **path** in the shared judgement
      // rather than a message id in this `State` (0.2.48: the old field died with
      // the State, so a tab switch brought the row back looking healthy).
      for (final String path in vanished) {
        _sources.markGone(path);
      }
      setState(() {});
      // 0.2.49: the sentence no longer promises 「该附件已标记为源文件不可用」 —
      // that is now the *bubble's* call and it is deliberately false for a `done`
      // outgoing message (see `MessageBubble._lossIsRoutine`: a completed send's
      // missing source is the routine cache cleanup, not a mark). What is true of
      // every row this can happen to is that the file can no longer be opened.
      notice = '拖出后源文件不在了（可能被移走），该附件已无法打开';
    }
    if (notice != null) {
      showTransientNoticeOn(
        messenger,
        notice,
        bottomInset: kComposerNoticeInset,
      );
      return;
    }
    // `parseDragOutEffect` already refused every word this app does not allow (a
    // `move` throws above, so it cannot reach here), so all three survivors are
    // **silent**: the user watched the file land, watched it drop on nothing, or
    // pressed Esc. The switch has no `default` on purpose — a future fourth value
    // would break the build right here instead of being quietly ignored.
    switch (effect!) {
      case DragOutEffect.copy:
      case DragOutEffect.none:
      case DragOutEffect.canceled:
        return;
    }
  }

  /// Opens the **directory page** for a folder message (0.2.38 / T05).
  ///
  /// One push for both surfaces: the thread is the same widget in the phone shell
  /// and in the desktop's right pane, so there is exactly one way in
  /// (`docs/22` §5.2). The page reads the message's files itself — a folder is a
  /// snapshot of one send, and a page that outlives the conversation's controller
  /// must not depend on it.
  void _openFolder(ChatMessage message) {
    if (!message.isFolder) {
      return;
    }
    unawaited(Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FolderBrowsePage(
          message: message,
          subtitle: widget.peer.alias,
        ),
      ),
    ));
  }

  /// Re-reads **every** attachment of this conversation from disk (0.2.48).
  ///
  /// Until this release the probe was narrower on purpose and wrong in effect:
  /// it walked the history, kept the messages that were `outgoing` **and**
  /// `failed`/`canceled`, and asked `canResend` about each — so a file that went
  /// away under a `done` message was never noticed, even though the 最近文件 page
  /// (which probes everything) had already told the user it was gone. One file,
  /// two verdicts.
  ///
  /// The probe now asks the only question that all three surfaces can share — is
  /// the path on disk — and does it through [SourceAvailability] so the rule
  /// cannot drift again. `canResend` keeps its own job (a *resend* is only legal
  /// for `failed`/`canceled`); it is no longer the existence oracle as well.
  ///
  /// Called when the thread mounts and after every send / cancel / retry, the
  /// same moments as before.
  ///
  /// **0.2.50 — it now judges only what is new, and rebuilds only if it judged
  /// something.** See [_probedPaths] for the measurement. Both halves matter:
  /// the stats are what the batch is charged for, and the trailing `setState`
  /// was a **second** full rebuild of the timeline per arriving file (the
  /// arriving message had already rebuilt it once).
  Future<void> _probeSources() async {
    final PlatformPorts platform = context.deps.platform;
    final List<ChatMessage> messages =
        widget.controller.messages.valueOrNull ?? const <ChatMessage>[];
    final List<FileAttachment> fresh = <FileAttachment>[];
    for (final ChatMessage message in messages) {
      final List<FileAttachment>? more = _unjudgedFiles(message);
      if (more != null) {
        fresh.addAll(more);
      }
    }
    if (fresh.isEmpty) {
      // Nothing new to ask: no stat, and no `setState` — an arrival that adds
      // nothing new must not cost a repaint of the whole thread.
      return;
    }
    await _sources.probeFiles(fresh, platform);
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  /// The attachments of [message] that [_sources] has **not** been told about
  /// yet, or `null` when there is nothing new to judge.
  ///
  /// Two things can be new:
  ///
  /// * the message itself — its id has never been seen by this thread;
  /// * a **folder** message that is still arriving: the store appends every file
  ///   of a session to the same message id, so the id alone does not change.
  ///   `folderFiles` is the sender's *declared* count, so "declared > judged" is
  ///   the honest "more may still come"; a declared count of 0 (unknown, e.g. a
  ///   descriptor that carried none) is treated the same way, and costs only
  ///   that one message's read, never the conversation's.
  ///
  /// Paths are de-duplicated through [_probedPaths]: a re-sent file reuses its
  /// path, and one `exists` per distinct path is what the 最近文件 page already
  /// did for the whole database.
  List<FileAttachment>? _unjudgedFiles(ChatMessage message) {
    final int judged = _probedAttachments[message.id] ?? -1;
    final bool unseen = judged < 0;
    final bool folderStillArriving = message.isFolder &&
        (message.folderFiles <= 0 || judged < message.folderFiles);
    if (!unseen && !folderStillArriving) {
      return null;
    }
    final List<FileAttachment> files = widget.controller.filesOf(message.id);
    _probedAttachments[message.id] = files.length;
    final List<FileAttachment> fresh = <FileAttachment>[];
    for (final FileAttachment file in files) {
      final String? path = file.localPath;
      if (path == null || path.isEmpty) {
        continue;
      }
      if (_probedPaths.add(path)) {
        fresh.add(file);
      }
    }
    return fresh;
  }
}

/// One message row that is **built**, as the reveal loop needs it (0.2.59).
///
/// Two numbers and nothing else: where the row sits in the timeline's `children`,
/// and the scroll offset at which it would be flush with the viewport's leading
/// edge. Together they are a fixed point a dead reckoning can start from — see
/// `_ConversationThreadState._estimateOffsetFor`.
class _MeasuredRow {
  const _MeasuredRow({required this.index, required this.topOffset});

  /// The row's index in the timeline's `children` (0-based).
  final int index;

  /// The scroll offset that puts this row's leading edge at the viewport's.
  final double topOffset;
}

/// A local-day divider in the timeline (A2-6).
/// One `HH:mm` above a message, aligned to that message's side (docs/19 §9-B).
///
/// Same type ramp as [_DateSeparator] — the two read as one timeline device, not
/// as two different kinds of label. On the desktop an incoming bubble carries a
/// [kMessageAvatar]-wide avatar to its left, so the label is nudged past it to
/// sit over the bubble rather than over the gutter.
class _TimeLabel extends StatelessWidget {
  const _TimeLabel({required this.label, required this.outgoing});

  final String label;
  final bool outgoing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool desktop = !context.deps.platform.isMobile;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Align(
        alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.only(
            left: (!outgoing && desktop) ? kMessageAvatar + 6 : 0,
          ),
          child: Text(
            label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

class _DateSeparator extends StatelessWidget {
  const _DateSeparator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Text(
          label,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// The last path segment, handling both separators (no `path` package, §7).
///
/// Used by the 待发送 row to name a shared file. The same rule as
/// `conversation_controller.dart::_baseName`, kept local because that one is
/// private to the controller layer and re-exporting it would make the UI depend
/// on a controller's internals.
String _baseNameOf(String path) {
  final int slash = path.lastIndexOf('/');
  final int backslash = path.lastIndexOf(r'\');
  final int cut = slash > backslash ? slash : backslash;
  return cut >= 0 ? path.substring(cut + 1) : path;
}
