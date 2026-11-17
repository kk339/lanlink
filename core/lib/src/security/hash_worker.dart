/// The worker contract behind [IsolateHasher]: a tiny message protocol plus the
/// `HashWorkerBackend` interface, kept free of `dart:isolate` so it can be
/// imported on **every** platform (the Web build has no isolates at all).
///
/// **Why this file exists (0.2.16).** Until 0.2.16 the receiver hashed every
/// chunk inside the same `await for` loop that reads the socket and writes the
/// file (`PeerServer._handleUpload`). Pure-Dart SHA-256 is synchronous, so the
/// receiving isolate could not read the next chunk while it hashed the previous
/// one: measured on the user's phone, the receive direction ran at **8.2 MiB/s**
/// and decayed to 3–5 MiB/s (Wi-Fi 6, 962 MB, ≈118 s) while the *same* link,
/// the same file and the same bytes in the other direction hit **12.8 MiB/s**
/// (75 s) — because the sending side hashed in `Isolate.run` and only the
/// receiving side did not. Moving the hash to a worker isolate puts the hash on
/// another core, so reading and hashing overlap instead of alternating.
///
/// **Split of responsibilities.**
/// * [HashWorkerBackend] is everything platform specific: how bytes reach the
///   worker and how acks/digests come back. Only `hash_worker_isolate.dart`
///   (native) and `hash_worker_stub.dart` (Web) implement it.
/// * `isolate_hasher.dart` owns the platform-independent half: the credit
///   window (backpressure), the inline fallback, and the public API. That half
///   is unit-testable with a fake backend, which is how the credit window is
///   tested without touching a real isolate.
library;

import 'dart:typed_data';

/// How many chunks may be in flight (sent, not yet acked) before `add` blocks.
///
/// The sender streams 64 KiB chunks, so this bounds the extra memory the worker
/// path holds to **1 MiB** — the transferable copies created by
/// `TransferableTypedData.fromList` — no matter how fast the network delivers.
/// Without a window a slow worker would let the queue grow to the size of the
/// file (962 MB in the user's test), which is exactly the "unbounded buffering"
/// failure mode a transfer tool must not have.
const int kDefaultHashWorkerCreditWindow = 16;

/// Spawns a worker backend. Injected so tests can force the fallback path (a
/// factory that throws) or drive a fake backend deterministically.
typedef HashWorkerSpawner = Future<HashWorkerBackend> Function();

/// One event travelling **from** the worker back to the receiving isolate.
sealed class HashWorkerEvent {
  const HashWorkerEvent();
}

/// The worker finished hashing one chunk, so one credit is free again.
///
/// [bytes] is the chunk length the worker actually consumed; the receiving side
/// only asserts it is positive (it is the worker's own count, not a checksum).
final class HashWorkerAck extends HashWorkerEvent {
  const HashWorkerAck(this.bytes);

  /// Number of bytes the worker folded into the digest for that chunk.
  final int bytes;
}

/// The final digest, as **uppercase hex** (`bytesToHex` format, identical to
/// `Sha256Accumulator.finish()` and to the sender's value).
final class HashWorkerDigest extends HashWorkerEvent {
  const HashWorkerDigest(this.hex);

  /// The digest of every byte handed to the worker, uppercase hex.
  final String hex;
}

/// The worker died or reported an error; its digest can no longer be trusted.
final class HashWorkerFailure extends HashWorkerEvent {
  const HashWorkerFailure(this.message);

  /// Human-readable cause, for the receiver's log.
  final String message;
}

/// The platform half of the hashing worker.
///
/// Implementations must deliver events in the order the worker produced them,
/// and must call [dispose] safely from any state.
abstract class HashWorkerBackend {
  /// Events from the worker: one [HashWorkerAck] per [addChunk], then exactly
  /// one [HashWorkerDigest] after [finish] — or a [HashWorkerFailure] instead.
  ///
  /// Single-subscription: the owner listens exactly once, immediately.
  Stream<HashWorkerEvent> get events;

  /// Hands [chunk] to the worker. Must not copy it on the isolate boundary
  /// (the native backend transfers it); must be a no-op after [dispose].
  void addChunk(Uint8List chunk);

  /// Tells the worker that no more chunks follow, so it should emit the digest.
  void finish();

  /// Releases the worker. Idempotent, and safe to call at any point — including
  /// before [finish] (the receiver does that on every early-return path).
  Future<void> dispose();
}
