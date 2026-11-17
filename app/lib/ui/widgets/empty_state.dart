/// The empty-state view (spec §2, PRD §4.1–§4.3 / §6).
///
/// Strictly distinct from the loading state ([LoadingState]): an empty state
/// means "we looked and there is nothing", never "we are still looking". The
/// generic constructor takes caller-supplied copy (so each pane keeps its own
/// wording); the named constructors cover the app's standard empties with the
/// PRD's exact copy, keeping those strings in one place.
///
/// Layering (M4 §8.1): `ui/**` imports only `package:flutter/**` and this
/// package's `domain/**`; never `lanlink_core` / `lanlink_store` / `dart:io`.
library;

import 'package:flutter/material.dart';

/// A centred icon + title (+ optional message / footer) empty state.
class EmptyState extends StatelessWidget {
  /// Creates an empty state with explicit copy.
  ///
  /// [footer] is any extra widget shown below (e.g. [TroubleshootHints] on the
  /// conversations list).
  const EmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
    this.footer,
  });

  /// The conversations "no devices" empty (reuses the four troubleshooting hints
  /// as [footer]).
  const EmptyState.devices({super.key, this.footer})
      : title = '还没有发现设备',
        message = '请确认对方已打开 lanlink，且两台设备连在同一个局域网',
        icon = Icons.devices_other_outlined;

  /// The conversation "no messages" empty (PRD §4.2).
  const EmptyState.messages({super.key})
      : title = '还没有传输记录',
        message = '点下面的入口发第一份文件',
        icon = Icons.send_outlined,
        footer = null;

  /// The recent-files "no files" empty (PRD §4.3).
  const EmptyState.files({super.key})
      : title = '还没有文件记录',
        message = null,
        icon = Icons.folder_open_outlined,
        footer = null;

  /// The right-pane global placeholder shown when no conversation is selected
  /// (PRD §6) — the detail pane must never be a blank hole.
  const EmptyState.rightPlaceholder({super.key})
      : title = '左侧选一台设备开始',
        message = null,
        icon = Icons.devices_other_outlined,
        footer = null;

  /// The right-pane "this conversation has no files" empty (PRD §4).
  const EmptyState.conversationFiles({super.key})
      : title = '本会话还没有文件',
        message = null,
        icon = Icons.folder_open_outlined,
        footer = null;

  /// The primary line.
  final String title;

  /// The optional secondary line.
  final String? message;

  /// The leading icon.
  final IconData icon;

  /// Optional extra widget below the copy.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurfaceVariant;
    final String? secondary = message;
    final Widget? tail = footer;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48, color: muted),
            const SizedBox(height: 12),
            Text(
              title,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (secondary != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                secondary,
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                textAlign: TextAlign.center,
              ),
            ],
            if (tail != null) ...<Widget>[
              const SizedBox(height: 16),
              tail,
            ],
          ],
        ),
      ),
    );
  }
}
