/// The loading-state view (spec §2 `loading_state.dart`, PRD §4.1–§4.3).
///
/// Deliberately a **different widget** from [EmptyState] so "still searching" is
/// never mistaken for "found nothing" (A2-2). The progress bar is indeterminate,
/// so it animates forever — widget tests must `pump` a fixed duration rather
/// than `pumpAndSettle`, or pass `showProgress: false`.
///
/// Layering (M4 §8.1): `ui/**` imports only `package:flutter/**` and this
/// package's `domain/**`; never `lanlink_core` / `lanlink_store` / `dart:io`.
library;

import 'package:flutter/material.dart';

/// A centred progress bar + message.
class LoadingState extends StatelessWidget {
  /// Creates a loading state.
  ///
  /// [showProgress] = `false` hides the bar (useful for tests that settle).
  const LoadingState({
    super.key,
    this.message = '正在发现设备…',
    this.showProgress = true,
  });

  /// The message shown under the bar.
  final String message;

  /// Whether to draw the (indeterminate) progress bar.
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (showProgress) ...<Widget>[
            const LinearProgressIndicator(),
            const SizedBox(height: 16),
          ],
          Text(
            message,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
