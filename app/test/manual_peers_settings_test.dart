/// 0.2.54 — 「手动填写对端 IP」 remembered across launches.
///
/// **The defect these pin down.** The feature exists for the network where
/// discovery is blocked. If the address is not remembered, every restart puts
/// the user back in front of an empty device list with nothing to type into
/// twice: the self-rescue path becomes a chore, and the app looks broken in
/// exactly the situation it was built for.
///
/// **What is deliberately *not* stored.** Only `{host, port}` — never the
/// certificate fingerprint. A peer that reinstalls lanlink comes back under a
/// new identity; a remembered fingerprint would make the saved target refuse a
/// device standing right in front of the user, forever, with no visible cause.
/// The fingerprint is observed fresh on every probe, which is what lets a stored
/// target heal itself (pinned in ⑧).
///
/// Everything here runs against the **real** [SystemPlatformPorts] on real
/// temporary files: the fakes never touch `dart:io`, so a persistence bug would
/// be invisible to them — and the whole point of this file is persistence.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/data/real/system_platform_ports.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory saveDirectory;
  late String settingsPath;

  /// A port over the temp settings file — the constructor the native bootstrap
  /// uses. A **fresh instance** is how a restart is modelled: nothing survives
  /// in memory, only what reached the disk.
  SystemPlatformPorts ports() => SystemPlatformPorts(
        settingsPath: settingsPath,
        defaultAlias: 'test-device',
        defaultSaveDirectory: saveDirectory.path,
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lanlink_manual_peers_');
    saveDirectory = Directory(p.join(root.path, 'received'));
    settingsPath = p.join(root.path, 'settings.json');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  /// Writes a settings document verbatim — the only way to reproduce a file
  /// written by another build (or by a user with an editor).
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

  /// A document that a current build would have written, minus the key under
  /// test (i.e. what 0.2.53 and earlier wrote, `settingsVersion` aside).
  Map<String, Object?> documentWithoutTargets() => <String, Object?>{
        'settingsVersion': 2,
        'alias': '老机器',
        'saveDirectory': saveDirectory.path,
        'acceptByDefault': false,
        'receivedSubdirectory': '素材',
      };

  // ── ① round trip ────────────────────────────────────────────────────────
  group('① what was typed comes back, in order', () {
    test('two targets survive save → restart → load, element for element',
        () async {
      const List<ManualPeerTarget> typed = <ManualPeerTarget>[
        ManualPeerTarget(host: '192.168.1.23', port: 49494),
        ManualPeerTarget(host: '10.0.0.7', port: 50000),
      ];

      await ports().saveSettings(
        (await ports().loadSettings()).copyWith(manualPeers: typed),
      );

      // ★ A brand-new port over the same file: this is the restart, and the only
      // thing it can learn is what the writer actually put on disk.
      final AppSettings reloaded = await ports().loadSettings();
      expect(reloaded.manualPeers, typed,
          reason: 'order included — the user sees this list, and a reordered one '
              'reads as "the app remembered something else"');
      expect(reloaded.manualPeers.length, 2);

      // The stored shape, so a future reader (or a human with an editor) sees
      // what the docs say it is.
      final Map<String, Object?> document = await readDocument();
      expect(document['manualPeers'], <Object?>[
        <String, Object?>{'host': '192.168.1.23', 'port': 49494},
        <String, Object?>{'host': '10.0.0.7', 'port': 50000},
      ]);
      expect(document['settingsVersion'], kSettingsDocumentVersion);
    });

    test('★ renaming the device keeps the remembered targets', () async {
      // `SettingsController.applyAlias` is `copyWith(alias: …)` on the loaded
      // settings plus one save. If the writer forgot the key, the addresses
      // would evaporate on an action that has nothing to do with them — the same
      // silent loss 0.2.23's save directory and 0.2.29's folder both had.
      const ManualPeerTarget target =
          ManualPeerTarget(host: '192.168.1.23', port: 49494);
      await ports().saveSettings(
        (await ports().loadSettings())
            .copyWith(manualPeers: const <ManualPeerTarget>[target]),
      );
      await ports().saveSettings(
        (await ports().loadSettings()).copyWith(alias: '客厅的电脑'),
      );

      final Map<String, Object?> document = await readDocument();
      expect(document['alias'], '客厅的电脑');
      expect(document['manualPeers'], <Object?>[
        <String, Object?>{'host': '192.168.1.23', 'port': 49494},
      ]);
      expect((await ports().loadSettings()).manualPeers,
          const <ManualPeerTarget>[target]);
    });

    test('clearing the list is a real edit, not a no-op', () async {
      await ports().saveSettings(
        (await ports().loadSettings()).copyWith(
          manualPeers: const <ManualPeerTarget>[
            ManualPeerTarget(host: '192.168.1.23', port: 49494),
          ],
        ),
      );
      await ports().saveSettings(
        (await ports().loadSettings())
            .copyWith(manualPeers: const <ManualPeerTarget>[]),
      );

      expect((await readDocument())['manualPeers'], isEmpty);
      expect((await ports().loadSettings()).manualPeers, isEmpty);
    });
  });

  // ── ② an old document ───────────────────────────────────────────────────
  test(
    '② a document with NO manualPeers key (every install before this build) '
    'loads, and every other field is untouched',
    () async {
      await writeDocument(documentWithoutTargets());

      final AppSettings settings = await ports().loadSettings();

      expect(settings.manualPeers, isEmpty,
          reason: 'absent means "never typed anything" — not an error');
      // ★ The half that matters: loading an old document must not cost the user
      // anything they *did* save.
      expect(settings.alias, '老机器');
      expect(settings.saveDirectory, saveDirectory.path);
      expect(settings.receivedSubdirectory, '素材');
      expect(settings.acceptByDefault, isFalse,
          reason: 'a v2 document\'s false is the USER\'s choice after 0.2.25');
    },
  );

  // ── ③ one bad entry costs one entry ─────────────────────────────────────
  test(
    '③ three stored entries, two of them unusable → the good one loads and the '
    'alias is still there',
    () async {
      await writeDocument(<String, Object?>{
        ...documentWithoutTargets(),
        'manualPeers': <Object?>[
          <String, Object?>{'host': '192.168.1.23', 'port': 49494},
          // `port: 0` — nothing listens there.
          <String, Object?>{'host': '10.0.0.9', 'port': 0},
          // Blank host — a dial target with no address.
          <String, Object?>{'host': '   ', 'port': 5000},
        ],
      });

      final AppSettings settings = await ports().loadSettings();

      expect(settings.manualPeers,
          const <ManualPeerTarget>[
            ManualPeerTarget(host: '192.168.1.23', port: 49494),
          ],
          reason: 'dropped one by one, not all-or-nothing');
      // ★ The reason for the per-entry rule: an all-or-nothing reader throws,
      // `loadSettings` catches it and answers *defaults* — so one typo in one
      // address would silently reset the device name and the save folder.
      expect(settings.alias, '老机器');
      expect(settings.saveDirectory, saveDirectory.path);
      expect(settings.receivedSubdirectory, '素材');
      expect(settings.acceptByDefault, isFalse);
    },
  );

  // ── ④ the version bump is not a migration ───────────────────────────────
  test(
    '④ a v2 document (the version this build replaced) still loads — not '
    'rejected, not reset to defaults, and NOT re-migrated',
    () async {
      await writeDocument(<String, Object?>{
        ...documentWithoutTargets(),
        'manualPeers': <Object?>[
          <String, Object?>{'host': '192.168.1.23', 'port': 49494},
        ],
      });

      final AppSettings settings = await ports().loadSettings();

      expect(settings.alias, '老机器', reason: 'a v2 document is not corrupt');
      expect(settings.acceptByDefault, isFalse,
          reason: '★ the acceptByDefault migration is gated on v2 — bumping the '
              'document version to 3 must NOT re-arm it, or the user\'s own '
              '"receiving off" is silently undone at every restart');
      expect(settings.manualPeers.length, 1);

      // Nothing was rewritten: v3 added an optional key, so there is no data
      // migration to perform and no reason to touch the user's file.
      expect((await readDocument())['settingsVersion'], 2);
      expect((await readDocument())['acceptByDefault'], isFalse);
    },
  );

  test('④b a v3 document is read as current', () async {
    await writeDocument(<String, Object?>{
      ...documentWithoutTargets(),
      'settingsVersion': kSettingsDocumentVersion,
      'manualPeers': <Object?>[
        <String, Object?>{'host': '192.168.1.23', 'port': 49494},
      ],
    });

    final AppSettings settings = await ports().loadSettings();
    expect(settings.manualPeers.length, 1);
    expect(settings.acceptByDefault, isFalse);
  });

  // ── ⑤ what counts as a usable target ────────────────────────────────────
  group('⑤ entry-level validation', () {
    Future<List<ManualPeerTarget>> loadWith(List<Object?> raw) async {
      await writeDocument(<String, Object?>{
        ...documentWithoutTargets(),
        'settingsVersion': kSettingsDocumentVersion,
        'manualPeers': raw,
      });
      return (await ports().loadSettings()).manualPeers;
    }

    test('the port range is 1…65535 inclusive', () async {
      final List<ManualPeerTarget> loaded = await loadWith(<Object?>[
        <String, Object?>{'host': '10.0.0.1', 'port': 1},
        <String, Object?>{'host': '10.0.0.2', 'port': 65535},
        <String, Object?>{'host': '10.0.0.3', 'port': 0},
        <String, Object?>{'host': '10.0.0.4', 'port': 65536},
        <String, Object?>{'host': '10.0.0.5', 'port': -1},
      ]);
      expect(loaded, <ManualPeerTarget>[
        const ManualPeerTarget(host: '10.0.0.1', port: 1),
        const ManualPeerTarget(host: '10.0.0.2', port: 65535),
      ]);
    });

    test('a JSON decimal port is a port; a fractional one is not', () async {
      // `49494.0` is what a hand-edit or another language's encoder leaves
      // behind; `49494.5` is not a port anybody typed.
      final List<ManualPeerTarget> loaded = await loadWith(<Object?>[
        <String, Object?>{'host': '10.0.0.1', 'port': 49494.0},
        <String, Object?>{'host': '10.0.0.2', 'port': 49494.5},
      ]);
      expect(loaded, <ManualPeerTarget>[
        const ManualPeerTarget(host: '10.0.0.1', port: 49494),
      ]);
    });

    test('entries that are not {host: string, port: number} are dropped',
        () async {
      final List<ManualPeerTarget> loaded = await loadWith(<Object?>[
        '192.168.1.23', //  a bare string
        <String, Object?>{}, // no keys
        <String, Object?>{'host': '10.0.0.1'}, // no port
        <String, Object?>{'port': 49494}, // no host
        <String, Object?>{'host': 10, 'port': 49494}, // host is a number
        <String, Object?>{'host': '10.0.0.2', 'port': '49494'}, // port is text
        <String, Object?>{'host': '10.0.0.3', 'port': 49494},
      ]);
      expect(loaded, <ManualPeerTarget>[
        const ManualPeerTarget(host: '10.0.0.3', port: 49494),
      ]);
    });

    test('a surrounded host is trimmed; the trimmed value is what is kept',
        () async {
      final List<ManualPeerTarget> loaded = await loadWith(<Object?>[
        <String, Object?>{'host': '  192.168.1.23  ', 'port': 49494},
      ]);
      expect(loaded, <ManualPeerTarget>[
        const ManualPeerTarget(host: '192.168.1.23', port: 49494),
      ]);
    });

    test('a non-list value is an empty list, not a failed load', () async {
      for (final Object? raw in <Object?>[null, 'nope', 42, <String, Object?>{}]) {
        final List<ManualPeerTarget> loaded = await loadWith(<Object?>[raw]);
        expect(loaded, isEmpty, reason: 'stored value $raw must read as "none"');
      }
      // …and the rest of the document is intact after all of that.
      final AppSettings settings = await ports().loadSettings();
      expect(settings.alias, '老机器');
      expect(settings.saveDirectory, saveDirectory.path);
    });

    test('an IPv6 literal and a hostname survive verbatim (the probe decides)',
        () async {
      // The domain type describes what is *stored*; what can be *dialled* is
      // `PeerDiscovery.probeHost`'s call, so nothing is normalised away here.
      final List<ManualPeerTarget> loaded = await loadWith(<Object?>[
        <String, Object?>{'host': 'fe80::1', 'port': 49494},
        <String, Object?>{'host': 'mypc.local', 'port': 49494},
      ]);
      expect(loaded, <ManualPeerTarget>[
        const ManualPeerTarget(host: 'fe80::1', port: 49494),
        const ManualPeerTarget(host: 'mypc.local', port: 49494),
      ]);
    });
  });

  // ── ⑥ what the writer refuses to store ──────────────────────────────────
  test('⑥ a model holding an undialable target never puts it on disk', () async {
    // The document must not contain something its own reader would discard: the
    // user would see the row, restart, and find it gone with nothing to blame.
    await ports().saveSettings(
      (await ports().loadSettings()).copyWith(
        manualPeers: const <ManualPeerTarget>[
          ManualPeerTarget(host: '192.168.1.23', port: 49494),
          ManualPeerTarget(host: '', port: 5000),
          ManualPeerTarget(host: '10.0.0.9', port: 70000),
        ],
      ),
    );

    expect((await readDocument())['manualPeers'], <Object?>[
      <String, Object?>{'host': '192.168.1.23', 'port': 49494},
    ]);
  });

  // ── ⑦ the one-time migration must not drop the new key ──────────────────
  test('⑦ the receive-mode migration rewrite carries manualPeers through',
      () async {
    // A v1 document (no `settingsVersion`) is migrated and rewritten. The
    // rewrite serialises the loaded model, so a writer that forgot the new key
    // would lose the user's addresses during an upgrade they never asked for.
    await writeDocument(<String, Object?>{
      'alias': '老机器',
      'saveDirectory': saveDirectory.path,
      'acceptByDefault': false,
      'manualPeers': <Object?>[
        <String, Object?>{'host': '192.168.1.23', 'port': 49494},
      ],
    });

    final AppSettings settings = await ports().loadSettings();
    expect(settings.acceptByDefault, isTrue,
        reason: 'the 0.2.25 migration still applies to a v1 document');
    expect(settings.manualPeers.length, 1);

    final Map<String, Object?> rewritten = await readDocument();
    expect(rewritten['settingsVersion'], kSettingsDocumentVersion);
    expect(rewritten['manualPeers'], <Object?>[
      <String, Object?>{'host': '192.168.1.23', 'port': 49494},
    ],
        reason: 'a migration must move data, never lose it');
  });

  // ── ⑧ the value object itself ───────────────────────────────────────────
  group('⑧ ManualPeerTarget', () {
    test('equals by host and port, and hashes with it', () {
      const ManualPeerTarget a =
          ManualPeerTarget(host: '192.168.1.23', port: 49494);
      const ManualPeerTarget b =
          ManualPeerTarget(host: '192.168.1.23', port: 49494);
      const ManualPeerTarget otherPort =
          ManualPeerTarget(host: '192.168.1.23', port: 49495);
      const ManualPeerTarget otherHost =
          ManualPeerTarget(host: '192.168.1.24', port: 49494);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(otherPort));
      expect(a, isNot(otherHost));
      expect(a.toJson(), <String, Object?>{'host': '192.168.1.23', 'port': 49494});
      expect(ManualPeerTarget.tryParse(a.toJson()), a);
    });

    test('★ holds no fingerprint — the identity is re-observed on every probe',
        () {
      const ManualPeerTarget target =
          ManualPeerTarget(host: '192.168.1.23', port: 49494);
      // The whole reason a reinstall self-heals: nothing about a certificate is
      // remembered, so a peer's new identity is simply observed next time.
      expect(target.toJson().keys, <String>['host', 'port']);
    });

    test('AppSettings equality notices the list; copyWith replaces it', () {
      const AppSettings base =
          AppSettings(alias: 'a', saveDirectory: '/save');
      expect(base.manualPeers, isEmpty, reason: 'empty by default');
      expect(base.copyWith(manualPeers: const <ManualPeerTarget>[
        ManualPeerTarget(host: '10.0.0.1', port: 1),
      ]), isNot(base));
      expect(base, const AppSettings(alias: 'a', saveDirectory: '/save'));
      expect(
        base
            .copyWith(manualPeers: const <ManualPeerTarget>[
              ManualPeerTarget(host: '10.0.0.1', port: 1),
            ])
            .copyWith(manualPeers: const <ManualPeerTarget>[]),
        base,
        reason: 'clearing the list must round-trip to the default value',
      );
    });
  });
}
