/// A one-shot fade-in (with a small slide) for pane swaps (design §9.2).
///
/// Used where a pane's **content is replaced** — switching the middle pane's
/// module or the bound conversation — so the swap reads as a short transition
/// instead of a hard cut (PRD §2.5 "点击反馈": switching sessions / recent files
/// felt "僵硬"). Give it a `key` that changes with the thing being switched
/// (e.g. `ValueKey(module)`); the remount re-runs the animation, while a rebuild
/// at the same position (a selection change) does not.
///
/// **It always settles.** [TweenAnimationBuilder] drives the value once from
/// `0` to `1` over [duration] and then stops — there is no `repeat()` and no
/// unbounded `AnimationController` here, so `pumpAndSettle` can never hang
/// (the lesson from `StatusChip`, which was deliberately left animation-free).
///
/// Layering (M4 §8.1): `ui/**` imports only `package:flutter/**` and this
/// package's `domain/**`; never `lanlink_core` / `lanlink_store` / `dart:io`.
library;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Wraps [child] in a bounded fade-in (and optional upward slide) on mount.
class FadeIn extends StatelessWidget {
  /// Creates a fade-in wrapper.
  ///
  /// [offset] is the starting displacement (relative to the final position); it
  /// decays to zero as the fade completes. Pass [Offset.zero] for a pure fade.
  /// [duration] defaults to the shared [kTransitionDuration].
  const FadeIn({
    super.key,
    required this.child,
    this.duration = kTransitionDuration,
    this.offset = const Offset(0, 6),
    this.curve = Curves.easeOutCubic,
  });

  /// The content that fades in.
  final Widget child;

  /// How long the one-shot animation runs.
  final Duration duration;

  /// The starting displacement, sliding to [Offset.zero] as it fades in.
  final Offset offset;

  /// The easing applied to the fade / slide.
  final Curve curve;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: duration,
      curve: curve,
      child: child,
      builder: (BuildContext context, double t, Widget? child) {
        final Widget faded = Opacity(opacity: t, child: child);
        if (offset == Offset.zero) {
          return faded;
        }
        return Transform.translate(offset: offset * (1 - t), child: faded);
      },
    );
  }
}
