import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/data/real/lan_transfer_service.dart';

/// The rate line is what a human reads to judge the link, so its units are
/// pinned here: bytes in, **MiB/s** out, divided by the *measured* interval.
void main() {
  test('reports MiB/s from bytes over the real interval', () {
    expect(
      formatTransferRate(
        deltaBytes: 2 * 1024 * 1024,
        elapsed: const Duration(seconds: 1),
        sentBytes: 2 * 1024 * 1024,
        totalBytes: 411 * 1024 * 1024,
      ),
      'upload rate: 2.0 MiB/s (2.0/411.0 MiB)',
    );
  });

  test('uses the elapsed time, not an assumed one-second tick', () {
    // The same 2 MiB in a *delayed* tick is half the rate. This is the whole
    // reason for dividing by the measured interval: a timer can fire late, and
    // assuming one second would then report a rate higher than reality — on the
    // one line we are using to judge the network.
    expect(
      formatTransferRate(
        deltaBytes: 2 * 1024 * 1024,
        elapsed: const Duration(seconds: 2),
        sentBytes: 4 * 1024 * 1024,
        totalBytes: 411 * 1024 * 1024,
      ),
      'upload rate: 1.0 MiB/s (4.0/411.0 MiB)',
    );
  });

  test('never divides by zero when a tick comes back immediately', () {
    expect(
      formatTransferRate(
        deltaBytes: 0,
        elapsed: Duration.zero,
        sentBytes: 0,
        totalBytes: 1024,
      ),
      'upload rate: 0.0 MiB/s (0.0/0.0 MiB)',
    );
  });
}
