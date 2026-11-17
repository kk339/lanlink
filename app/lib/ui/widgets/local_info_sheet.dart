/// The phone's **本机信息 sheet** (docs/18 §3.3) — device alias, LAN address,
/// port and fingerprint, sliding **up from the bottom**, full-bleed across the
/// screen width, over a dimmed backdrop.
///
/// **No QR code** — the user ruled "add it when there is a real scan-to-pair
/// landing" (§3.3), so this sheet deliberately draws none. Do not add one here
/// without that landing existing.
///
/// **What is measured vs taken as a tier** (the rule we keep: don't dress a guess
/// up as a measurement):
///  * **full-bleed** — measured: the Flix sheet's top row spans the full 1200px
///    screenshot width (its edges are the screen edges, not a floating card);
///  * **backdrop** — the *composite* was measured as `#CCCCCC` over our
///    `#EEEFF4` page. The scrim's own colour was **not** measured, so the barrier
///    below is **derived** (black at ~14%) to reproduce that composite. Labelled
///    as derived, not measured.
///  * **top corner radius** — the corners **are** rounded (visible in the shot)
///    but the **radius was not measured**. This takes `kRadiusCard` (12) **as a
///    tier**, chosen because it already exists in the app rather than picking an
///    arbitrary 12-or-16 — **it is not a measured value.**
library;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Identifies the sheet for tests (`find.byKey(kLocalInfoSheetKey)`).
const Key kLocalInfoSheetKey = ValueKey<String>('local-info-sheet');

/// One label/value line in the sheet.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// The sheet body: alias / address / port / fingerprint.
class LocalInfoSheet extends StatelessWidget {
  /// Creates the sheet body.
  const LocalInfoSheet({
    super.key,
    required this.alias,
    required this.address,
    required this.port,
    required this.fingerprint,
  });

  /// This device's display name.
  final String alias;

  /// This device's LAN address, or a placeholder when the NIC is not chosen yet.
  final String address;

  /// The listening port.
  final int port;

  /// This device's identity fingerprint.
  final String fingerprint;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // The drag handle: also the visual cue that this came up from below.
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('本机信息', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _Field(label: '设备别名', value: alias),
            _Field(label: '本机 IP', value: address),
            _Field(label: '端口', value: '$port'),
            _Field(label: '指纹', value: fingerprint),
          ],
        ),
      ),
    );
  }
}

/// Slides the local-info sheet up from the bottom.
///
/// Full-bleed by construction: a modal bottom sheet spans the whole width unless
/// constrained, and this adds no width constraint (docs/18 §3.3).
Future<void> showLocalInfoSheet(
  BuildContext context, {
  required String alias,
  required String address,
  required int port,
  required String fingerprint,
}) {
  return showModalBottomSheet<void>(
    context: context,
    // Derived from the measured composite (black @ ~14% over our #EEEFF4 page);
    // see the file header — this is NOT a measured colour.
    // Derived from the measured composite (black @ ~14% over our #EEEFF4 page);
    // see the file header — this is NOT a measured colour. (The framework's own
    // default is black54 = ~54%, i.e. much darker than Flix's read — verified by
    // temporarily reverting this line and measuring the barrier.)
    barrierColor: const Color(0x24000000),
    // Surface: left to the theme's default (M3 surface) — the same surface the
    // rest of the app's sheets/dialogs use, so it follows light/dark for free.
    // Rounded top corners: a TIER (= kRadiusCard), not a measurement. See header.
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(kRadiusCard)),
    ),
    builder: (BuildContext sheetContext) => LocalInfoSheet(
      key: kLocalInfoSheetKey,
      alias: alias,
      address: address,
      port: port,
      fingerprint: fingerprint,
    ),
  );
}
