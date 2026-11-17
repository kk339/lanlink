/// One file row: type icon (or image thumbnail) + name + size (spec §2).
///
/// Reused by the message bubble (one row per attached file) and the recent
/// files pages. It renders the size through `ui/format.dart::fileSizeText` (so
/// `size == -1` shows "未知大小", never "0 B"). When the file is an **image** and
/// a [path] is given, the leading slot becomes a real [FileThumbnail] (PRD §5);
/// otherwise it is the [TypeIcon] fallback (design §1.3).
///
/// When [unavailable] the row is dimmed and [unavailableLabel] replaces the
/// size — the conversation passes "源文件不可用" (A2-18), the recent files page
/// "文件已不在原位置" (PRD §4.3). A thumbnail for an [unavailable] file reads
/// nothing and falls back to the icon (PRD §8-G30).
///
/// Layering (M4 §8.1): `ui/**` imports only `package:flutter/**` and this
/// package's `domain/**`; never `lanlink_core` / `lanlink_store` / `dart:io`.
library;

import 'package:flutter/material.dart';

import '../../domain/selectors.dart';
import '../format.dart';
import '../theme.dart';
import 'file_thumbnail.dart';
import 'type_icon.dart';

/// A single file line (leading icon or thumbnail + name + size).
class FileTile extends StatelessWidget {
  /// Creates a file tile.
  ///
  /// [size] is the byte count (`-1` = unknown → "未知大小"). [path] is the
  /// on-disk location, used only to render an image thumbnail; `null` keeps the
  /// type icon. [trailing] is an optional trailing widget (e.g. a status
  /// indicator, a direction/time marker). [unavailable] flags a file that is no
  /// longer on disk and disables the tap.
  const FileTile({
    super.key,
    required this.fileName,
    required this.size,
    this.mime,
    this.path,
    this.onTap,
    this.trailing,
    this.unavailable = false,
    this.unavailableLabel = '文件已不在原位置',
  });

  /// File name on the wire.
  final String fileName;

  /// Size in bytes (`-1` = unknown).
  final int size;

  /// MIME type, or `null` to classify by [fileName].
  final String? mime;

  /// On-disk path, or `null` — only used for the image thumbnail.
  final String? path;

  /// Called when the row is tapped, or `null` for a non-interactive row.
  final VoidCallback? onTap;

  /// Optional trailing widget.
  final Widget? trailing;

  /// Whether the underlying file is missing on disk.
  final bool unavailable;

  /// The note shown (in place of the size) when [unavailable] is `true`.
  final String unavailableLabel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color nameColor = unavailable
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onSurface;
    final Widget row = Row(
      children: <Widget>[
        _leading(context),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: nameColor),
              ),
              Text(
                unavailable ? unavailableLabel : fileSizeText(size),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        if (trailing != null) ...<Widget>[const SizedBox(width: 8), trailing!],
      ],
    );

    final Widget content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: row,
    );
    // Every row is held to Material's 48 hit-box floor (kMinTapTarget), tappable
    // or not: a non-tappable row shorter than a tappable one would make the same
    // list jagged. Measured 44 before this (test/widget/tap_target_fix_test.dart).
    final Widget faded = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinTapTarget),
      child: Opacity(opacity: unavailable ? 0.6 : 1, child: content),
    );
    if (onTap == null || unavailable) {
      return faded;
    }
    return InkWell(
      onTap: onTap,
      // PRD §2.5: hovering a tappable row gives visible feedback (the shared
      // neutral hover fill). Requires a Material ancestor — the panes supply a
      // transparent one, since their surface colour is opaque.
      borderRadius: BorderRadius.circular(kRadiusThumb),
      child: faded,
    );
  }

  /// The leading slot: a real thumbnail for an image **or a video** with a path,
  /// else the icon.
  ///
  /// Video joined this gate later than the thumbnail widget itself did: until it
  /// did, a video attachment always fell through to the plain icon on the
  /// conversation row (the user's report — "视频传输过去还是一个图标在会话里").
  /// [FileThumbnail] already knew how to read a frame and draws the ▶ itself;
  /// only this condition kept it out. Its own `_shouldLoad` still decides *per
  /// platform* whether a frame is read, so this gate is about **routing**, not
  /// about loading.
  Widget _leading(BuildContext context) {
    final String? location = path;
    final FileClass cls = classifyFile(fileName, mime: mime);
    if (location != null &&
        location.isNotEmpty &&
        (cls == FileClass.image || cls == FileClass.video)) {
      return FileThumbnail(
        fileName: fileName,
        mime: mime,
        path: location,
        unavailable: unavailable,
        edge: kListIconDiameter,
      );
    }
    return TypeIcon(
      fileName: fileName,
      mime: mime,
      size: 20,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }
}
