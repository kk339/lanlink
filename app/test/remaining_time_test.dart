/// Unit tests for the remaining-time estimator (0.2.25) — the pure half of
/// `剩 N 秒`.
///
/// These pin the *judgement* the feature rests on, not the arithmetic:
///
/// * the rate comes from the **last ~3 s**, so a transfer that crawls and then
///   speeds up stops advertising the old, slow average (a "whole-run average"
///   implementation is red here, which is the point);
/// * nothing is shown when the answer would be noise — under 2 s of history, a
///   stalled link, an unknown total — because a number that jumps between 3 s
///   and 300 s is worse than no number;
/// * the printed number moves smoothly: one repaint may change it by at most
///   1.5× (clamp 2×, then half the remaining gap), so `3 秒 → 300 秒 → 4 秒`
///   cannot be rendered.
///
/// No clock, no widget, no fake async: every instant is a value handed in, which
/// is exactly why the estimator takes timestamps instead of reading them.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/domain/remaining_time.dart';

const int _mib = 1024 * 1024;

/// A run of samples produced at [rate] bytes per second, starting at [at] and
/// continuing for [count] one-second ticks from a byte counter of [from].
///
/// Built as a plain list so each test states its own traffic shape — the whole
/// subject here is *what the history looked like*.
List<ProgressSample> _stream({
  required DateTime at,
  required int from,
  required int rate,
  required int count,
}) {
  final List<ProgressSample> samples = <ProgressSample>[];
  for (int i = 0; i <= count; i++) {
    samples.add(
      ProgressSample(
        bytesDone: from + rate * i,
        at: at.add(Duration(seconds: i)),
      ),
    );
  }
  return samples;
}

/// Folds [samples] through one estimator, returning **every** output in order —
/// the consecutive pairs are what "no jumping" is about.
List<Duration?> _outputs(List<ProgressSample> samples, {required int bytesTotal}) {
  final RemainingTimeEstimator estimator = RemainingTimeEstimator();
  return <Duration?>[
    for (final ProgressSample sample in samples)
      estimator.addSample(
        bytesDone: sample.bytesDone,
        at: sample.at,
        bytesTotal: bytesTotal,
      ),
  ];
}

void main() {
  final DateTime t0 = DateTime.utc(2026, 1, 7, 12);

  group('the window, not the whole run', () {
    test('a steady 10 MiB/s with 100 MiB left estimates 10 s', () {
      // 10 MiB/s for 10 s, then exactly 100 MiB of file left.
      final List<ProgressSample> samples = _stream(
        at: t0,
        from: 0,
        rate: 10 * _mib,
        count: 10,
      );
      final Duration? eta = estimateRemainingTime(
        samples,
        bytesTotal: 200 * _mib,
      );

      expect(eta, isNotNull);
      // ±1 s: the exponential smoothing deliberately trails the raw value by
      // about one tick, and a whole second of lag is not worth a jumpier number.
      expect(eta!.inSeconds, inInclusiveRange(9, 11),
          reason: 'steady rate over the window → remaining / rate');
    });

    test('after a slowdown→speed-up the estimate follows the LAST 3 s, and a '
        'whole-run average is red', () {
      // 60 s at 1 MiB/s, then 20 s at 20 MiB/s.
      final List<ProgressSample> slow = _stream(
        at: t0,
        from: 0,
        rate: 1 * _mib,
        count: 60,
      );
      final List<ProgressSample> fast = _stream(
        at: t0.add(const Duration(seconds: 60)),
        from: 60 * _mib,
        rate: 20 * _mib,
        count: 20,
      );
      final List<ProgressSample> samples = <ProgressSample>[
        ...slow,
        // The join sample is shared; drop the duplicate instant.
        ...fast.skip(1),
      ];
      const int total = 800 * _mib;

      final Duration? eta = estimateRemainingTime(samples, bytesTotal: total);
      expect(eta, isNotNull);

      // What a whole-run average would claim at this instant:
      final int done = samples.last.bytesDone; // 460 MiB
      final double runSeconds =
          samples.last.at.difference(samples.first.at).inMicroseconds / 1e6;
      final double wholeRunEta = (total - done) / (done / runSeconds);

      expect(eta!.inSeconds, lessThan(wholeRunEta / 3),
          reason: 'window rate is 20 MiB/s (ETA ≈ 17 s), the whole-run average '
              'is ~5.75 MiB/s (ETA ≈ 59 s) — an implementation that averages '
              'the whole run reports ~59 s and must fail here');
      expect(eta.inSeconds, lessThanOrEqualTo(25),
          reason: 'the recent window governs: 340 MiB left at 20 MiB/s');
    });

    test('rateBytesPerSecond is measured over the window only', () {
      final List<ProgressSample> samples = <ProgressSample>[
        ..._stream(at: t0, from: 0, rate: 1 * _mib, count: 20),
        ..._stream(
          at: t0.add(const Duration(seconds: 20)),
          from: 20 * _mib,
          rate: 20 * _mib,
          count: 3,
        ).skip(1),
      ];
      final RemainingTimeEstimator estimator = RemainingTimeEstimator();
      for (final ProgressSample sample in samples) {
        estimator.addSample(
          bytesDone: sample.bytesDone,
          at: sample.at,
          bytesTotal: 400 * _mib,
        );
      }

      // Whole-run average here is 66 MiB / 23 s ≈ 2.9 MiB/s; the window is the
      // last ~3 s, which is entirely inside the fast phase.
      expect(estimator.rateBytesPerSecond, closeTo(20 * _mib, 0.01 * _mib));
      expect(estimator.samples.length, lessThanOrEqualTo(4),
          reason: 'the sample list stays a handful long, however long the '
              'transfer runs');
    });
  });

  group('no honest number → null (the UI then draws nothing)', () {
    test('less than 2 s of history is not an estimate', () {
      final List<ProgressSample> samples = _stream(
        at: t0,
        from: 0,
        rate: 10 * _mib,
        count: 1, // two samples, span 1 s
      );
      expect(
        estimateRemainingTime(samples, bytesTotal: 200 * _mib),
        isNull,
        reason: 'a 1 s window projects noise across the rest of the file',
      );
      expect(
        estimateRemainingTime(
          <ProgressSample>[
            ProgressSample(bytesDone: 5 * _mib, at: t0),
          ],
          bytesTotal: 200 * _mib,
        ),
        isNull,
        reason: 'one sample is not an interval',
      );
    });

    test('two samples at the SAME instant never divide by zero', () {
      final List<ProgressSample> samples = <ProgressSample>[
        ProgressSample(bytesDone: 0, at: t0),
        ProgressSample(bytesDone: 4 * _mib, at: t0),
      ];
      expect(estimateRemainingTime(samples, bytesTotal: 200 * _mib), isNull);
    });

    test('a stalled transfer has no ETA — and says nothing rather than "∞"', () {
      final List<ProgressSample> samples = _stream(
        at: t0,
        from: 8 * _mib,
        rate: 0,
        count: 5,
      );
      expect(estimateRemainingTime(samples, bytesTotal: 200 * _mib), isNull);

      // And the estimate comes back once bytes move again — the stall is not
      // sticky.
      final RemainingTimeEstimator estimator = RemainingTimeEstimator();
      for (final ProgressSample sample in samples) {
        estimator.addSample(
          bytesDone: sample.bytesDone,
          at: sample.at,
          bytesTotal: 200 * _mib,
        );
      }
      Duration? resumed;
      for (int i = 1; i <= 3; i++) {
        resumed = estimator.addSample(
          bytesDone: 8 * _mib + i * 10 * _mib,
          at: t0.add(Duration(seconds: 5 + i)),
          bytesTotal: 200 * _mib,
        );
      }
      expect(resumed, isNotNull);
    });

    test('an unknown total (-1) yields null', () {
      final List<ProgressSample> samples = _stream(
        at: t0,
        from: 0,
        rate: 10 * _mib,
        count: 5,
      );
      expect(estimateRemainingTime(samples, bytesTotal: -1), isNull);
      expect(estimateRemainingTime(samples, bytesTotal: 0), isNull);
    });

    test('an absurd projection is dropped, not printed', () {
      // 1 byte per second on a 900 MiB file → ~29 years. The percentage still
      // says 1%; the ETA line must simply be absent.
      final List<ProgressSample> samples = _stream(
        at: t0,
        from: 0,
        rate: 1,
        count: 4,
      );
      expect(estimateRemainingTime(samples, bytesTotal: 900 * _mib), isNull);
    });
  });

  group('smoothing: one repaint may not move the number by more than ~1.5×', () {
    test('a sudden rate collapse never prints a jump', () {
      // 20 s at 10 MiB/s, then the link falls to 0.5 MiB/s — the shape that used
      // to produce 3 秒 → 300 秒 in a single tick.
      final List<ProgressSample> samples = <ProgressSample>[
        ..._stream(at: t0, from: 0, rate: 10 * _mib, count: 20),
        ..._stream(
          at: t0.add(const Duration(seconds: 20)),
          from: 200 * _mib,
          rate: _mib ~/ 2,
          count: 12,
        ).skip(1),
      ];
      final List<Duration?> outputs = _outputs(samples, bytesTotal: 1000 * _mib);

      // The estimate exists before and after the collapse, so the ratios below
      // compare real, drawn numbers.
      expect(outputs.whereType<Duration>().length, greaterThanOrEqualTo(20));

      double worst = 1;
      for (int i = 1; i < outputs.length; i++) {
        final Duration? previous = outputs[i - 1];
        final Duration? current = outputs[i];
        if (previous == null || current == null) {
          continue;
        }
        final double up =
            current.inMicroseconds / previous.inMicroseconds.clamp(1, 1 << 62);
        final double down = previous.inMicroseconds /
            current.inMicroseconds.clamp(1, 1 << 62);
        final double ratio = up > down ? up : down;
        if (ratio > worst) {
          worst = ratio;
        }
      }
      expect(worst, lessThanOrEqualTo(2.0),
          reason: 'clamp 2× then move half the gap ⇒ at most 1.5×; anything '
              'near 100× is the jump this exists to prevent');

      // It still *moves* towards the truth: a collapse must not be smoothed into
      // a number that never reacts.
      expect(outputs.last!.inSeconds, greaterThan(outputs[20]!.inSeconds * 2),
          reason: 'the slower link does raise the estimate — smoothing is not a '
              'freeze');
    });

    test('a speed-up converges instead of parking on a stale number', () {
      final List<ProgressSample> samples = <ProgressSample>[
        ..._stream(at: t0, from: 0, rate: 1 * _mib, count: 20),
        ..._stream(
          at: t0.add(const Duration(seconds: 20)),
          from: 20 * _mib,
          rate: 20 * _mib,
          count: 20,
        ).skip(1),
      ];
      final List<Duration?> outputs = _outputs(samples, bytesTotal: 1000 * _mib);

      // At the end the link has been at 20 MiB/s for 20 s.
      final int remaining = 1000 * _mib - samples.last.bytesDone;
      final int truthSeconds = remaining ~/ (20 * _mib);
      expect(outputs.last!.inSeconds, lessThanOrEqualTo(truthSeconds + 3),
          reason: 'within a few seconds of the window rate, not stuck at the '
              'old slow phase');
    });
  });

  group('state hygiene', () {
    test('a retry (byte counter restarts) begins a fresh measurement', () {
      final RemainingTimeEstimator estimator = RemainingTimeEstimator();
      for (final ProgressSample sample
          in _stream(at: t0, from: 40 * _mib, rate: 10 * _mib, count: 4)) {
        estimator.addSample(
          bytesDone: sample.bytesDone,
          at: sample.at,
          bytesTotal: 200 * _mib,
        );
      }
      expect(estimator.estimate, isNotNull);

      // Same bubble, new attempt: the counter goes back to 0.
      final Duration? afterRestart = estimator.addSample(
        bytesDone: 0,
        at: t0.add(const Duration(seconds: 5)),
        bytesTotal: 200 * _mib,
      );
      expect(afterRestart, isNull,
          reason: 'one sample of a new attempt is not an interval');
      expect(estimator.samples.length, 1);
    });

    test('time running backwards resets rather than producing a negative rate',
        () {
      final RemainingTimeEstimator estimator = RemainingTimeEstimator();
      for (final ProgressSample sample
          in _stream(at: t0, from: 0, rate: 10 * _mib, count: 3)) {
        estimator.addSample(
          bytesDone: sample.bytesDone,
          at: sample.at,
          bytesTotal: 200 * _mib,
        );
      }
      expect(
        estimator.addSample(
          bytesDone: 30 * _mib,
          at: t0, // the same instant as the first sample — clock went back
          bytesTotal: 200 * _mib,
        ),
        isNull,
      );
      expect(estimator.samples.length, 1);
    });

    test('reset() forgets the history', () {
      final RemainingTimeEstimator estimator = RemainingTimeEstimator();
      for (final ProgressSample sample
          in _stream(at: t0, from: 0, rate: 10 * _mib, count: 4)) {
        estimator.addSample(
          bytesDone: sample.bytesDone,
          at: sample.at,
          bytesTotal: 200 * _mib,
        );
      }
      estimator.reset();
      expect(estimator.samples, isEmpty);
      expect(estimator.estimate, isNull);
      expect(estimator.rateBytesPerSecond, isNull);
    });

    test('done (bytesDone == bytesTotal) estimates zero — smoothing must not '
        'leave "剩 2 秒" on a finished file', () {
      // The realistic shape: the last ticks approach the total, so there *is* a
      // live estimate (and a smoothing anchor) at the moment the counter lands
      // exactly on the total.
      final List<ProgressSample> samples = <ProgressSample>[
        ProgressSample(bytesDone: 90 * _mib, at: t0),
        ProgressSample(
            bytesDone: 100 * _mib, at: t0.add(const Duration(seconds: 1))),
        ProgressSample(
            bytesDone: 105 * _mib, at: t0.add(const Duration(seconds: 2))),
        ProgressSample(
            bytesDone: 110 * _mib, at: t0.add(const Duration(seconds: 3))),
      ];
      final RemainingTimeEstimator estimator = RemainingTimeEstimator();
      Duration? eta;
      for (final ProgressSample sample in samples) {
        eta = estimator.addSample(
          bytesDone: sample.bytesDone,
          at: sample.at,
          bytesTotal: 110 * _mib,
        );
      }
      expect(eta, Duration.zero,
          reason: 'zero left is a fact, not an estimate to smooth');
    });
  });
}
