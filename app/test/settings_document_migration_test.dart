/// 0.2.25 — 「接收模式默认开着就行」 and the one-time migration that makes it true
/// for machines that already ran an older build.
///
/// **The defect these pin down.** Flipping `AppSettings.acceptByDefault` to
/// `true` only reaches a device whose settings JSON does not mention the key.
/// Every device that ever toggled the switch — i.e. every existing user who
/// looked at the feature — has an explicit `"acceptByDefault": false` on disk,
/// and would start up still refusing files while the changelog says the default
/// is now on. "用户以为改好了、其实还是关着" is the one failure mode this project
/// refuses to ship.
///
/// The fix is a document version: v2 is written by 0.2.25, so anything **below**
/// v2 can only hold the *old* default and is migrated exactly once. Everything
/// here runs against the **real** [SystemPlatformPorts] on real temporary files
/// — the fakes never touch `dart:io`, so a migration bug would be invisible to
/// them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/data/real/lan_transfer_service.dart';
import 'package:lanlink_app/data/real/system_platform_ports.dart';
import 'package:lanlink_app/domain/clock.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/platform_ports.dart'
    show SettingsWriteException;
import 'package:lanlink_core/lanlink_core.dart' show DeviceCertificate;
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory saveDirectory;
  late String settingsPath;

  /// A port over the temp settings file — the very constructor the native
  /// bootstrap uses (it touches nothing on construction).
  SystemPlatformPorts ports() => SystemPlatformPorts(
        settingsPath: settingsPath,
        defaultAlias: 'test-device',
        defaultSaveDirectory: saveDirectory.path,
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lanlink_settings_mig_');
    saveDirectory = Directory(p.join(root.path, 'received'));
    settingsPath = p.join(root.path, 'settings.json');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<bool> documentExists() => File(settingsPath).exists();

  /// Writes a settings document verbatim — the only way to reproduce a file
  /// written by an older build.
  Future<void> writeDocument(Map<String, Object?> document) async {
    final File file = File(settingsPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(document), flush: true);
  }

  /// The document as it stands on disk right now.
  Future<Map<String, Object?>> readDocument() async {
    final Object? decoded = jsonDecode(await File(settingsPath).readAsString());
    return decoded! as Map<String, Object?>;
  }

  // ── ① fresh install ─────────────────────────────────────────────────────
  test(
    '① a fresh install boots RECEIVING — no document, real read path, same '
    'wiring line as the bootstrap',
    () async {
      expect(await documentExists(), isFalse,
          reason: 'the test must start from "nothing has ever been stored"');

      final AppSettings settings = await ports().loadSettings();
      expect(settings.acceptByDefault, isTrue);
      // Still no document: reading must not invent state the user never set.
      // The first real save creates it (and stamps the version).
      expect(await documentExists(), isFalse);

      // ★ The end-to-end half. `create_deps_native.dart` builds the receiver
      // with exactly this expression:
      //     LanTransferService(acceptUploads: settings.acceptByDefault, …)
      // so asserting on `settings` alone would leave "does the app actually
      // receive?" untested. The real adapter is constructed here (its
      // constructor binds nothing — the receiver only starts on
      // `startReceiver`) and asked what it would do on launch.
      final Directory certs = Directory(p.join(root.path, 'certs'));
      final DeviceCertificate certificate =
          await DeviceCertificate.loadOrCreate(
        directory: certs,
        commonName: 'lanlink',
      );
      final LanTransferService receiver = LanTransferService(
        certificate: certificate,
        clock: const SystemClock(),
        alias: settings.alias,
        tcpPort: 0,
        saveDirectory: saveDirectory.path,
        acceptUploads: settings.acceptByDefault,
      );
      addTearDown(receiver.dispose);

      expect(receiver.accepting, isTrue,
          reason:
              'a fresh install must be reachable without touching anything');
    },
  );

  // ── ② the old machine ───────────────────────────────────────────────────
  test(
    '② an old document (explicit false, NO settingsVersion) reads as ON and is '
    'rewritten with settingsVersion: 2',
    () async {
      // Exactly what 0.2.24 and earlier wrote.
      await writeDocument(<String, Object?>{
        'alias': '老机器',
        'saveDirectory': saveDirectory.path,
        'acceptByDefault': false,
      });

      final AppSettings settings = await ports().loadSettings();

      expect(settings.acceptByDefault, isTrue,
          reason: 'the stored false is the OLD DEFAULT, not a user choice');
      expect(settings.alias, '老机器', reason: 'the migration must not move data');

      // …and it is migrated on disk, so this is a one-time event.
      final Map<String, Object?> migrated = await readDocument();
      expect(migrated['settingsVersion'], kSettingsDocumentVersion);
      expect(migrated['acceptByDefault'], isTrue);
      expect(migrated['alias'], '老机器');
      expect(migrated['saveDirectory'], saveDirectory.path);
    },
  );

  // ── ③ the user's later "off" wins, for good ─────────────────────────────
  test(
    '③ after the migration the user switches it off — every later launch stays '
    'OFF (the migration is NOT re-applied)',
    () async {
      await writeDocument(<String, Object?>{
        'alias': '老机器',
        'saveDirectory': saveDirectory.path,
        'acceptByDefault': false,
      });

      // Launch #1 after the upgrade: migrated to on.
      expect((await ports().loadSettings()).acceptByDefault, isTrue);

      // The user turns receiving off (this is the path the settings page and the
      // rail both take: `SettingsController.setAccepting` → `saveSettings`).
      final AppSettings stored = await ports().loadSettings();
      await ports().saveSettings(stored.copyWith(acceptByDefault: false));

      // Launch #2 and #3: still off. An implementation that forced the value on
      // every load would answer `true` here — that is exactly the difference
      // this assertion is here to catch.
      expect((await ports().loadSettings()).acceptByDefault, isFalse);
      expect((await ports().loadSettings()).acceptByDefault, isFalse);
      expect((await readDocument())['acceptByDefault'], isFalse);
    },
  );

  // ── ④ a v2 document that says false ─────────────────────────────────────
  test('④ a v2 document saying false is respected verbatim', () async {
    await writeDocument(<String, Object?>{
      'settingsVersion': 2,
      'alias': 'this device',
      'saveDirectory': saveDirectory.path,
      'acceptByDefault': false,
    });

    expect((await ports().loadSettings()).acceptByDefault, isFalse);
    expect((await readDocument())['acceptByDefault'], isFalse,
        reason:
            'a v2 document is current — nothing to migrate, nothing to rewrite');
  });

  // ── ⑤ v2 but the key is missing ─────────────────────────────────────────
  test('⑤ a v2 document that omits the key falls back to ON, not to false',
      () async {
    await writeDocument(<String, Object?>{
      'settingsVersion': 2,
      'alias': 'this device',
      'saveDirectory': saveDirectory.path,
    });

    // A hand-edited / truncated current document must not be able to resurrect
    // the pre-0.2.25 default.
    expect((await ports().loadSettings()).acceptByDefault, isTrue);
  });

  // ── ⑥ a corrupt document ────────────────────────────────────────────────
  test('⑥ a corrupt document still starts the app, receivable', () async {
    final File file = File(settingsPath);
    await file.parent.create(recursive: true);
    await file.writeAsString('{ this is not json', flush: true);

    final AppSettings settings = await ports().loadSettings();
    expect(settings.acceptByDefault, isTrue);
    expect(settings.alias, 'test-device');
    expect(settings.saveDirectory, saveDirectory.path);
  });

  // ── ⑦ a future document ─────────────────────────────────────────────────
  test('⑦ a NEWER document (version 4) is not mistaken for a v1 one', () async {
    // Was `3` until 0.2.54 bumped [kSettingsDocumentVersion] to 3; the number
    // here only has to be **above** it, so it moved to keep testing "a document
    // from a build that does not exist yet".
    await writeDocument(<String, Object?>{
      'settingsVersion': 4,
      'alias': 'from the future',
      'saveDirectory': saveDirectory.path,
      'acceptByDefault': false,
    });

    // `version < kAcceptByDefaultMigrationVersion` (2) is the migration
    // condition, so a newer document keeps its stored value. (Reading it is safe:
    // the fields it uses are unchanged.)
    expect((await ports().loadSettings()).acceptByDefault, isFalse);
  });

  test('⑦b a hand-edited `2.0` (a JSON double) is still version 2', () async {
    // `2.0` decodes as a `double`, and a naive `is int` check would read it as
    // version 0 → migrate → overrule the stored `false`. The version is parsed
    // as a `num` for exactly this reason.
    await writeDocument(<String, Object?>{
      'settingsVersion': 2.0,
      'alias': 'this device',
      'saveDirectory': saveDirectory.path,
      'acceptByDefault': false,
    });

    expect((await ports().loadSettings()).acceptByDefault, isFalse);
  });

  // ── ⑨ the chosen save folder survives unrelated writes (0.2.29) ─────────
  //
  // **The defect this pins down is a silent one.** `receivedSubdirectory` is a
  // field on `AppSettings`, and `_writeDocument` serialises the model — so a
  // release that adds the field to the model but forgets the writer does not
  // fail, log, or warn. It does this: the user picks 下载/素材, later renames the
  // device (or flips the receive switch), the document is rewritten **without**
  // the key, and the next launch quietly returns to 下载/lanlink. The choice
  // evaporates days later, attached to an action that has nothing to do with it.
  // Exactly the same shape as 0.2.23's save directory that only took effect
  // after a restart, and it can only be caught here — against the **real** port
  // and a real file, because the fakes write nothing.
  group('⑨ the chosen folder is sticky', () {
    test('it is written, read back, and a fresh port sees it', () async {
      final AppSettings base = await ports().loadSettings();
      await ports().saveSettings(base.copyWith(receivedSubdirectory: '素材'));

      expect((await readDocument())['receivedSubdirectory'], '素材');
      expect((await ports().loadSettings()).receivedSubdirectory, '素材');
    });

    test('★ renaming the device keeps it (the writer must carry the field)',
        () async {
      await ports().saveSettings(
        (await ports().loadSettings()).copyWith(receivedSubdirectory: '素材'),
      );
      // What SettingsController.applyAlias does: `copyWith(alias: …)` on the
      // **loaded** settings and one save. If `_writeDocument` dropped the field,
      // the document loses it right here.
      await ports().saveSettings(
        (await ports().loadSettings()).copyWith(alias: '客厅的电脑'),
      );

      final Map<String, Object?> document = await readDocument();
      expect(document['alias'], '客厅的电脑');
      expect(document['receivedSubdirectory'], '素材',
          reason: 'a rename must not clear where files are saved');
      expect((await ports().loadSettings()).receivedSubdirectory, '素材');
    });

    test('★ toggling the receive switch keeps it too', () async {
      await ports().saveSettings(
        (await ports().loadSettings()).copyWith(receivedSubdirectory: '素材'),
      );
      await ports().saveSettings(
        (await ports().loadSettings()).copyWith(acceptByDefault: false),
      );

      expect((await readDocument())['receivedSubdirectory'], '素材');
      expect((await ports().loadSettings()).receivedSubdirectory, '素材');
    });

    test('a document written by 0.2.28 (no such key) reads as the default',
        () async {
      // The upgrade path: every existing install has a document without the key.
      await writeDocument(<String, Object?>{
        'settingsVersion': 2,
        'alias': 'this device',
        'saveDirectory': saveDirectory.path,
        'acceptByDefault': true,
      });

      expect((await ports().loadSettings()).receivedSubdirectory, 'lanlink');
    });

    test('blank / malformed values all normalise to the default', () async {
      // Everything that cannot name a folder **inside** Download. A value that
      // names something (even after dropping `..`) is kept but can never climb
      // out — see the traversal case below.
      for (final Object? raw in <Object?>[null, '', '   ', '/', '..', '.', '///']) {
        await writeDocument(<String, Object?>{
          'settingsVersion': 2,
          'alias': 'this device',
          'saveDirectory': saveDirectory.path,
          'acceptByDefault': true,
          'receivedSubdirectory': raw,
        });
        expect(
          (await ports().loadSettings()).receivedSubdirectory,
          'lanlink',
          reason: 'stored value $raw must mean "never chosen"',
        );
      }
    });

    test('a traversal-shaped value cannot climb out of Download', () async {
      await writeDocument(<String, Object?>{
        'settingsVersion': 2,
        'alias': 'this device',
        'saveDirectory': saveDirectory.path,
        'acceptByDefault': true,
        'receivedSubdirectory': '../../Documents/x',
      });
      final String stored =
          (await ports().loadSettings()).receivedSubdirectory;
      expect(stored, isNot(contains('..')));
      expect(stored, isNot(startsWith('/')));
      expect(stored, isNot(contains('\\')));
      // `Documents` survives as a *name under Download*, which is harmless; the
      // point is that the `..` segments are gone.
      expect(stored, 'Documents/x');
    });

    test('a blank in the model is written as the default, never as ""',
        () async {
      await ports().saveSettings(
        (await ports().loadSettings()).copyWith(receivedSubdirectory: '  '),
      );
      expect((await readDocument())['receivedSubdirectory'], 'lanlink');
    });

    test('the live value (the one the publisher reads) follows a successful '
        'save and is untouched by a failed one', () async {
      final SystemPlatformPorts port = ports();
      expect(port.receivedSubdirectory, 'lanlink',
          reason: 'a port that has not loaded yet must not report a blank folder');

      await port.saveSettings(
        (await port.loadSettings()).copyWith(receivedSubdirectory: '素材'),
      );
      expect(port.receivedSubdirectory, '素材',
          reason: 'the publish step reads this field, so it has to move with the '
              'save — otherwise the next file lands in the old folder');

      // A **failed** write must leave it where it was: `saveSettings` updates the
      // cache only after the document is on disk, so a failure cannot make the
      // running app write somewhere the next launch does not know about.
      final String blockedPath = p.join(root.path, 'blocked-by-a-directory');
      await Directory(blockedPath).create(recursive: true);
      final SystemPlatformPorts blocked = SystemPlatformPorts(
        settingsPath: blockedPath,
        defaultAlias: 'test-device',
        defaultSaveDirectory: saveDirectory.path,
      );
      await expectLater(
        blocked.saveSettings(
          AppSettings(
            alias: 'test-device',
            saveDirectory: saveDirectory.path,
            receivedSubdirectory: '素材',
          ),
        ),
        throwsA(isA<SettingsWriteException>()),
      );
      expect(blocked.receivedSubdirectory, 'lanlink',
          reason: 'a save that failed must not move the live folder');
    });
  });

  // ── ⑧ the fakes agree with production ───────────────────────────────────
  //
  // The suite is driven by `FakeBackend`. If the fake kept booting "off" while
  // production boots "on", every widget test would keep passing against a state
  // a real install can no longer be in — the green would be about the fake.
  group('⑧ fake parity', () {
    test('a bare FakeBackend boots receivable, like production', () {
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);
      expect(backend.transfer.accepting, isTrue);
      expect(backend.platform.presetSettings.acceptByDefault, isTrue);
    });

    test('a backend whose settings say false boots with the receiver off', () {
      // The "returning user who switched it off" state, expressible without
      // reaching around the wiring.
      final FakeBackend backend = FakeBackend(
        settings: const AppSettings(
          alias: '老机器',
          saveDirectory: '/save',
          acceptByDefault: false,
        ),
      );
      addTearDown(backend.dispose);
      expect(backend.transfer.accepting, isFalse);
    });
  });
}
