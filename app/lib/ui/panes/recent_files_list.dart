/// The middle pane's `最近文件` body (design §1.3 / §1.4; rewritten from
/// `recent_files_page`).
///
/// A **read-only** view of every file ever sent or received. All grouping (by
/// local day), classification (the seven category tabs) and search live in
/// [RecentFilesController] — which delegates to the pure selectors of
/// `domain/selectors.dart` — so this widget **only renders**.
///
/// Tapping a row **selects** it for the right pane's file detail (via
/// [ShellController.selectRecentFile]); opening the file is the detail pane's
/// explicit action, not the row tap (design §1.4). A row whose source file is
/// gone (`sourceMissing`) is dimmed and cannot be tapped at all (PRD §8-F26:
/// "点击不打开").
///
/// The row passes the file's `path` to [FileTile] so image rows render a real
/// thumbnail (PRD §5) — the exact wiring the old page omitted.
///
/// **Layering (design §9.6):** imports only `package:flutter/**`, this package's
/// `domain/**`, `controllers/**` and sibling `ui/**` — never `dart:io` /
/// `dart:ffi` / `lanlink_core` / `lanlink_store`.
library;

import 'package:flutter/material.dart';

import '../../controllers/recent_files_controller.dart';
import '../../domain/models.dart';
import '../../domain/selectors.dart';
import '../format.dart';
import '../shell/shell_controller.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/file_tile.dart';
import '../widgets/loading_state.dart';

/// The category tabs in display order (`any` is the "全部" tab) — PRD §4.3:
/// 全部 / 图片 / 视频 / 音频 / 安装包 / 压缩包 / 文档.
const List<FileKind> _tabOrder = <FileKind>[
  FileKind.any,
  FileKind.image,
  FileKind.video,
  FileKind.audio,
  FileKind.installer,
  FileKind.archive,
  FileKind.document,
];

/// The label of a category tab.
///
/// **Exhaustive** over [FileKind]: adding a value to the enum is a compile
/// error here until it is given a tab label (this is why `document` had to be
/// added alongside A's `FileKind` change).
String _tabLabel(FileKind kind) => switch (kind) {
      FileKind.any => '全部',
      FileKind.image => '图片',
      FileKind.video => '视频',
      FileKind.audio => '音频',
      FileKind.installer => '安装包',
      FileKind.archive => '压缩包',
      FileKind.document => '文档',
    };

/// The recent-files body: search box + category tabs + grouped list.
class RecentFilesList extends StatelessWidget {
  /// Creates the recent-files body.
  ///
  /// [files] is the app-level recent-files controller (data); [selection] is the
  /// shared shell state, written to when a row is chosen.
  const RecentFilesList({
    super.key,
    required this.files,
    required this.selection,
  });

  /// The recent-files data + query + tab.
  final RecentFilesController files;

  /// The shell selection (a row tap selects it for the right pane).
  final ShellController selection;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: files,
      builder: (BuildContext context, Widget? child) => _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (files.all.isLoading) {
      return const LoadingState(message: '正在整理最近文件…');
    }
    if (files.all.valueOrNull?.isEmpty ?? true) {
      return const EmptyState.files();
    }
    final List<RecentFileItem> visible = files.visible;
    return Column(
      children: <Widget>[
        _searchField(context),
        _tabs(),
        const Divider(height: 1),
        Expanded(
          child: visible.isEmpty
              ? const EmptyState(
                  title: '没有匹配的文件',
                  message: '换个关键词试试',
                  icon: Icons.search_off,
                )
              : ListView(
                  // The first group's header keeps the same air as the gaps
                  // between groups (docs/18 §3.2), so nothing is glued to the
                  // divider above it.
                  padding: const EdgeInsets.only(top: kCardGap),
                  children: _rows(context),
                ),
        ),
      ],
    );
  }

  /// The white rounded search box the reference page shows (docs/18 §3.2).
  ///
  /// The **search itself is unchanged** — same `TextField`, same `onChanged`
  /// wiring to [RecentFilesController.setQuery]; only its skin moves (filled
  /// white, no outline), which is why no behaviour can regress here.
  Widget _searchField(BuildContext context) => Padding(
        padding:
            const EdgeInsets.fromLTRB(kListRowPadding, 12, kListRowPadding, 8),
        child: TextField(
          onChanged: files.setQuery,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            // 「筛选」, matching the device list's field (0.2.57). Same control,
            // same behaviour — `files.setQuery` only filters the rows already in
            // this list (`RecentFilesController.setQuery` touches a field and
            // notifies) — so it must not be the one box that still says 搜索.
            hintText: '筛选文件名',
            filled: true,
            fillColor: cardSurface(Theme.of(context)),
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(kRadiusCard),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      );

  /// The category row, as **underline tabs** (docs/18 §3.2) — the reference's
  /// selected tab is bold with a bar under it, not a filled chip.
  ///
  /// A [Wrap], **not** a horizontal scroller: on a phone the seven tabs line up
  /// in **one row** (what the reference shows), but in a **narrow pane** — the
  /// 320px middle column of a compact window — they wrap onto a second line
  /// rather than pushing the last ones out of reach. That reachability is not
  /// cosmetic: `tester.tap(find.text('文档'))` fails when the seventh tab sits
  /// outside the pane, and it also means a real user could not pick the last
  /// category at all. The previous `ChoiceChip`s wrapped, so this keeps that
  /// behaviour and only changes the skin.
  Widget _tabs() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: kListRowPadding),
        child: Wrap(
          children: <Widget>[
            for (final FileKind kind in _tabOrder) _tab(kind),
          ],
        ),
      );

  Widget _tab(FileKind kind) => Builder(
        builder: (BuildContext context) {
          final ThemeData theme = Theme.of(context);
          final bool selected = files.tab == kind;
          return InkWell(
            onTap: () => files.setTab(kind),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Container(
                // The bar is **always laid out** (transparent when unselected),
                // so choosing a tab never shifts the row by a pixel. Its colour
                // is the §1 slot — never a hand-written hex, and specifically
                // not the reference's own blue, which the user ruled out.
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: selected ? statusNetwork : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  _tabLabel(kind),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: selected
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          );
        },
      );

  /// One block per date group: a grey header, then that group's rows inside
  /// **one white card** (docs/18 §3.2) — the reference draws a card per group,
  /// with the 1px line *inside* the card and the air *between* the groups.
  List<Widget> _rows(BuildContext context) {
    final List<Widget> blocks = <Widget>[];
    for (final MapEntry<String, List<RecentFileItem>> group
        in files.grouped.entries) {
      blocks.add(_groupBlock(context, group.key, group.value));
    }
    return blocks;
  }

  Widget _groupBlock(
    BuildContext context,
    String date,
    List<RecentFileItem> items,
  ) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      // The horizontal page inset only. The air between groups is the bottom
      // [kCardGap], so `nextHeader.top - thisCard.bottom == kCardGap` holds
      // exactly — which is what the criterion measures.
      padding: const EdgeInsets.fromLTRB(
          kListRowPadding, 0, kListRowPadding, kCardGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _groupHeader(context, date, items.length),
          Container(
            key: ValueKey<String>('recent-card-$date'),
            decoration: BoxDecoration(
              color: cardSurface(theme),
              borderRadius: BorderRadius.circular(kRadiusCard),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: <Widget>[
                // Rows are separated by **air**, not by a hairline.
                //
                // ★ UNVERIFIED — keep it labelled that way: the reference image
                // is downscaled (~486px for a ~1080px phone), so a 1px line would
                // be invisible in it **either way**. "I cannot see a line" is NOT
                // "there is no line". The line was removed on the lead's
                // judgement; it is cheap to restore (one `if (i > 0) Divider(…)`).
                // On the on-device watch-list — not a measured fact.
                for (final RecentFileItem item in items)
                  _itemTile(context, item),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupHeader(BuildContext context, String date, int count) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      key: ValueKey<String>('recent-group-$date'),
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 6),
      child: Text(
        // The reference reads `01.07 | 1 项`, in small grey type.
        '$date | $count 项',
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _itemTile(BuildContext context, RecentFileItem item) {
    return Padding(
      // The row now sits *inside* a card, so the page inset is the card's job;
      // this vertical padding is the air between two rows (see the UNVERIFIED
      // note above — the reference's row separation is not a measured fact).
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: FileTile(
        fileName: item.file.fileName,
        size: item.file.size,
        mime: item.file.mime,
        // ★ The wiring the old page missed: hand the path down so an image row
        // renders a real thumbnail instead of the type-icon fallback.
        path: item.file.localPath,
        unavailable: item.sourceMissing,
        trailing: Text(
          directionText(item.direction),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        onTap: () => selection.selectRecentFile(
          fileId: item.file.id,
          messageId: item.messageId,
        ),
      ),
    );
  }
}
