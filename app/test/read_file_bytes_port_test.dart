/// Port-contract tests for `PlatformPorts.readFileBytes` (design §3 / PRD §8-G32).
///
/// Exercises the **real** adapter ([SystemPlatformPorts]) against a temp file,
/// so the contract is proven end-to-end: the whole file normally, and `null` —
/// **never a truncated prefix** — when the file exceeds `maxBytes` or cannot be
/// read at all.
///
/// `dart:io` is deliberate here: a test that hits the real filesystem is exactly
/// the point of a port contract test (the fake adapter is tested separately).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/data/real/system_platform_ports.dart';

void main() {
  late Directory dir;
  late SystemPlatformPorts ports;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lanlink-readbytes-');
    ports = SystemPlatformPorts(
      settingsPath: '${dir.path}${Platform.pathSeparator}settings.json',
      defaultAlias: 'test',
      defaultSaveDirectory: dir.path,
    );
  });

  tearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  String pathOf(String name) => '${dir.path}${Platform.pathSeparator}$name';

  test('returns the whole file when it is within maxBytes', () async {
    final File file = File(pathOf('small.bin'));
    await file.writeAsBytes(<int>[1, 2, 3, 4, 5]);

    final Uint8List? bytes =
        await ports.readFileBytes(file.path, maxBytes: 1024);

    expect(bytes, isNotNull);
    expect(bytes, equals(<int>[1, 2, 3, 4, 5]));
  });

  test('returns null (never a truncated prefix) when the file exceeds maxBytes',
      () async {
    final File file = File(pathOf('big.bin'));
    await file.writeAsBytes(List<int>.filled(2048, 7));

    final Uint8List? bytes =
        await ports.readFileBytes(file.path, maxBytes: 1024);

    // Not a 1024-byte prefix — a truncated JPEG would decode into half an image.
    expect(bytes, isNull);
  });

  test('maxBytes == file length is allowed (the cap is "larger than")',
      () async {
    final File file = File(pathOf('exact.bin'));
    await file.writeAsBytes(List<int>.filled(1024, 9));

    final Uint8List? bytes =
        await ports.readFileBytes(file.path, maxBytes: 1024);

    expect(bytes, isNotNull);
    expect(bytes!.length, 1024);
  });

  test('maxBytes null means "no cap"', () async {
    final File file = File(pathOf('nocap.bin'));
    await file.writeAsBytes(List<int>.filled(4096, 3));

    final Uint8List? bytes = await ports.readFileBytes(file.path);

    expect(bytes, isNotNull);
    expect(bytes!.length, 4096);
  });

  test('returns null for a missing file', () async {
    final Uint8List? bytes =
        await ports.readFileBytes(pathOf('does-not-exist.bin'));

    expect(bytes, isNull);
  });

  test('returns null for an empty path', () async {
    final Uint8List? bytes = await ports.readFileBytes('');

    expect(bytes, isNull);
  });

  test('returns null (does not throw) when the path is not a readable file',
      () async {
    // A directory is not a file: `exists()`/`readAsBytes()` cannot yield bytes,
    // so the port must degrade to `null`, never throw (design §3.5).
    final Uint8List? bytes = await ports.readFileBytes(dir.path);

    expect(bytes, isNull);
  });
}
