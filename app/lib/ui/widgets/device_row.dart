/// The middle-pane conversation row (design §1.3 / K4 — rewritten and renamed
/// from the old `device_card.dart`).
///
/// One merged [PeerDevice] per line: a circular kind icon, the alias in **bold**,
/// the `[类型] 文件名` summary in gray, and the last-activity time on the right.
///
/// **Two selection looks, deliberately (docs/18d §1):**
/// * the **phone card** (`carded`) keeps what it always had — the brand-tinted
///   full-bleed fill plus a 2px brand bar;
/// * the **wide / compact** row paints an **inset rounded block** instead — the
///   reference's selected row is 342 x 69 image px inset 9 on each side of a
///   360-wide column (docs/18b §2b / §6.2), so the block does *not* span the
///   pane, and the reference has **no** 2px bar.
/// The two branches are gated rather than split so the phone's widget tree stays
/// byte-for-byte what it was.
///
/// The `[类型]` prefix reuses `ui/format.dart::fileSummaryPrefix` (itself derived
/// from `domain/selectors.dart::classifyFile`), so there is no second file-type
/// table. A multi-file preview (the store produces `"N files"`) carries a
/// tooltip so the known precision limit is never read as a bug (PRD §8-G2-34/35).
///
/// **Layering (design §9.6):** imports only `package:flutter/**`, this package's
/// `domain/**` and sibling `ui/**` — never `dart:io` / `dart:ffi` /
/// `lanlink_core` / `lanlink_store`.
library;

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../format.dart';
import '../scope.dart';
import '../theme.dart';

/// The icon for a [DeviceKind], hoisted from the old `device_card._iconForKind`
/// (design K4) so a device kind becomes pixels in exactly one place.
IconData deviceKindIcon(DeviceKind kind) => switch (kind) {
      DeviceKind.mobile => Icons.smartphone,
      DeviceKind.desktop => Icons.desktop_windows,
      DeviceKind.web => Icons.public,
      DeviceKind.headless => Icons.terminal,
      DeviceKind.server => Icons.dns,
      DeviceKind.unknown => Icons.devices_other,
    };

/// A single middle-pane conversation row (device / session merged view).
class DeviceRow extends StatelessWidget {
  /// Creates a conversation row.
  ///
  /// [onTap] selects the row (the caller wires it to
  /// `ShellController.selectPeer`); `null` renders a non-interactive row.
  const DeviceRow({
    super.key,
    required this.device,
    this.selected = false,
    this.onTap,
    this.carded = false,
  });

  /// The merged device view to render.
  final PeerDevice device;

  /// Whether this row is the shell's current selection.
  final bool selected;

  /// Called when the row is tapped, or `null`.
  final VoidCallback? onTap;

  /// Draw the row as a **card** (docs/18 §2.1) — the phone home list's look:
  /// a rounded [kCardSurface] surface of its own at [kCardHeight], inset by
  /// [kListRowPadding], with the air between cards owned by the list
  /// ([kCardGap]) instead of an inter-row hairline.
  ///
  /// **Defaults to `false`, and on `false` this widget's tree is exactly what it
  /// was** — the wide / compact rendering must stay byte-for-byte identical
  /// (docs/18 §2.0), which the wide-screen baseline in
  /// `test/widget/responsive_test.dart` enforces line by line.
  final bool carded;

  /// Summary shown for a device that has never transferred anything (A2-4).
  static const String neverTransferred = '尚未传输过';

  /// Note shown for a device whose `lastPort == 0` (PRD E6 / C11).
  static const String notReceivable = '对方当前不可接收';

  /// Tooltip shown on a multi-file summary line (PRD §8-G2-34/35).
  static const String multiFileTooltip = '多文件消息仅显示数量';

  /// Matches the store's multi-file preview (`"N files"`).
  static final RegExp _multiFile = RegExp(r'^\d+\s+files$');

  /// Fixed row height: a 40px leading icon plus 8px above and below (design
  /// §6.2 — every list row is a fixed height, so the text never wraps).
  static const double _rowHeight = kListIconDiameter + 16;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String summary = _summary();
    final bool multi = _multiFile.hasMatch((device.lastPreview ?? '').trim());
    final DateTime? at =
        device.isOnline ? device.lastSeenAt : device.lastActivityAt;

    // Grey → colour on a phone (docs/18 §5.2): a connected peer's icon goes
    // colour, an offline one keeps the neutral it always had. Both expressions
    // reduce to the exact colours the wide / compact paths already used, so
    // those stay byte-identical and the §7.1 baseline keeps holding.
    final Color iconColor = carded
        ? (device.isOnline ? statusDeviceOn : statusDeviceOff(theme))
        : theme.colorScheme.onSurfaceVariant;
    final Color ringFill = carded
        ? deviceRingFill(theme, online: device.isOnline)
        : theme.colorScheme.surfaceContainerHighest;

    // The row's body: identical in both modes — only the *shell* differs, so
    // the wide tree keeps exactly the widgets it had.
    final Widget body = Material(
      // Transparent so the InkWell's hover fill shows over the opaque pane
      // surface colour beneath this row.
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        // PRD §2.5: hovering the row must give visible feedback.
        child: AnimatedContainer(
          duration: kTransitionDuration,
          // Painted by the **phone card only**. The wide / compact row paints its
          // own inset rounded block in the shell below (docs/18d §1), so exactly
          // one of the two paints the selection.
          color: carded && selected ? selectionFill(theme) : Colors.transparent,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // The 2px "current row" bar (PRD §2.1) — **phone cards only** now.
              // The wide / compact row drops it: the reference has no such bar
              // (docs/18d §1). Gated rather than deleted so the phone branch's
              // widget tree is unchanged.
              if (carded)
                AnimatedContainer(
                  duration: kTransitionDuration,
                  width: kSelectionBarWidth,
                  color: selected ? kSeedColor : Colors.transparent,
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: <Widget>[
                      CircleAvatar(
                        radius: kListIconDiameter / 2,
                        backgroundColor: ringFill,
                        child: Icon(
                          deviceKindIcon(device.kind),
                          size: kListIconDiameter * 0.5,
                          color: iconColor,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              device.alias,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            // 2px **on purpose** — not the 4px grid step. This
                            // gap sits inside a row that is exactly 56 (the M3
                            // list-item height), and rounding it to 4 pushes the
                            // row to 58, i.e. off that spec. Two rules collide
                            // here and the row height wins: it decides how many
                            // rows fit on a screen, the gap only decides how
                            // airy one row looks (a 2px change is not visible).
                            // Measured for `test/widget/layout_host_probe_test.dart`.
                            const SizedBox(height: 2),
                            _subtitle(theme, summary, multi),
                          ],
                        ),
                      ),
                      if (at != null) ...<Widget>[
                        const SizedBox(width: 8),
                        Text(
                          rowTimeText(context.deps.clock.nowUtc(), at),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (!carded) {
      // The wide / compact row: a fixed 56 tall. **Its selection is an inset
      // rounded block, not a full-bleed fill (docs/18d §1)** — the reference's
      // selected row measures 342 x 69 image px inside a 360-wide column, i.e.
      // inset 9 image px on *each* side, so the block does not span the pane.
      //
      // Inset 8 = 9 image px / 360 content width = 2.50%, applied to our 320-wide
      // pane. Radius reuses [kRadiusNavItem] (8), which sits inside the
      // reference's 8~10 image px band. **Both come from ratios, not from a
      // measured absolute value** (docs/18d §0-1).
      return SizedBox(
        height: _rowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: kNavItemInset),
          child: AnimatedContainer(
            duration: kTransitionDuration,
            decoration: BoxDecoration(
              color: selected ? selectionFillList(theme) : Colors.transparent,
              borderRadius: BorderRadius.circular(kRadiusNavItem),
            ),
            child: body,
          ),
        ),
      );
    }

    // The phone card (docs/18 §2.1): its own rounded surface, **at least**
    // [kCardHeight] tall, with the page inset around it. `clipBehavior` keeps the
    // ink splash inside the rounded corners; the air *between* cards is the
    // list's job ([kCardGap]), which is why this row no longer draws a hairline.
    //
    // `minHeight`, not `height` (0.2.10): a hard 67 clipped the two text lines
    // once the system font scale grew — 7 px of overflow at 2x and 43 px at 3x,
    // measured at 320 / 360 / 412 wide — so the alias and the summary were cut
    // off. A `ListView.separated` is happy with taller items, so the card grows
    // with its content and 67 stays the **minimum** (it is still exactly 67.0 at
    // 1x, which `test/widget/phone_card_test.dart` pins). The wide / compact row
    // above keeps its fixed 56 and never grows.
    //
    // `IntrinsicHeight` is what makes that possible: [body]'s Row uses
    // `CrossAxisAlignment.stretch` (for the 2px selection bar), which needs a
    // **bounded** height — with only a `minHeight` the incoming constraint is
    // infinite and the layout asserts ("BoxConstraints forces an infinite
    // height"). Asking for the intrinsic height first turns "how tall does this
    // card want to be?" into a number, and the minimum then floors it at 67. The
    // price is one extra intrinsic pass per visible card; only the phone branch
    // pays it (the wide row keeps its const 56 and its tree).
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kListRowPadding),
      child: IntrinsicHeight(
        child: Container(
          constraints: const BoxConstraints(minHeight: kCardHeight),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: cardSurface(theme),
            borderRadius: BorderRadius.circular(kRadiusCard),
          ),
          child: body,
        ),
      ),
    );
  }

  /// The gray second line: the `[类型] 文件名` summary, plus — for a device that
  /// cannot receive — its own `对方当前不可接收` marker (PRD C11), kept as a
  /// separate [Text] so it is never swallowed by the summary's ellipsis.
  Widget _subtitle(ThemeData theme, String summary, bool multi) {
    final Text text = Text(
      summary,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
    final Widget summaryWidget =
        multi ? Tooltip(message: multiFileTooltip, child: text) : text;
    if (device.canSend) {
      return summaryWidget;
    }
    return Row(
      children: <Widget>[
        Expanded(child: summaryWidget),
        const SizedBox(width: 6),
        // `Flexible` (not a bare Text): a non-flexible child is laid out with an
        // unbounded width, so its own `ellipsis` can never apply and the row
        // overflows — spilling the marker off-screen (M5d ③; a large text scale
        // reproduces it on any platform).
        Flexible(
          child: Text(
            notReceivable,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ),
      ],
    );
  }

  /// The summary copy (PRD §3.2 / §2.3): `[类型] 文件名`, `尚未传输过`, or
  /// `已建立会话` when a history exists but has no preview text.
  String _summary() {
    if (!device.hasHistory) {
      return neverTransferred;
    }
    final String preview = device.lastPreview?.trim() ?? '';
    if (preview.isEmpty) {
      return '已建立会话';
    }
    return '${fileSummaryPrefix(preview)} $preview';
  }
}
