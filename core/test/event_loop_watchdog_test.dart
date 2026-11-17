import 'dart:async';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// The watchdog exists to answer "did the isolate stop running?" on a real
/// device, so its own tests do exactly that: one proves a healthy loop is
/// silent, the other blocks the isolate on purpose and proves the stall is
/// reported with a plausible length.
void main() {
  test('a healthy event loop reports nothing', () async {
    final List<Duration> lags = <Duration>[];
    final watchdog = EventLoopWatchdog(
      onLag: lags.add,
      period: const Duration(milliseconds: 20),
      threshold: const Duration(milliseconds: 250),
    );
    addTearDown(watchdog.stop);

    watchdog.start();
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(lags, isEmpty);
  });

  test('a blocked isolate is reported, with the real stall length', () async {
    final List<Duration> lags = <Duration>[];
    final watchdog = EventLoopWatchdog(
      onLag: lags.add,
      period: const Duration(milliseconds: 20),
      threshold: const Duration(milliseconds: 150),
    );
    addTearDown(watchdog.stop);

    watchdog.start();

    // Block the isolate synchronously for ~300ms — no `await`, no yielding.
    // This is the shape of a "the computer froze for a few seconds" report.
    final DateTime end = DateTime.now().add(const Duration(milliseconds: 300));
    while (DateTime.now().isBefore(end)) {
      // deliberate busy-wait
    }
    // Let the periodic timer fire at least once after the block ends.
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(lags, isNotEmpty);
    // The reported overshoot is the stall (minus the nominal period), so it must
    // clear the 150ms threshold — this is what would be logged on-device.
    expect(watchdog.maxLag, greaterThan(const Duration(milliseconds: 150)));
  });

  test('is idempotent and stops cleanly', () async {
    final List<Duration> lags = <Duration>[];
    final watchdog = EventLoopWatchdog(
      onLag: lags.add,
      period: const Duration(milliseconds: 20),
      threshold: const Duration(milliseconds: 10),
    );

    watchdog.start();
    watchdog.start(); // second start is a no-op, not a second timer
    expect(watchdog.isRunning, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 120));

    watchdog.stop();
    watchdog.stop(); // idempotent
    expect(watchdog.isRunning, isFalse);

    final int seenWhileRunning = lags.length;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(lags.length, seenWhileRunning, reason: 'no ticks after stop()');
  });
}
