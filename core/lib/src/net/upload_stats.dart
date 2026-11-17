/// Receive-side transfer accounting for `PeerServer._handleUpload` (0.2.17).
///
/// **Why this exists.** 0.2.16 moved the receiver's SHA-256 onto a worker
/// isolate and the user's phone measured the PC → phone direction improving from
/// 118.5 s to 95.5 s (8.1 → 10.1 MiB/s), with the old tail collapse (3–5 MiB/s)
/// gone. But the *other* direction — phone → PC, where the phone is the sender —
/// ran at 12.8 MiB/s over the same router, so roughly 2.7 MiB/s of the receive
/// path is still unexplained. Guessing at that gap means either rewriting the
/// TLS plumbing or second-guessing `IOSink` backpressure, both expensive and
/// both able to regress a working transfer. So 0.2.17 adds **instruments only**:
/// this class accumulates counters that cost an `int` add per chunk, and
/// `_handleUpload` prints one summary line per upload. No behaviour changes —
/// chunk sizes, buffer strategy, credit window and wire protocol are untouched.
///
/// **What the numbers answer.** For every received chunk the handler records how
/// long the disk write took ([addSink]), how long the `await hash.add` took
/// ([addHash], which includes waiting on the worker's credit window), and the
/// wall clock of the whole `await for` loop ([loopMicros]). The remainder,
/// `loop - hash - sink`, is the receive loop itself plus time parked waiting for
/// the socket — that is the "fast" bucket. The three shares tell apart the three
/// candidate causes of the missing throughput:
///
/// * `hash` dominant and `hashAwaitPct` high → the hasher (worker or inline
///   fallback) is the bottleneck.
/// * `sink` dominant → the disk write end is the bottleneck (the known
///   `IOSink` backpressure question, deliberately not touched here).
/// * `fast` dominant → the receiver is *not* the bottleneck at all; the bytes are
///   simply not arriving faster (link, sender, or TCP window).
///
/// Chunk shape is recorded too ([chunkCount], [minChunkBytes], [maxChunkBytes]):
/// if the sending phone's HTTP body arrives in far smaller pieces than 64 KiB,
/// the per-chunk overhead — not the CPU — explains part of the gap, and every
/// later optimisation would be aimed at the wrong layer.
///
/// **Cost discipline.** Everything here is `int` accumulation. Nothing in the hot
/// path formats a string, allocates a `Map`, or writes a log line; the one
/// formatted line is produced by [summary] / [formatReceiveRate] when a transfer
/// finishes or once a second.
library;

/// Body size at or above which `_handleUpload` logs a summary line.
///
/// 4 MiB keeps the line out of the log for the small files and thumbnails that
/// would otherwise flood it, while still covering every transfer whose rate is
/// worth analysing.
const int kUploadStatsMinBytes = 4 * 1024 * 1024;

/// Counters for a single inbound `/put` body.
///
/// One instance per upload; `_handleUpload` feeds it from the receive loop and
/// calls [summary] once, after the file has been flushed and closed.
class UploadStats {
  /// Creates an empty accumulator.
  ///
  /// [summaryThresholdBytes] is the body size at or above which [shouldLog] is
  /// `true`; production uses [kUploadStatsMinBytes] and never overrides it. It
  /// is a constructor argument rather than a global so a test can pin the
  /// formatting of a small body without pushing megabytes through a socket.
  UploadStats({this.summaryThresholdBytes = kUploadStatsMinBytes});

  /// Bytes at or above which [shouldLog] reports `true`.
  final int summaryThresholdBytes;

  int _chunkCount = 0;
  int _bytesTotal = 0;
  int _minChunkBytes = 0;
  int _maxChunkBytes = 0;
  int _hashMicros = 0;
  int _sinkMicros = 0;
  int _loopMicros = 0;
  int _flushMicros = 0;
  int _closeMicros = 0;

  /// Number of non-empty chunks received.
  int get chunkCount => _chunkCount;

  /// Total bytes received (equals the body length on a complete upload).
  int get bytesTotal => _bytesTotal;

  /// Smallest received chunk in bytes, or `0` before the first chunk.
  int get minChunkBytes => _minChunkBytes;

  /// Largest received chunk in bytes, or `0` before the first chunk.
  int get maxChunkBytes => _maxChunkBytes;

  /// Mean received chunk size in bytes (`0` when nothing arrived).
  double get averageChunkBytes =>
      _chunkCount == 0 ? 0 : _bytesTotal / _chunkCount;

  /// Cumulative `await hash.add(chunk)` time, including credit-window waits.
  int get hashMicros => _hashMicros;

  /// Cumulative `sink.add(chunk)` time (the disk write hand-off).
  int get sinkMicros => _sinkMicros;

  /// Wall clock of the entire `await for (final chunk in request)` loop.
  int get loopMicros => _loopMicros;

  /// Wall clock of `await sink.flush()`.
  int get flushMicros => _flushMicros;

  /// Wall clock of `await sink.close()`.
  int get closeMicros => _closeMicros;

  /// Loop time that is neither hashing nor writing — the loop itself plus time
  /// parked waiting for the socket. Never negative (the phases are measured
  /// inside the loop, but clock granularity can still make the sum exceed it by
  /// a few microseconds on a very short transfer).
  int get fastMicros {
    final int rest = _loopMicros - _hashMicros - _sinkMicros;
    return rest < 0 ? 0 : rest;
  }

  /// Whether this transfer is large enough to deserve a summary line.
  bool get shouldLog => _bytesTotal >= summaryThresholdBytes;

  /// Records one received chunk of [length] bytes.
  ///
  /// Empty chunks are ignored entirely: an HTTP body can in principle deliver a
  /// zero-length piece, and letting one through would report `min=0.0KiB` and
  /// make the chunk-shape numbers useless.
  void addChunk(int length) {
    if (length <= 0) {
      return;
    }
    _chunkCount++;
    _bytesTotal += length;
    if (_chunkCount == 1) {
      _minChunkBytes = length;
      _maxChunkBytes = length;
      return;
    }
    if (length < _minChunkBytes) {
      _minChunkBytes = length;
    }
    if (length > _maxChunkBytes) {
      _maxChunkBytes = length;
    }
  }

  /// Adds the time `await hash.add(chunk)` took.
  void addHash(int micros) {
    if (micros > 0) {
      _hashMicros += micros;
    }
  }

  /// Adds the time `sink.add(chunk)` took.
  void addSink(int micros) {
    if (micros > 0) {
      _sinkMicros += micros;
    }
  }

  /// Sets the measured wall clock of the receive loop.
  ///
  /// Assigned (not accumulated) because it is read from one stopwatch that spans
  /// the whole loop; it may be set twice — once when the loop ends normally and
  /// once on the error path — and the last write wins.
  set loopMicros(int micros) {
    _loopMicros = micros < 0 ? 0 : micros;
  }

  /// Sets the measured `await sink.flush()` duration.
  set flushMicros(int micros) {
    _flushMicros = micros < 0 ? 0 : micros;
  }

  /// Sets the measured `await sink.close()` duration.
  set closeMicros(int micros) {
    _closeMicros = micros < 0 ? 0 : micros;
  }

  /// Renders the single summary line `_handleUpload` logs.
  ///
  /// One physical line on purpose: the on-device log is read with `grep`, and a
  /// wrapped record would bury the fields. Keys are stable (`bytes`, `chunks`,
  /// `avg`, `min`, `max`, `minB`, `maxB`, `loop`, `fastMs`, `fast`, `hash`,
  /// `sink`, `flush`, `close`, `hashBackpressure`, `hashAwaitPct`, `worker`) so
  /// the next measurement can be parsed instead of eyeballed.
  ///
  /// `minB` / `maxB` repeat the two ends in raw bytes: the first real 256 MiB run
  /// printed `min=0.00KiB`, i.e. a fragment smaller than the KiB precision can
  /// express, and a field that always reads zero invites the reader to assume the
  /// counter is broken rather than the chunk is dust.
  ///
  /// `fast` is the share in percent (as sketched in the ticket) and is wrapped in
  /// parentheses for prose; its duration is the separate `fastMs` key, because
  /// "26.3% of a 900 ms loop" and "237 ms" answer different questions and a
  /// parser should not have to divide to get the second. A parser should strip a
  /// leading `(` and trailing `%)` from that one field.
  ///
  /// [hashBackpressureWaits] / [hashBackpressureMicros] are passed in rather than
  /// accumulated here because only [IsolateHasher] knows when its credit window
  /// was full — a transfer that never waited on the worker is telling a very
  /// different story from one that stalled repeatedly.
  ///
  /// [usesIsolateWorker] is the hasher's mode (`null` = not decided yet, which
  /// prints nothing extra). An inline fallback halves the meaning of `hash=`, so
  /// it must be visible on the same line.
  String summary({
    int hashBackpressureWaits = 0,
    int hashBackpressureMicros = 0,
    bool? usesIsolateWorker,
  }) {
    final String worker =
        usesIsolateWorker == null ? '' : ' worker=$usesIsolateWorker';
    return 'upload stats: bytes=$_bytesTotal chunks=$_chunkCount '
        'avg=${_kib(averageChunkBytes)}KiB '
        'min=${_kib(_minChunkBytes.toDouble())}KiB '
        'max=${_kib(_maxChunkBytes.toDouble())}KiB '
        'minB=$_minChunkBytes maxB=$_maxChunkBytes '
        'loop=${_ms(_loopMicros)}ms fastMs=${_ms(fastMicros)}ms '
        '(fast=${_pct(fastMicros, _loopMicros)}%) '
        'hash=${_ms(_hashMicros)}ms sink=${_ms(_sinkMicros)}ms '
        'flush=${_ms(_flushMicros)}ms close=${_ms(_closeMicros)}ms '
        'hashBackpressure=${hashBackpressureWaits}x/'
        '${_ms(hashBackpressureMicros)}ms '
        'hashAwaitPct=${_pct(_hashMicros, _loopMicros)}%$worker';
  }

  /// Microseconds to milliseconds with one decimal, as printed in [summary].
  static String _ms(int micros) => (micros / 1000).toStringAsFixed(1);

  /// Bytes to KiB with **two** decimals.
  ///
  /// Two, not one, because the first real 256 MiB desktop run measured
  /// `avg=3.2KiB chunks=81692` — the loopback receive path is fed ~3 KiB pieces,
  /// not 64 KiB ones — and a one-decimal `min` collapsed the sub-100-byte
  /// fragments to `0.0KiB`, i.e. the field that says "the tail arrives as dust"
  /// printed nothing at all. Two decimals resolve to ~10 bytes and still read as
  /// KiB.
  static String _kib(double bytes) => (bytes / 1024).toStringAsFixed(2);

  /// `part` as a percentage of `whole`, one decimal; `0.0` when `whole` is 0.
  static String _pct(int part, int whole) =>
      whole <= 0 ? '0.0' : (part * 100 / whole).toStringAsFixed(1);
}

/// One receive-side rate line, emitted at most once a second while a body is
/// arriving: `recv rate: 10.1 MiB/s (850.0/962.5 MiB) chunks=... hashWait=...ms`.
///
/// The mirror image of the sender's `upload rate:` line (see
/// `app/lib/data/real/lan_transfer_service.dart`), and for the same reason: the
/// *shape* of the curve is the diagnostic. Reading `hashWait` on the same line as
/// the rate is what makes the next device measurement decisive — when the rate
/// drops, either the hasher's credit window is closing at the same moment (the
/// hasher is the bottleneck) or it is not (the bytes stopped arriving, and the
/// receiver is innocent).
///
/// Pure and separated from the handler so the units — [deltaBytes] is bytes,
/// the printed number is **MiB/s** — can be pinned by a test.
String formatReceiveRate({
  required int deltaBytes,
  required Duration elapsed,
  required int receivedBytes,
  required int totalBytes,
  required int chunkCount,
  required int hashWaitMicros,
}) {
  const int mib = 1024 * 1024;
  final double seconds = elapsed.inMicroseconds / 1000000;
  final String rate =
      seconds <= 0 ? '0.0' : (deltaBytes / mib / seconds).toStringAsFixed(1);
  final String got = (receivedBytes / mib).toStringAsFixed(1);
  // `totalBytes < 0` means the sender declared no size; print the bytes so far
  // instead of a `x/-1.0` pair that would read as a broken counter.
  final String progress = totalBytes < 0
      ? '$got MiB'
      : '$got/${(totalBytes / mib).toStringAsFixed(1)} MiB';
  final String wait = (hashWaitMicros / 1000).toStringAsFixed(1);
  return 'recv rate: $rate MiB/s ($progress) chunks=$chunkCount '
      'hashWait=${wait}ms';
}
