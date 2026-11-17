import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// Unit tests for fingerprint normalisation, comparison and hashing.
void main() {
  group('normalizeFingerprint', () {
    test('upper-cases the digest', () {
      expect(normalizeFingerprint('abcd'), 'ABCD');
      expect(normalizeFingerprint('AbCdEf'), 'ABCDEF');
    });

    test('ignores surrounding whitespace', () {
      expect(normalizeFingerprint('  abcd  '), 'ABCD');
      expect(normalizeFingerprint('abcd '), 'ABCD');
      expect(normalizeFingerprint(' abcd'), 'ABCD');
    });

    test('collapses separators (spec §4 requirement 1)', () {
      // `AA:BB`, `aabb` and `aabb ` must describe the same device.
      final canonical = normalizeFingerprint('aabb');
      expect(normalizeFingerprint('AA:BB'), canonical);
      expect(normalizeFingerprint('aabb '), canonical);
      expect(normalizeFingerprint('AA:BB'), 'AABB');
    });
  });

  group('fingerprintsEqual', () {
    test('ignores case and surrounding whitespace', () {
      expect(fingerprintsEqual(' abcd ', 'ABCD'), isTrue);
      expect(fingerprintsEqual('ABCD', 'ABCE'), isFalse);
    });

    test('treats same device written differently as equal', () {
      expect(fingerprintsEqual('AA:BB', 'aabb'), isTrue);
    });

    test('empty fingerprints never match', () {
      expect(fingerprintsEqual('', ''), isFalse);
      expect(fingerprintsEqual('  ', 'ABC'), isFalse);
      expect(fingerprintsEqual('ABC', ''), isFalse);
      expect(fingerprintsEqual('', '   '), isFalse);
    });

    test('a non-empty fingerprint never equals an empty one', () {
      expect(fingerprintsEqual('00', ''), isFalse);
      expect(fingerprintsEqual('', '00'), isFalse);
    });
  });

  group('sha256HexOfBytes', () {
    test('returns uppercase hex of length 64', () {
      final hex = sha256HexOfBytes([1, 2, 3]);
      expect(hex.length, 64);
      expect(hex, hex.toUpperCase());
      // Known vector: SHA-256(0x010203), cross-checked with openssl.
      expect(
        hex,
        '039058C6F2C0CB492C533B0A4D14EF77CC0F78ABCCCED5287D84A1A2011CFB81',
      );
    });
  });
}
