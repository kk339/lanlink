/// The right pane's file detail (design §1.4; PRD §1.4).
///
/// A large preview (a real thumbnail for an image, else a large type icon), the
/// file name, its size, the direction and time, the owning conversation
/// (tappable — jumps back to the conversations module) and the two actions.
///
/// **The actions are platform-dependent (M5 §E — the same intent, a different
/// landing per platform):** a **mobile** build offers 「打开 / 分享」 (Android has
/// no "show me the folder"), a **desktop** build keeps 「打开文件 /
/// 打开所在位置」 unchanged. [isMobile] selects which; the default (`false`) is
/// the desktop wording, so the desktop pane renders byte-for-byte as before.
///
/// Opening is **only** available here (never on the middle-pane row tap), so a
/// file whose source is gone can never be opened (PRD §8-F26).
///
/// **Layering (design §9.6):** imports only `package:flutter/**` and this
/// package's `domain/**` + sibling `ui/**`; never `dart:io` / `dart:ffi` /
/// `lanlink_core` / `lanlink_store`.
library;

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/selectors.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/fade_in.dart';
import '../widgets/file_thumbnail.dart';
import '../widgets/type_icon.dart';

/// The detail view of one selected recent file.
class FileDetail extends StatelessWidget {
  /// Creates the file detail.
  ///
  /// [onOpen] / [onReveal] / [onShare] are `null` when there is no local path
  /// (the buttons render disabled). [onOpenConversation] jumps to the owning
  /// conversation. [isMobile] selects the mobile actions (打开 / 分享) instead
  /// of the desktop ones (打开文件 / 打开所在位置).
  const FileDetail({
    super.key,
    required this.fileName,
    required this.size,
    this.mime,
    this.path,
    required this.direction,
    required this.at,
    required this.conversationLabel,
    this.onOpenConversation,
    this.onOpen,
    this.onReveal,
    this.onShare,
    this.isMobile = false,
    this.available = true,
  });

  /// File name on the wire.
  final String fileName;

  /// Size in bytes (`-1` = unknown).
  final int size;

  /// MIME type, or `null` to classify by [fileName].
  final String? mime;

  /// On-disk path, or `null` (no open/reveal, no thumbnail).
  final String? path;

  /// Whether the file was received or sent.
  final MessageDirection direction;

  /// When the owning message was created.
  final DateTime at;

  /// The owning conversation's display label.
  final String conversationLabel;

  /// Called to jump to the owning conversation, or `null`.
  final VoidCallback? onOpenConversation;

  /// Called to open the file, or `null`.
  final VoidCallback? onOpen;

  /// Called to reveal the file in the OS file manager, or `null`.
  final VoidCallback? onReveal;

  /// Called to share the file via the OS share sheet, or `null`.
  final VoidCallback? onShare;

  /// Whether this is a mobile build (selects 打开 / 分享 over the desktop
  /// 打开文件 / 打开所在位置 — M5 §E).
  final bool isMobile;

  /// Whether the file is still available on disk.
  final bool available;

  /// The preview edge (design §5.1: at most 320×320).
  static const double _previewEdge = 320;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? location = path;
    final bool canPreview = available &&
        location != null &&
        location.isNotEmpty &&
        classifyFile(fileName, mime: mime) == FileClass.image;
    final Widget preview = canPreview
        ? FileThumbnail(
            fileName: fileName,
            mime: mime,
            path: location,
            edge: _previewEdge,
            radius: kRadiusCard,
            // The large preview must not distort: keep the source ratio within
            // the 320×320 cap (PRD §5) — same rule as a bubble's single image.
            preserveAspect: true,
            // On a phone the preview itself is tap-to-open (M5 §D); the desktop
            // keeps its non-tappable preview (the 打开文件 button remains).
            onTap: isMobile && available ? onOpen : null,
          )
        : TypeIcon(
            fileName: fileName,
            mime: mime,
            size: 96,
            color: theme.colorScheme.onSurfaceVariant,
          );

    return FadeIn(
      child: Material(
        type: MaterialType.transparency,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Center(child: preview),
              const SizedBox(height: 20),
              Text(
                fileName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                fileSizeText(size),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Text(
                '${directionText(direction)} · ${dateTimeText(at)}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              _conversationRow(context),
              const SizedBox(height: 20),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: available ? onOpen : null,
                    icon: const Icon(Icons.open_in_new),
                    label: Text(isMobile ? '打开' : '打开文件'),
                  ),
                  // The secondary intent ("do something else with this file")
                  // lands differently per platform (M5 §E): a phone has no
                  // "folder to reveal", so it shares; a desktop keeps reveal.
                  if (isMobile)
                    OutlinedButton.icon(
                      onPressed: available ? onShare : null,
                      icon: const Icon(Icons.share),
                      label: const Text('分享'),
                    )
                  else
                    OutlinedButton.icon(
                      onPressed: available ? onReveal : null,
                      icon: const Icon(Icons.folder_outlined),
                      label: const Text('打开所在位置'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The "所属会话" line (tappable when a callback is supplied).
  Widget _conversationRow(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final VoidCallback? onTap = onOpenConversation;
    final Widget row = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          Icons.forum_outlined,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            '所属会话：$conversationLabel',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.primary),
          ),
        ),
      ],
    );
    if (onTap == null) {
      return row;
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(kRadiusThumb),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: row,
      ),
    );
  }
}
