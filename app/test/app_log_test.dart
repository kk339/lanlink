import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/data/real/app_log.dart';

/// The log writes to **every** destination it can open, and a destination it
/// cannot open must never throw into start-up or cost us the other copies.
///
/// The second copy exists because the private Android directory is unreachable
/// by the user: without the external one they cannot send us the log at all.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('applog_test_');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  String path(String name) => '${root.path}/$name';

  test('writes the same line to every destination that opened', () async {
    final String first = path('private.log');
    final String second = path('external.log');
    final AppLog log = await AppLog.openMany(<String>[first, second]);
    expect(log.openedPaths, <String>[first, second]);

    log.log('both copies');
    await log.close();

    expect(await File(first).readAsString(), contains('both copies'));
    expect(await File(second).readAsString(), contains('both copies'));
  });

  test(
      'an unwritable destination is skipped without throwing, and the '
      'guaranteed copy still works', () async {
    final String good = path('good.log');
    // A *file* used as a directory: opening a file under it cannot succeed.
    final String bad = '$good/inside.log';

    // Must return normally — a bad second destination may never stop start-up.
    final AppLog log = await AppLog.openMany(<String>[good, bad]);
    log.log('still logged');
    await log.close();

    expect(await File(good).readAsString(), contains('still logged'));
    // The primary keeps working no matter what the second one did.
    expect(log.openedPaths, contains(good));
  });

  test('a single destination keeps the original open() behaviour', () async {
    final String only = path('only.log');
    final AppLog log = await AppLog.open(only);
    expect(log.openedPaths, <String>[only]);
    log.log('single');
    await log.close();
    expect(await File(only).readAsString(), contains('single'));
  });

  test('50 rapid log() calls neither throw nor lose a line', () async {
    // The regression that shipped: `log()` did `writeln` + an un-awaited
    // `flush()`, and `flush()` binds the sink to a stream — so a second line
    // arriving while the first flush was still in flight threw
    // `Bad state: StreamSink is bound to a stream`. Startup logs many lines in
    // a row (one per interface candidate), which is why it only surfaced then.
    final String only = path('rapid.log');
    final AppLog log = await AppLog.open(only);

    for (int i = 0; i < 50; i++) {
      log.log('line $i'); // deliberately NOT awaited
    }
    await log.close();

    final String written = await File(only).readAsString();
    for (int i = 0; i < 50; i++) {
      expect(written, contains('line $i'), reason: 'line $i must be present');
    }
  });
}
