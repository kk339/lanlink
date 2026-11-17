import 'package:flutter/material.dart';

/// One row of a [showFastMenu] menu.
class FastMenuItem {
  /// Creates a menu row.
  const FastMenuItem({
    required this.value,
    required this.label,
    this.enabled = true,
    this.dividerBefore = false,
  });

  /// Returned by [showFastMenu] when this row is chosen.
  final String value;

  /// The visible label.
  final String label;

  /// `false` renders the row **greyed out and inert** — the caller must disable
  /// an action it cannot perform rather than let a tap do nothing.
  final bool enabled;

  /// Draws a hairline above this row (group separator).
  final bool dividerBefore;
}

/// A context menu that **appears like a desktop menu**, not like a Material one.
///
/// Why this exists instead of `showMenu`: `showMenu`'s route is private and its
/// duration is fixed at **300 ms** with a *size* transition that grows the menu
/// out of the tap point. Microsoft's Fluent motion table asks for far less —
/// "direct entrance" is **cubic-bezier(0, 0, 0, 1) at 167 ms**, "minimal" is an
/// **83 ms** fade — and a 300 ms grow reads as sluggish on a mouse (docs/19 §9.7).
///
/// This route: **150 ms in / 120 ms out**, fade + a 0.96→1 scale, on the Fluent
/// curve. Positioning is a [SingleChildLayoutDelegate] so the menu flips up near
/// the bottom edge and clamps to the screen — the same behaviour `showMenu` has.
Future<String?> showFastMenu(
  BuildContext context, {
  required Offset position,
  required List<FastMenuItem> items,
  required double rowHeight,
}) {
  return Navigator.of(context, rootNavigator: true).push<String>(
    _FastMenuRoute(position: position, items: items, rowHeight: rowHeight),
  );
}

class _FastMenuRoute extends PopupRoute<String> {
  _FastMenuRoute({
    required this.position,
    required this.items,
    required this.rowHeight,
  });

  final Offset position;
  final List<FastMenuItem> items;
  final double rowHeight;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 150);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 120);

  @override
  bool get barrierDismissible => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => '关闭菜单';

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      CustomSingleChildLayout(
        delegate: _FastMenuLayout(position),
        child: _FastMenuBody(items: items, rowHeight: rowHeight),
      );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // MS Fluent "direct entrance": cubic-bezier(0, 0, 0, 1), 167 ms on a desktop
    // menu. We use the same curve at 150 ms, and a 4% scale so it reads as
    // "appeared here" without the heavy size animation `showMenu` uses.
    final Animation<double> curved = CurvedAnimation(
      parent: animation,
      curve: const Cubic(0, 0, 0, 1),
      reverseCurve: const Cubic(0, 0, 0, 1),
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
        child: child,
      ),
    );
  }
}

class _FastMenuBody extends StatelessWidget {
  const _FastMenuBody({required this.items, required this.rowHeight});

  final List<FastMenuItem> items;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      color: theme.brightness == Brightness.dark
          ? const Color(0xFF2C2D31)
          : Colors.white,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      elevation: 8,
      // **IntrinsicWidth**: a menu hugs its widest label (docs/19 §9.9). The
      // previous `minWidth 156 / maxWidth 280` plus a `stretch` Column always
      // resolved to **280** -- measured 280x198 (desktop) and 280x258 (phone) --
      // which on a 375-wide phone is 75% of the screen. With the intrinsic width
      // the same menu measures ~156 and the widest label ("打开所在位置") still fits.
      child: IntrinsicWidth(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 156, maxWidth: 280),
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final FastMenuItem item in items) ...<Widget>[
              if (item.dividerBefore)
                Divider(height: 9, thickness: 1, color: theme.dividerColor),
              InkWell(
                // Keyed so a test can measure the row and read its enabled state
                // without reaching into private widgets.
                key: ValueKey<String>('fast-menu-${item.value}'),
                onTap: item.enabled
                    ? () => Navigator.of(context).pop(item.value)
                    : null,
                child: SizedBox(
                  height: rowHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: item.enabled
                              ? theme.colorScheme.onSurface
                              : theme.disabledColor,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Places the menu at the tap point, flipping and clamping so it never leaves
/// the screen. The child is measured first, so the flip is exact.
class _FastMenuLayout extends SingleChildLayoutDelegate {
  _FastMenuLayout(this.anchor);

  final Offset anchor;

  static const double _margin = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double left = anchor.dx;
    double top = anchor.dy;
    if (left + childSize.width > size.width - _margin) {
      left = size.width - childSize.width - _margin;
    }
    if (top + childSize.height > size.height - _margin) {
      // Flip above the cursor: a menu that runs off the bottom edge is the one
      // case where "open downwards" is simply wrong.
      top = anchor.dy - childSize.height;
    }
    final double maxLeft = (size.width - childSize.width - _margin);
    final double maxTop = (size.height - childSize.height - _margin);
    return Offset(
      left.clamp(_margin, maxLeft < _margin ? _margin : maxLeft),
      top.clamp(_margin, maxTop < _margin ? _margin : maxTop),
    );
  }

  @override
  bool shouldRelayout(_FastMenuLayout oldDelegate) =>
      oldDelegate.anchor != anchor;
}
