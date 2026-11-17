/// The persistent **informational** banner (P0-7 follow-up).
///
/// The sibling of [ErrorBanner], but in **neutral** colours on purpose: red is
/// reserved for real failures (a service that actually broke), so it stays
/// meaningful. "Someone tried to send and we refused by policy" is information,
/// not an error — it is often the designed outcome (the receive switch is off),
/// and a red strip would read as "the app is broken".
///
/// Like [ErrorBanner] it is a pure view: it stays pinned until the controller
/// clears it (the caller owns [onDismiss]).
///
/// Layering (M4 §8.1): `ui/**` imports only `package:flutter/**` and this
/// package's `domain/**`; never `lanlink_core` / `lanlink_store` / `dart:io`.
library;

import 'package:flutter/material.dart';

/// A full-width neutral info strip with an optional dismiss action.
class NoticeBanner extends StatelessWidget {
  /// Creates a notice banner.
  ///
  /// [onDismiss] = `null` hides the action; when given, a button labelled
  /// [dismissLabel] is shown.
  const NoticeBanner({
    super.key,
    required this.message,
    this.onDismiss,
    this.dismissLabel = '知道了',
    this.icon = Icons.info_outline,
  });

  /// The human-readable message.
  final String message;

  /// Called when the dismiss action is tapped, or `null` to omit it.
  final VoidCallback? onDismiss;

  /// The dismiss button label.
  final String dismissLabel;

  /// The leading icon.
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final VoidCallback? dismiss = onDismiss;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: <Widget>[
          Icon(icon, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style:
                  theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
            ),
          ),
          if (dismiss != null)
            TextButton(onPressed: dismiss, child: Text(dismissLabel)),
        ],
      ),
    );
  }
}
