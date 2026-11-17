/// A message bubble: `out` right / `in` left, one row per file, an inline image
/// thumbnail, inline progress and the resend / cancel actions (spec §2).
///
/// The bubble is a **pure view**: it takes a [ChatMessage], its
/// [FileAttachment]s and an optional [TransferProgress], and reports intent
/// through [onResend] / [onCancel] / [onOpenFile]. It subscribes to nothing and
/// owns no state, so a page or a widget test can drive any of the seven states
/// by constructing the models directly (spec §8.8: assert behaviour, not
/// implementation).
///
/// **Skin (PRD §2.4):** `out` is the brand container, `in` the surface container;
/// both are radius [kRadiusCard] with a 4px "tail" corner on the sender's side,
/// capped at [kBubbleMaxWidthFactor] of the pane. Image attachments render a
/// [FileThumbnail] (one image up to 240×240 **keeping its own ratio**, or a
/// 3-column 96px square grid for several — PRD §5) **with the file name in a
/// one-line caption underneath**, so an image attachment never hides which file
/// it is (A2-3 / E3 / E11); any non-image attachment keeps the [FileTile] row.
///
/// Which action is offered is derived from the frozen [MessageStatus] set:
/// `pending` / `awaitingConfirm` / `transferring` may be canceled — and since
/// 0.2.22 every one of those really cancels (the controller used to refuse the
/// two in-flight ones, which made the button dead in exactly the case the user
/// reaches for it); `failed` / `canceled` offers resend, **disabled while the
/// source file is provably gone** ([sourceUnavailable], A2-18). Date separators
/// are **not** drawn here; the conversation thread owns the timeline (A2-6).
///
/// **「文件没了」 and 「这是我们自己删的」 are two different facts (0.2.49).**
/// [sourceUnavailable] is only the disk: *at least one of this message's
/// attachments is not at its `localPath`*. Whether that is **bad news** is the
/// second question, and the answer is **who removed it** — never the message's
/// status:
///
/// | who removed it | [sourceCleanedByUs] | what the bubble draws |
/// |---|---|---|
/// | we did — the Android post-send cache cleanup | `true` | **nothing**: a plain, completed bubble |
/// | the user / another program (desktop, a moved file, a photo deleted from 下载) | `false` | 源文件不可用 + red link-off, and — on `failed` / `canceled` only — a greyed 重新发送 |
///
/// A `done` row never gets the button: `canResend` refuses anything that is not
/// `failed` / `canceled`, so on a delivered message it could only ever be pressed
/// zero times. The loss it would have described is already on screen twice (the red
/// mark and 「源文件不可用」).
///
/// The first row is the defect this split fixes. On Android a picked or shared
/// file is a **cache copy** that is deleted as soon as the send succeeds
/// (`PlatformPorts.discardPickedCopy` → `ConversationController._discardPickedCopies`),
/// so *every* successfully sent file leaves its attachment pointing at a path
/// that is gone. Judged with the bare disk fact — which is what 0.2.48 did — a
/// mere **cleanup** painted a red broken-link icon next to 「已完成」 and a
/// greyed-out 重新发送 under it, on every file the user had ever sent:
/// *"发送成功后，已完成旁边却会显示离线的那个红色图标，下面还有重新发送。"*
///
/// **Status is deliberately not the switch.** 0.2.49's first attempt keyed this
/// on `outgoing && done`, which silences the *real* loss too: delete your own
/// source file on the desktop after sending it and the bubble says nothing. The
/// honest reason "a `done` file is gone" is routine is that *we* are the ones who
/// deleted it — so that is what the caller reports
/// (`ConversationController.discardedByUs`), and the status plays no part.
/// [SourceAvailability] keeps answering the disk question for the surfaces that
/// genuinely need it (文件 tab / 最近文件 / 设备资料墙: *"this file cannot be opened
/// now"* is the right thing to say there, whatever removed it); the **warning**
/// is drawn here.
///
/// **Text is selectable (0.2.28).** A text message's body is a real selectable
/// paragraph (`SelectionArea` over the plain [Text], see [_textBody]) — mouse
/// drag + `Ctrl+C` on the desktop, long press + handles + the copy toolbar on a
/// phone — and the right-click 「复制文字」 of 0.2.27 stays as the one-gesture
/// "copy the whole message". A file bubble is untouched by all of this.
///
/// Layering (M4 §8.1): `ui/**` imports only `package:flutter/**` and this
/// package's `domain/**`; never `lanlink_core` / `lanlink_store` / `dart:io`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/clock.dart';
import '../../domain/models.dart';
import '../../domain/remaining_time.dart';
import '../../domain/selectors.dart';
import '../format.dart';
import '../notices.dart';
import '../theme.dart';
import 'file_thumbnail.dart';
import 'file_tile.dart';
import 'missing_files_note.dart';
import 'status_chip.dart';

/// The **minimum width** of a folder card on the desktop (0.2.39).
///
/// The card shrinks to its content, and its content is two short lines
/// (`放这看` + `110 KB · 1 个文件`) — so a real desktop report was a card **229.6 dp
/// wide in a ~700 dp message column**: 21 % of the row, sitting next to file rows
/// that fill it, reading like a stray line rather than a card. The phone does not
/// have the problem (its card is stretched to the bubble cap — 449.3 of 576), which
/// is exactly why the user said *"电脑显示的看着有点短，手机上感觉合适的"*.
///
/// A **floor**, not a fixed width: a long folder name still grows the card, up to
/// the bubble's own cap (the `ConstrainedBox` in [build] still clamps it), and the
/// value is additionally clamped to the room actually available, so a narrow
/// desktop pane cannot be overrun by it.
const double kFolderCardMinWidth = 320;

/// How far (in logical pixels) the pointer must move after pressing an
/// attachment before the move counts as a **drag out** of the app (0.2.45).
///
/// Measured from the press point, not from the moment Flutter's pan recogniser
/// accepts the gesture: with a mouse the recogniser accepts after ~1 px (the
/// precise-pointer slop), so a threshold taken from *there* would fire on the
/// first jitter of a click. From the press point the number means what it says,
/// and it keeps the three gestures on one attachment row distinct — a tap opens
/// the file, a right click / long press opens its menu, and only a real move
/// starts a drag.
///
/// 12 dp is roughly half the 18 dp touch slop Flutter uses for scrolling, i.e. a
/// deliberate move with a mouse and clearly more than a click's tremor.
const double kDragOutSlop = 12;

/// Renders one conversation message as a bubble.
class MessageBubble extends StatelessWidget {
  /// Creates a message bubble.
  ///
  /// [files] are the message's attachments (empty for a text message).
  /// [progress] is shown inline while the status is `transferring`.
  /// [sourceUnavailable] says that at least one of this message's attachments is
  /// **not at its `localPath`** (A2-18) — a fact about the disk, nothing more.
  /// [sourceCleanedByUs] says **we** are the ones who deleted it, which is what
  /// turns that fact into no news at all; see [_sourceWarning].
  /// [isMobile] makes an image/video thumbnail **tap-to-open** (M5 §D) — the
  /// desktop bubble keeps non-tappable thumbnails unchanged.
  const MessageBubble({
    super.key,
    required this.message,
    this.files = const <FileAttachment>[],
    this.progress,
    this.progressOrdinal,
    this.onResend,
    this.onCancel,
    this.onOpenFile,
    this.sourceUnavailable = false,
    this.sourceCleanedByUs = false,
    this.isMobile = false,
    this.clock = const SystemClock(),
    this.incomingAvatar,
    this.isLastInThread = true,
    this.onShowAttachmentMenu,
    this.onCopyText,
    this.failureNote,
    this.publishNote,
    this.selectableText = true,
    this.folder,
    this.onOpenFolder,
    this.onDragOut,
    this.onShowFolderMenu,
  });

  /// What a **folder message** prints on its card, or `null` for an ordinary
  /// message (0.2.38 / `docs/22` §5.1).
  ///
  /// The summary arrives ready-made from the caller: the bubble must **not**
  /// walk `files` itself, or the card's `12/20` and the directory page's row
  /// count would slowly disagree (`selectors.dart::summarizeFolder` is the one
  /// place that counts).
  final FolderSummary? folder;

  /// Opens the folder's directory page. Wired only when [folder] is set.
  ///
  /// The whole card is the tap target: a folder is **one** object, and a second
  /// clickable region inside it (one per file) would fight the "open the folder"
  /// gesture the reference app uses.
  final VoidCallback? onOpenFolder;

  /// Reports that the user **dragged attachments out** of the app (0.2.45).
  ///
  /// One callback for both shapes the timeline has, because they are the same
  /// intent:
  ///  * a file row or a thumbnail reports **just that one file** —
  ///    `onDragOut([file])`;
  ///  * a **folder message** (which draws one card, not N rows) reports the whole
  ///    message's attachments — `onDragOut(files)` — because dragging a folder out
  ///    means "take the folder's files", and the card is the only thing there is to
  ///    grab.
  ///
  /// `null` ⇒ **no gesture at all** (`null` is what a phone, Web or any
  /// non-Windows host passes: `PlatformPorts.supportsDragOut` is false there). The
  /// bubble deliberately decides nothing beyond "the user grabbed this": whether
  /// the files still exist, whether the drag may start, what the OS reported and
  /// what happens to the row afterwards all belong to the caller — the same
  /// division [onResend] / [onCancel] / [onOpenFile] already follow.
  ///
  /// The gesture is a **pan**: pointer down, then movement past [kDragOutSlop]
  /// (measured from the press, so a click, a long press and a right click are
  /// untouched). That is the same threshold-or-move rule Explorer itself uses, and
  /// it is why a row can still be tapped to open and right-clicked for its menu.
  final void Function(List<FileAttachment> files)? onDragOut;

  /// Opens the **folder card's** context menu at a global position, or `null`
  /// for no menu at all (0.2.46).
  ///
  /// A folder message draws one card, so it never goes through
  /// [onShowAttachmentMenu] (which is per attachment): before 0.2.46 a
  /// right-click on that card did nothing at all, and 「转发到…」 — the one thing
  /// the user actually wants from it — had no way in. The same
  /// secondary-tap / long-press pair as the attachment rows, for the same
  /// reason (a desktop has a right button, a phone has a finger).
  ///
  /// The bubble still decides **nothing** about the menu: the entries (转发到… /
  /// 删除) are the caller's — see `attachment_menu.dart::showFolderMessageMenu`.
  final void Function(Offset position)? onShowFolderMenu;

  /// Whether this bubble wraps its own text body in a [SelectionArea]
  /// (`true` by default — 0.2.28).
  ///
  /// **0.2.30 passes `false` from the timeline.** The selection layer has to be
  /// **one** region for the whole list, mounted **above** the `ListView`
  /// (`ConversationThread._timeline`), not one per row: a `SelectableRegion`
  /// only competes for a drag that was hit-tested **inside its own box**, and
  /// with a region per bubble that box is one paragraph. So any press that
  /// landed on the card's padding, in the gap between two line boxes, or in the
  /// empty half of a short last line was a drag on **nothing**, and a drag that
  /// ran past the bubble it started in could select that one bubble only — the
  /// two cases `desktop_mouse_selection_test.dart` case C fails on 0.2.29 and
  /// passes now. One region above the scrollable is also what Flutter documents
  /// for text inside a list.
  ///
  /// Nesting **two** regions would be the worst of both: the inner one owns the
  /// gesture (recognizers are added deepest-first) and the outer one never sees
  /// it. So this is a switch, not an addition — exactly one region exists in a
  /// mounted thread.
  ///
  /// Keeping the default `true` means a bubble used on its own (every widget
  /// test that mounts one, and any future single-message surface) is still
  /// selectable without wiring anything.
  final bool selectableText;

  /// Opens the attachment's context menu at a global position.
  ///
  /// The bubble does not know what the menu contains on purpose: the entries are
  /// the caller's (and the platform's) business — see
  /// `ui/widgets/attachment_menu.dart`. Invoked by a **secondary tap** on the
  /// desktop and a **long press** on a phone (docs/19 §9.6).
  final void Function(FileAttachment file, Offset position)? onShowAttachmentMenu;

  /// Copies the **whole** body of a text message, or `null` to draw no
  /// 「复制」button at all (0.2.31).
  ///
  /// **0.2.31 — the button replaces the bubble's right-click menu, and that is
  /// the whole point.** 0.2.27 answered *"我发文字出去电脑端貌似没办法复制文本"*
  /// with a `复制文字` entry on the bubble's secondary tap; 0.2.28/0.2.30 added
  /// real text selection on top. The two then fought for the same button: the
  /// bubble's own `onSecondaryTapDown` had to sit **inside** the selection layer
  /// to win the arena, which meant the layer's recognizer **never saw a right
  /// click** — so the user could drag a selection and then had no way to copy
  /// *that range*, only the whole message again. His report (*"我怀疑电脑上选中
  /// 文字后，右键优先级是整个文字气泡右键的复制文字"*) names the cause exactly.
  ///
  /// So the bubble no longer takes the secondary tap on a text body at all: the
  /// right click belongs to the selection layer, which owns the `复制 / 全选`
  /// menu for the range. "Copy the whole message, verbatim" — still the fastest
  /// way to get one line out — moves to a **button under the bubble**
  /// ([_copyButton]), where it competes with nothing.
  ///
  /// The bubble still decides **nothing** about the clipboard: like
  /// [onShowAttachmentMenu] it only reports "the user asked to copy this one",
  /// and the caller owns the write and the confirmation. `null` ⇒ no button
  /// (which is why a bare bubble — every widget test, any future single-message
  /// surface — is byte-identical to 0.2.30).
  final VoidCallback? onCopyText;

  /// Whether this is the **last** message of the thread (default `true`).
  ///
  /// docs/19 §9-A: a delivered message's「已完成」is drawn **only here**. Six
  /// identical green dots down one conversation said nothing that the first one
  /// had not; the newest one does ("your last send landed"). The default is
  /// `true` so a lone bubble — every widget test, and any future single-message
  /// surface — still shows the label, which is what **A2-7 / A2-8** requires
  /// ("the seven status labels render exactly").
  final bool isLastInThread;

  /// A round avatar drawn **outside** an incoming bubble, aligned with its top
  /// (docs/19 §8-⑥, desktop only).
  ///
  /// The caller owns it because the bubble does not know which peer a message
  /// belongs to — `conversation_thread` already resolves the peer for its header
  /// and passes the same avatar here. `null` reserves the same width with a
  /// blank space, so every incoming bubble still lines up.
  final Widget? incomingAvatar;

  /// The message to render.
  final ChatMessage message;

  /// The message's file attachments.
  final List<FileAttachment> files;

  /// Recent delivery progress, or `null`.
  ///
  /// **For a message with N attachments this is the batch, not the first file**
  /// (0.2.49) — the caller sums them up with
  /// `selectors.dart::MessageTransferProgress.of` and passes that aggregate's
  /// `bar`. The bubble never counts `files` itself: it holds no per-file lookup,
  /// and the message-level arithmetic (which file is home, which is in flight)
  /// belongs in the pure selector where it can be tested without a repository.
  final TransferProgress? progress;

  /// 「第 k/N 个」 — which attachment of the batch is being uploaded now, or
  /// `null` (0.2.49).
  ///
  /// Drawn on the progress line, beside the bytes and the percentage. It exists
  /// because a percentage alone cannot answer "is this still moving?": a batch of
  /// videos sits at 97 % for minutes while the last one trickles in, and a number
  /// that sits still is indistinguishable from a stalled link — the exact shape
  /// of the report this release fixes (`第 2/5 个` moves when the batch moves on;
  /// `97 %` does not).
  ///
  /// The **caller** supplies it (`MessageTransferProgress.ordinal`) so that one
  /// function owns the counting: `null` for a one-attachment message and for a
  /// batch with nothing in flight, which is why a lone file bubble and a finished
  /// batch both draw nothing extra.
  final String? progressOrdinal;

  /// Invoked to resend a failed message, or `null` to hide the action.
  final VoidCallback? onResend;

  /// Invoked to cancel an in-flight message, or `null` to hide the action.
  final VoidCallback? onCancel;

  /// A one-line reason drawn under a failed bubble's actions, or `null`
  /// (0.2.22).
  ///
  /// The bubble is a pure view and does not know why a send died, so the copy
  /// comes from the caller — which is also what keeps a raw
  /// `SocketException: …` (a diagnostic, not an answer) out of the UI: the
  /// thread passes a sentence only for causes it can name, e.g. 连接中断.
  final String? failureNote;

  /// A one-line note on a bubble that **succeeded**, or `null` (0.2.23).
  ///
  /// The case it exists for: a file was received (`done`) but could not be
  /// exported to the user-visible store, so it is still inside the app. That is
  /// not a failure — the bytes are on disk and openable through 分享 — which is
  /// why it is drawn in the **neutral** text colour instead of the error colour
  /// [failureNote] uses, and why it never replaces the status chip.
  final String? publishNote;

  /// Invoked with the tapped attachment, or `null` for non-interactive rows.
  final ValueChanged<FileAttachment>? onOpenFile;

  /// Whether **some** attachment of this message is off disk — the shared
  /// [SourceAvailability] verdict, handed in by the caller.
  ///
  /// This is the *disk* question only. Read it through [_sourceWarning], which is
  /// the same fact minus our own cleanup, and never decide anything on it
  /// directly — see the library doc for why one bool could not carry both.
  final bool sourceUnavailable;

  /// Whether the missing attachment(s) are missing **because the app deleted
  /// them** — the Android post-send cache cleanup (0.2.49).
  ///
  /// The caller answers it with `ConversationController.discardedByUs(path)`,
  /// i.e. from "did we delete this?" and not from the message's status, because a
  /// `done` message can lose its file either way and the two cases need opposite
  /// treatment. Only ever meaningful together with [sourceUnavailable].
  final bool sourceCleanedByUs;

  /// Whether this is a mobile build — thumbnails become tap-to-open (M5 §D).
  final bool isMobile;

  /// The time source the remaining-time estimate is sampled from (0.2.25).
  ///
  /// Defaults to the system clock, so every existing caller is unchanged and
  /// the bubble still calls **no** `DateTime.now()` itself (spec §3.2: reading
  /// the clock is a port's job). A test injects a [FixedClock] and advances it,
  /// which is the only way to measure a *duration* without sleeping.
  final Clock clock;

  /// The bubble-edge length used when a message carries a single image (§5).
  static const double _singleImageEdge = 240;

  /// The per-cell edge of the multi-image grid (§5).
  static const double _gridEdge = 96;

  /// The columns in the multi-image grid (§5).
  static const int _gridColumns = 3;

  /// Whether the missing source is **worth warning about**: it is off disk and it
  /// is **not** there because we deleted it (0.2.49).
  ///
  /// The single verdict behind all three places a missing attachment shows up —
  /// the red marker ([_marker]), the row's 「源文件不可用」 ([_fileRow]) and the
  /// thumbnail that stops trying to read ([_thumbnail]). They used to share one
  /// bool; they must keep sharing the *right* one, or the bubble stops being red
  /// while its thumbnail stays grey.
  ///
  /// Why "who deleted it" and not the status: the only reason a `done` file being
  /// gone is unremarkable is that the app cleaned up its own cache copy
  /// (`ConversationController._discardPickedCopies`). On the desktop the same
  /// state means the user deleted or moved **their own** source file — a real
  /// loss, still reported. `direction`/`status` cannot tell those apart; the
  /// deleter can. A `failed` / `canceled` message therefore behaves exactly as in
  /// 0.2.48 unless we removed the file ourselves (which cannot happen: the cleanup
  /// only runs on a delivered send).
  bool get _sourceWarning => sourceUnavailable && !sourceCleanedByUs;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool outgoing = message.direction == MessageDirection.outgoing;
    final Widget? progressBar = _progressBar();
    // The width cap is a fraction of the **pane this bubble is laid out in**, not
    // of the whole window (theme.dart: "as a fraction of its pane"). Reading the
    // pane width off the incoming constraints is what keeps `in` / `out` readable
    // on a phone: measured against the *window* width the cap grew to ~93% of a
    // narrow pane, both sides filled the pane and the left/right split vanished —
    // the "#4 左右反了" report (the alignment code was never wrong). On a wide
    // pane the absolute cap still binds, so the desktop split is unchanged.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double maxWidth = _maxBubbleWidth(constraints.maxWidth);
        return Align(
          alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: _bubble(context, theme, outgoing, progressBar, maxWidth),
          ),
        );
      },
    );
  }

  /// The bubble's box (colour, radius, padding, content and footer), given the
  /// pane-resolved cap by [build].
  Widget _bubble(
    BuildContext context,
    ThemeData theme,
    bool outgoing,
    Widget? progressBar,
    /// The bubble's width cap for this pane — passed down so the folder card can
    /// floor its width **without ever exceeding it** (0.2.39).
    double maxWidth,
  ) {
    // docs/19 §8: the **desktop** bubble is restructured — avatar outside, file
    // name + status below the card, and a single photo/video filling the card.
    // The **phone** keeps the tree it had, with **one** exception since 0.2.37: a
    // single photo/video is now the same **bare card** it is on the desktop — see
    // [bareMediaOnPhone] below.
    final bool desktop = !isMobile;
    // 0.2.37 — *"按电脑的那种气泡来"*. A single image/video fills the card edge to
    // edge, so the card's own fill is never visible (the thumbnail paints an
    // opaque image / loading / error box over it, exactly as on the desktop).
    // Until now this was `desktop && _isSingleMedia()`: on a phone the media kept
    // the 12 dp bubble inset **and** printed the file name inside the coloured
    // box, which is the "video in a light-blue bubble" the user sent a screenshot
    // of. One expression for both surfaces means the shape cannot drift again.
    // ★ A folder whose only attachment is an image/video must NOT become a hero
    // media card — it would hide the folder behind its first picture.
    final bool mediaCard = !message.isFolder && _isSingleMedia();
    // …and on a phone a bare card forces everything else **out** of it: a status
    // chip, a 重新发送 row or a failure note left inside would put the card's fill
    // back on screen as a coloured strip under the image — the "no background but
    // still indented one notch" failure this change exists to avoid.
    final bool bareMediaOnPhone = mediaCard && !desktop;
    final Widget? actions = _actions();
    final Widget? marker = desktop ? _marker(context) : null;
    // docs/19 §9-A: **success is the default state**. A delivered message shows
    // 「已完成」only on the thread's last bubble; every other state always shows.
    final bool showStatus =
        message.status != MessageStatus.done || isLastInThread;
    final Widget? footer = desktop ? null : _footer(context, showStatus: showStatus);
    // The two "why" lines, in one place: they sit inside the bubble normally, and
    // below a bare media card (see [bareMediaOnPhone]).
    final List<Widget> notes = <Widget>[
      // 0.2.22: the reason a send died, on **both** surfaces (the phone footer and
      // the desktop action row both already say 失败; this says *why*, which is
      // the difference between "try again" and "the peer is gone, walk closer to
      // the router").
      if (failureNote != null) ...<Widget>[
        const SizedBox(height: 4),
        // A diagnosis, not message content — same rule as the buttons.
        SelectionContainer.disabled(
          child: Text(
            failureNote!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ),
      ],
      // 0.2.38: how many files of a folder are **not coming**. Since 0.2.42 the
      // thread fills it in for real (`selectors.dart::missingFolderFiles`): the
      // sender's declared count minus what arrived, but **only** once the folder
      // has been silent for longer than `kFolderQuietPeriod` (90 s) — the
      // receiver has no "batch finished" signal, so silence is the only proof.
      // The bubble still decides nothing itself: `0` simply draws no line, so a
      // folder that is merely slow, or complete, or flat, never grows this row.
      // Same slot and style as [publishNote]: it is a remark on a `done`
      // message, not a failure.
      //
      // ★ 0.2.52 — the sentence itself now lives in [MissingFilesNote], **one**
      // implementation shared with the flat-batch bubble that
      // `conversation_thread.dart` draws under a multi-attachment message. Two
      // written-out copies of one line is precisely the shape that produced the
      // 0.2.49 folder-card bug (`summarizeFolder` existed, the card counted for
      // itself, and they drifted). The tree below is byte-identical to what was
      // here before: `SelectionContainer.disabled` + `bodySmall` in
      // `onSurfaceVariant`.
      if ((folder?.missing ?? 0) > 0) ...<Widget>[
        const SizedBox(height: 4),
        MissingFilesNote(count: folder!.missing),
      ],
      // 0.2.23: a *delivered* file that did not land in 下载. Neutral colour on
      // purpose — nothing failed, the file is just somewhere else, and the
      // sentence says which somewhere.
      if (publishNote != null) ...<Widget>[
        const SizedBox(height: 4),
        SelectionContainer.disabled(
          child: Text(
            publishNote!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    ];

    final Widget card = Container(
      decoration: BoxDecoration(
        color: outgoing
            ? theme.colorScheme.primaryContainer
            // docs/19 §8-⑦: on the desktop an incoming bubble is **light blue**;
            // the phone keeps the neutral fill (it follows Flix, not this one).
            : (desktop
                ? incomingBubbleFill(theme)
                : theme.colorScheme.surfaceContainerHighest),
        borderRadius: _bubbleRadius(outgoing),
      ),
      // A single media attachment fills the card edge to edge (docs/19 §8-⑤):
      // no padding, and the radius clips the image.
      padding: mediaCard ? EdgeInsets.zero : const EdgeInsets.all(12),
      clipBehavior: mediaCard ? Clip.antiAlias : Clip.none,
      // ★ 0.2.47 — the card's children are aligned **by direction** now that none
      // of them stretches. It used to be `start` for both, which was invisible
      // only because [_footer]'s `Align` made the card full-width anyway; with that
      // gone, an outgoing bubble whose footer is wider than its text would put the
      // text on the wrong side. (When the text is the widest child the two are
      // identical: the Column is exactly the text's width.)
      child: Column(
        crossAxisAlignment: outgoing
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // ★ 0.2.32 — **only a text body is selectable.** Since 0.2.30 one
          // `SelectionArea` covers the whole timeline, so *every* `Text` under it
          // was fair game for a drag: the user's report is exactly that
          // (*"从这一个气泡复制到另一个，貌似会复制到气泡周围的重新发送啊，取消发送
          // 这些东西"*). [`SelectionContainer.disabled`] is Flutter's own answer —
          // it unregisters the subtree from the region's registrar, so nothing
          // inside can be selected, nothing inside can appear in the copied text,
          // and (unlike wrapping in our own hit-test fiddling) it inserts **no
          // render object**, so no geometry moves.
          folder != null
              // 0.2.38: one card for the whole folder — no FileTile rows, no
              // thumbnail grid (a 200-photo folder must not inflate a bubble).
              ? SelectionContainer.disabled(
                  // 0.2.45: dragging the card out hands over the message's files.
                  // 0.2.46: and the card answers a right click / long press with
                  // the message-level menu (转发到… / 删除), which it had no way
                  // into before.
                  child: _folderDragOut(
                    _folderMenu(_folderCard(context, theme, maxWidth)),
                  ),
                )
              : message.kind == MessageKind.text
              ? _content(context, showMediaCaption: !mediaCard)
              // A file bubble has no selectable text at all: rows, file names,
              // sizes, thumbnails and captions are all labels on a card.
              : SelectionContainer.disabled(
                  child: _content(context, showMediaCaption: !mediaCard),
                ),
          if (progressBar != null && folder == null) ...<Widget>[
            const SizedBox(height: 8),
            // 百分比 / `已传 / 总量` / `剩 3 分 20 秒` — read-outs, not text.
            SelectionContainer.disabled(
              child: mediaCard
                  ? Padding(padding: const EdgeInsets.all(8), child: progressBar)
                  : progressBar,
            ),
          ],
          // ★ 0.2.47 — the phone footer is **outside the card** now (see the return
          // below). Leaving it in here is what made the newest bubble wider than
          // itself one message later: the chip is a line of its own, and any child
          // of this `Column` sets its width.
          if (desktop && actions != null) ...<Widget>[
            const SizedBox(height: 8),
            // The desktop action row: 重新发送 / 取消.
            SelectionContainer.disabled(child: actions),
          ],
          // 0.2.47: the phone carries the notes **under the bubble** (with the
          // footer), so they must not also be drawn inside the card — that would
          // print 「N 个未收到」 twice.
          if (desktop) ...notes,
        ],
      ),
    );

    // ★ 0.2.39/0.2.40 — a folder card's width is now decided **by the card**, on
    // both surfaces, instead of by whatever happens to sit next to it. See
    // [_sizeFolderCard]; for every other kind of message this is a no-op.
    final Widget sizedCard =
        folder != null ? _sizeFolderCard(card, maxWidth) : card;

    // 0.2.27–0.2.30 used to hang 「复制文字」on the card's right click and then on
    // the body's; **0.2.31 moves it out of the gesture arena entirely** — see
    // [onCopyText]. A file message keeps its per-attachment menu ([_withMenu]),
    // which is the one secondary-tap the app still owns, and it cannot collide
    // with a selection layer because the attachment cards have none.

    if (!desktop) {
      if (!bareMediaOnPhone) {
        // ★ `sizedCard`, not `card`: on the phone that is the folder card **filled
        // to the bubble's cap** (0.2.40). For a text bubble `sizedCard == card`.
        //
        // 0.2.47 — the status/actions row moved **out of the bubble**, which is
        // where the desktop has always had it. Inside, it was the widest child of a
        // shrink-wrapping column on the *newest* message (the only one that shows
        // 已完成), so `好` measured 449.28 as the last message and 38.25 a moment
        // later: *"我发的第一个文字消息会让气泡变得很长，第二消息会让第一个消息恢复
        // 正常大小"*. Under the bubble it can be as wide as it likes without the
        // bubble noticing — `message_bubble_footer_width_test.dart` pins it.
        if (footer == null && notes.isEmpty) {
          return sizedCard;
        }
        return Column(
          crossAxisAlignment:
              outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            sizedCard,
            if (footer != null) ...<Widget>[
              const SizedBox(height: 4),
              SelectionContainer.disabled(child: footer),
            ],
            ...notes,
          ],
        );
      }
      // 0.2.37 — the phone's media bubble **is** the desktop shape now: bare
      // rounded thumbnail, then the name in the description colour, then the
      // status / actions, then any note — all of it outside the card, aligned the
      // same way the bubble is. (Same 4 dp gap the desktop uses between card and
      // its meta row, so the two surfaces read identically.)
      return Column(
        crossAxisAlignment:
            outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          card,
          const SizedBox(height: 4),
          // The name is chrome, not selectable text (0.2.32's rule).
          SelectionContainer.disabled(child: _mediaFileName(theme)),
          if (footer != null) ...<Widget>[
            const SizedBox(height: 6),
            SelectionContainer.disabled(child: footer),
          ],
          ...notes,
        ],
      );
    }

    // Below the card: the file name a full-bleed media card can no longer show
    // inside (A2-3 / E3 / E11 still require it), the status (docs/19 §8-⑧), and
    // — for a text message — 「复制」 (0.2.31).
    //
    // `showCopy` keeps the row even when there is no status to show: the button
    // is the **only** way left to copy a whole text message, so it may not
    // depend on "is this the newest bubble". A file message with nothing to say
    // still draws no row at all (the old behaviour).
    final bool showCopy = message.kind == MessageKind.text && onCopyText != null;
    final Widget? below = (mediaCard || showStatus || marker != null || showCopy)
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (mediaCard) ...<Widget>[
                _mediaFileName(theme),
                const SizedBox(width: 8),
              ],
              if (showStatus) StatusChip(status: message.status),
              if (marker != null) ...<Widget>[const SizedBox(width: 6), marker],
              if (showCopy) ...<Widget>[
                // Separates the button from the status word without drawing a
                // divider: on a delivered message the chip is absent and the
                // button stands alone under the bubble.
                if (showStatus || marker != null) const SizedBox(width: 8),
                _copyButton(theme),
              ],
            ],
          )
        : null;

    final Widget column = Column(
      crossAxisAlignment:
          outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        sizedCard,
        if (below != null) ...<Widget>[
          const SizedBox(height: 4),
          // 0.2.32: the whole meta row is chrome — the media file name, 已完成 /
          // 失败（可重新发送）, the marker icon and the 「复制」 button. A cross-bubble
          // drag must not paste any of it, so the row is unselectable as a unit.
          SelectionContainer.disabled(child: below),
        ],
      ],
    );

    if (outgoing) {
      return column;
    }
    // Incoming: the round avatar sits **outside** the card, aligned to its top
    // (docs/19 §8-⑥). No avatar passed still reserves the width, so consecutive
    // incoming bubbles line up.
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 20,
          height: 20,
          child: incomingAvatar ?? const SizedBox.shrink(),
        ),
        const SizedBox(width: 6),
        Flexible(child: column),
      ],
    );
  }

  /// The **desktop** 「复制」 affordance under a text bubble (0.2.31).
  ///
  /// It replaces the bubble's right-click menu (see [onCopyText]) and is
  /// deliberately **quiet**: `bodySmall` in the muted `onSurfaceVariant` colour and
  /// 6 dp of side padding, which measures **36.8 × 20 dp** on the desktop — the
  /// weight of a remark under the bubble, not a call to action. (20, not the
  /// 28 dp `minimumSize`, because `VisualDensity.compact` shaves it; the row is
  /// therefore 20 dp tall instead of the status chip's 16, which is the +4 px the
  /// 0.2.30 → 0.2.31 geometry change in `bubble_copy_button_test.dart` accounts
  /// for.) It sits on the same meta line as the status chip, so a delivered
  /// message reads "bubble / 复制" and a failed one reads "bubble / 失败 / 复制"
  /// with nothing moving sideways.
  ///
  /// **Not drawn on a phone at all** (the caller only builds the meta row on the
  /// desktop): there a long press selects and the platform's own toolbar copies,
  /// which is one gesture instead of two, and an extra button under every bubble
  /// would be the only thing on the screen that is *not* part of the message.
  Widget _copyButton(ThemeData theme) {
    final VoidCallback? copy = onCopyText;
    if (copy == null) {
      return const SizedBox.shrink();
    }
    return TextButton(
      // A key, because the selection toolbar also has a button reading 复制 and a
      // test (or a future reader) must be able to say **which** one it means.
      key: const ValueKey<String>('bubble-copy-text'),
      onPressed: copy,
      style: TextButton.styleFrom(
        foregroundColor: theme.colorScheme.onSurfaceVariant,
        textStyle: theme.textTheme.bodySmall,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        minimumSize: const Size(0, 28),
        // No 36/48 dp reserved tap ring: this is a mouse-only affordance, and on
        // the desktop the pointer is precise. On a phone the widget is not built.
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      child: const Text('复制'),
    );
  }

  /// The card a **folder message** draws instead of N file rows (0.2.38 / T05).
  ///
  /// Shape taken from the reference screenshot (`docs/22` §5.1): a folder glyph,
  /// the name (which may wrap to **two** lines — a folder name is longer than a
  /// file name), one meta line `32 MB · 20 个文件`, and — only while the batch is
  /// still arriving — `已收到 12/20`.
  ///
  /// Three deliberate omissions:
  /// * **no status chip**: both surfaces already draw one (the desktop meta row,
  ///   the phone footer). Repeating it inside the card was the "two 已完成" bug
  ///   waiting to happen;
  /// * **no percentage bar**: the caller suppresses `progressBar` for a folder —
  ///   `12/20` is the reference app's own unit and it moves on every file, where
  ///   a byte percentage sits at 97 % for the length of the last video;
  /// * **no per-file rows**: the whole card is one tap target that opens the
  ///   directory page. A second clickable region inside it would fight that.
  Widget _folderCard(BuildContext context, ThemeData theme, double maxWidth) {
    final FolderSummary data = folder!;
    // `tabularFigures` so `9/20` and `12/20` line up as the numbers tick over
    // instead of shifting the text sideways on every arrival.
    final TextStyle? countStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    return InkWell(
      onTap: onOpenFolder,
      borderRadius: _bubbleRadius(message.direction == MessageDirection.outgoing),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Amber, not the muted grey a "document" icon would use: on a phone the
          // card has no thumbnail, so the glyph is the only thing that says
          // "this is a folder and it opens" (the reference screenshot's colour).
          Icon(Icons.folder, size: 24, color: Colors.amber.shade700),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  data.name,
                  // Two lines: `lanlink-电脑版-0.2.33-正式版` does not fit one line
                  // on a 320 dp phone, and truncating a folder's name to
                  // `lanlink-电脑版-…` makes two adjacent cards indistinguishable.
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  '${fileSizeText(data.bytes)} · ${data.total} 个文件',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                if (!data.isComplete) ...<Widget>[
                  const SizedBox(height: 4),
                  Text('已收到 ${data.done}/${data.total}', style: countStyle),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Gives a **folder card** its width on each surface (0.2.39 / 0.2.40).
  ///
  /// **Why the card decides its own width now.** Measured on real data (a
  /// one-file folder named `放这看`, 600×1200): the phone drew it **449.28 × 84**
  /// when the message was the newest — the `已完成` footer's `Align` was what
  /// stretched the bubble — and **229.60 × 62** for an older message, where
  /// `showStatus` is false and there is no footer at all. Same card, same name,
  /// half the width, purely because of a sibling that is not part of it. A folder
  /// is a **container message, not a sentence**: it has to look the same every
  /// time, so nothing outside it may decide its size.
  ///
  /// * **phone** — the bubble's full width ([maxWidth]); one shape for every
  ///   folder message, footer or not. `SizedBox(width:)` is a constraint on the
  ///   card itself, so there is no "invisible stretcher" to copy the old bug:
  ///   if the footer disappears tomorrow the card does not move.
  /// * **desktop** — a **floor**, not a width: 320 dp so a short name still reads
  ///   as a card (0.2.39), while a long one keeps growing up to the bubble's cap
  ///   (`ConstrainedBox(maxWidth: …)` in [build] still clamps it).
  Widget _sizeFolderCard(Widget card, double maxWidth) {
    if (isMobile) {
      return SizedBox(width: maxWidth, child: card);
    }
    return ConstrainedBox(
      constraints: BoxConstraints(
        // `min(320, cap)`: on a narrow pane (a 420 dp compact layout) the floor
        // shrinks to what actually fits instead of overflowing it.
        minWidth:
            maxWidth < kFolderCardMinWidth ? maxWidth : kFolderCardMinWidth,
      ),
      child: card,
    );
  }

  /// The attachment's name, **below** a bare media card (A2-3 / E3 / E11: the
  /// thumbnail alone would hide which file it is).
  ///
  /// One widget for both surfaces (0.2.37): the desktop already printed it this
  /// way in its meta row, and the phone now shows the same line under the same
  /// bare card — a second copy of this style is how the two would drift into
  /// "(on the phone it is blue)".
  Widget _mediaFileName(ThemeData theme) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Text(
          files.single.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );

  /// Whether the message carries exactly one image/video — the case whose card
  /// fills edge to edge on the desktop (docs/19 §8-⑤) **and, since 0.2.37, on the
  /// phone too** (the same bare-card shape, see [bareMediaOnPhone]).
  bool _isSingleMedia() {
    if (files.length != 1) {
      return false;
    }
    final FileClass cls =
        classifyFile(files.single.fileName, mime: files.single.mime);
    return cls == FileClass.image || cls == FileClass.video;
  }

  /// The bubble's width cap: the **smaller** of the absolute [kBubbleMaxWidthPx]
  /// and [kBubbleMaxWidthFactor] × [paneWidth] — the width the bubble is offered
  /// by its pane, not the window (PRD §2.4 / design §6 / `theme.dart` §"fraction
  /// of its pane").
  ///
  /// The absolute term dominates on a wide pane — so a bubble stays clearly
  /// narrower than the pane and the `in` / `out` split reads at a glance — while
  /// the proportional term takes over on a narrow one, so the split survives
  /// there too and the bubble never overflows.
  double _maxBubbleWidth(double paneWidth) {
    final double proportional = paneWidth * kBubbleMaxWidthFactor;
    return proportional < kBubbleMaxWidthPx ? proportional : kBubbleMaxWidthPx;
  }

  /// Radius [kRadiusCard] with a 4px tail on the sender's side (PRD §2.4).
  BorderRadius _bubbleRadius(bool outgoing) => BorderRadius.only(
        topLeft: const Radius.circular(kRadiusCard),
        topRight: const Radius.circular(kRadiusCard),
        bottomLeft: Radius.circular(outgoing ? kRadiusCard : 4),
        bottomRight: Radius.circular(outgoing ? 4 : kRadiusCard),
      );

  Widget _content(BuildContext context, {required bool showMediaCaption}) {
    if (message.kind == MessageKind.text) {
      return _textBody(message.textBody ?? '');
    }
    // Images render as thumbnails; every other attachment stays a file row.
    final List<FileAttachment> images = <FileAttachment>[];
    final List<FileAttachment> others = <FileAttachment>[];
    for (final FileAttachment file in files) {
      final FileClass cls = classifyFile(file.fileName, mime: file.mime);
      // **Images and videos share the big-thumbnail path** (docs/18 §4). The user
      // ruled "两端都改": on the desktop an image was already a big thumbnail, so
      // leaving a video as a small row was the inconsistency. This is the **one
      // approved exception** to §7.1's "wide is byte-identical" contract — every
      // other wide assertion still has to match its baseline.
      if (cls == FileClass.image || cls == FileClass.video) {
        images.add(file);
      } else {
        others.add(file);
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (images.isNotEmpty) ...<Widget>[
          _imageGrid(context, images, showCaption: showMediaCaption),
          if (others.isNotEmpty) const SizedBox(height: 6),
        ],
        for (final FileAttachment file in others)
          _attachment(file, _fileRow(file)),
      ],
    );
  }

  /// A text message's body, **selectable like any other text** (0.2.28).
  ///
  /// The defect it answers: *"你这个复制只能右键复制文字，不能是我选择文字进行复制的那种吗"*
  /// — 0.2.27 only offered "copy the whole message", which is the wrong unit when
  /// what the user wants is three words out of a paragraph.
  ///
  /// **Why [SelectionArea] and not [SelectableText]:** *layout*. [SelectableText]
  /// is an `EditableText`, i.e. a **different text renderer**: it reserves a caret
  /// margin beside the text, and it resolves its own `strutStyle` / `textScaler`
  /// defaults, so the same string can break its lines on different pixels than the
  /// [Text] it replaces — and the bubble **shrink-wraps** its body, so a 2 px
  /// difference moves the whole card. [SelectionArea] inserts **no render object**
  /// between the bubble and the [Text] (its wrappers are a focus node, a mouse
  /// region, a tap region and a selection registrar — all pass-through), so the
  /// paragraph is measured by exactly the same `RenderParagraph`, with the same
  /// `DefaultTextStyle`, the same wrapping and the same `textAlign`/`maxLines`
  /// (there are none to restore: this body never set them). The 40-character
  /// baseline in `test/widget/message_selection_test.dart` pins that to the pixel.
  ///
  /// What the user gets is the platform's own behaviour, not a re-implementation:
  /// **mouse drag + `Ctrl+C`** on the desktop and **long press → drag a handle →
  /// the copy toolbar** on a phone, both owned by [SelectionArea]'s
  /// `SelectableRegion`.
  ///
  /// **0.2.30 — where that [SelectionArea] lives.** It used to be created here,
  /// i.e. **inside every bubble**, and a bubble lives **inside** the timeline's
  /// `ListView`; the region is therefore inside the scrollable and its box is
  /// only the bubble's own paragraph. The user's report (*"手机上倒是可以选择
  /// 文字，电脑上反而不行"*) is precisely the asymmetry that arrangement
  /// produces: a finger's **long press** is a gesture no sibling competes for,
  /// so the phone path always works, while a mouse **drag** is a pan that only
  /// reaches the region when the pointer came down inside that one paragraph's
  /// box — one row at a time, never across the rows a human drags over. The
  /// timeline now mounts **one** `SelectionArea` above the `ListView` and passes
  /// [selectableText] `false`; see that parameter for why it is a switch and not
  /// a second layer.
  ///
  /// **0.2.31 — nothing in this bubble touches a pointer any more.** 0.2.27–0.2.30
  /// wrapped the body in a `GestureDetector(onSecondaryTapDown:)` to offer
  /// 「复制文字」on the right click, and had to place it **inside** the selection
  /// layer to win the arena — which is exactly why the layer never received a
  /// right click and could not offer 复制 for the *range* the user had just
  /// dragged. That detector is **gone**: the body is a bare [Text], the right
  /// click goes to whatever selection layer is above it (the timeline's), and
  /// "copy the whole message" is the button below the bubble ([onCopyText]).
  /// No `GestureDetector` here also means no `HitTestBehavior.opaque` between
  /// the paragraph and the region, so the region sees the full press path.
  Widget _textBody(String body) {
    final Widget text = Text(body);
    // `selectableText` is `false` inside a thread (the timeline owns the one
    // region); `true` keeps a bubble used on its own selectable.
    return selectableText ? SelectionArea(child: text) : text;
  }

  /// One image → a single capped thumbnail (up to 240×240, **keeping the
  /// image's ratio**); several → a fixed 3-column grid of 96px square
  /// thumbnails (PRD §5). The grid cells stay square so the wrapped rows line
  /// up; only the single, "hero" image is unconstrained to its own ratio.
  Widget _imageGrid(BuildContext context, List<FileAttachment> images,
      {required bool showCaption}) {
    if (images.length == 1) {
      return _attachment(
        images.single,
        _thumbnail(
          context,
          images.single,
          _singleImageEdge,
          kRadiusCard,
          preserveAspect: true,
          showCaption: showCaption,
        ),
      );
    }
    const double gridWidth =
        _gridColumns * _gridEdge + (_gridColumns - 1) * kRadiusThumb;
    return SizedBox(
      width: gridWidth,
      child: Wrap(
        spacing: kRadiusThumb,
        runSpacing: kRadiusThumb,
        children: <Widget>[
          for (final FileAttachment file in images)
            _attachment(
              file,
              _thumbnail(context, file, _gridEdge, kRadiusThumb,
                  showCaption: showCaption),
            ),
        ],
      ),
    );
  }

  /// A thumbnail with its file name in a one-line caption underneath (A2-3 /
  /// E3 / E11): the thumbnail alone would hide which file an image attachment
  /// is, so the name is always shown — small, muted, single-line, ellipsised.
  ///
  /// When [preserveAspect] (the single "hero" image) the thumbnail keeps the
  /// image's ratio and the caption is merely **capped** at [edge] so it never
  /// widens the bubble; otherwise the thumbnail is a fixed [edge] × [edge]
  /// square (the multi-image grid) and the caption matches that width.
  Widget _thumbnail(
    BuildContext context,
    FileAttachment file,
    double edge,
    double radius, {
    bool preserveAspect = false,
    bool showCaption = true,
  }) {
    final ThemeData theme = Theme.of(context);
    final Widget caption = Text(
      file.fileName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FileThumbnail(
          fileName: file.fileName,
          mime: file.mime,
          path: file.localPath,
          // 0.2.49: the *fact* is not enough — a file the app deleted itself must
          // not turn its thumbnail grey. [_sourceWarning] is the same verdict the
          // row below gets, so a thumbnail and a row of the same file never
          // disagree.
          unavailable: _sourceWarning,
          edge: edge,
          radius: radius,
          preserveAspect: preserveAspect,
          onTap: _openAttachment(file),
        ),
        // docs/19 §8-⑤: a full-bleed media card on the desktop hides the caption
        // (the caller prints the name **below** the card instead, so A2-3 / E3 /
        // E11 — "an attachment never hides which file it is" — still holds).
        if (showCaption) ...<Widget>[
          const SizedBox(height: 4),
          preserveAspect
              ? ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: edge),
                  child: caption,
                )
              : SizedBox(width: edge, child: caption),
        ],
      ],
    );
  }

  /// A tap-to-open handler for a bubble attachment, or `null` when the caller
  /// did not wire [onOpenFile].
  ///
  /// **Not gated on `isMobile` any more** (docs/19 §9.6): a media card is the
  /// biggest, most obviously clickable thing in the bubble, and on the desktop it
  /// used to do nothing at all — the user's "点不开视频" report. The phone keeps
  /// its tap-to-open, the desktop gains the same behaviour through the same
  /// `openFile` port call.
  VoidCallback? _openAttachment(FileAttachment file) {
    final ValueChanged<FileAttachment>? open = onOpenFile;
    if (open == null) {
      return null;
    }
    return () => open(file);
  }

  /// Wraps one attachment's card with the gestures its context menu needs:
  /// **secondary tap** on the desktop, **long press** on a phone (a right-click
  /// never happens there). Both hand back the global position so the menu opens
  /// under the cursor / finger (docs/19 §9.6).
  ///
  /// **0.2.31 — this is now the app's only secondary-tap handler.** A text
  /// message used to share it (to offer 「复制文字」), which is what starved the
  /// selection layer of right clicks; the text body has no gesture of its own any
  /// more (see [_textBody]) and "copy the whole message" is a button
  /// ([_copyButton]). Attachments are unaffected: they have no selection layer,
  /// so nothing competes for the right button here.
  Widget _withMenu(FileAttachment file, Widget child) {
    final void Function(FileAttachment, Offset)? showMenu = onShowAttachmentMenu;
    if (showMenu == null) {
      return child;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (TapDownDetails details) => showMenu(
        file,
        details.globalPosition,
      ),
      // A phone has no right button; a long press is the same request there.
      onLongPressStart: isMobile
          ? (LongPressStartDetails details) => showMenu(
                file,
                details.globalPosition,
              )
          : null,
      child: child,
    );
  }

  /// One attachment's card with **all** of its gestures on it: drag-out outside,
  /// the context menu inside (0.2.45).
  ///
  /// The drag wrapper is on the **outside** on purpose: the menu detector below it
  /// only claims the secondary button, so the two never fight, and putting the pan
  /// outermost means it sees the press before the row's own tap target does (which
  /// is what a drag is). For a bubble with no [onDragOut] this returns exactly what
  /// 0.2.44 returned — the `child` wrapped in the menu, or the bare `child`.
  Widget _attachment(FileAttachment file, Widget child) {
    final Widget withMenu = _withMenu(file, child);
    final void Function(List<FileAttachment>)? drag = onDragOut;
    if (drag == null) {
      return withMenu;
    }
    return _DragOutDetector(
      onStart: () => drag(<FileAttachment>[file]),
      child: withMenu,
    );
  }

  /// The **folder card** with the drag-out gesture (0.2.45).
  ///
  /// What it hands over is <em>the whole message's</em> attachments (`files`, which
  /// the caller filled from the store) — not the single file the card's summary
  /// happens to name: dragging a folder out means taking the folder's files, and
  /// the caller is the one that drops the ones no longer on disk.
  Widget _folderDragOut(Widget card) {
    final void Function(List<FileAttachment>)? drag = onDragOut;
    if (drag == null) {
      return card;
    }
    return _DragOutDetector(
      onStart: () => drag(files),
      child: card,
    );
  }

  /// Wraps the folder card with the gestures its **message menu** needs (0.2.46):
  /// a secondary tap on the desktop, a long press on a phone — the same pair
  /// [_withMenu] gives an attachment row, on the same reasoning (a phone has no
  /// right button).
  ///
  /// It claims *only* those two gestures, so the card's own tap (which opens the
  /// folder) and the drag-out pan above it are untouched. `null` ⇒ the card is
  /// returned exactly as 0.2.45 built it.
  Widget _folderMenu(Widget card) {
    final void Function(Offset position)? show = onShowFolderMenu;
    if (show == null) {
      return card;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (TapDownDetails details) =>
          show(details.globalPosition),
      onLongPressStart: isMobile
          ? (LongPressStartDetails details) => show(details.globalPosition)
          : null,
      child: card,
    );
  }

  Widget _fileRow(FileAttachment file) {
    final ValueChanged<FileAttachment>? open = onOpenFile;
    // [FileTile] lays out its name / size with an [Expanded], so on its own it
    // always fills the widest width it is offered — a short file name would
    // still yield a full-width bubble. [IntrinsicWidth] hands it a tight,
    // content-sized width instead, while the bubble's outer cap still clamps a
    // long name. (This is a bounded, few-row context — unlike the three-pane
    // `Row`, where `IntrinsicWidth` is avoided for resize jank, design §6.2.)
    final Widget tile = IntrinsicWidth(
      child: FileTile(
        fileName: file.fileName,
        size: file.size,
        mime: file.mime,
        // ★ Hand the path down — **the wiring this row was missing**. Without it
        // `FileTile._leading` bails on `location != null` and *every* attachment
        // renders the type-icon fallback; images only look right because the
        // bubble routes them the other way (`_imageGrid` → `FileThumbnail`, which
        // gets `file.localPath` directly). Same fix, same reason, as the wiring
        // the recent-files page already needed (`recent_files_list.dart:172-174`).
        path: file.localPath,
        // 0.2.49: [_sourceWarning], not the raw disk fact — a file the app cleaned
        // up after a successful send must keep its normal row. See the library doc.
        unavailable: _sourceWarning,
        unavailableLabel: '源文件不可用',
        onTap: open == null ? null : () => open(file),
      ),
    );
    // ★ 0.2.48 — a row that already reads 「源文件不可用」 must still **answer** a
    // tap. `FileTile` drops its `InkWell` for an unavailable row (by design: the
    // row's own label is the normal feedback), which left this one shape with no
    // handler at all — the "点「打开」完全没反应" the user reported. The wrapper is
    // only mounted in that state, so it cannot compete with the live `InkWell` of
    // a row whose file is there; it calls the same [onOpenFile] the row would,
    // and the caller answers with a notice and marks the file gone.
    //
    // 0.2.49: same flag as the row, i.e. [_sourceWarning]. A row whose file the app
    // deleted itself is *not* in that state, so it keeps `FileTile`'s own
    // `InkWell` — its tap still reaches `ConversationThread._openAttachment`,
    // which answers 「文件已不在原位置，无法打开」 for the discarded cache copy
    // instead of opening nothing.
    if (!_sourceWarning || open == null) {
      return tile;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => open(file),
      child: tile,
    );
  }

  Widget? _progressBar() {
    final TransferProgress? current = progress;
    if (current == null || message.status != MessageStatus.transferring) {
      return null;
    }
    return _ProgressBar(
      progress: current,
      clock: clock,
      ordinal: progressOrdinal,
    );
  }

  Widget? _footer(BuildContext context, {required bool showStatus}) {
    final bool outgoing = message.direction == MessageDirection.outgoing;
    final Widget? marker = _marker(context);
    final Widget? actions = _actions();
    final List<Widget> rows = <Widget>[
      if (showStatus || marker != null)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (showStatus) StatusChip(status: message.status),
            if (marker != null) ...<Widget>[const SizedBox(width: 6), marker],
          ],
        ),
    ];
    if (actions != null) {
      rows.add(actions);
    }
    if (rows.isEmpty) {
      // Nothing to say (a delivered message with no actions) — the caller then
      // draws no footer at all, instead of an empty row plus its 6px gap.
      return null;
    }
    // ★ 0.2.47 — **this is what used to stretch the phone bubble.** `Align` with no
    // `widthFactor` is as wide as its parent allows, so inside the card's `Column`
    // it made the whole bubble take the full width **whenever a footer existed**.
    // On a phone the footer exists only on the *newest* message (`docs/19` §9-A
    // shows 已完成 on the last bubble) and on anything not `done` — so the same
    // sentence was 449.28 wide as the last message and 38.25 wide one second later
    // when the next message arrived. That is the user's "我发的第一个文字消息会让气泡
    // 变得很长".
    //
    // The footer is a *remark under the content*, never a width constraint: it now
    // shrink-wraps and the card's own Column aligns it (see above), so every kind of
    // bubble — text, file row, folder card — measures the same at both positions.
    // The desktop never had this bug because its footer is the `below` row outside
    // the card; `message_bubble_footer_width_test.dart` pins both surfaces.
    return Column(
      crossAxisAlignment:
          outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }

  Widget? _marker(BuildContext context) {
    // 0.2.49 — **the reported bug was here.** This used to be
    // `if (sourceUnavailable)`, i.e. the bare disk fact, unconditionally: every
    // file a successful Android send had just cleaned up wore a red broken-link
    // icon beside 「已完成」. [_sourceWarning] subtracts only *our own* cleanup —
    // a file the user deleted or moved (the desktop case) still gets the icon.
    if (_sourceWarning) {
      return Icon(
        Icons.link_off,
        size: 16,
        color: Theme.of(context).colorScheme.error,
      );
    }
    if (message.status == MessageStatus.failed ||
        message.status == MessageStatus.rejected) {
      // The status palette keeps failed (red) and rejected (amber) distinct.
      return Icon(Icons.close, size: 16, color: statusColor(message.status));
    }
    return null;
  }

  Widget? _actions() {
    final bool outgoing = message.direction == MessageDirection.outgoing;
    final MessageStatus status = message.status;
    // The three states the store can move to `canceled` **and** the controller
    // really cancels (0.2.22). Kept as an explicit set rather than "not done":
    // a state the click cannot act on must not draw the button (docs/18 §8.2).
    final bool cancelable =
        outgoing && kCancelableStatuses.contains(status);
    // ★ 0.2.49 — **the button is drawn only for the two states that can act on
    // it.** 0.2.48 added `|| sourceUnavailable` here, i.e. the bare disk fact, and
    // that fact is true on **every completed Android send** (its cache copy has
    // just been cleaned up) — so every delivered file grew a 「重新发送」 it could
    // never use. `_sourceWarning` would have narrowed that to "genuinely lost
    // files", but the narrowing is not enough: `ConversationController.canResend`
    // refuses anything that is not `failed` / `canceled`, so on a **`done`** row
    // this button has exactly one destiny — permanently grey. A control that can
    // never be pressed is the thing this project keeps deleting (docs/18 §8.2), and
    // the row already says 「源文件不可用」 next to a red mark; a dead button adds
    // nothing but a thing to tap that does not answer.
    //
    // So: no `|| _sourceWarning`. The mark still reports the loss (that is
    // [_sourceWarning]'s other three readers), the button simply is not offered
    // where it could not work.
    final bool resendable = outgoing &&
        (status == MessageStatus.failed || status == MessageStatus.canceled);
    final VoidCallback? cancel = onCancel;
    final VoidCallback? resend = onResend;
    // A ≥44px hit target (M5c §5): the actions are reached for in a hurry, and a
    // missed tap on 重新发送 is exactly when it hurts.
    final ButtonStyle actionStyle =
        TextButton.styleFrom(minimumSize: const Size(44, 44));
    final List<Widget> buttons = <Widget>[
      // A `failed` / `canceled` row whose source is provably gone cannot be
      // re-sent **this moment**, so the button is drawn **disabled** rather than
      // hidden: the row above already says 源文件不可用, and hiding it would leave
      // the user guessing whether he mis-tapped. The authority on "can this be
      // re-sent" stays `canResend` (it re-`exists` every path, so restoring the
      // file re-enables it); this is only the synchronous face of the same answer,
      // which a `build` cannot await.
      if (resendable && resend != null)
        TextButton(
          style: actionStyle,
          onPressed: _sourceWarning ? null : resend,
          child: const Text('重新发送'),
        ),
      if (cancelable && cancel != null)
        TextButton(
          style: actionStyle,
          onPressed: cancel,
          child: const Text('取消'),
        ),
    ];
    if (buttons.isEmpty) {
      return null;
    }
    return Row(mainAxisSize: MainAxisSize.min, children: buttons);
  }
}

/// Copies a **whole text message** to the clipboard and says so (0.2.31).
///
/// This is what the 「复制」button under a text bubble runs ([onCopyText]). It is
/// the surviving half of 0.2.27's `showMessageTextMenu`: the *menu* is gone —
/// that gesture now belongs to the selection layer, where 复制 means "copy the
/// range I just dragged" — but the two rules that menu got right are kept
/// verbatim, because they are about the clipboard, not about the gesture:
///
/// * **what is copied is the message body, exactly** — no time, no status, no
///   quotation marks, no trailing decoration. The user asked to get his own words
///   out of the app; anything else would have to be deleted again by hand;
/// * the clipboard write is `await`ed **before** the confirmation appears: a
///   toast that says 已复制 while the clipboard is still empty is a lie the user
///   can catch by pasting (the same rule `attachment_menu.dart` follows).
Future<void> copyMessageText(
  BuildContext context, {
  required String text,
}) async {
  // A text message with an empty body (only reachable through a hand-built
  // model — the composer refuses to send one) has nothing to offer.
  if (text.isEmpty) {
    return;
  }
  // Captured before the first `await`: the button can outlive this frame, and
  // `ScaffoldMessenger.of(context)` after it may run on a dead element.
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  await Clipboard.setData(ClipboardData(text: text));
  // 0.2.36: a floating 2 s notice that clears the composer (see `ui/notices.dart`).
  showTransientNoticeOn(messenger, '已复制', bottomInset: kComposerNoticeInset);
}

/// The inline `bytes_done / bytes_total` bar shown while transferring.
///
/// **One bar per message, whatever the number of attachments (0.2.49).** The
/// numbers it draws are the message's aggregate
/// (`selectors.dart::MessageTransferProgress`), and [ordinal] adds 「第 k/N 个」
/// in front of them — the batch's position, which is the only signal that keeps
/// moving when a single huge file pins the percentage.
///
/// The bar is always determinate ([TransferProgress.bytesTotal] `> 0`), so it
/// never spins forever and never blocks `pumpAndSettle`; an unknown total
/// ([TransferProgress.bytesTotal] `<= 0`) renders the byte label without a bar.
///
/// When the total is known the label also carries the **percentage** (A4-1 /
/// M5 §3.6 / W1): `已传 / 总量 · NN%`. This is a **pure addition** on the shared
/// label — the screenshot/desktop rendering gains the suffix and the `total <=
/// 0` downgrade below is untouched, so no existing label behaviour changes.
///
/// **0.2.25 — the remaining time.** Asked "要不要等？", a percentage has no
/// answer, so the same line gains `剩 3 分 20 秒` after the percentage. It is a
/// `StatefulWidget` for exactly one reason: a rate needs a *history*, and this
/// widget is where the successive [progress] values arrive. It owns a
/// [RemainingTimeEstimator] and feeds it one sample per build — **no timer** is
/// created here (the progress updates themselves are already throttled by the
/// controller's 1 Hz poll; a second clock would only be a second thing to leak,
/// which this project has already paid for once).
///
/// The estimate is `null` — and therefore invisible — whenever the estimator
/// says it has nothing honest to say: less than
/// [kRemainingTimeMinSpan] of history, a stalled link, an unknown total, or an
/// absurd projection. Nothing is drawn then, not a placeholder and not `∞`.
class _ProgressBar extends StatefulWidget {
  const _ProgressBar({
    required this.progress,
    required this.clock,
    this.ordinal,
  });

  final TransferProgress progress;

  /// Where each sample's timestamp comes from (see [MessageBubble.clock]).
  final Clock clock;

  /// 「第 k/N 个」, or `null` (see [MessageBubble.progressOrdinal]).
  ///
  /// Passed in, never derived here: the bar sees one aggregate number and cannot
  /// know how many files a batch has.
  final String? ordinal;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  /// One estimator per mounted progress bar, i.e. per in-flight transfer. It
  /// resets itself when the byte counter restarts (a retry), so a new attempt
  /// never inherits the previous one's rate.
  final RemainingTimeEstimator _estimator = RemainingTimeEstimator();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int total = widget.progress.bytesTotal;
    final int done = widget.progress.bytesDone;
    // `total > 0` → `已传 / 总量 · NN%` (clamped to 0..100, floored). `total <=
    // 0` keeps the existing "already-sent bytes only" label — never a fake
    // percentage, never a `-1 B` (A4-2).
    final String label = total > 0
        ? '${fileSizeText(done)} / ${fileSizeText(total)}'
            ' · ${(done / total * 100).clamp(0, 100).floor()}%'
        : fileSizeText(done);
    // Sampled **in build** on purpose: every rebuild is a new observation of
    // `bytes_done`, and that is exactly the history the rate needs. It is not
    // new state to react to, so no `setState` is involved.
    final Duration? remaining = _estimate(total);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (total > 0)
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (done / total).clamp(0.0, 1.0).toDouble(),
            ),
          ),
        const SizedBox(height: 4),
        // The ETA joins the percentage **on the same line** (`Wrap`, not a
        // `Row`: on a 320 dp phone the pair is wider than the bubble, and a
        // `Row` would overflow instead of dropping the ETA to a second line).
        // Same `bodySmall` size, muted colour, so it reads as a remark on the
        // numbers rather than as another number competing with them.
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: <Widget>[
            // ★ 0.2.49 — 「第 2/5 个」 leads the line, because it is the answer to
            // *"is this still going?"* and the numbers after it are the answer to
            // *"how much longer?"*. Slightly heavier than the bytes: the batch
            // position is the moving part, the percentage is the slow one. Absent
            // for a one-file message and for a batch with nothing in flight, so a
            // lone bubble's line is exactly what it was.
            if (widget.ordinal != null)
              Text(
                widget.ordinal!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            Text(label, style: theme.textTheme.bodySmall),
            if (remaining != null)
              Text(
                remainingTimeText(remaining),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
      ],
    );
  }

  /// The remaining-time estimate for the current [TransferProgress], or `null`.
  ///
  /// The timestamp is read here — once per build — and handed to the estimator
  /// with the byte counter; the estimator itself never looks at a clock.
  Duration? _estimate(int total) {
    if (total <= 0) {
      return null;
    }
    return _estimator.addSample(
      bytesDone: widget.progress.bytesDone,
      at: widget.clock.nowUtc(),
      bytesTotal: total,
    );
  }
}

/// Turns "press, then move" on one attachment into **one** drag-out request
/// (0.2.45).
///
/// Three properties, and each one is the answer to a real failure:
///
/// * **It is a pan, not a tap and not a long press.** Those two already mean
///   something on an attachment row — open the file, open its menu — so a drag
///   may only start once the pointer has *moved*: down alone does nothing, and a
///   click that ends where it started never reaches [kDragOutSlop].
/// * **It fires once.** The OS drag loop ([MessageBubble.onDragOut] →
///   `PlatformPorts.startDrag` → `DoDragDrop`) is **modal**: while the user drags,
///   this widget keeps receiving moves, and every one of them would otherwise
///   start a second, nested drag. [_started] is released only by the next press.
/// * **The threshold is measured from the press point.** Flutter's pan recogniser
///   accepts a *mouse* drag after about one pixel, so a threshold taken from the
///   recogniser's own start would fire on the tremor of a click; from
///   [DragDownDetails.globalPosition] the number means what [kDragOutSlop] says.
///
/// The gesture is mounted only where the caller wired [MessageBubble.onDragOut]
/// (Windows), and it inserts nothing but a hit-test proxy — no render object that
/// could move a pixel of the row, which is what keeps the bubble's geometry
/// contract with 0.2.44 intact.
class _DragOutDetector extends StatefulWidget {
  const _DragOutDetector({required this.onStart, required this.child});

  /// Invoked once the pointer has moved past [kDragOutSlop].
  final VoidCallback onStart;

  /// The attachment's card.
  final Widget child;

  @override
  State<_DragOutDetector> createState() => _DragOutDetectorState();
}

class _DragOutDetectorState extends State<_DragOutDetector> {
  /// Where the pointer came down (global, so it is comparable to the drag
  /// updates' `globalPosition`), or `null` between gestures.
  Offset? _pressOrigin;

  /// Whether this gesture already asked for a drag.
  bool _started = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Default `HitTestBehavior.deferToChild`: the row / card already owns its
      // own hit area, and making this opaque would let the wrapper absorb presses
      // the bubble's existing targets (the tile's tap, the card's `InkWell`) are
      // entitled to.
      onPanDown: (DragDownDetails details) {
        _pressOrigin = details.globalPosition;
        _started = false;
      },
      // Both callbacks are consulted, and that is not belt-and-braces: the pan
      // recogniser reports `onPanStart` on the event that **wins the arena**, so a
      // move large enough to be accepted in one go (a fast flick, or one synthetic
      // pointer event) arrives there with everything it has and never sends an
      // update. Listening only to `onPanUpdate` would drop exactly those drags.
      onPanStart: (DragStartDetails details) =>
          _maybeStart(details.globalPosition),
      onPanUpdate: (DragUpdateDetails details) =>
          _maybeStart(details.globalPosition),
      onPanEnd: (DragEndDetails details) => _reset(),
      onPanCancel: _reset,
      child: widget.child,
    );
  }

  /// Starts the drag once the pointer is [kDragOutSlop] away from the press, and
  /// never twice for the same press.
  void _maybeStart(Offset globalPosition) {
    final Offset? origin = _pressOrigin;
    if (origin == null || _started) {
      return;
    }
    if ((globalPosition - origin).distance < kDragOutSlop) {
      return;
    }
    // Set **before** the call: the drag loop is modal, so a re-entrant update
    // would otherwise start a second drag on top of the first.
    _started = true;
    widget.onStart();
  }

  void _reset() {
    _pressOrigin = null;
    _started = false;
  }
}
