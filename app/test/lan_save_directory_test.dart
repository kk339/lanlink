/// Tests for the **real** adapter's 保存位置 switch (0.2.23).
///
/// **The defect these pin down.** `LanTransferService` read the save directory
/// once in its constructor and kept it in a `final` field, and
/// `SettingsController.setSaveDirectory` only persisted the value. So the
/// settings page showed the new path while the running receiver kept writing to
/// the old one — for the rest of the session. "改完要重启才生效" is a silent
/// failure: nothing on screen says a restart is needed.
///
/// Two properties, both on the real `LanTransferService` (not a fake):
///
/// 1. a usable directory is adopted **immediately** — no restart;
/// 2. an unusable one is **refused**, the previous directory stays in force, and
///    the caller gets a typed exception it can turn into a visible error.
///
/// The receiver really binds a TCP port here, which is the point: the rebuild
/// (not just a field write) is what makes the change take effect, and only the
/// real adapter exercises it.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/data/real/lan_transfer_service.dart';
import 'package:lanlink_app/domain/clock.dart';
import 'package:lanlink_app/domain/transfer_service.dart';
import 'package:lanlink_core/lanlink_core.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory first;
  late Directory second;
  late LanTransferService service;
  late List<String> logs;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lanlink_savedir_test_');
    first = Directory(p.join(root.path, 'first'));
    second = Directory(p.join(root.path, 'second'));
    await first.create(recursive: true);
    logs = <String>[];

    final DeviceCertificate certificate = await DeviceCertificate.loadOrCreate(
      directory: Directory(p.join(root.path, 'certs')),
      commonName: 'lanlink',
    );
    service = LanTransferService(
      certificate: certificate,
      clock: const SystemClock(),
      alias: 'Test Device',
      // Port 0 = let the OS pick: the test must never fight a real lanlink
      // instance for the fixed 53317.
      tcpPort: 0,
      saveDirectory: first.path,
      acceptUploads: true,
      onLog: logs.add,
    );
  });

  tearDown(() async {
    await service.dispose();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('a new directory is in force immediately — the receiver is rebuilt',
      () async {
    await service.startReceiver();
    expect(service.saveDirectory, first.path);

    await service.setSaveDirectory(second.path);

    // The value the receiver was **rebuilt with**, i.e. where the next accepted
    // file lands. Before 0.2.23 this stayed `first.path` for the whole session.
    expect(service.saveDirectory, second.path);
    // The rebuild kept the receiver up: peers can still dial us.
    expect(service.localPort, isNotNull);
    expect(service.accepting, isTrue);
    // And the directory was created if it did not exist.
    expect(await second.exists(), isTrue);
  });

  test('a directory that cannot be used is refused and the old one stays',
      () async {
    await service.startReceiver();

    // Deterministic, portable "unusable": a *file* stands where the directory
    // would have to be, so creating it must fail (no permissions games, no
    // dependence on running as a normal user).
    final File blocker = File(p.join(root.path, 'blocker'));
    await blocker.writeAsString('not a directory');

    await expectLater(
      service.setSaveDirectory(p.join(blocker.path, 'received')),
      throwsA(isA<SaveDirectoryException>()),
    );

    expect(service.saveDirectory, first.path,
        reason: 'a refused change must never be adopted — the setting and the '
            'running receiver have to keep agreeing');
    expect(service.localPort, isNotNull, reason: 'the old receiver is still up');
    // The user-visible half: the refusal is in the log, not swallowed.
    expect(logs.any((String line) => line.contains('SAVE 保存位置不可用')), isTrue);
  });

  test('an empty directory is refused rather than silently ignored', () async {
    await service.startReceiver();

    await expectLater(
      service.setSaveDirectory('   '),
      throwsA(isA<SaveDirectoryException>()),
    );
    expect(service.saveDirectory, first.path);
  });

  test('setting the same directory again is a no-op (no needless rebuild)',
      () async {
    await service.startReceiver();
    final int? port = service.localPort;

    await service.setSaveDirectory(first.path);

    expect(service.localPort, port);
    expect(service.saveDirectory, first.path);
  });
}
