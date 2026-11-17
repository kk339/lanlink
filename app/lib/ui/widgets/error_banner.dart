/// The persistent error banner (spec §2 `error_banner.dart`, PRD §4.1 / E10).
///
/// A pure view: a human-readable message plus an optional retry action. It is
/// meant to stay pinned at the top of a page (发现层失败不静默, A2-14) rather
/// than to disappear on its own — the controller owns when it is shown.
///
/// Layering (M4 §8.1): `ui/**` imports only `package:flutter/**` and this
/// package's `domain/**`; never `lanlink_core` / `lanlink_store` / `dart:io`.
library;

import 'package:flutter/material.dart';

/// A full-width error strip with an optional retry button.
class ErrorBanner extends StatelessWidget {
  /// Creates an error banner.
  ///
  /// [onRetry] = `null` hides the action (an unrecoverable error); when given, a
  /// button labelled [retryLabel] is shown.
  const ErrorBanner({
    super.key,
    required this.message,
    this.onRetry,
    this.retryLabel = '重试',
    this.icon = Icons.error_outline,
  });

  /// The human-readable error text.
  final String message;

  /// Called when retry is tapped, or `null` to omit the action.
  final VoidCallback? onRetry;

  /// The retry button label.
  final String retryLabel;

  /// The leading icon.
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final VoidCallback? retry = onRetry;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: <Widget>[
          Icon(icon, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
          if (retry != null)
            TextButton(onPressed: retry, child: Text(retryLabel)),
        ],
      ),
    );
  }
}
