// Tests for the 0.2.16 receive-path hasher: a worker isolate that computes the
// file's SHA-256 while the receiving isolate keeps reading the socket.
//
// What each group is defending (the change is worthless if any of these is
// false):
//   1. digest   — the worker produces exactly the bytes the sender vouched for,
//                 including the empty stream and a short final chunk;
//   2. ★ delay   — hashing 64 MiB does NOT stall the receiving isolate's event
//                 loop (this is the whole point of the change);
//      control  — the same 64 MiB hashed inline DOES stall it, so the first
//                 assertion is a measurement and not a tautology;
//   3. window   — feeding faster than the worker consumes is throttled instead
//                 of queued (bounded memory);
//   4. fallback — a worker that cannot be spawned still yields a correct digest,
//                 with one log line saying so.
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// 64 MiB, in 64 KiB chunks — the sender streams 64 KiB chunks, so this is the
/// same message shape the real receive loop produces.
const int _kStressBytes = 64 * 1024 * 1024;
const int _kChunkBytes = 64 * 1024;

void main() {
  group('digest matches sha256HexOfBytes', () {
    // The five inputs the change must not regress, including the two that catch
    // real mistakes: an empty stream (no `add` ⇒ must still be the digest of
    // "", not an empty string) and a length that is not a multiple of the chunk
    // size (a "forgot the tail" bug).
    final cases = <String, Uint8List>{
      'empty': Uint8List(0),
      'one byte': Uint8List.fromList(<int>[0x00]),
      'exactly 64 KiB': _randomBytes(_kChunkBytes, seed: 1),
      '64 KiB + 1': _randomBytes(_kChunkBytes + 1, seed: 2),
      '1 MiB across 16 chunks': _randomBytes(1024 * 1024, seed: 3),
    };

    for (final entry in cases.entries) {
      test(entry.key, () async {
        final data = entry.value;
        final hasher = IsolateHasher();
        addTearDown(hasher.dispose);
        // Feed the way the receive loop does: 64 KiB chunks, awaited in order,
        // with a deliberately short final chunk.
        for (var offset = 0; offset < data.length; offset += _kChunkBytes) {
          final end = min(offset + _kChunkBytes, data.length);
          await hasher.add(Uint8List.sublistView(data, offset, end));
        }
        final digest = await hasher.finish();
        expect(
          hasher.usesWorker,
          isTrue,
          reason: 'this group must exercise the worker, not the fallback '
              '(a silent fallback would hide worker bugs)',
        );
        expect(digest, sha256HexOfBytes(data));
        expect(digest, hasLength(64));
        expect(digest, digest.toUpperCase(),
            reason: 'uppercase hex, exactly '
                'like Sha256Accumulator and the sender');
      });
    }

    test('a trailing partial chunk is not dropped', () async {
      // 64 KiB * 3 + 5 bytes: a final chunk smaller than a full chunk. If the
      // implementation ever stopped forwarding the last chunk (or hashed only
      // full chunks), this digest changes.
      final data = _randomBytes(3 * _kChunkBytes + 5, seed: 4);
      final hasher = IsolateHasher();
      addTearDown(hasher.dispose);
      for (var offset = 0; offset < data.length; offset += _kChunkBytes) {
        final end = min(offset + _kChunkBytes, data.length);
        await hasher.add(Uint8List.sublistView(data, offset, end));
      }
      expect(await hasher.finish(), sha256HexOfBytes(data));
    });

    test('matches the inline accumulator chunk for chunk', () async {
      // Same bytes, both paths, interleaved per chunk: proves the two agree
      // *incrementally* and not only on a whole-file coincidence.
      final data = _randomBytes(2 * _kChunkBytes + 17, seed: 5);
      final hasher = IsolateHasher();
      addTearDown(hasher.dispose);
      final inline = Sha256Accumulator();
      for (var offset = 0; offset < data.length; offset += _kChunkBytes) {
        final end = min(offset + _kChunkBytes, data.length);
        final chunk = Uint8List.sublistView(data, offset, end);
        inline.add(chunk);
        await hasher.add(chunk);
      }
      expect(await hasher.finish(), inline.finish());
    });
  });

  group('does not stall the receiving isolate', () {
    test('★ hashing 64 MiB on the worker keeps a 16 ms timer under 50 ms',
        () async {
      final chunk = Uint8List(_kChunkBytes)..fillRange(0, _kChunkBytes, 0x5a);
      final chunksPerFeed = _kStressBytes ~/ _kChunkBytes;

      // Warm-up first: spawning an isolate and JIT-warming `package:crypto` must
      // not be charged to the measurement below.
      final warmup = IsolateHasher();
      await warmup.add(chunk);
      await warmup.finish();
      await warmup.dispose();

      // Three rounds, judged on the best one. `dart test` runs test files in
      // parallel, so a single round can be descheduled by an unrelated file and
      // report tens of ms of *ambient* jitter that has nothing to do with
      // hashing (first run of this test in the full suite reported 64 ms for
      // code that measures 1–3 ms on an idle box). The minimum is the round
      // that actually reflects this code; all rounds are printed on failure, so
      // an ambient problem stays visible instead of being averaged away.
      final stalls = <int>[];
      for (var round = 0; round < 3; round++) {
        final hasher = IsolateHasher();
        final meter = _MaxDelayMeter();
        await meter.run(() async {
          for (var sent = 0; sent < chunksPerFeed; sent++) {
            await hasher.add(chunk);
          }
        });
        final digest = await hasher.finish();
        await hasher.dispose();
        stalls.add(meter.maxDelayMs);

        // The bytes really were hashed (a worker that dropped chunks would pass
        // the timing assertion while producing a wrong digest). The reference is
        // computed without materialising 64 MiB in a List<int>: 64 M boxed ints
        // would be half a gigabyte.
        final reference = Sha256Accumulator();
        for (var i = 0; i < chunksPerFeed; i++) {
          reference.add(chunk);
        }
        expect(digest, reference.finish());
      }

      expect(
        stalls.reduce(min),
        lessThan(50),
        reason: 'the receiving isolate must stay responsive while 64 MiB is '
            'hashed; stalls per round: $stalls ms (16 ms timer, 3 rounds, best '
            'round is judged)',
      );
    });

    test(
        'control: the same 64 MiB hashed inline stalls it (this is the cost '
        'the worker removes)', () async {
      // Deliberately the OLD shape: fold every chunk on the receiving isolate.
      // If this control ever stops being red, the assertion above has lost its
      // meaning and must be re-thought. Measured ~500 ms against a 50 ms
      // threshold here — a 10x separation, not a marginal one.
      final chunk = Uint8List(_kChunkBytes)..fillRange(0, _kChunkBytes, 0x5a);
      final meter = _MaxDelayMeter();
      final accumulator = Sha256Accumulator();
      await meter.run(() async {
        for (var sent = 0; sent < _kStressBytes; sent += _kChunkBytes) {
          accumulator.add(chunk);
        }
      });
      accumulator.finish();
      expect(
        meter.maxDelayMs,
        greaterThan(50),
        reason: 'inline SHA-256 of 64 MiB should starve the event loop; '
            'measured only ${meter.maxDelayMs} ms, so the ★ test above is not '
            'measuring what it claims',
      );
    });
  });

  group('backpressure', () {
    test('never lets more chunks in flight than the credit window', () async {
      final backend = _FakeBackend();
      final hasher = IsolateHasher(
        spawnWorker: () async => backend,
        creditWindow: 4,
      );
      addTearDown(hasher.dispose);
      final chunk = Uint8List(1024);

      // Fire 64 adds without awaiting: a fast producer against a worker that has
      // not acked anything yet. Only `creditWindow` may reach the worker.
      final pending = <Future<void>>[
        for (var i = 0; i < 64; i++) hasher.add(chunk),
      ];
      await _pump();
      expect(backend.received, hasLength(4),
          reason: 'the window is the only '
              'thing standing between a fast network and unbounded memory');
      expect(hasher.outstandingChunks, 4);
      expect(hasher.peakOutstandingChunks, 4);

      // Acks release exactly one slot each; the peak must never grow.
      for (var ack = 0; ack < 60; ack++) {
        backend.ackOne();
        await _pump();
        expect(hasher.peakOutstandingChunks, lessThanOrEqualTo(4));
      }
      await Future.wait(pending);
      expect(backend.received, hasLength(64),
          reason: 'every chunk still got '
              'through — throttling must not drop data');
      expect(hasher.peakOutstandingChunks, lessThanOrEqualTo(4));
    });

    test('a small window still produces the right digest', () async {
      // Same bytes through a window of 1: throttling must not reorder or drop
      // anything (a digest is order sensitive).
      final data = _randomBytes(8 * _kChunkBytes + 3, seed: 6);
      final hasher = IsolateHasher(creditWindow: 1);
      addTearDown(hasher.dispose);
      for (var offset = 0; offset < data.length; offset += _kChunkBytes) {
        final end = min(offset + _kChunkBytes, data.length);
        await hasher.add(Uint8List.sublistView(data, offset, end));
      }
      expect(await hasher.finish(), sha256HexOfBytes(data));
      expect(hasher.peakOutstandingChunks, lessThanOrEqualTo(1));
    });
  });

  group('fallback', () {
    test('a spawner that throws still yields the correct digest, and says so',
        () async {
      final logs = <String>[];
      final hasher = IsolateHasher(
        spawnWorker: () async => throw StateError('no isolate for you'),
        log: logs.add,
      );
      addTearDown(hasher.dispose);
      final data = _randomBytes(5 * _kChunkBytes + 9, seed: 7);
      for (var offset = 0; offset < data.length; offset += _kChunkBytes) {
        final end = min(offset + _kChunkBytes, data.length);
        await hasher.add(Uint8List.sublistView(data, offset, end));
      }
      expect(await hasher.finish(), sha256HexOfBytes(data));
      expect(hasher.isInline, isTrue);
      expect(hasher.usesWorker, isFalse);
      expect(
        logs.join('\n'),
        contains('falling back to inline SHA-256'),
        reason: 'a degraded rate on a user device must be explainable from its '
            'log, without a debugger',
      );
      expect(logs.join('\n'), contains('no isolate for you'));
    });

    test('a worker lost mid-stream makes finish() throw, not answer', () async {
      // Answering with a partial digest would delete a good file as a "sha
      // mismatch"; the receiver prefers to re-read the file it already wrote.
      final logs = <String>[];
      final backend = _FakeBackend();
      final hasher = IsolateHasher(
        spawnWorker: () async => backend,
        log: logs.add,
      );
      addTearDown(hasher.dispose);
      await hasher.add(Uint8List(64));
      backend.fail('simulated crash');
      await _pump();
      expect(hasher.isCompromised, isTrue);
      expect(hasher.finish, throwsA(isA<HashDigestUnavailable>()));
      expect(logs.join('\n'), contains('recomputed from the file'));
      // The receive loop is still running when this happens: feeding more bytes
      // must not throw and must not accumulate them for a digest nobody can use.
      await hasher.add(Uint8List(64));
      expect(hasher.outstandingChunks, lessThanOrEqualTo(1));
    });

    test('add() on a disposed hasher is a no-op, not a throw', () async {
      // The receive loop can still be mid-`await` when the request unwinds.
      final hasher = IsolateHasher();
      await hasher.add(Uint8List(64));
      await hasher.dispose();
      await hasher.add(Uint8List(64)); // must not throw
      await hasher.dispose(); // idempotent
    });

    test('finish() twice is a StateError (same contract as the accumulator)',
        () async {
      final hasher = IsolateHasher();
      addTearDown(hasher.dispose);
      await hasher.add(Uint8List.fromList(<int>[1, 2, 3]));
      await hasher.finish();
      expect(hasher.finish, throwsStateError);
    });
  });
}

/// Measures the longest stall of a 16 ms periodic timer while [body] runs.
///
/// Stalls are computed against the timer's *expected* firing time, so a stalled
/// event loop shows up as a delay of the whole stall, and the tick that was due
/// during the stall is given a chance to land before the timer is cancelled —
/// otherwise a stall at the very end of [body] would be cancelled away and the
/// measurement would report 0 ms (which is exactly what a first draft did: a
/// tight 500 ms synchronous loop measured "0 ms" until the pending tick was
/// allowed to fire).
class _MaxDelayMeter {
  int maxDelayMs = 0;
  int feedMs = 0;

  Future<void> run(Future<void> Function() body) async {
    var tick = 0;
    final stopwatch = Stopwatch()..start();
    final timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      tick++;
      final delay = stopwatch.elapsedMilliseconds - 16 * tick;
      if (delay > maxDelayMs) {
        maxDelayMs = delay;
      }
    });
    await body();
    feedMs = stopwatch.elapsedMilliseconds;
    // Let the tick that was due during the feed fire before cancelling.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    timer.cancel();
  }
}

/// A deterministic in-memory backend: acknowledges only when the test says so,
/// so the producer is free to outrun the consumer on purpose.
class _FakeBackend implements HashWorkerBackend {
  final StreamController<HashWorkerEvent> _events =
      StreamController<HashWorkerEvent>();
  final List<Uint8List> received = <Uint8List>[];
  var _acksSent = 0;

  @override
  Stream<HashWorkerEvent> get events => _events.stream;

  @override
  void addChunk(Uint8List chunk) {
    received.add(chunk);
  }

  @override
  void finish() {
    _events.add(const HashWorkerDigest('00'));
  }

  /// Reports a worker crash, i.e. "no digest will ever arrive".
  void fail(String message) {
    _events.add(HashWorkerFailure(message));
  }

  /// Releases one credit, i.e. "the worker consumed one chunk".
  void ackOne() {
    if (_acksSent >= received.length) {
      return;
    }
    _acksSent++;
    _events.add(const HashWorkerAck(1));
  }

  @override
  Future<void> dispose() async {
    await _events.close();
  }
}

Uint8List _randomBytes(int length, {required int seed}) {
  final random = Random(seed);
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

/// Lets queued microtasks and port messages run without a long sleep.
Future<void> _pump() => Future<void>.delayed(Duration.zero);
