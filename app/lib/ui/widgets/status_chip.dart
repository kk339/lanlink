/// The single status renderer (spec §2 `status_chip.dart`, §8.4).
///
/// The seven-state **text** comes from `ui/format.dart::statusText` and the
/// **colour** from `ui/theme.dart::statusColor` — this widget inlines neither,
/// so it is the one place a [MessageStatus] becomes pixels. That keeps the
/// "rejected ≠ failed" copy contract (A2-7) and the palette in one source.
///
/// It is intentionally animation-free (a flat coloured dot + label), so page
/// and widget tests may call `pumpAndSettle` freely; any in-flight spinner /
/// progress belongs to the bubble, not to the status map.
///
/// Layering (M4 §8.1): `ui/**` imports only `package:flutter/**` and this
/// package's `domain/**`; never `lanlink_core` / `lanlink_store` / `dart:io`.
library;

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../format.dart';
import '../theme.dart';

/// Renders a [MessageStatus] as its unique copy + colour.
class StatusChip extends StatelessWidget {
  /// Creates a status chip.
  ///
  /// When [compact] is `true` only the text is drawn (for dense rows such as a
  /// bubble footer); otherwise a leading status-coloured dot is included.
  const StatusChip({
    super.key,
    required this.status,
    this.compact = false,
  });

  /// The lifecycle state to render.
  final MessageStatus status;

  /// Whether to drop the leading dot and show the label only.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final Color color = statusColor(status);
    final Text label = Text(
      statusText(status),
      style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
    );
    if (compact) {
      return label;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        label,
      ],
    );
  }
}
