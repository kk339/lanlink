// Tests for the 0.2.17 receive-side accounting (`upload_stats.dart`).
//
// 0.2.17 is **diagnostics only**: these tests pin the numbers that the on-device
// summary line will be read for, so that the next real-device measurement
// ("the rate dropped 8 → 3 MiB/s, what was the hash share?") is answered by a
// field that was actually verified, not by a print statement nobody re-read.
//
// The end-to-end half of the contract — that `PeerServer._handleUpload` really
// emits this line for a real upload over TLS — lives in `upload_flow_test.dart`.
import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// Splits one summary line into `key -> raw value`.
///
/// Deliberately dumb: it exists to prove the line is machine-readable with
/// `split(' ')` + `indexOf('=')`, the way an `awk` one-liner on the device log
/// would read it. A leading `(` and a trailing `%)` are stripped because the
/// `fast` share is wrapped in parentheses for prose.
Map<String, String> _parseSummary(String line) {
  final Map<String, String> fields = <String, String>{};
  for (final String raw in line.split(' ')) {
    String token = raw;
    if (token.isEmpty) {
      continue;
    }
    if (token.startsWith('(')) {
      token = token.substring(1);
    }
    if (token.endsWith('%)')) {
      token = token.substring(0, token.length - 2);
    } else if (token.endsWith('%')) {
      token = token.substring(0, token.length - 1);
    }
    final int eq = token.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    fields[token.substring(0, eq)] = token.substring(eq + 1);
  }
  return fields;
}

/// Parses a `<number>ms` / `<number>KiB` / `<number>%` field.
double _number(Map<String, String> fields, String key) {
  final String? raw = fields[key];
  if (raw == null) {
    fail('field "$key" is missing from the summary line: $fields');
  }
  return double.parse(
    raw.replaceAll('ms', '').replaceAll('KiB', '').replaceAll('%', ''),
  );
}

void main() {
  group('UploadStats chunk shape', () {
    test('chunkCount/min/max/avg reflect the fed chunk sizes', () {
      final UploadStats stats = UploadStats();
      // Deliberately unordered and mixed: the widest chunk arrives second, the
      // narrowest third, so a min/max kept only from the first chunk would show
      // up here.
      const List<int> sizes = <int>[
        100,
        64 * 1024,
        7,
        4096,
        64 * 1024,
        1,
      ];
      for (final int size in sizes) {
        stats.addChunk(size);
      }
      final int total = sizes.fold<int>(0, (int a, int b) => a + b);

      expect(stats.chunkCount, sizes.length);
      expect(stats.bytesTotal, total);
      expect(stats.minChunkBytes, 1);
      expect(stats.maxChunkBytes, 64 * 1024);
      expect(stats.averageChunkBytes, closeTo(total / sizes.length, 1e-9));
    });

    test('a zero-length chunk is ignored instead of poisoning min', () {
      // An HTTP body is not supposed to deliver an empty piece, but if it ever
      // does, `min=0.0KiB` would make the chunk-shape numbers worthless at
      // exactly the moment they are being read.
      final UploadStats stats = UploadStats();
      stats.addChunk(0);
      expect(stats.chunkCount, 0);
      expect(stats.minChunkBytes, 0);
      expect(stats.maxChunkBytes, 0);
      expect(stats.averageChunkBytes, 0);

      stats.addChunk(1024);
      stats.addChunk(0);
      expect(stats.chunkCount, 1);
      expect(stats.bytesTotal, 1024);
      expect(stats.minChunkBytes, 1024);
      expect(stats.maxChunkBytes, 1024);
      expect(stats.averageChunkBytes, 1024);
    });

    test('an untouched accumulator reports zeros, not NaN', () {
      final UploadStats stats = UploadStats();
      expect(stats.chunkCount, 0);
      expect(stats.bytesTotal, 0);
      expect(stats.averageChunkBytes, 0);
      expect(stats.fastMicros, 0);
      final Map<String, String> fields = _parseSummary(stats.summary());
      expect(fields['bytes'], '0');
      expect(fields['chunks'], '0');
      expect(_number(fields, 'avg'), 0);
      // No loop measured: a percentage of nothing is 0, never NaN or Infinity.
      expect(_number(fields, 'hashAwaitPct'), 0);
      expect(_number(fields, 'fast'), 0);
    });
  });

  group('UploadStats summary line', () {
    test('a 1 MiB + 7 B body yields parseable fields that match the bytes fed',
        () {
      // The size the ticket asked for: sixteen 64 KiB chunks plus a 7-byte tail,
      // i.e. the smallest body where a dropped tail would change the digest and
      // where the chunk-shape fields have something to say.
      const int chunk = 64 * 1024;
      const int size = 1024 * 1024 + 7;
      final UploadStats stats = UploadStats(summaryThresholdBytes: 0);
      int fed = 0;
      while (fed + chunk <= size) {
        stats.addChunk(chunk);
        fed += chunk;
      }
      stats.addChunk(size - fed);

      expect(stats.chunkCount, 17);
      expect(stats.bytesTotal, size);

      // Phase timings as `_handleUpload` accumulates them: 100 µs of sink and
      // 420 µs of hash per chunk.
      for (int i = 0; i < stats.chunkCount; i++) {
        stats.addSink(100);
        stats.addHash(420);
      }
      stats.loopMicros = 12000;
      stats.flushMicros = 1500;
      stats.closeMicros = 300;

      final String line = stats.summary(
        hashBackpressureWaits: 3,
        hashBackpressureMicros: 2500,
        usesIsolateWorker: true,
      );
      expect(line, startsWith('upload stats: '));
      expect(line, isNot(contains('\n')), reason: 'one line, greppable');

      final Map<String, String> fields = _parseSummary(line);
      expect(fields['bytes'], '$size');
      expect(int.parse(fields['chunks']!), stats.chunkCount);
      expect(_number(fields, 'avg'), closeTo(size / 17 / 1024, 0.05));
      expect(_number(fields, 'min'), closeTo(7 / 1024, 0.05));
      expect(_number(fields, 'max'), closeTo(64, 0.05));
      // The raw-byte repeats exist because a 7 B tail prints as 0.01KiB and a
      // fragment below that prints as 0.00KiB.
      expect(int.parse(fields['minB']!), 7);
      expect(int.parse(fields['maxB']!), 64 * 1024);

      // The invariant the ticket asked to be able to check: the loop cannot be
      // shorter than the two phases measured inside it. 0.2 ms of slack absorbs
      // one-decimal rounding on three fields.
      final double loop = _number(fields, 'loop');
      final double hash = _number(fields, 'hash');
      final double sink = _number(fields, 'sink');
      expect(loop, greaterThanOrEqualTo(hash + sink - 0.2));
      expect(loop, closeTo(12.0, 0.05));
      expect(hash, closeTo(7.14, 0.05));
      expect(sink, closeTo(1.7, 0.05));

      // fast = loop - hash - sink, the "socket wait + loop itself" remainder,
      // printed both as a duration and as a share of the loop.
      expect(_number(fields, 'fastMs'), closeTo(12.0 - 7.14 - 1.7, 0.1));
      expect(_number(fields, 'fast'), closeTo(3160 / 12000 * 100, 0.1));
      // hashAwaitPct is the share of the loop spent in `await hash.add`.
      expect(_number(fields, 'hashAwaitPct'), closeTo(7140 / 12000 * 100, 0.1));
      expect(_number(fields, 'flush'), closeTo(1.5, 0.05));
      expect(_number(fields, 'close'), closeTo(0.3, 0.05));
      expect(fields['hashBackpressure'], '3x/2.5ms');
      expect(fields['worker'], 'true');
    });

    test('fast never goes negative when phase timings overshoot the loop', () {
      // Stopwatch granularity on Windows can make `hash + sink` exceed the loop
      // by a few microseconds; a negative share would print `-0.1%` and read as
      // a bug in the measurement instead of noise.
      final UploadStats stats = UploadStats(summaryThresholdBytes: 0);
      stats.addChunk(1000);
      stats.addHash(5000);
      stats.addSink(9000);
      stats.loopMicros = 10000;
      expect(stats.fastMicros, 0);
      final Map<String, String> fields = _parseSummary(stats.summary());
      expect(_number(fields, 'fastMs'), 0);
      expect(_number(fields, 'fast'), 0);
      expect(stats.summary(), contains('(fast=0.0%)'));
    });

    test('worker mode is printed only when it is known', () {
      final UploadStats stats = UploadStats(summaryThresholdBytes: 0);
      stats.addChunk(1);
      expect(_parseSummary(stats.summary()).containsKey('worker'), isFalse);
      expect(
        _parseSummary(stats.summary(usesIsolateWorker: false))['worker'],
        'false',
      );
    });

    test('the 4 MiB threshold keeps small bodies out of the log', () {
      final UploadStats small = UploadStats();
      small.addChunk(kUploadStatsMinBytes - 1);
      expect(small.shouldLog, isFalse);

      final UploadStats exact = UploadStats();
      exact.addChunk(kUploadStatsMinBytes);
      expect(exact.shouldLog, isTrue, reason: 'inclusive: >= threshold');
    });
  });

  group('formatReceiveRate', () {
    test('prints MiB/s and the received/total pair, not raw bytes', () {
      // 10 MiB in one second, 850 of 962.5 MiB done: the exact numbers from the
      // 0.2.16 device run, so the units are pinned against a real measurement.
      final String line = formatReceiveRate(
        deltaBytes: 10 * 1024 * 1024,
        elapsed: const Duration(seconds: 1),
        receivedBytes: 850 * 1024 * 1024,
        totalBytes: 1009254400, // 962.5 MiB
        chunkCount: 4096,
        hashWaitMicros: 12345,
      );
      expect(
        line,
        'recv rate: 10.0 MiB/s (850.0/962.5 MiB) chunks=4096 hashWait=12.3ms',
      );
    });

    test('the rate comes from the delta, not from the running total', () {
      final String line = formatReceiveRate(
        deltaBytes: 1024 * 1024,
        elapsed: const Duration(seconds: 2),
        receivedBytes: 500 * 1024 * 1024,
        totalBytes: 4096 * 1024 * 1024,
        chunkCount: 10,
        hashWaitMicros: 0,
      );
      expect(line, startsWith('recv rate: 0.5 MiB/s'));
    });

    test('an undeclared total prints the bytes so far instead of /-1.0', () {
      final String line = formatReceiveRate(
        deltaBytes: 8 * 1024 * 1024,
        elapsed: const Duration(seconds: 1),
        receivedBytes: 8 * 1024 * 1024,
        totalBytes: -1,
        chunkCount: 32,
        hashWaitMicros: 0,
      );
      expect(line, 'recv rate: 8.0 MiB/s (8.0 MiB) chunks=32 hashWait=0.0ms');
    });

    test('a zero elapsed never divides by zero', () {
      final String line = formatReceiveRate(
        deltaBytes: 4096,
        elapsed: Duration.zero,
        receivedBytes: 4096,
        totalBytes: 1048576,
        chunkCount: 1,
        hashWaitMicros: 0,
      );
      expect(line, startsWith('recv rate: 0.0 MiB/s'));
    });
  });
}
