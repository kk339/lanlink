/// The **directory page** of a folder message (0.2.38 / `docs/22` §5.2, T05).
///
/// One send = one message = one folder; this page walks **into** it. The
/// hierarchy is not stored anywhere — it is derived from the attachments'
/// `relativePath` by `domain/folder_tree.dart`, so this file is only presentation
/// and navigation.
///
/// **One implementation, two doors** (`device_profile.dart`'s rule): the page is
/// pushed from `conversation_thread`, which is the same widget in the phone shell
/// and in the desktop's right pane — so both surfaces reach the same route. What
/// differs is only what fits: `docs/22` §5.3 pins the breakpoint at **720 logical
/// px of this page's own width** (a `LayoutBuilder`, never `MediaQuery`: in the
/// three-pane desktop the right pane is far narrower than the window — the lesson
/// from 0.2.36's bubble cap):
///
/// | width | shape |
/// |---|---|
/// | `>= 720` | `发送人` + `发送时间` columns and their header, 56 dp rows |
/// | `< 720` | no columns, no header; `9.4 MB · 小甲 · 10月23日` on the second line |
///
/// **What is deliberately absent** (`docs/22` §8, and the round's own list):
/// a search box, a grid/list toggle, multi-select / batch download, and a
/// separate "download" button — the desktop keeps the existing ⤓ = open
/// semantics, and the ⋯ menu is the existing attachment menu, unchanged.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/folder_tree.dart';
import '../../domain/models.dart';
import '../format.dart';
import '../scope.dart';
import '../theme.dart';
import '../widgets/attachment_menu.dart';
import '../widgets/empty_state.dart';
import '../widgets/type_icon.dart';

/// The width at which the two meta columns appear (`docs/22` §5.3).
const double kFolderColumnsBreakpoint = 720;

/// Row height on the wide layout — the reference screenshot's density.
const double kFolderRowHeightWide = 56;

/// Row height where the meta line wraps under the name (the phone shape).
const double kFolderRowHeightNarrow = 64;

/// The square each row action occupies (⤓ / ⋯) — the smallest click target this
/// project allows a row action (`tap_target_fix_test`), which is what still fits
/// on a 360 dp phone next to a long file name.
const double kFolderActionSlot = 36;

/// A pushed page that browses **inside** one folder message.
class FolderBrowsePage extends StatefulWidget {
  /// Creates the page for [message], whose `folderName` is the root's name.
  ///
  /// [subtitle] is the peer's alias — the `发送人` of every row (one folder is one
  /// send, so all its files share one sender and one timestamp).
  const FolderBrowsePage({
    super.key,
    required this.message,
    required this.subtitle,
  });

  /// The folder message. Its `id` is how the files are read (once, in `build`:
  /// the page must not depend on a conversation controller that can be disposed
  /// while the route is on the stack).
  final ChatMessage message;

  /// The peer's alias, printed in the 发送人 column / inline meta.
  final String subtitle;

  @override
  State<FolderBrowsePage> createState() => _FolderBrowsePageState();
}

class _FolderBrowsePageState extends State<FolderBrowsePage> {
  /// The directory **names** from the root down to the level on screen.
  ///
  /// Drilling down is a `setState` on this list rather than a `push`: the
  /// breadcrumb is the only expression of depth (`docs/22` §5.2), and stacked
  /// routes would give the user two ways to go "back" that disagree.
  List<String> _path = const <String>[];

  String get _rootName => widget.message.folderName ?? '';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // Read on every build: the list is an in-memory map (`repo.filesOf`), a
    // folder holds at most 200 rows, and re-deriving it keeps the page live if a
    // late file lands while it is open.
    final List<FileAttachment> files =
        context.deps.repo.filesOf(widget.message.id);
    final List<FolderEntry> root = buildFolderTree(files);
    final List<FolderEntry> entries = _resolve(root) ?? root;

    return Focus(
      // Same reason as `device_profile`: with nothing focused the route's
      // `FocusScope` would eat the first key press; `autofocus` puts this node in
      // the chain, so Esc pops on a desktop that has no system back button.
      autofocus: true,
      onKeyEvent: _handleKey,
      child: Scaffold(
        backgroundColor: surfaceList(theme),
        appBar: AppBar(
          title: Text(
            _rootName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // No ⋯ on the right: every entry it could hold (rename / delete the
          // folder / batch download) is on the round's "not doing" list.
        ),
        body: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool wide = constraints.maxWidth >= kFolderColumnsBreakpoint;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _breadcrumb(context, theme),
                if (wide) _columnHeader(theme),
                if (wide) const Divider(height: 1, thickness: 1),
                Expanded(
                  child: entries.isEmpty
                      ? const EmptyState(
                          title: '这个文件夹里没有可显示的文件',
                          message: '发送方还没有传完，或者这些文件没有携带目录信息',
                          icon: Icons.folder_open_outlined,
                        )
                      : ListView.separated(
                          padding: EdgeInsets.zero,
                          itemCount: entries.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1, thickness: 1),
                          itemBuilder: (BuildContext context, int index) =>
                              _row(context, theme, entries[index], wide: wide),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Esc pops (desktop); everything else is left alone.
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      unawaited(Navigator.of(context).maybePop());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The entries at [_path], or `null` when the path no longer exists (a file
  /// list that shrank under us) — the caller then falls back to the root for
  /// that frame instead of throwing.
  List<FolderEntry>? _resolve(List<FolderEntry> root) {
    List<FolderEntry> level = root;
    for (final String segment in _path) {
      final int index = level.indexWhere(
        (FolderEntry e) => e.isDirectory && e.name == segment,
      );
      if (index < 0) {
        return null;
      }
      level = level[index].children;
    }
    return level;
  }

  // ── breadcrumb ───────────────────────────────────────────────────────────

  /// `文件夹名 › data › deep` — the first crumb is the folder itself, and the
  /// last one is not tappable (you are already there).
  ///
  /// **One deliberate difference from the reference app:** its leftmost crumb is
  /// `文件` (the file module's root). We are pushed from a conversation and have
  /// no such module to return to, so the row starts at the folder name
  /// (`docs/22` §5.2).
  Widget _breadcrumb(BuildContext context, ThemeData theme) {
    final List<String> crumbs = <String>[_rootName, ..._path];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < crumbs.length; i++) ...<Widget>[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  '›',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            _crumb(context, theme, crumbs[i], index: i, last: i == crumbs.length - 1),
          ],
        ],
      ),
    );
  }

  Widget _crumb(
    BuildContext context,
    ThemeData theme,
    String label, {
    required int index,
    required bool last,
  }) {
    final bool current = index == _path.length;
    final TextStyle? style = theme.textTheme.bodyMedium?.copyWith(
      color: last
          ? theme.colorScheme.onSurface
          : theme.colorScheme.onSurfaceVariant,
      fontWeight: last ? FontWeight.w600 : null,
    );
    final Widget text = ConstrainedBox(
      // A root folder name can be long (`lanlink-电脑版-0.2.33-正式版`); the
      // crumb keeps one line and ellipsises rather than pushing the trail off
      // screen — the reference screenshot shows exactly that truncation.
      constraints: const BoxConstraints(maxWidth: 180),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
    if (current) {
      return text;
    }
    return InkWell(
      onTap: () => setState(() {
        _path = _path.sublist(0, index);
      }),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        child: text,
      ),
    );
  }

  // ── columns + rows ───────────────────────────────────────────────────────

  Widget _columnHeader(ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        child: Row(
          children: <Widget>[
            const Spacer(),
            SizedBox(
              width: _senderWidth,
              child: Text('发送人', style: _metaStyle(theme)),
            ),
            SizedBox(
              width: _timeWidth,
              child: Text('发送时间', style: _metaStyle(theme)),
            ),
            // The two action buttons' gutter, so the header lines up with the
            // rows' text columns instead of floating over the icons.
            const SizedBox(width: kFolderActionSlot * 2),
          ],
        ),
      );

  static const double _senderWidth = 140;
  static const double _timeWidth = 96;

  TextStyle? _metaStyle(ThemeData theme) => theme.textTheme.bodySmall
      ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

  Widget _row(
    BuildContext context,
    ThemeData theme,
    FolderEntry entry, {
    required bool wide,
  }) {
    final String size = fileSizeText(entry.size);
    final String time = timeText(widget.message.createdAt);
    final String day = dayText(widget.message.createdAt);
    // Phone shape (no columns): everything the wide row splits into three cells
    // is folded onto one `·`-separated line — `9.4 MB · 小甲 · 10月23日`.
    final String inlineMeta = '$size · ${widget.subtitle} · $day';

    return InkWell(
      onTap: () => _activate(entry),
      child: SizedBox(
        height: wide ? kFolderRowHeightWide : kFolderRowHeightNarrow,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: <Widget>[
              _leading(theme, entry),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      entry.name,
                      // One line, ellipsised: a long DLL name must not push the
                      // actions off a 360 dp phone (`docs/22` §5.3).
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (!wide) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        inlineMeta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _metaStyle(theme),
                      ),
                    ],
                  ],
                ),
              ),
              if (wide) ...<Widget>[
                SizedBox(
                  width: _senderWidth,
                  child: Text(
                    widget.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _metaStyle(theme),
                  ),
                ),
                SizedBox(
                  width: _timeWidth,
                  child: Text(time, style: _metaStyle(theme)),
                ),
              ],
              // ⤓ = open (the same action as tapping the row), and ⋯ = the
              // existing attachment menu. Two entries, both already implemented —
              // no new menu was written for this page (`docs/22` §5.2).
              _action(
                theme,
                icon: Icons.download_outlined,
                tooltip: entry.isDirectory ? '打开文件夹' : '打开',
                onPressed: (_) => _activate(entry),
              ),
              _action(
                theme,
                icon: Icons.more_horiz,
                tooltip: '更多',
                onPressed: entry.file == null
                    ? null
                    : (BuildContext button) => _showMenu(button, entry.file!),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _leading(ThemeData theme, FolderEntry entry) {
    if (entry.isDirectory) {
      // Amber, matching the bubble's folder card: the same object, the same
      // colour, on both screens.
      return Icon(Icons.folder, size: 24, color: Colors.amber.shade700);
    }
    return TypeIcon(
      fileName: entry.name,
      mime: entry.file?.mime,
      size: 24,
      color: theme.colorScheme.onSurfaceVariant,
    );
  }

  /// One row action in a 36 dp square (the smallest slot this project allows a
  /// row action — `tap_target_fix_test` — and what keeps both icons on a 360 dp
  /// row).
  ///
  /// [onPressed] receives the **button's own** `BuildContext` through a
  /// [Builder]: the ⋯ menu has to open under the button that was pressed, and the
  /// page's context would put it in the top-left corner instead.
  Widget _action(
    ThemeData theme, {
    required IconData icon,
    required String tooltip,
    required void Function(BuildContext button)? onPressed,
  }) =>
      Builder(
        builder: (BuildContext button) => SizedBox(
          width: kFolderActionSlot,
          height: kFolderActionSlot,
          child: IconButton(
            padding: EdgeInsets.zero,
            iconSize: 18,
            tooltip: tooltip,
            onPressed: onPressed == null ? null : () => onPressed(button),
            icon: Icon(icon),
          ),
        ),
      );

  /// A directory drills in; a file opens through the platform.
  ///
  /// ★ **`localPath`, never `relativePath`** (`docs/22` §5.2): after publishing,
  /// the relative path no longer points at the disk (Android flattens the tree
  /// into `Download/<子目录>/`), so joining `relativePath` onto anything would
  /// produce a path that does not exist. The attachment already carries the
  /// saved path.
  void _activate(FolderEntry entry) {
    if (entry.isDirectory) {
      setState(() {
        _path = <String>[..._path, entry.name];
      });
      return;
    }
    final String? path = entry.file?.localPath;
    if (path != null && path.isNotEmpty) {
      unawaited(context.deps.platform.openFile(path));
    }
  }

  /// Opens the **existing** attachment menu under the ⋯ button (`docs/22` §5.2:
  /// reuse it, do not write a second one).
  Future<void> _showMenu(BuildContext button, FileAttachment file) async {
    final RenderBox? box = button.findRenderObject() as RenderBox?;
    final Offset position = box == null
        ? Offset.zero
        : box.localToGlobal(Offset(box.size.width, box.size.height));
    await showAttachmentMenu(button, file: file, position: position);
  }
}
