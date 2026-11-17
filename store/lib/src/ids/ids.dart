/// Local id generators used by the data layer (spec §9.4).
///
/// Ids are **injected**, never read from a hidden clock or a global RNG inside
/// the store: the DAO/facade methods that mint a row take the generated string
/// from the caller, which keeps every write deterministic under test. These
/// generators are the two production implementations:
///
/// * [RandomIdGenerator] — collision-resistant hex ids for rows whose identity
///   is "this particular local object" (`conversations.id`, `files.id`,
///   `transfers.id`, a text message's `event_nonce`).
/// * [SequentialIdGenerator] — a monotonic counter, useful for tests and for
///   anything that only needs to be unique within one run.
library;

import 'dart:math';
import 'dart:typed_data';

/// A source of fresh, unique string ids.
abstract class IdGenerator {
  /// Returns a new id that has not been handed out before.
  String newId();
}

/// Generates ids as the lowercase hex of [byteLength] random bytes.
///
/// The default of 16 bytes (128 bits) matches the "random 16-byte hex" text
/// `event_nonce` of spec §5.6.2. A [Random] may be supplied for deterministic
/// tests; otherwise a cryptographically secure source is used.
class RandomIdGenerator implements IdGenerator {
  /// Creates a generator producing [byteLength]-byte (hex) ids.
  RandomIdGenerator({this.byteLength = 16, Random? random})
      : _random = random ?? Random.secure();

  /// Number of random bytes drawn per id (the hex string is twice as long).
  final int byteLength;

  final Random _random;

  @override
  String newId() {
    final bytes = Uint8List(byteLength);
    for (var index = 0; index < byteLength; index += 1) {
      bytes[index] = _random.nextInt(256);
    }
    return _toLowerHex(bytes);
  }
}

/// Generates ids as `"<prefix>-<n>"` with `n` increasing from zero.
///
/// Not random and therefore unsuitable as a durable primary key in production;
/// it exists for deterministic tests and short-lived scratch objects.
class SequentialIdGenerator implements IdGenerator {
  /// Creates a generator whose ids are prefixed with [prefix].
  SequentialIdGenerator({this.prefix = 'id'});

  /// The literal text placed before the counter.
  final String prefix;

  int _counter = 0;

  @override
  String newId() {
    final value = _counter;
    _counter += 1;
    return '$prefix-$value';
  }
}

/// Lowercase hex encoding of [bytes] (the ids of this package are lowercase).
String _toLowerHex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write((byte & 0xff).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
