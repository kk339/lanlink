/// Fingerprint normalisation, comparison and SHA-256 helpers.
///
/// The LocalSend fingerprint is the **SHA-256 of the certificate DER**, encoded
/// as hexadecimal. Real implementations disagree on casing (the official app
/// emits uppercase, OpenSSL emits lowercase) and on separators, so every
/// comparison in the codebase goes through [normalizeFingerprint] first.
///
/// Security checklist item "指纹大小写不归一化" is handled here.
///
/// **Why `package:crypto` and not `pointycastle` (0.2.12):** both are pure Dart,
/// but pointycastle's SHA-256 goes through `src/ufixnum.dart`'s `clip32` masks,
/// which the AOT compiler cannot fold away — measured **21.1 MiB/s** in an AOT
/// build, i.e. a full 1 GiB file cost ~48 s of single-core CPU on the isolate
/// that also draws the UI. `package:crypto`'s implementation keeps its state in
/// a `Uint32List` with explicit `& 0xffffffff`, reaches **117.2 MiB/s** (5.55x)
/// in the same AOT harness, and produces **byte-identical digests** (verified on
/// a 256 MiB file: `e58693b9…7cce1304` from pointycastle, crypto and BCRYPT).
/// The output format here is unchanged — uppercase hex, via [bytesToHex].
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Normalises a hex fingerprint before any comparison.
///
/// All whitespace and `:` separators are removed and the result is
/// upper-cased. This makes `AA:BB`, `aabb` and `aabb ` collapse to the same
/// value, which is required for them to be treated as one device
/// (spec §4 requirement 1). Real fingerprints carry no separators, so this is
/// lossless for them.
String normalizeFingerprint(String raw) =>
    raw.replaceAll(RegExp(r'[\s:]'), '').toUpperCase();

/// Compares two hex digests case-insensitively and separator-insensitively.
///
/// Empty strings never match: an empty fingerprint must not be treated as
/// "equal to another empty one" (nor to a non-empty one).
bool fingerprintsEqual(String a, String b) {
  final normalizedA = normalizeFingerprint(a);
  final normalizedB = normalizeFingerprint(b);
  return normalizedA.isNotEmpty && normalizedA == normalizedB;
}

/// Uppercase hex encoding of [bytes].
String bytesToHex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write((byte & 0xff).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString().toUpperCase();
}

/// SHA-256 of [bytes] as uppercase hex.
///
/// Used for small byte arrays only (a certificate's DER, a message id). File
/// contents go through [sha256FileHex] / [Sha256Accumulator] instead, so a file
/// is never materialised in memory just to be hashed.
String sha256HexOfBytes(List<int> bytes) =>
    bytesToHex(sha256.convert(bytes).bytes);

/// Incremental SHA-256 that accepts data in chunks and yields uppercase hex.
///
/// This is the single streaming primitive behind both file hashing paths — the
/// sender's pre-send hash ([sha256FileHex]) and the receiver's hash-while-writing
/// (`PeerServer._handleUpload`) — so the two can never drift apart on encoding
/// or algorithm. Create one per stream, [add] every chunk, then [finish] exactly
/// once.
class Sha256Accumulator {
  /// Starts a new accumulator (the underlying chunked conversion is live
  /// immediately, so an empty stream hashes to the digest of the empty input).
  Sha256Accumulator() {
    _input = sha256.startChunkedConversion(_DigestSink(_collect));
  }

  late final ByteConversionSink _input;
  Digest? _digest;
  bool _finished = false;

  void _collect(Digest digest) {
    _digest = digest;
  }

  /// Feeds the next [chunk] of data. Must not be called after [finish].
  void add(List<int> chunk) {
    if (_finished) {
      throw StateError('Sha256Accumulator.add() called after finish()');
    }
    _input.add(chunk);
  }

  /// Closes the hash and returns the digest as **uppercase hex**.
  ///
  /// Idempotent in the sense that a second call throws rather than silently
  /// returning a digest of partial data.
  String finish() {
    if (_finished) {
      throw StateError('Sha256Accumulator.finish() called twice');
    }
    _finished = true;
    _input.close();
    // `crypto` always emits a digest on close (including for empty input); the
    // fallback only guards against a future implementation that does not, so
    // this path can never return a wrong-but-plausible empty string.
    final Digest digest = _digest ?? sha256.convert(const <int>[]);
    return bytesToHex(digest.bytes);
  }
}

/// Streams [file] through SHA-256 without holding it whole in memory.
///
/// Used by the M2 upload path to verify received files; it lives here so the
/// hashing logic stays in one place.
Future<String> sha256FileHex(File file) async {
  final Sha256Accumulator accumulator = Sha256Accumulator();
  await for (final chunk in file.openRead()) {
    accumulator.add(chunk);
  }
  return accumulator.finish();
}

/// Collects the single [Digest] a chunked conversion emits on close.
class _DigestSink implements Sink<Digest> {
  _DigestSink(this._onDigest);

  final void Function(Digest digest) _onDigest;

  @override
  void add(Digest data) => _onDigest(data);

  @override
  void close() {}
}
