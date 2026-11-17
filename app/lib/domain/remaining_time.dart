/// "How much longer?" — the remaining-time estimate behind the bubble's
/// `剩 N 秒` (0.2.25).
///
/// A percentage answers "how far along" but not the only question a user with a
/// 900 MB file actually asks: *is this worth waiting for?* A rate answers it in
/// bytes/s, which nobody converts in their head. This module turns the byte
/// counter into a `Duration`.
///
/// **Pure, and clock-free on purpose.** Every instant comes from the
/// [ProgressSample]s the caller feeds in; nothing here reads `DateTime.now()`.
/// That is what lets a test *advance time* without sleeping, and it is why this
/// file has no Flutter import at all (it must compile for the Web build, and
/// `domain/**` never depends on the UI).
///
/// Two decisions worth knowing before changing anything here:
///
/// 1. **The rate comes from the last ~3 s, not from the whole run.** A whole-run
///    average lies in exactly the case the user is watching: a transfer that
///    crawls for the first 20 s and then speeds up keeps showing the *slow*
///    average, so the ETA never improves even though the transfer plainly did.
///    [_window] fixes that; [kRemainingTimeMinSpan] keeps a 2-sample "window"
///    from producing a nonsense rate.
/// 2. **No number is better than a jumping number.** Under
///    [kRemainingTimeMinSpan] of history, on a stalled link, on an unknown total
///    or on an absurd estimate, every entry point returns `null` — the UI then
///    draws nothing at all instead of `剩 ∞` or a value that swings between 3 s
///    and 300 s.
library;

/// One observation of a transfer's byte counter, at one instant.
///
/// [at] must be a real reading of a clock (the caller's), never a value
/// synthesised here — the estimator measures *intervals* between samples, so a
/// made-up timestamp silently becomes a made-up rate.
class ProgressSample {
  /// Creates a sample of [bytesDone] bytes at [at].
  const ProgressSample({required this.bytesDone, required this.at});

  /// Bytes transferred so far within the current attempt.
  final int bytesDone;

  /// When [bytesDone] was observed.
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is ProgressSample && other.bytesDone == bytesDone && other.at == at;

  @override
  int get hashCode => Object.hash(bytesDone, at);

  @override
  String toString() => 'ProgressSample($bytesDone B @ ${at.toIso8601String()})';
}

/// The sliding window a rate is measured over — "the last 3 seconds".
///
/// Three seconds is ~3 progress ticks (the controller polls at 1 Hz): long
/// enough that one late tick does not double the rate, short enough that a real
/// speed-up shows up while the user is still looking.
const Duration kRemainingTimeWindow = Duration(seconds: 3);

/// The minimum history a rate may be measured over — below this nothing is
/// shown.
///
/// Two samples 200 ms apart "measure" 200 ms of link behaviour; projecting that
/// across 900 MB produces a number that is pure noise (and, on the first tick,
/// usually a wildly optimistic one).
const Duration kRemainingTimeMinSpan = Duration(seconds: 2);

/// How far one output may move from the previous one, as a ratio — the ETA is
/// clamped to `[previous / 2, previous * 2]` before smoothing.
const double kRemainingTimeJumpLimit = 2;

/// The exponential-smoothing weight given to the newest (clamped) estimate.
///
/// 0.5 — half of the gap per tick: fast enough to follow a real change within a
/// handful of seconds, slow enough that one noisy window cannot repaint the
/// number. Combined with [kRemainingTimeJumpLimit] the **largest** possible
/// step between two consecutive outputs is `1 + 0.5 × (2 − 1) = 1.5×`.
const double kRemainingTimeSmoothing = 0.5;

/// The largest estimate worth printing; beyond it the answer is `null`.
///
/// A link trickling at a few bytes per second yields a mathematically valid
/// "剩 40000 小时", which is not an answer. Past ~4 days the honest statement is
/// "no useful estimate", so nothing is shown (the percentage still is).
const Duration kRemainingTimeMaxEstimate = Duration(hours: 99);

/// Accumulates progress samples and yields a smoothed remaining-time estimate.
///
/// One instance per in-flight transfer. Feed it every progress update
/// ([addSample]); it keeps only the samples inside [window] (plus the one
/// anchoring the far edge of the window), so it holds a handful of entries no
/// matter how long the transfer runs.
///
/// All the state is derived from the samples passed in, so a test can drive it
/// with synthetic timestamps and get deterministic answers; there is no timer,
/// no clock and no I/O here.
class RemainingTimeEstimator {
  /// Creates an estimator. The tuning knobs default to the module constants and
  /// exist so tests (and future callers) can pin the behaviour they rely on.
  RemainingTimeEstimator({
    this.window = kRemainingTimeWindow,
    this.minSpan = kRemainingTimeMinSpan,
    this.smoothing = kRemainingTimeSmoothing,
    this.jumpLimit = kRemainingTimeJumpLimit,
    this.maxEstimate = kRemainingTimeMaxEstimate,
  })  : assert(window > Duration.zero, 'window must be positive'),
        assert(minSpan > Duration.zero, 'minSpan must be positive'),
        assert(smoothing > 0 && smoothing <= 1, 'smoothing is a weight'),
        assert(jumpLimit >= 1, 'jumpLimit is a ratio >= 1'),
        assert(maxEstimate > Duration.zero, 'maxEstimate must be positive');

  /// The sliding window a rate is measured over ([kRemainingTimeWindow]).
  final Duration window;

  /// The minimum measured span ([kRemainingTimeMinSpan]).
  final Duration minSpan;

  /// The weight of the newest estimate ([kRemainingTimeSmoothing]).
  final double smoothing;

  /// The clamp applied before smoothing ([kRemainingTimeJumpLimit]).
  final double jumpLimit;

  /// The largest estimate that is still printed ([kRemainingTimeMaxEstimate]).
  final Duration maxEstimate;

  /// The retained samples, oldest first.
  final List<ProgressSample> _samples = <ProgressSample>[];

  /// The last **smoothed** estimate, in seconds, or `null` when the stream of
  /// numbers was interrupted (a stall, a reset) and there is nothing to smooth
  /// against.
  double? _smoothedSeconds;

  /// The retained samples, oldest first (a read-only view).
  List<ProgressSample> get samples => List<ProgressSample>.unmodifiable(_samples);

  /// The estimate produced by the most recent [addSample], or `null`.
  ///
  /// Convenience only: it re-reads the last stored value, so a caller that
  /// needs the value must not use this as a substitute for remembering the
  /// return of [addSample] (a stalled link legitimately returns `null` while an
  /// older value is still in the field).
  Duration? get estimate {
    final double? seconds = _smoothedSeconds;
    if (seconds == null) {
      return null;
    }
    return Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());
  }

  /// Forgets everything — the next [addSample] starts a fresh measurement.
  void reset() {
    _samples.clear();
    _smoothedSeconds = null;
  }

  /// Records one observation and returns the (smoothed) estimate, or `null`
  /// when no honest number can be given.
  ///
  /// [bytesTotal] is the size of the whole transfer; `<= 0` means "unknown" and
  /// yields `null` (there is nothing to subtract the done bytes from).
  /// A `bytesDone` that **went backwards** is read as a new attempt (a retry
  /// restarts the counter) and restarts the measurement rather than producing a
  /// negative rate.
  Duration? addSample({
    required int bytesDone,
    required DateTime at,
    required int bytesTotal,
  }) {
    _record(bytesDone: bytesDone, at: at);
    final double? rawSeconds = _rawRemainingSeconds(bytesTotal: bytesTotal);
    if (rawSeconds == null) {
      // No honest number right now (too little history, a stall, an unknown
      // total): drop the anchor so the next real estimate is not blended with a
      // stale one, and say nothing.
      _smoothedSeconds = null;
      return null;
    }
    if (rawSeconds == 0) {
      // Everything has arrived. Smoothing here would do real damage: the last
      // frame would read `剩 4 秒` on a finished file. Zero is not an estimate,
      // it is a fact.
      _smoothedSeconds = 0;
      return Duration.zero;
    }
    final double value = _smooth(rawSeconds);
    _smoothedSeconds = value;
    return Duration(microseconds: (value * Duration.microsecondsPerSecond).round());
  }

  /// The rate the **window** achieved, in bytes per second, or `null` when the
  /// history is too short to measure one.
  ///
  /// Exposed because it is the half of the estimate that must be verifiable on
  /// its own: "the window is used, not the whole run" is a statement about this
  /// number, and asserting it directly keeps it from being hidden behind the
  /// smoothing (which by design lags).
  double? get rateBytesPerSecond {
    if (_samples.length < 2) {
      return null;
    }
    final Duration span = _samples.last.at.difference(_samples.first.at);
    if (span < minSpan) {
      return null;
    }
    final int deltaBytes = _samples.last.bytesDone - _samples.first.bytesDone;
    if (deltaBytes <= 0) {
      return null;
    }
    return deltaBytes /
        (span.inMicroseconds / Duration.microsecondsPerSecond);
  }

  /// Stores [bytesDone] / [at], keeping the sample list trimmed to [window].
  void _record({required int bytesDone, required DateTime at}) {
    if (_samples.isNotEmpty) {
      final ProgressSample last = _samples.last;
      if (bytesDone < last.bytesDone) {
        // The counter restarted (a retry, or a new attempt on the same bubble):
        // every sample before this one belongs to a different transfer.
        reset();
      } else if (!at.isAfter(last.at)) {
        if (at.isBefore(last.at)) {
          // Time ran backwards — nothing measured across that seam is usable.
          reset();
        } else {
          // Same instant: a rebuild, not a new observation. Refresh the byte
          // counter in place so the newest reading is used, but do **not**
          // invent a zero-length interval (that is a divide-by-zero waiting to
          // happen).
          _samples[_samples.length - 1] =
              ProgressSample(bytesDone: bytesDone, at: at);
          return;
        }
      }
    }
    _samples.add(ProgressSample(bytesDone: bytesDone, at: at));
    _prune();
  }

  /// Drops samples that fell out of the trailing window, keeping the one that
  /// anchors its far edge so the measured span still covers [window].
  void _prune() {
    final DateTime cutoff = _samples.last.at.subtract(window);
    // Keep `_samples[0]` while it is the last sample at or before the cutoff —
    // it is what makes the span ≈ the window instead of "since the last tick".
    while (_samples.length >= 2 && !_samples[1].at.isAfter(cutoff)) {
      _samples.removeAt(0);
    }
  }

  /// The unsmoothed remaining time in seconds, or `null` when the window cannot
  /// support one.
  double? _rawRemainingSeconds({required int bytesTotal}) {
    if (bytesTotal <= 0) {
      return null;
    }
    final double? rate = rateBytesPerSecond;
    if (rate == null || rate <= 0) {
      // A stalled transfer has no ETA. Saying "剩 ∞" (or a number that grows
      // every tick) is worse than saying nothing.
      return null;
    }
    final int remainingBytes = bytesTotal - _samples.last.bytesDone;
    if (remainingBytes <= 0) {
      return 0;
    }
    final double raw =
        remainingBytes / rate;
    if (raw > maxEstimate.inMicroseconds / Duration.microsecondsPerSecond) {
      return null;
    }
    return raw;
  }

  /// Clamps [raw] to one [jumpLimit] step away from the previous estimate, then
  /// moves [smoothing] of the way towards it.
  ///
  /// The clamp is what makes the output **monotone-smooth**: a window that
  /// suddenly reports 100× slower can move the printed number by at most 1.5×
  /// per update, so `剩 3 秒 → 剩 300 秒` can no longer happen in one repaint.
  /// The exponential step then keeps the number from parking on the clamp: with
  /// a genuinely changed rate it reaches the new value in ~10 s, all the while
  /// moving in one direction.
  double _smooth(double raw) {
    final double? previous = _smoothedSeconds;
    if (previous == null || previous <= 0) {
      return raw;
    }
    final double lower = previous / jumpLimit;
    final double upper = previous * jumpLimit;
    final double bounded = raw < lower
        ? lower
        : (raw > upper ? upper : raw);
    return previous + (bounded - previous) * smoothing;
  }
}

/// The estimate for a whole series of [samples] against [bytesTotal].
///
/// A one-shot convenience over [RemainingTimeEstimator] (it folds the samples in
/// order, so the answer is identical to feeding them one by one). Returns
/// `null` under exactly the same conditions — see [RemainingTimeEstimator].
Duration? estimateRemainingTime(
  Iterable<ProgressSample> samples, {
  required int bytesTotal,
  Duration window = kRemainingTimeWindow,
  Duration minSpan = kRemainingTimeMinSpan,
  double smoothing = kRemainingTimeSmoothing,
  double jumpLimit = kRemainingTimeJumpLimit,
  Duration maxEstimate = kRemainingTimeMaxEstimate,
}) {
  final RemainingTimeEstimator estimator = RemainingTimeEstimator(
    window: window,
    minSpan: minSpan,
    smoothing: smoothing,
    jumpLimit: jumpLimit,
    maxEstimate: maxEstimate,
  );
  Duration? result;
  for (final ProgressSample sample in samples) {
    result = estimator.addSample(
      bytesDone: sample.bytesDone,
      at: sample.at,
      bytesTotal: bytesTotal,
    );
  }
  return result;
}
