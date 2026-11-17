/// [IsolateHasher] — the receiver's SHA-256, moved off the receiving isolate.
///
/// **The problem it solves (0.2.16).** `PeerServer._handleUpload` hashes each
/// chunk while it is still reading the socket and writing the file. Pure-Dart
/// SHA-256 is synchronous and CPU-bound, so in the receive direction the hash and
/// the I/O take turns on one core instead of overlapping. The user's own
/// measurements on one Wi-Fi 6 link, same 962 MB file, both directions:
///
/// | direction                     | transfer | rate        |
/// |-------------------------------|----------|-------------|
/// | phone → PC (phone sends)      | 75.0 s   | 12.8 MiB/s  |
/// | PC → phone (phone receives)   | ≈118 s   | 8.2 MiB/s   |
///
/// …and the receive rate *decayed* (13–15 → 8–13 → 3–5 MiB/s), the signature of a
/// receiver that cannot keep up and lets TCP push back. The sender already hashes
/// in `Isolate.run`; only the receiver did not. This class gives the receiver the
/// same shape: bytes are handed to a worker isolate, which hashes them on another
/// core while the receiving isolate keeps reading.
///
/// **Contract**
/// * [add] is called once per received chunk, **awaited sequentially** (that is
///   what preserves byte order — a hash is order sensitive). It returns a future
///   only so the caller can be throttled; under the credit window it completes
///   without suspending the caller for long.
/// * [finish] yields the digest as **uppercase hex**, byte-identical in format to
///   `Sha256Accumulator.finish()` and to the sender's `sha256FileHex`.
/// * [dispose] must be called on every path (the receiver uses `try/finally`);
///   it is idempotent and safe before [finish].
///
/// **Failure policy — slow, never broken.** A LAN transfer tool that refuses a
/// file because an internal optimisation failed is worse than a slow one:
/// * If the worker cannot be *spawned* (no `dart:isolate`, spawn error, handshake
///   timeout, or an injected spawner that throws) the hasher silently switches to
///   the inline [Sha256Accumulator] for the whole file, so the digest is exactly
///   what it would have been before this optimisation. One log line records it.
/// * If the worker dies *mid-stream*, its digest is unrecoverable: the chunks it
///   already hashed were transferred away and no longer exist on the receiving
///   side, so replaying the remaining bytes inline would produce a *wrong* digest
///   and get a perfectly good file deleted as a false mismatch. [finish] therefore
///   throws [HashDigestUnavailable] instead of answering, and the caller re-hashes
///   the file it has already written (a full re-read — slow, but correct). See
///   `PeerServer._handleUpload`.
/// * [add] itself never throws: a throwing receive loop would abort a transfer
///   that is otherwise still healthy.
library;

import 'dart:async';
import 'dart:typed_data';

import 'fingerprint.dart';
import 'hash_worker.dart';

// Native builds get the real worker; every other platform (Web, where
// `dart:isolate` does not exist) gets a stub that reports "no worker", which
// turns into the inline fallback above. The conditional import is what keeps
// `lanlink_core` platform independent — without it `flutter build web` fails on
// the `dart:isolate` import inside `hash_worker_isolate.dart`.
import 'hash_worker_stub.dart' if (dart.library.io) 'hash_worker_isolate.dart';

/// Thrown by [IsolateHasher.finish] when the worker died after hashing some of
/// the stream, so no trustworthy digest exists.
///
/// Callers must treat this as "recompute from the bytes you already stored" and
/// **not** as "the transfer failed": the file on disk is complete and intact.
class HashDigestUnavailable implements Exception {
  const HashDigestUnavailable(this.reason);

  /// Why the digest is unavailable, for the log.
  final String reason;

  @override
  String toString() => 'HashDigestUnavailable: $reason';
}

/// Streaming SHA-256 whose CPU work runs on a worker isolate when one is
/// available, and on the calling isolate otherwise. See the library doc.
class IsolateHasher {
  /// Creates a hasher and starts the worker in the background.
  ///
  /// [spawnWorker] overrides how the worker is obtained: the test suite injects a
  /// fake backend (to drive the credit window deterministically) or a throwing
  /// factory (to exercise the inline fallback). Production passes nothing.
  ///
  /// [log] receives diagnostics — one line on a fallback, one on a worker loss.
  ///
  /// [creditWindow] is the maximum number of sent-but-unacked chunks; it bounds
  /// the memory the worker path can hold to `creditWindow * chunkSize`.
  IsolateHasher({
    HashWorkerSpawner? spawnWorker,
    void Function(String message)? log,
    int creditWindow = kDefaultHashWorkerCreditWindow,
  })  : _spawnWorker = spawnWorker ?? spawnHashWorker,
        _log = log,
        _creditWindow = creditWindow < 1 ? 1 : creditWindow {
    _start = _startWorker();
  }

  final HashWorkerSpawner _spawnWorker;
  final void Function(String message)? _log;
  final int _creditWindow;

  /// Completes once the mode is decided: worker attached, or inline chosen.
  /// Never completes with an error (a failed spawn is a mode, not a failure).
  late final Future<void> _start;

  HashWorkerBackend? _backend;
  StreamSubscription<HashWorkerEvent>? _events;

  /// Non-null when hashing runs on the calling isolate (the pre-0.2.16 path).
  Sha256Accumulator? _inline;

  /// Waiter for a free credit slot; completed by a [HashWorkerAck].
  Completer<void>? _credit;

  /// Waiter for the digest; completed by [HashWorkerDigest].
  Completer<String>? _digest;

  int _outstanding = 0;
  int _peakOutstanding = 0;
  int _backpressureWaits = 0;
  int _backpressureWaitMicros = 0;
  bool _workerFailedMidStream = false;
  String? _workerFailureReason;
  bool _digestDelivered = false;
  bool _finishing = false;
  bool _disposed = false;

  /// Whether hashing actually runs on a worker isolate (decided on first [add]).
  ///
  /// `false` means the inline fallback is in use — either the platform has no
  /// isolates or the spawn failed. Exposed for tests and for the diagnostic log;
  /// nothing in the receive path branches on it.
  bool get usesWorker => _backend != null;

  /// Whether this hasher fell back to hashing on the calling isolate.
  bool get isInline => _inline != null;

  /// Chunks sent to the worker that it has not acked yet (0 while inline).
  int get outstandingChunks => _outstanding;

  /// High-water mark of [outstandingChunks].
  ///
  /// Bounded by [kDefaultHashWorkerCreditWindow] by construction; the test suite
  /// asserts it never exceeds the configured window when feeding far faster than
  /// the worker consumes. Public so a test can observe the window without
  /// reaching into private state.
  int get peakOutstandingChunks => _peakOutstanding;

  /// Whether the worker died after hashing part of the stream, in which case
  /// [finish] will throw [HashDigestUnavailable].
  bool get isCompromised => _workerFailedMidStream;

  /// How many times [add] had to park because the credit window was full.
  ///
  /// Read-only counter added in 0.2.17 for the receive-side diagnostics: a
  /// transfer whose rate decays while this number climbs is being throttled by
  /// *this* class, not by the link. Deliberately exposed as a plain `int` getter
  /// rather than by loosening the encapsulation (no callback, no event stream) —
  /// the receive loop samples it once per second and once at the end.
  int get backpressureWaits => _backpressureWaits;

  /// Total time [add] spent parked on a full credit window, in microseconds.
  int get backpressureWaitMicros => _backpressureWaitMicros;

  /// An already-completed future for the no-op paths, so the hot loop does not
  /// allocate one per chunk.
  static final Future<void> _completed = Future<void>.value();

  /// Feeds the next [chunk]. Await it before feeding the next one: a digest is
  /// order sensitive and this method does not queue internally.
  ///
  /// Completes immediately (same future object) while the credit window is open,
  /// and suspends while the worker is behind. Never throws.
  Future<void> add(Uint8List chunk) {
    if (chunk.isEmpty) {
      return _completed;
    }
    return _add(chunk);
  }

  /// Closes the hash and returns the digest as **uppercase hex**.
  ///
  /// Throws [HashDigestUnavailable] if the worker died mid-stream; throws
  /// [StateError] if called twice.
  Future<String> finish() async {
    if (_finishing) {
      throw StateError('IsolateHasher.finish() called twice');
    }
    _finishing = true;
    await _start;
    final inline = _inline;
    if (inline != null) {
      return inline.finish();
    }
    if (_workerFailedMidStream) {
      throw HashDigestUnavailable(
        _workerFailureReason ?? 'hash worker failed',
      );
    }
    final completions = Completer<String>();
    _digest = completions;
    _backend?.finish();
    // No ack drain needed: two isolates exchange messages in send order, so the
    // digest the worker emits after `finish()` already covers every chunk sent
    // before it.
    final hex = await completions.future;
    _outstanding = 0;
    return hex;
  }

  /// Releases the worker. Idempotent; safe before [finish].
  ///
  /// The receiver calls this from a `finally`, so every early return (rejected
  /// upload, size overflow, write error, sha mismatch) tears the worker down.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    // Wake any waiter so a pending `add` unwinds instead of hanging on a worker
    // that is about to disappear.
    final credit = _credit;
    _credit = null;
    if (credit != null && !credit.isCompleted) {
      credit.complete();
    }
    final digest = _digest;
    _digest = null;
    if (digest != null && !digest.isCompleted) {
      digest.completeError(
        const HashDigestUnavailable(
            'hasher disposed before the digest arrived'),
      );
    }
    final events = _events;
    _events = null;
    await events?.cancel();
    final backend = _backend;
    _backend = null;
    _outstanding = 0;
    await backend?.dispose();
  }

  Future<void> _startWorker() async {
    try {
      final backend = await _spawnWorker();
      if (_disposed) {
        // Disposed while the worker was still starting: drop it here rather
        // than leaking an isolate for the lifetime of the process.
        await backend.dispose();
        return;
      }
      _backend = backend;
      _events = backend.events.listen(
        _onEvent,
        onError: (Object error) => _onWorkerLoss('worker stream error: $error'),
      );
      return;
    } catch (error) {
      // Slower, but the transfer still happens — the whole point of the
      // fallback. One line, so an on-device log explains the rate.
      _log?.call(
        'hash worker unavailable ($error) - falling back to inline SHA-256 on '
        'the receiving isolate',
      );
    }
    _inline = Sha256Accumulator();
  }

  void _onEvent(HashWorkerEvent event) {
    switch (event) {
      case HashWorkerAck():
        if (_outstanding > 0) {
          _outstanding--;
        }
        final credit = _credit;
        if (credit != null && !credit.isCompleted) {
          credit.complete();
        }
      case HashWorkerDigest(:final String hex):
        _digestDelivered = true;
        final digest = _digest;
        if (digest != null && !digest.isCompleted) {
          digest.complete(hex);
        }
      case HashWorkerFailure(:final String message):
        _onWorkerLoss(message);
    }
  }

  void _onWorkerLoss(String message) {
    if (_disposed || _workerFailedMidStream) {
      return;
    }
    if (_digestDelivered) {
      // The worker closed its inbox right after sending the digest, so seeing it
      // exit now is the *normal* end of life. Without this guard every successful
      // upload could log "worker lost mid-transfer" (and flag the hasher as
      // compromised) purely because the exit notice lost a race with `dispose`.
      return;
    }
    _workerFailedMidStream = true;
    _workerFailureReason = message;
    if (!_finishing) {
      // Mid-stream: the caller will notice at `finish()`. Say so now, because
      // the delayed failure is a full re-read of the file and that is worth
      // seeing in the log.
      _log?.call(
        'hash worker lost mid-transfer ($message) - the digest will be '
        'recomputed from the file already on disk',
      );
    }
    final credit = _credit;
    if (credit != null && !credit.isCompleted) {
      credit.complete();
    }
    final digest = _digest;
    if (digest != null && !digest.isCompleted) {
      digest.completeError(HashDigestUnavailable(message));
    }
  }

  Future<void> _add(Uint8List chunk) async {
    await _start;
    if (_disposed) {
      return;
    }
    final inline = _inline;
    if (inline != null) {
      // Fallback path: exactly the pre-0.2.16 behaviour, on this isolate.
      inline.add(chunk);
      return;
    }
    if (_workerFailedMidStream) {
      // Nothing can make the digest valid again, so do not accumulate memory for
      // bytes that will be recomputed from disk.
      return;
    }
    final backend = _backend;
    if (backend == null) {
      return;
    }
    if (!await _reserveSlot()) {
      return;
    }
    backend.addChunk(chunk);
  }

  /// Blocks until fewer than [_creditWindow] chunks are in flight.
  ///
  /// This is the backpressure that keeps the transfer honest: while it waits, the
  /// receive loop is not pulling from the socket, so the peer's TCP window closes
  /// and the sender slows down to the rate the hasher can sustain — instead of the
  /// queue growing to the size of the file.
  /// Reserves one slot in the credit window, waiting if the worker is behind.
  ///
  /// The increment happens **inside** this method, with no `await` between the
  /// check and the increment: reserving in the caller (`await takeCredit();
  /// outstanding++`) would let every concurrent `add` pass the check before any
  /// of them incremented, which is precisely the unbounded queue the window is
  /// there to prevent. (First implementation did that; the 64-chunk feeding test
  /// caught all 64 reaching the worker, peak 64 with a window of 4.)
  ///
  /// Returns `false` when the window closed for good (disposed or worker lost).
  Future<bool> _reserveSlot() async {
    // 0.2.17 diagnostics: one stopwatch, allocated only when the window is
    // actually full (the fast path never reaches it), so measuring costs nothing
    // on a healthy transfer and exactly one `Stopwatch` per stall otherwise.
    Stopwatch? stalled;
    while (_outstanding >= _creditWindow) {
      if (_disposed || _workerFailedMidStream) {
        _recordStall(stalled);
        return false;
      }
      final waiter = _credit ??= Completer<void>();
      stalled ??= Stopwatch()..start();
      await waiter.future;
      if (identical(_credit, waiter)) {
        _credit = null;
      }
    }
    _recordStall(stalled);
    if (_disposed || _workerFailedMidStream) {
      return false;
    }
    _outstanding++;
    if (_outstanding > _peakOutstanding) {
      _peakOutstanding = _outstanding;
    }
    return true;
  }

  /// Folds one stall into the diagnostic counters; a no-op when nothing waited.
  void _recordStall(Stopwatch? stalled) {
    if (stalled == null) {
      return;
    }
    _backpressureWaits++;
    _backpressureWaitMicros += stalled.elapsedMicroseconds;
  }
}
