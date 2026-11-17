/// The native (VM/AOT) hashing worker: a real background isolate that folds
/// chunks into a SHA-256 digest on another core, so the receiving isolate is
/// free to read the socket and write the file at the same time.
///
/// **Why an isolate and not a `Timer`/`scheduleMicrotask`:** SHA-256 is
/// CPU-bound and, in `package:crypto`, entirely synchronous. Yielding more often
/// cannot create a core; only another isolate can. (0.2.16 measured the
/// difference: see `hash_worker.dart` for the device numbers that motivated
/// this.)
///
/// **Transport, precisely.** Chunks travel as `TransferableTypedData`, which the
/// receiving isolate can `materialize()` in place. Handing a plain `Uint8List`
/// to `SendPort.send` instead would put it through the message serialiser — an
/// extra copy plus envelope overhead per 64 KiB chunk, which is the same order
/// as the hash itself at these sizes. `TransferableTypedData.fromList` does
/// consolidate the bytes into one transferable buffer (one copy, unavoidable
/// through this API), but that copy is a `memcpy` while the work it replaces is
/// SHA-256 — roughly 1% of the cost, and it is what keeps the *send* free.
///
/// **Flow control.** The worker acks every chunk it consumed; the credit window
/// lives in `isolate_hasher.dart` (platform independent) rather than here. The
/// only ordering guarantee this file relies on is the one the isolate API gives:
/// messages between two isolates arrive in send order, so the digest the worker
/// emits for `_FinishMessage` necessarily covers every chunk sent before it —
/// no "drain the acks first" handshake is needed.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../security/fingerprint.dart';
import 'hash_worker.dart';

/// How long to wait for the worker's first message (its send port) before
/// declaring the spawn failed and falling back to inline hashing.
///
/// A spawn that never answers must not hang a transfer: this bound turns "no
/// worker" into a logged, slow-but-correct path.
const Duration _kHandshakeTimeout = Duration(seconds: 10);

/// The worker's debug name, so it is identifiable in a profiler / DevTools.
const String _kWorkerDebugName = 'lanlink-hash-worker';

/// Spawns the hashing isolate and completes once it is ready to receive chunks.
///
/// Throws (rather than returning a broken backend) when the isolate cannot be
/// created or does not answer within [_kHandshakeTimeout]; `IsolateHasher` turns
/// that into the inline fallback.
Future<HashWorkerBackend> spawnHashWorker() async {
  // One port carries both the handshake (the worker's send port, sent back as
  // the first message) and every later event. It must not be a `.first`
  // subscription: `first` cancels itself after the handshake and the acks and
  // digest that follow would be dropped on the floor — which looked exactly like
  // a worker that hashes nothing and then dies.
  final fromWorker = ReceivePort();
  final errors = ReceivePort();
  final exit = ReceivePort();
  final events = StreamController<HashWorkerEvent>();
  final ready = Completer<SendPort>();
  fromWorker.listen((Object? message) {
    if (message is SendPort) {
      if (!ready.isCompleted) {
        ready.complete(message);
      }
      return;
    }
    if (message is HashWorkerEvent && !events.isClosed) {
      events.add(message);
    }
  });
  Isolate? isolate;
  try {
    isolate = await Isolate.spawn<SendPort>(
      _hashWorkerMain,
      fromWorker.sendPort,
      debugName: _kWorkerDebugName,
      onError: errors.sendPort,
      onExit: exit.sendPort,
      errorsAreFatal: true,
    );
    final SendPort worker = await ready.future.timeout(_kHandshakeTimeout);
    return _IsolateHashWorker(
      isolate: isolate,
      worker: worker,
      fromWorker: fromWorker,
      errors: errors,
      exit: exit,
      events: events,
    );
  } catch (error) {
    isolate?.kill(priority: Isolate.immediate);
    fromWorker.close();
    errors.close();
    exit.close();
    unawaited(events.close());
    rethrow;
  }
}

/// Worker-side entry point. Runs in the spawned isolate for its whole life.
///
/// [replyTo] is the parent's port; the first thing sent back is this isolate's
/// own inbox port, which is the handshake the parent waits for.
void _hashWorkerMain(SendPort replyTo) {
  final inbox = ReceivePort();
  replyTo.send(inbox.sendPort);

  // The worker uses the very same accumulator as the sender and the inline
  // fallback, so the digest format (uppercase hex via `bytesToHex`) and the
  // algorithm can never drift between the three paths.
  final Sha256Accumulator accumulator = Sha256Accumulator();
  var closed = false;

  inbox.listen((Object? message) {
    if (closed) {
      return;
    }
    try {
      if (message is _ChunkMessage) {
        final Uint8List bytes = message.data.materialize().asUint8List();
        accumulator.add(bytes);
        replyTo.send(HashWorkerAck(bytes.length));
      } else if (message is _FinishMessage) {
        closed = true;
        replyTo.send(HashWorkerDigest(accumulator.finish()));
        inbox.close();
      }
    } catch (error) {
      // A throwing worker must not vanish silently: report it once and stop, so
      // the parent can fall back instead of waiting for a digest forever.
      closed = true;
      replyTo.send(HashWorkerFailure('worker failed: $error'));
      inbox.close();
    }
  });
}

/// One chunk on its way to the worker, already consolidated into a transferable.
final class _ChunkMessage {
  const _ChunkMessage(this.data);

  /// Single-use transferable buffer holding exactly one received chunk.
  final TransferableTypedData data;
}

/// "No more chunks — close the hash and send the digest."
final class _FinishMessage {
  const _FinishMessage();
}

/// The parent side of a live worker isolate.
final class _IsolateHashWorker implements HashWorkerBackend {
  _IsolateHashWorker({
    required Isolate isolate,
    required SendPort worker,
    required ReceivePort fromWorker,
    required ReceivePort errors,
    required ReceivePort exit,
    required StreamController<HashWorkerEvent> events,
  })  : _isolate = isolate,
        _worker = worker,
        _fromWorker = fromWorker,
        _errors = errors,
        _exit = exit,
        _events = events {
    // Uncaught errors in the worker arrive here as `[error, stackTrace]`.
    _errors.listen((Object? message) {
      if (_events.isClosed) {
        return;
      }
      _events.add(
        HashWorkerFailure('worker error: ${_describe(message)}'),
      );
    });
    // A worker that exits before delivering a digest leaves the parent waiting
    // for something that will never arrive; surface it as a failure instead.
    _exit.listen((Object? message) {
      if (_events.isClosed) {
        return;
      }
      _events.add(
        HashWorkerFailure('worker exited before sending a digest'),
      );
    });
  }

  final Isolate _isolate;
  final SendPort _worker;
  final ReceivePort _fromWorker;
  final ReceivePort _errors;
  final ReceivePort _exit;
  final StreamController<HashWorkerEvent> _events;
  bool _closed = false;

  @override
  Stream<HashWorkerEvent> get events => _events.stream;

  @override
  void addChunk(Uint8List chunk) {
    if (_closed) {
      return;
    }
    // One transferable per chunk: single-use by definition (`materialize` may
    // only be called once), and released by the worker as soon as it hashes it.
    _worker.send(
      _ChunkMessage(TransferableTypedData.fromList(<Uint8List>[chunk])),
    );
  }

  @override
  void finish() {
    if (_closed) {
      return;
    }
    _worker.send(const _FinishMessage());
  }

  @override
  Future<void> dispose() async {
    if (_closed) {
      return;
    }
    _closed = true;
    // Closing the controller *before* the kill keeps the kill's own `onExit`
    // message from surfacing as a failure after a clean finish.
    unawaited(_events.close());
    _fromWorker.close();
    _errors.close();
    _exit.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  static String _describe(Object? message) {
    if (message is List && message.isNotEmpty) {
      return '${message.first}';
    }
    return '$message';
  }
}
