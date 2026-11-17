/// A cheap probe for "this isolate stopped running".
///
/// A `Timer.periodic` only fires when the event loop is free, so the amount by
/// which an interval **overshoots** its nominal [EventLoopWatchdog.period] *is*
/// the stall of whatever held the loop — no guesses about which component to
/// instrument. That property is what makes this the right tool for a "the
/// computer froze for a few seconds" report: it measures the freeze itself
/// rather than inferring it from a suspect (a synchronous SHA-256 was a
/// plausible suspect once and turned out to be innocent).
///
/// A healthy loop reports nothing: only overshoots beyond
/// [EventLoopWatchdog.threshold] reach the callback.
library;

import 'dart:async';

/// Watches this isolate's event loop and reports stalls through `onLag`.
class EventLoopWatchdog {
  /// Creates a watchdog.
  ///
  /// `onLag` receives the **overshoot** (measured interval minus [period]) of
  /// every interval that exceeded [threshold]. `now` is injectable so a test can
  /// drive the clock; it defaults to [DateTime.now].
  EventLoopWatchdog({
    required void Function(Duration lag) onLag,
    this.period = const Duration(milliseconds: 200),
    this.threshold = const Duration(seconds: 1),
    DateTime Function()? now,
  })  : _onLag = onLag,
        _now = now ?? DateTime.now;

  /// Nominal interval between checks.
  final Duration period;

  /// Overshoots at or below this are ordinary scheduling jitter and stay silent.
  final Duration threshold;

  final void Function(Duration lag) _onLag;
  final DateTime Function() _now;

  Timer? _timer;
  DateTime? _last;

  /// The largest overshoot seen since [start] (`Duration.zero` before then).
  ///
  /// Kept so a caller can print one summary line even when it chose to log each
  /// stall individually.
  Duration maxLag = Duration.zero;

  /// Whether the watchdog is currently ticking.
  bool get isRunning => _timer != null;

  /// Starts ticking. Idempotent: a second call while running is a no-op.
  void start() {
    if (_timer != null) {
      return;
    }
    _last = _now();
    _timer = Timer.periodic(period, _tick);
  }

  /// Stops ticking. Idempotent.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _last = null;
  }

  void _tick(Timer _) {
    final DateTime now = _now();
    final DateTime last = _last ?? now;
    _last = now;
    // `- period` removes the intended interval, leaving only the delay: ~0 on a
    // healthy loop, ~the stall length when something blocked the isolate. It can
    // be slightly negative under jitter, which is why maxLag only ever grows.
    final Duration overshoot = now.difference(last) - period;
    if (overshoot > maxLag) {
      maxLag = overshoot;
    }
    if (overshoot > threshold) {
      _onLag(overshoot);
    }
  }
}
