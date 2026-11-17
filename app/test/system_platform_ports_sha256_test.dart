/// Exercises the **real** `SystemPlatformPorts.sha256Hex` — the one path in the
/// app that spawns a worker isolate.
///
/// Every other app test goes through `FakePlatformPorts`, so the real port (and
/// therefore `Isolate.run`) has **no coverage**: a closure-context mistake there
/// compiles, passes all 321 tests, and only blows up on a user's machine with
/// `Illegal argument in isolate message: object is unsendable`. This file closes
/// that hole with two calls on real temporary files.
///
/// Native-only by nature (`dart:io`), like the port itself.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/data/real/system_platform_ports.dart';
import 'package:lanlink_core/lanlink_core.dart' show sha256FileHex;

/// A port over a throwaway settings path — the constructor touches nothing.
SystemPlatformPorts _ports(Directory dir) => SystemPlatformPorts(
      settingsPath: '${dir.path}/settings.json',
      defaultAlias: 'test-device',
      defaultSaveDirectory: dir.path,
    );

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('lanlink_ports_sha_');
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  test('sha256Hex hashes a real file on the worker isolate, uppercase hex',
      () async {
    final File file = File('${dir.path}/hello.txt');
    await file.writeAsString('hello');

    final String actual = await _ports(dir).sha256Hex(file.path);

    // Independent oracle: the published SHA-256 of "hello" (also cross-checked
    // with Windows `certutil -hashfile`), so this does not merely agree with our
    // own implementation.
    expect(
      actual,
      '2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824',
    );
    expect(
      actual,
      matches(RegExp(r'^[0-9A-F]{64}$')),
      reason: 'the stored/wire format is uppercase hex, fixed width',
    );
  });

  test('sha256Hex streams across chunk boundaries and matches the core helper',
      () async {
    // 64 KiB + 7 bytes: crosses the read block boundary, so a chunked-conversion
    // bug (final partial block dropped) would show up here.
    final List<int> bytes =
        List<int>.generate(64 * 1024 + 7, (int i) => (i * 31 + 7) & 0xff);
    final File file = File('${dir.path}/payload.bin');
    await file.writeAsBytes(bytes, flush: true);

    final String viaIsolate = await _ports(dir).sha256Hex(file.path);
    final String inProcess = await sha256FileHex(file);

    expect(viaIsolate, inProcess);
    expect(viaIsolate, matches(RegExp(r'^[0-9A-F]{64}$')));
  });
}
