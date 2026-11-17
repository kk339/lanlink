/// Pure id minting for the app (spec §3.2 / §9.4).
///
/// The `fileId` contract: **mint once per send, persist, reuse on every retry**
/// (M3 §5.6) — otherwise the idempotent message id changes.
///
/// Pure Dart (`dart:math` only) so it compiles on Web.
library;

import 'dart:math';

/// A source of fresh, unique string ids.
abstract interface class IdFactory {
  /// Returns a new id that has not been handed out before.
  String newId();
}

/// Production [IdFactory]: lowercase hex of [hexChars] random hex digits.
class RandomIdFactory implements IdFactory {
  /// Creates a factory producing [hexChars]-character ids.
  RandomIdFactory({this.hexChars = 16}) : assert(hexChars > 0);

  /// Number of hex characters per id (default 16 = 64 bits).
  final int hexChars;

  static final Random _random = Random.secure();

  @override
  String newId() {
    final buffer = StringBuffer();
    for (var index = 0; index < hexChars; index++) {
      buffer.write(_random.nextInt(16).toRadixString(16));
    }
    return buffer.toString();
  }
}

/// Deterministic [IdFactory] for tests: `"<prefix>-<n>"`, n increasing from 0.
class FixedIdFactory implements IdFactory {
  /// Creates a factory whose ids are prefixed with [prefix].
  FixedIdFactory([this.prefix = 'id']);

  /// The literal text placed before the counter.
  final String prefix;

  int _n = 0;

  @override
  String newId() => '$prefix-${_n++}';
}
