/// Unit tests for [SettingsController] (spec §4.4 / §4.6 / §8.5, M4 T03).
///
/// Driven entirely by [FakeBackend]. Covers the three V1 settings and their
/// persistence, the cross-port alias change of §4.6, and the "a write failure is
/// surfaced, never swallowed" rule of §8.5 (`SettingsWriteException`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/settings_controller.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/peer_discovery.dart';

import 'support/fakes.dart';

void main() {
  late FakeBackend backend;
  late SettingsController controller;

  setUp(() {
    // `acceptByDefault: false` is stated **explicitly** (0.2.25). It used to be
    // implied by the model default; since the default is now on, leaving it out
    // would silently change what this whole file is about. The state exercised
    // below is "a user who already switched receiving off", which is still a
    // reachable state — and the interesting one for a toggle — so it is written
    // down rather than inherited.
    backend = FakeBackend(
      settings: const AppSettings(
        alias: '老名字',
        saveDirectory: '/save',
        acceptByDefault: false,
      ),
    );
    controller = SettingsController(
      platform: backend.platform,
      discovery: backend.discovery,
      transfer: backend.transfer,
    );
  });

  tearDown(() {
    controller.dispose();
    backend.dispose();
  });

  test('settings is Loading until load(), then echoes the persisted values',
      () async {
    expect(controller.settings.isLoading, isTrue);

    await controller.load();
    final AppSettings settings = controller.settings.valueOrNull!;
    expect(settings.alias, '老名字');
    expect(settings.saveDirectory, '/save');
    expect(settings.acceptByDefault, isFalse);
    expect(controller.error, isNull);
  });

  test(
      'applyAlias writes through BOTH ports and updates the local state (§4.6)',
      () async {
    await controller.load();

    await controller.applyAlias('新名字');
    expect(backend.discovery.status.selfAlias, '新名字');
    expect(backend.transfer.alias, '新名字');
    expect(controller.settings.valueOrNull!.alias, '新名字');
    expect(controller.error, isNull);
  });

  test('setSaveDirectory persists and is echoed back by the platform',
      () async {
    await controller.load();

    await controller.setSaveDirectory('/other');
    expect(controller.settings.valueOrNull!.saveDirectory, '/other');
    expect((await backend.platform.loadSettings()).saveDirectory, '/other');
    expect(controller.error, isNull);
  });

  test(
      'setAccepting delegates to the receiver and remembers the default (P0-7)',
      () async {
    await controller.load();
    expect(controller.accepting, isFalse);

    await controller.setAccepting(true);
    expect(controller.accepting, isTrue);
    expect(backend.transfer.accepting, isTrue);
    expect(controller.settings.valueOrNull!.acceptByDefault, isTrue);
    expect((await backend.platform.loadSettings()).acceptByDefault, isTrue);
  });

  test(
    '0.2.25: nothing stored ⇒ the receive mode is already ON when load() '
    'resolves (the controller does not need a toggle to get there)',
    () async {
      // The read-disk half of this property lives in
      // `settings_document_migration_test.dart`; this one pins that the
      // controller's view (and therefore the rail icon + the settings switch)
      // agrees with it without any user action.
      final FakeBackend fresh = FakeBackend();
      addTearDown(fresh.dispose);
      final SettingsController freshController = SettingsController(
        platform: fresh.platform,
        discovery: fresh.discovery,
        transfer: fresh.transfer,
      );
      addTearDown(freshController.dispose);

      await freshController.load();

      expect(freshController.settings.valueOrNull!.acceptByDefault, isTrue);
      expect(freshController.accepting, isTrue);
    },
  );

  test(
    'setAccepting before load() is a no-op that never blanks the persisted '
    'settings (P0-7 pre-load guard)',
    () async {
      // `ready` is false until load() resolves, so the single receive-mode write
      // entry must bail: a `copyWith` on the empty fallback (`_current`) would
      // clobber alias + saveDirectory — and an empty save directory means
      // received files have nowhere to land.
      //
      // RED before the guard: the receiver flips (assertion 1) AND the persisted
      // alias/saveDirectory are blanked (the last three assertions), because the
      // write goes through with the empty fallback as its base.
      expect(controller.ready, isFalse);

      await controller.setAccepting(true);

      // The receiver was not toggled either — the guard sits in front of BOTH
      // writes, not just the persist.
      expect(backend.transfer.accepting, isFalse);

      // Nothing was persisted: the pre-load settings survive untouched.
      final AppSettings persisted = await backend.platform.loadSettings();
      expect(persisted.alias, '老名字');
      expect(persisted.saveDirectory, '/save');
      expect(persisted.acceptByDefault, isFalse);
    },
  );

  test(
    'renaming never drifts the device fingerprint — even after a reload '
    '(§4.6 / §8.2)',
    () async {
      // ⑥ **Regression guard — it will NOT go red against the current code.**
      // The alias and the fingerprint are already independent (the certificate
      // directory is alias-independent, §8.2), so today this passes trivially.
      // It exists to catch a *future* change that routes the alias through the
      // certificate / fingerprint path — precisely what §8.2 forbids — which
      // would silently re-identify the device on every rename.
      //
      // A dedicated backend keeps a non-null fingerprint observable (the shared
      // `setUp` backend leaves `selfFingerprint` null).
      const String fingerprint = 'AB:CD:EF:12:34:56:78:90';
      final FakeBackend local = FakeBackend(
        status: const DiscoveryStatus(
          phase: DiscoveryPhase.running,
          selfAlias: '老名字',
          selfFingerprint: fingerprint,
          selfPort: 53317,
        ),
        settings: const AppSettings(alias: '老名字', saveDirectory: '/save'),
      );
      addTearDown(local.dispose);
      final SettingsController localController = SettingsController(
        platform: local.platform,
        discovery: local.discovery,
        transfer: local.transfer,
      );
      addTearDown(localController.dispose);

      await localController.load();
      expect(local.discovery.status.selfFingerprint, fingerprint);

      await localController.applyAlias('新名字');
      expect(local.discovery.status.selfFingerprint, fingerprint);

      // "回来": reload the settings — the new alias is echoed back, the
      // fingerprint is unchanged (it never depended on the alias).
      await localController.load();
      expect(localController.settings.valueOrNull!.alias, '新名字');
      expect(local.discovery.status.selfFingerprint, fingerprint);
    },
  );

  test(
    'a settings write failure is surfaced, never swallowed, and the old value '
    'stands (§8.5)',
    () async {
      await controller.load();

      backend.platform.failSaveWith('目录不可写');
      await controller.setSaveDirectory('/nope');
      expect(controller.error, isNotNull);
      expect(controller.error, contains('保存位置保存失败'));
      // The failed write must not be adopted as the new state.
      expect(controller.settings.valueOrNull!.saveDirectory, '/save');

      controller.clearError();
      expect(controller.error, isNull);
    },
  );

  test('a persistence failure on applyAlias is surfaced too', () async {
    await controller.load();

    backend.platform.failSaveWith('目录不可写');
    await controller.applyAlias('新名字');
    expect(controller.error, contains('改名失败'));
    // The ports are updated before the save, so the alias still took effect.
    expect(backend.discovery.status.selfAlias, '新名字');
    expect(backend.transfer.alias, '新名字');
  });

  // ── 0.2.23: 保存位置 must take effect immediately, or say it did not ──────

  test('setSaveDirectory reaches the RUNNING receiver, not just the store',
      () async {
    await controller.load();
    expect(backend.transfer.saveDirectory, isNot('/new-place'));

    await controller.setSaveDirectory('/new-place');

    // Before 0.2.23 this was the entire defect: the setting was persisted and
    // echoed by the UI while `LanTransferService` kept its constructor-time
    // `final` directory, so the next received file still went to the old path
    // until the app was restarted.
    expect(backend.transfer.saveDirectory, '/new-place',
        reason: 'the transport must be writing to the new directory now');
    expect(controller.settings.valueOrNull!.saveDirectory, '/new-place');
    expect(controller.error, isNull);
  });

  test('a refused directory is reported AND rolled back', () async {
    await controller.load();
    backend.transfer.failSaveDirectoryWith = '无法写入 /ro（权限不足）';

    await controller.setSaveDirectory('/ro');

    // 1. Visible: never a silent no-op.
    expect(controller.error, contains('保存位置没有改'));
    expect(controller.error, contains('无法写入 /ro'));
    // 2. Rolled back: the transport never adopted it…
    expect(backend.transfer.saveDirectory, '/save');
    // 3. …and neither did the persisted setting, so the two still agree.
    expect(controller.settings.valueOrNull!.saveDirectory, '/save');
    expect((await backend.platform.loadSettings()).saveDirectory, '/save');
  });

  test('a persist failure after the transport moved puts the receiver back',
      () async {
    await controller.load();
    backend.platform.failSaveWith('磁盘满了');

    await controller.setSaveDirectory('/half-applied');

    expect(controller.error, contains('保存位置保存失败'));
    expect(controller.settings.valueOrNull!.saveDirectory, '/save');
    // The receiver must not keep writing somewhere the stored setting does not
    // name — that is the same "界面说的和实际写的不一致" defect, mirrored.
    expect(backend.transfer.saveDirectory, '/save');
  });
}
