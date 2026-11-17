/// Tests for the temporary-copy cleaner (0.2.23).
///
/// **The defect these pin down.** `MainActivity.copyPickedUri` writes a full
/// copy of every picked / shared file into `cacheDir/lanlink-picked/<uuid>/`, and
/// nothing on the Dart side ever deleted it: `discardDraft` / `consumeDraft`
/// cleared the *fields* and left the bytes. Sending a 1 GB video grew the app
/// cache by 1 GB, permanently.
///
/// Two properties matter, and they pull in opposite directions — which is why
/// both are pinned here:
///
/// 1. **our copies go** (after a send, after a cancelled draft, and on launch);
/// 2. **the user's own file never does** — the whole rule is "is this path under
///    `<temp>/lanlink-picked/`", and a file anywhere else is not ours to delete.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/data/real/picked_cache.dart';
import 'package:lanlink_app/domain/picked_cache.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late String root;
  late List<String> logs;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('lanlink_cache_test_');
    root = p.join(temporary.path, kPickedCacheDirectoryName);
    logs = <String>[];
  });

  tearDown(() async {
    if (await temporary.exists()) {
      await temporary.delete(recursive: true);
    }
  });

  PickedFileCache cleaner() => PickedFileCache(
        temporaryDirectory: () async => temporary,
        onLog: logs.add,
      );

  /// Creates `<root>/<uuid>/<name>` with one byte of content and answers the
  /// file's path — the exact shape the Android host produces.
  Future<String> seedCopy(String uuid, {String name = 'video.mp4'}) async {
    final Directory directory = Directory(p.join(root, uuid));
    await directory.create(recursive: true);
    final File file = File(p.join(directory.path, name));
    await file.writeAsBytes(<int>[1, 2, 3, 4]);
    return file.path;
  }

  group('owningDirectory (the whole safety story)', () {
    test('a path inside the cache names its per-send directory', () {
      expect(
        PickedFileCache.owningDirectory(
          root: root,
          path: p.join(root, 'uuid-1', 'clip.mp4'),
        ),
        p.join(root, 'uuid-1'),
      );
    });

    test('a path OUTSIDE the cache is refused (the user own file)', () {
      // The gallery's original, a Download folder, a desktop drop — all of these
      // must be untouchable, and none of them is under our root.
      expect(
        PickedFileCache.owningDirectory(
          root: root,
          path: p.join(temporary.path, 'DCIM', 'clip.mp4'),
        ),
        isNull,
      );
      expect(
        PickedFileCache.owningDirectory(root: root, path: '/sdcard/DCIM/a.jpg'),
        isNull,
      );
    });

    test('the root itself is never "owned" by a file path', () {
      expect(PickedFileCache.owningDirectory(root: root, path: root), isNull);
    });

    test('a `..` cannot escape the root', () {
      // Normalised BEFORE the containment test, so the traversal collapses and
      // the answer is "that is not under our root" — never "/sdcard".
      expect(
        PickedFileCache.owningDirectory(
          root: root,
          path: p.join(root, '..', '..', 'something', 'clip.mp4'),
        ),
        isNull,
      );
    });
  });

  group('discard', () {
    test('deletes the copy directory and leaves the outside source file alone',
        () async {
      final String copy = await seedCopy('uuid-1');
      final Directory copyDirectory = Directory(p.dirname(copy));
      // The "original": outside the cache, the same bytes the user still owns.
      final File original = File(p.join(temporary.path, 'clip.mp4'));
      await original.writeAsBytes(<int>[1, 2, 3, 4]);

      await cleaner().discard(<String>[copy]);

      expect(await copyDirectory.exists(), isFalse,
          reason: 'the per-send cache directory must be gone');
      expect(await original.exists(), isTrue,
          reason: 'THE invariant: never delete the user file — the judgement is '
              'purely "is this path under <temp>/lanlink-picked/"');
    });

    test('two files from the same pick free one directory, not two', () async {
      final String first = await seedCopy('uuid-2', name: 'a.mp4');
      final String second = p.join(p.dirname(first), 'b.mp4');
      await File(second).writeAsBytes(<int>[9]);

      await cleaner().discard(<String>[first, second]);

      expect(await Directory(p.join(root, 'uuid-2')).exists(), isFalse);
    });

    test('a foreign path is ignored without touching anything', () async {
      final File original = File(p.join(temporary.path, 'keep.mp4'));
      await original.writeAsBytes(<int>[1]);

      await cleaner().discard(<String>[original.path]);

      expect(await original.exists(), isTrue);
      expect(logs, isEmpty, reason: 'not ours is not an error — stay silent');
    });

    test('a missing directory is not an error', () async {
      await cleaner().discard(<String>[p.join(root, 'gone', 'x.mp4')]);
      expect(logs, isEmpty);
    });
  });

  group('clear (the launch sweep)', () {
    test('removes every per-send directory under the cache', () async {
      final String first = await seedCopy('uuid-a');
      final String second = await seedCopy('uuid-b', name: 'photo.jpg');
      expect(await Directory(p.dirname(first)).exists(), isTrue);
      expect(await Directory(p.dirname(second)).exists(), isTrue);

      await cleaner().clear();

      expect(await Directory(root).exists(), isFalse,
          reason: 'the whole lanlink-picked tree goes at launch — nothing in it '
              'is ever the only copy of anything');
    });

    test('leaves everything outside the cache untouched', () async {
      await seedCopy('uuid-c');
      final File sibling = File(p.join(temporary.path, 'unrelated.bin'));
      await sibling.writeAsBytes(<int>[7]);

      await cleaner().clear();

      expect(await sibling.exists(), isTrue);
    });

    test('a platform with no temporary directory is a silent no-op', () async {
      final PickedFileCache failing = PickedFileCache(
        temporaryDirectory: () async => throw const FileSystemException('nope'),
        onLog: logs.add,
      );

      await failing.clear();

      expect(logs.single, contains('CACHE 取不到临时目录'));
    });
  });
}
