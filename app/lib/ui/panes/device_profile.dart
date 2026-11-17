/// 媒体与文件页 (docs/18 §3.1) — one peer's profile, and **the media wall**.
///
/// The wall is "the transfer record **with this device**" — the user's own
/// wording, kept as the spec's 口径 even though Flix's screenshot could also be
/// read as "everything on that device" (§0-A 口径 2: the two readings are kept
/// side by side, and this implements the user's).
///
/// **What is deliberately absent** (§3.1's own table, applied consistently):
///  * 跨设备复制粘贴 — no such capability;
///  * 「清空消息记录」 — we archive, we do not hard-delete; a real delete would
///    change the data layer, which is out of a UI round;
///  * **消息通知 / 自动接收 (per device)** — §3.1 marks these "做" on the ground
///    that "我们有对应能力". **That ground does not hold**: `SettingsController`
///    has only *global* settings, and the store has no per-device preference —
///    so a switch here could not change anything, and a control that does
///    nothing is the one shape this whole round keeps ruling out (§8.2, and the
///    user's own "宁可形状差一点，不要一个假的菜单项").
///    Reported before building rather than shipped as two dead switches.
///  * the ✎ beside the name — same reason: there is no "rename a peer" ability
///    (only our own alias is ours to change), so it would be a dead affordance.
///
/// Phone-only: it is pushed from the conversation bar and is never mounted by
/// the wide/compact layouts.
///
/// **0.2.27 — no longer phone-only.** The desktop / compact conversation header
/// now carries the same 媒体与文件 entry (`detail_pane.dart`), in the same slot
/// beside the name, so this page is reached from both layouts through the same
/// `Navigator.push`. Nothing about the page is duplicated per platform: one
/// implementation, two doors. Because a desktop has a keyboard and no system
/// back button, [build] also turns Esc into a pop — see [_handleKey].
///
/// **0.2.28 — the wall adapts to a desktop width.** The user's report: *"电脑
/// 会话的那个文件分类适配做的不行，看起来像是直接把手机上的放到电脑上，导致
/// 很多东西看着放大了许多"*. The wall's column count was the literal `2` in
/// `(maxWidth - 2·padding) / 2`, so the card edge grew with the window and
/// nothing else did: the pushed page is the **full window** width, so on a
/// 1400×1000 desktop each square measured **685×685** (measured, not guessed).
/// The wall now asks how many columns fit at a capped edge ([kWallCardMaxSide],
/// [_wallColumns]) and gives the extra width to **more files per row**; a narrow
/// (phone) surface keeps the shipped shape and the shipped formula untouched —
/// see [_wall].
///
/// **0.2.59 — a card is now something you can act on.** The wall used to be
/// **inert**: no `onTap`, no menu, on any platform (`_card` returned a bare
/// `Column`). The two things it gains, and why exactly there:
///  * **单击 → 打开** through `openLocalPath` — the single implementation the
///    timeline and the 文件 tab already use, so the three surfaces cannot answer
///    "file is gone" differently. A broken card is **not** blocked: it opens
///    nothing and says 「文件已不在原位置，无法打开」, which is what the timeline
///    does, and the alternative (a card that swallows the tap) is the one shape
///    the round forbids;
///  * **长按 / 右键 → 打开 · 转到消息** — the second entry is what this page was
///    asked for: pick a file here, land on the message it came in with. The id
///    travels back as the **route's result** (`Navigator.pop(messageId)`), and
///    the two doors that push this page hand it to
///    `ConversationController.requestReveal`. Nothing is duplicated per
///    platform in this file either: the GestureDetector carries both the
///    long-press and the secondary-tap-down, and `showFastMenu` decides nothing
///    but the row height.
///
/// The entry's own label is 「媒体与文件」 (it was 「设备设置」, which promised
/// per-device settings this page deliberately has none of). The `AppBar` title is
/// still the **device name** — that is what the page is about, and it never said
/// otherwise.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models.dart';
import '../../domain/selectors.dart';
import '../../domain/source_availability.dart';
import '../format.dart';
import '../scope.dart';
import '../shell/shell_module.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/fast_menu.dart';
import '../widgets/file_thumbnail.dart';
import '../widgets/open_local_path.dart';

/// The widest a wall card may get, in logical px (0.2.28).
///
/// **Why a cap at all.** Without one, `side` is a function of the window width
/// only, so a desktop shows the phone layout blown up — the user's exact words.
///
/// **Why 240.** The edge is bounded from below by what a card has to hold: the
/// 「来源 时间」 line, whose time half is `yyyy-MM-dd HH:mm` at `bodyMedium`
/// (~118 px on the app's real font, ~228 px under the widget-test font, which
/// is about twice as wide). 240 keeps that line on **one** line with a name
/// beside it; the bottom of the suggested 200–240 band does not, which is why
/// the top of it is the value.
const double kWallCardMaxSide = 240;

/// The gap between two wall cards — and between two grid columns (0.2.28).
///
/// 12 logical px: the app's small step (`docs/19`), one and a half seams. It is
/// also part of the column maths ([_wallColumns]) so the last column lands on
/// the trailing padding instead of leaving a ragged sliver.
const double kWallCardGap = 12;

/// The gap between the source name and the time inside a card's meta line.
const double kMetaLineGap = 8;

/// Which slice of the wall is shown. **Three, not Flix's four**: we have no
/// `FileKind.text`, and the wall's subject is *files*, not text messages
/// (§3.1, user-ruled).
enum _WallFilter {
  images('图片'),
  videos('视频'),
  files('文件');

  const _WallFilter(this.label);

  final String label;
}

/// One peer's profile + media wall (docs/18 §3.1).
class DeviceProfilePage extends StatefulWidget {
  /// Creates the page for [peer], showing the record of [conversationId].
  const DeviceProfilePage({
    super.key,
    required this.peer,
    required this.conversationId,
  });

  /// The peer this page is about.
  final PeerDevice peer;

  /// The conversation whose files make up the wall.
  final String conversationId;

  @override
  State<DeviceProfilePage> createState() => _DeviceProfilePageState();
}

class _DeviceProfilePageState extends State<DeviceProfilePage> {
  _WallFilter _filter = _WallFilter.images;

  /// The wall's **broken state**, judged by the same rule as every other surface
  /// (0.2.48).
  ///
  /// This page used to be the **fourth** copy of "is the file still there": a
  /// private `Map<String, bool>` of broken cards plus its own `exists` loop, next
  /// to the timeline's `_probeSources`, the 文件 tab's (non-existent) probe and
  /// `RecentFilesController`'s `Set`. Four surfaces, four chances to disagree
  /// about one file — and the wall is the one the user compares by eye, because
  /// it shows the same attachments as thumbnails.
  ///
  /// It now reads [SourceAvailability], the same object (type, not instance) the
  /// other three use, so 「损毁」 here and 「源文件不可用」 there are one judgement.
  final SourceAvailability _sources = SourceAvailability();

  @override
  void initState() {
    super.initState();
    // ★ After the first frame, **not** directly: the probe reads `context.deps`,
    // and touching an inherited widget before `initState` completes throws
    // ("dependOnInheritedWidgetOfExactType<AppScope>() … called before … completed").
    // The widget test caught this — the page would have thrown the moment a user
    // opened it, which is exactly what judgements are for.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_probeSources());
    });
  }

  Future<void> _probeSources() async {
    await _sources.probeFiles(
      <FileAttachment>[
        for (final ConversationFileItem item in _items()) item.file,
      ],
      context.deps.platform,
    );
    if (mounted) {
      setState(() {});
    }
  }

  /// Whether one card is in the 损毁 state.
  ///
  /// Two facts, and only one of them is the shared judgement:
  /// * **no `localPath` at all** ⇒ broken. That was this page's own rule before
  ///   0.2.48 (a null/empty path was recorded as broken) and it stays:
  ///   [SourceAvailability] deliberately reads "unknown" as **present** — a row
  ///   must not be accused before the probe answers — and a card with nothing to
  ///   point at has no thumbnail to draw either;
  /// * **a path that is off disk** ⇒ broken, and that half is [SourceAvailability]
  ///   `.isOnDisk`, i.e. exactly what the timeline, the 文件 tab and the 最近文件
  ///   page ask.
  bool _isBroken(FileAttachment file) {
    final String? path = file.localPath;
    if (path == null || path.isEmpty) {
      return true;
    }
    return !_sources.isOnDisk(path);
  }

  /// The wall's data: the same builder the conversation's 文件 tab uses — no new
  /// query (§3.1: 复用、不新增查询). It carries the owning message's time, which
  /// is what each card's header shows.
  List<ConversationFileItem> _items() {
    final List<ChatMessage> messages =
        context.deps.repo.history(widget.conversationId);
    return buildConversationFiles(
      messages: messages,
      filesByMessage: <String, List<FileAttachment>>{
        for (final ChatMessage message in messages)
          message.id: context.deps.repo.filesOf(message.id),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // A pushed page, so Esc means "back" (0.2.27): a desktop has no system back
    // button and the ← this `AppBar` draws automatically is a mouse trip.
    //
    // `autofocus` is what makes the key reach [_handleKey]: `onKeyEvent` fires
    // for the focused node **and its ancestors**, and with nothing focused the
    // route's own `FocusScope` — an ancestor of this node — would consume the
    // first key press instead. A non-focusable, unpainted wrapper changes nothing
    // visible, and a key pressed while a descendant holds focus still bubbles
    // through here, so Esc works no matter what was clicked last.
    return Focus(
      autofocus: true,
      onKeyEvent: _handleKey,
      child: Scaffold(
        backgroundColor: surfaceList(theme),
        appBar: AppBar(
          title: Text(
            widget.peer.alias.isEmpty
                ? shortFingerprint(widget.peer.fingerprint)
                : widget.peer.alias,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _filterRow(theme),
            Expanded(child: _wall(context, theme)),
          ],
        ),
      ),
    );
  }

  /// Esc → pop, i.e. the keyboard's ← (0.2.27). Any other key is ignored, so
  /// nothing else on this page changes behaviour.
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      unawaited(Navigator.of(context).maybePop());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 图片 / 视频 / 文件 — selected = bold + the accent (docs/18 §3.1).
  Widget _filterRow(ThemeData theme) => Padding(
        padding:
            const EdgeInsets.fromLTRB(kListRowPadding, 8, kListRowPadding, 4),
        child: Row(
          children: <Widget>[
            for (final _WallFilter filter in _WallFilter.values)
              Padding(
                padding: const EdgeInsets.only(right: 20),
                child: InkWell(
                  onTap: () => setState(() => _filter = filter),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        filter.label,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: filter == _filter
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.onSurfaceVariant,
                          fontWeight: filter == _filter
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        height: 2,
                        width: filter.label.length * 16,
                        color: filter == _filter ? accent : Colors.transparent,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );

  /// The wall: a **card flow** of squares, each preceded by a grey
  /// 「来源 时间」 line (§3.1 — the spec corrected "list" to "card flow").
  ///
  /// Two shapes, chosen by the surface's own width (0.2.28):
  ///  * **narrow** (`< kNarrowBreakpoint`, i.e. the phone shell's page): the
  ///    shipped shape, **byte for byte** — the edge is still
  ///    `(width - 2·padding) / 2` and each row still carries one square, which
  ///    is the "card flow" the wall shipped with and the look the user calls
  ///    right ("现在手机上的观感是对的"). Not one number moves here.
  ///  * **wide** (desktop / compact): [_wideWall] — columns derived from the
  ///    width, edge capped at [kWallCardMaxSide], extra width spent on more
  ///    files per row instead of on bigger files.
  Widget _wall(BuildContext context, ThemeData theme) {
    final List<ConversationFileItem> items = _items()
        .where((ConversationFileItem item) => _matches(item.file))
        .toList();
    if (items.isEmpty) {
      return const EmptyState(
        title: '这里还没有文件',
        message: '与该设备的传输记录会出现在这里',
        icon: Icons.photo_library_outlined,
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available =
            math.max(0, constraints.maxWidth - kListRowPadding * 2);
        if (constraints.maxWidth < kNarrowBreakpoint) {
          // ★ The phone path, unchanged. `available / 2` *is*
          // `(maxWidth - kListRowPadding * 2) / 2` — the same expression the
          // shipped page used, kept in one place so the two cannot drift.
          final double side = available / 2;
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(
                kListRowPadding, 4, kListRowPadding, 24),
            itemCount: items.length,
            itemBuilder: (BuildContext context, int index) =>
                _card(context, theme, items[index], side),
          );
        }
        return _wideWall(context, theme, items, available);
      },
    );
  }

  /// How many columns fit in [available] px at a capped card edge (0.2.28).
  ///
  /// The rule is Flutter's own (`SliverGridDelegateWithMaxCrossAxisExtent`):
  /// as many whole columns as the cap allows, rounded **up**, so the extra
  /// width becomes another column rather than a bigger card. The gap is folded
  /// into both numerator and denominator, which is what guarantees two things
  /// at once:
  ///  * `columns ≥ (available + gap) / (cap + gap)` ⇒ the edge
  ///    `(available - (columns-1)·gap) / columns` is **≤ cap**, never above it;
  ///  * the last column ends exactly on the trailing padding — no ragged strip.
  ///
  /// The phone never reaches this: at `available = 730` (a 760-wide window) it
  /// already yields 3 columns.
  static int _wallColumns(double available) => math.max(
        2,
        ((available + kWallCardGap) / (kWallCardMaxSide + kWallCardGap)).ceil(),
      );

  /// The wide wall: a real grid, computed from the width (0.2.28).
  ///
  /// Rows are laid out by hand rather than through `GridView` / `SliverGrid`:
  /// a grid delegate needs a `childAspectRatio`, i.e. it needs each card's
  /// height *before* the card is built, and that height is text (the
  /// 「来源 时间」 line) which moves with the system text scale. Getting the
  /// ratio wrong is the classic "last row is clipped" bug, so here a row is a
  /// plain [Row] and its height is whatever its cards turn out to be.
  ///
  /// Lazy all the same: the builder is driven by **rows**, so only the rows in
  /// (and near) the viewport are built — a 500-file wall does not build 500
  /// thumbnails.
  Widget _wideWall(
    BuildContext context,
    ThemeData theme,
    List<ConversationFileItem> items,
    double available,
  ) {
    final int columns = _wallColumns(available);
    final double side = (available - (columns - 1) * kWallCardGap) / columns;
    final int rows = (items.length + columns - 1) ~/ columns;
    return ListView.builder(
      padding:
          const EdgeInsets.fromLTRB(kListRowPadding, 4, kListRowPadding, 24),
      itemCount: rows,
      itemBuilder: (BuildContext context, int row) {
        final int first = row * columns;
        return Row(
          // Top-aligned: every card starts with its meta line, and a row whose
          // cells grew to different heights must not push a card's header down
          // out of the row's rhythm.
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int column = 0; column < columns; column++) ...<Widget>[
              if (column > 0) const SizedBox(width: kWallCardGap),
              // `Expanded` rather than a fixed width: the cells then divide the
              // row's *actual* width, so `n·side + (n-1)·gap` can never drift
              // past the row by a rounding error and paint an overflow stripe.
              Expanded(
                child: first + column < items.length
                    ? _card(context, theme, items[first + column], side)
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        );
      },
    );
  }

  bool _matches(FileAttachment file) {
    final FileClass kind = classifyFile(file.fileName, mime: file.mime);
    return switch (_filter) {
      _WallFilter.images => kind == FileClass.image,
      _WallFilter.videos => kind == FileClass.video,
      // "文件" is everything that is not an image or a video — the wall is about
      // files, so documents / audio / archives all belong here.
      _WallFilter.files => kind != FileClass.image && kind != FileClass.video,
    };
  }

  /// One wall card: the 「来源 时间」 line, then the square (0.2.59 adds the
  /// three gestures to the square **only** — the meta line above it stays text
  /// you can read, not a third hit target competing with the card).
  Widget _card(
    BuildContext context,
    ThemeData theme,
    ConversationFileItem item,
    double side,
  ) {
    // The source is the peer's own name for a received file and our alias for a
    // sent one, which is what the reference shows.
    final String source = widget.peer.alias.isEmpty
        ? shortFingerprint(widget.peer.fingerprint)
        : widget.peer.alias;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 「来源  时间」 — **exactly as wide as the square below it** (0.2.59).
        //
        // The defect: this `Padding` had no width, the `Column` is
        // `CrossAxisAlignment.start`, and the wall's list gives its children the
        // **tight** row width. So the line measured the whole row — 570 on a
        // 600-wide phone whose card is 285, and up to 1370 on a desktop whose
        // cards are capped at 240 — and the time floated far to the right of the
        // card it belongs to. On the desktop it was the obvious one.
        //
        // `SizedBox(width: side)` is the whole fix and it changes **nothing
        // else**: the square's edge, the column count and the 240 cap are
        // untouched, and [_metaLine] keeps its own `LayoutBuilder` +
        // `FittedBox(scaleDown)` order of sacrifice — the time is still never
        // ellipsised, it is scaled down if a narrow card cannot hold it at full
        // size (at 180 px the real-font `yyyy-MM-dd HH:mm` is ~118 px and fits
        // outright; the widget-test font is ~2× wider and takes the scale path).
        SizedBox(
          width: side,
          child: Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 6),
            child: _metaLine(theme, item, source),
          ),
        ),
        _cardSurface(context, theme, item, side),
      ],
    );
  }

  /// The square itself — the thumb / 损毁 card **and** its three gestures.
  ///
  /// **Why this layer.** The gestures belong to the painted square and to
  /// nothing else: the 「来源 时间」 line above is a caption, and making the whole
  /// `Column` tappable would give the card a hit area larger than the thing the
  /// user sees. So the `GestureDetector` wraps exactly the `side × side` box,
  /// which is the same box the reference shows as "the file".
  ///
  /// **Why `HitTestBehavior.opaque`.** The box's *child* is a thumbnail or a
  /// centred glyph; neither fills the square (a `Center` + `Icon` hits only the
  /// glyph's bounds, and a decode failure falls back to a small type icon). With
  /// the default `deferToChild` a tap on the empty margin of a card would land
  /// on the page behind it — i.e. a card that looks clickable and is not.
  ///
  /// **All three handlers are registered on every platform**, deliberately:
  /// `onLongPressStart` is what a finger produces and `onSecondaryTapDown` what
  /// a mouse does, and a touch-screen Windows device legitimately produces both.
  /// Splitting them by `platform.isMobile` would add a second place where "what
  /// is a phone" is decided, for no behaviour the user could observe.
  /// `onLongPressStart` (not `onLongPress`) because the menu opens **at the
  /// finger**, exactly like the right-click opens at the cursor.
  ///
  /// **A broken card stays tappable**: this handler never consults [_isBroken].
  /// [openLocalPath] is the one place that decides what "cannot open" means and
  /// says it out loud (「文件已不在原位置，无法打开」) — the same answer the
  /// timeline and the 文件 tab give. [_isBroken] keeps its single job: choosing
  /// between the thumbnail and the 损毁 card.
  Widget _cardSurface(
    BuildContext context,
    ThemeData theme,
    ConversationFileItem item,
    double side,
  ) {
    final FileAttachment file = item.file;
    final bool broken = _isBroken(file);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 单击 → 打开, through the one shared implementation (the timeline's and
      // the 文件 tab's), so the three surfaces cannot drift apart.
      onTap: () => unawaited(openLocalPath(
        context,
        path: file.localPath,
        sources: _sources,
        onRepaint: () => setState(() {}),
      )),
      // 长按 (phone) / 右键 (desktop) → 打开 · 转到消息.
      onLongPressStart: (LongPressStartDetails details) =>
          unawaited(_showCardMenu(context, item, details.globalPosition)),
      onSecondaryTapDown: (TapDownDetails details) =>
          unawaited(_showCardMenu(context, item, details.globalPosition)),
      child: Container(
        width: side,
        height: side,
        decoration: BoxDecoration(
          color: cardSurface(theme),
          borderRadius: BorderRadius.circular(kRadiusCard),
        ),
        clipBehavior: Clip.antiAlias,
        child: broken
            // ★ 损毁态: the white card + a centred orange torn-page glyph.
            // The colour comes from the `dangerBroken` slot — the spec created
            // that slot for exactly this state, so it is not a hex written here.
            ? Center(
                child: Icon(Icons.broken_image_outlined,
                    size: side * 0.22, color: dangerBroken),
              )
            : FileThumbnail(
                fileName: file.fileName,
                mime: file.mime,
                path: file.localPath,
                unavailable: false,
                edge: side,
                radius: kRadiusCard,
                preserveAspect: false,
              ),
      ),
    );
  }

  /// The card's secondary menu: 「打开」 then 「转到消息」 (0.2.59).
  ///
  /// Written the way the rest of the app writes a context menu
  /// (`widgets/attachment_menu.dart`): the **position is given by the gesture**
  /// (long-press start / secondary tap down) and `showFastMenu` flips and clamps
  /// it, so no `RenderBox` has to be measured here. Row height is the same
  /// split that menu uses — 48 under a finger, 36 under a mouse — because 48 is
  /// a *touch* floor and five-to-nine 48-px rows read as a long airy strip with
  /// a mouse.
  ///
  /// **Both rows really do something** (the repo's one hard rule about menus):
  ///  * 「打开」 — [openLocalPath], the same call as the single tap. It is
  ///    **greyed out** when this card is already drawn as 损毁, which is a
  ///    statement about *this* menu only: it cannot work, and the codebase's
  ///    rule (docs/19 §9.6) is "an entry that could not work is greyed out or not
  ///    built". Note the card's own tap is **not** greyed — it answers with
  ///    「文件已不在原位置」 instead, so the user still gets the reason. The
  ///    enabled flag is [_isBroken]'s verdict, i.e. the **same** one that decided
  ///    to paint the 损毁 card, so the two can never disagree (a fresh `exists`
  ///    probe here would let a card look healthy while its 打开 row was dead).
  ///  * 「转到消息」 — closes this page with the owning message's id as the
  ///    route's result. The page does not know (and must not know) what the
  ///    conversation does with it: `ConversationController.requestReveal` owns
  ///    that, and the two entries that pushed this page are the ones that call
  ///    it. `ConversationFileItem.messageId` is already on the item — no lookup,
  ///    no second query.
  Future<void> _showCardMenu(
    BuildContext context,
    ConversationFileItem item,
    Offset position,
  ) async {
    final FileAttachment file = item.file;
    final bool mobile = context.deps.platform.isMobile;
    final String? choice = await showFastMenu(
      context,
      position: position,
      rowHeight: mobile ? kMinInteractiveDimension : 36,
      // Order is fixed (and asserted by a test): 打开 is what the card's own tap
      // does, so it leads; 转到消息 is the page-level trip, so it follows.
      items: <FastMenuItem>[
        FastMenuItem(value: 'open', label: '打开', enabled: !_isBroken(file)),
        const FastMenuItem(value: 'reveal', label: '转到消息'),
      ],
    );
    // Dismissed (a tap on the barrier / Esc) ⇒ nothing happened at all: no
    // notice, no navigation, no state change.
    if (choice == null || !context.mounted) {
      return;
    }
    switch (choice) {
      case 'open':
        await openLocalPath(
          context,
          path: file.localPath,
          sources: _sources,
          onRepaint: () => setState(() {}),
        );
      case 'reveal':
        // The page's whole answer: hand the message id back to whoever pushed
        // it (`phone_shell` / `detail_pane` → `requestReveal`).
        Navigator.of(context).pop(item.messageId);
    }
  }

  /// The 「来源  时间」 line above a card: name on the left, time on the right
  /// (the reference's own header).
  ///
  /// **The time is the one thing that may not be cut (0.2.28).** A wide card is
  /// at most [kWallCardMaxSide] wide while `dateTimeText` is `yyyy-MM-dd HH:mm`
  /// — ~118 px on the real font but ~228 px under the widget-test font, so on a
  /// narrow column the two cannot simply share a `Row` (that is a
  /// `RenderFlex overflow`, and ellipsising the time is what the round forbids).
  /// The order of sacrifice is therefore explicit:
  ///
  ///  1. the **name** gives up all of its space first (`Expanded` + ellipsis),
  ///     which is also what keeps 「来源」 and 「时间」 pinned to opposite ends;
  ///  2. if even the time alone would not fit, it is **scaled down** by
  ///     `FittedBox(scaleDown)` — the paragraph is still laid out at its
  ///     intrinsic width and only the *paint* shrinks, so the whole string is
  ///     drawn, on one line, never truncated.
  ///
  /// The `LayoutBuilder` is what makes the row's parts add up to exactly the
  /// row's width: the time is capped at `maxWidth - gap`, so the name's share
  /// can go to zero but the sum cannot exceed the constraint.
  Widget _metaLine(
    ThemeData theme,
    ConversationFileItem item,
    String source,
  ) {
    final TextStyle? style = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double timeMaxWidth =
            math.max(0, constraints.maxWidth - kMetaLineGap);
        return Row(
          children: <Widget>[
            Expanded(
              child: Text(
                source,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            const SizedBox(width: kMetaLineGap),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: timeMaxWidth),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  dateTimeText(item.messageCreatedAt),
                  maxLines: 1,
                  softWrap: false,
                  style: style,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
