import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// Unit tests for the [DeviceInfo] wire model and the shared frame header.
void main() {
  group('DeviceInfo JSON', () {
    test('round-trips through JSON without losing fields', () {
      const info = DeviceInfo(
        alias: 'NodeB',
        fingerprint: 'AABB',
        port: 49494,
        deviceModel: 'Windows 11',
        deviceType: DeviceType.desktop,
        download: true,
      );

      final restored = DeviceInfo.fromJson(info.toJson());

      expect(restored.alias, 'NodeB');
      expect(restored.fingerprint, 'AABB');
      expect(restored.port, 49494);
      expect(restored.deviceModel, 'Windows 11');
      expect(restored.deviceType, DeviceType.desktop);
      expect(restored.download, isTrue);
    });

    test('serialises to the new wire keys name/kind/model/fp/port/accepts', () {
      const info = DeviceInfo(
        alias: 'A',
        fingerprint: 'FF',
        port: 1,
        deviceModel: 'M',
        download: true,
      );

      final json = info.toJson();

      expect(json['name'], 'A');
      expect(json['kind'], 'desktop');
      expect(json['model'], 'M');
      expect(json['fp'], 'FF');
      expect(json['port'], 1);
      expect(json['accepts'], isTrue);
    });

    test('no longer serialises version/protocol/announce', () {
      const info =
          DeviceInfo(alias: 'A', fingerprint: 'FF', port: 1, announce: true);
      final json = info.toJson();

      expect(json.containsKey('version'), isFalse);
      expect(json.containsKey('protocol'), isFalse);
      expect(json.containsKey('announce'), isFalse);
    });

    test('tolerates missing fields by falling back to defaults', () {
      final info = DeviceInfo.fromJson(<String, dynamic>{'name': 'X'});

      expect(info.alias, 'X');
      expect(info.port, kDefaultPort);
      expect(info.protocol, ProtocolScheme.https);
      expect(info.deviceType, DeviceType.desktop);
      expect(info.fingerprint, isEmpty);
      expect(info.deviceModel, isNull);
      expect(info.download, isFalse);
      expect(info.announce, isFalse);
    });

    test('an unknown kind falls back to desktop', () {
      final info = DeviceInfo.fromJson(<String, dynamic>{'kind': 'toaster'});
      expect(info.deviceType, DeviceType.desktop);
    });

    test('model is omitted from JSON when null', () {
      const info = DeviceInfo(alias: 'A', fingerprint: 'FF', port: 1);
      expect(info.toJson().containsKey('model'), isFalse);
    });

    test('copyWith replaces only the given fields', () {
      const info = DeviceInfo(alias: 'A', fingerprint: 'FF', port: 1);
      final updated = info.copyWith(alias: 'B', announce: true);
      expect(updated.alias, 'B');
      expect(updated.announce, isTrue);
      expect(updated.fingerprint, 'FF');
      expect(updated.port, 1);
    });
  });

  group('DeviceType', () {
    test('parses known wire values', () {
      expect(DeviceType.parse('mobile'), DeviceType.mobile);
      expect(DeviceType.parse('server'), DeviceType.server);
    });

    test('unknown and non-string values fall back to desktop', () {
      expect(DeviceType.parse('??'), DeviceType.desktop);
      expect(DeviceType.parse(null), DeviceType.desktop);
      expect(DeviceType.parse(7), DeviceType.desktop);
    });
  });

  group('ProtocolScheme', () {
    test('parses http and defaults everything else to https', () {
      expect(ProtocolScheme.parse('http'), ProtocolScheme.http);
      expect(ProtocolScheme.parse('https'), ProtocolScheme.https);
      expect(ProtocolScheme.parse(null), ProtocolScheme.https);
      expect(ProtocolScheme.parse('quic'), ProtocolScheme.https);
    });
  });

  group('frame header (v/t)', () {
    const peer = DeviceInfo(alias: 'A', fingerprint: 'FF', port: 1);

    test('accepts a well-formed frame of the expected type', () {
      final frame = encodeFrame(kFrameHello, <String, dynamic>{
        'peer': peer.toJson(),
      });

      expect(requireFrameType(frame), kFrameHello);
      expect(() => requireFrameTypeIs(frame, kFrameHello), returnsNormally);
    });

    test('rejects a missing or wrong version', () {
      expect(
        () => requireFrameType(<String, dynamic>{'t': 'hello'}),
        throwsFormatException,
      );
      expect(
        () => requireFrameType(<String, dynamic>{'v': 2, 't': 'hello'}),
        throwsFormatException,
      );
    });

    test('rejects a missing or empty type', () {
      expect(
        () => requireFrameType(<String, dynamic>{'v': 1}),
        throwsFormatException,
      );
      expect(
        () => requireFrameType(<String, dynamic>{'v': 1, 't': ''}),
        throwsFormatException,
      );
    });

    test('rejects an unexpected frame type', () {
      expect(
        () => requireFrameTypeIs(
            <String, dynamic>{'v': 1, 't': 'bogus'}, kFrameHello),
        throwsFormatException,
      );
    });

    test('an unknown type is still a well-formed header (caller rejects)', () {
      expect(
        requireFrameType(<String, dynamic>{'v': 1, 't': 'future.thing'}),
        'future.thing',
      );
    });
  });
}
