/// 0.2.53 — readable names for photos the system picker named `1000055362.jpg`.
///
/// The user's report: the file keeps its `.jpg` but the name is a number, so the
/// bubble, 最近文件 and the saved copy are all unreadable. The rules under test are
/// the table in `lib/domain/media_file_name.dart`:
///
///  1. all-digit stem + a capture time ⇒ `yyyyMMdd_HHmmss` + the same extension;
///  2. no extension ⇒ one inferred from the MIME type (`image/jpeg` ⇒ `.jpg`);
///  3. **not** all digits ⇒ byte-for-byte unchanged;
///  4. all-digit stem **without** a time ⇒ unchanged (a wrong date is worse);
///  5. same-second siblings ⇒ `-2`, `-3`, … before the extension;
///  6. the rename must never lose the file: the returned path exists and the
///     bytes are untouched.
///
/// Every expected timestamp is built with `DateTime(…).millisecondsSinceEpoch`, so
/// these assertions pass in any timezone: the *formatting* is what is being
/// pinned, and it is deliberately local — it is a label a person reads.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/real/android_file_picker.dart';
import 'package:lanlink_app/domain/media_file_name.dart';

/// Local-time milliseconds for the instant the tests use as "the capture".
int _at(int y, int mo, int d, int h, int mi, int s) =>
    DateTime(y, mo, d, h, mi, s).millisecondsSinceEpoch;

void main() {
  group('mediaFileName — the naming rules', () {
    test('1: an all-digit name plus a capture time becomes a readable stamp', () {
      expect(
        mediaFileName(
          displayName: '1000055362.jpg',
          takenAtMillis: _at(2026, 11, 2, 15, 30, 12),
        ),
        '20261102_153012.jpg',
      );
    });

    test('2: no extension ⇒ inferred from the MIME type (never invented)', () {
      expect(
        mediaFileName(
          displayName: '1000055362',
          takenAtMillis: _at(2026, 11, 2, 15, 30, 12),
          mime: 'image/jpeg',
        ),
        '20261102_153012.jpg',
      );
      expect(
        mediaFileName(
          displayName: '1000055363',
          takenAtMillis: _at(2026, 11, 2, 15, 30, 13),
          mime: 'image/heic',
        ),
        '20261102_153013.heic',
      );
      expect(
        mediaFileName(
          displayName: '1000055364',
          takenAtMillis: _at(2026, 11, 2, 15, 30, 14),
          mime: 'application/octet-stream',
        ),
        '20261102_153014',
        reason: 'an unknown type must not turn into a made-up .bin',
      );
    });

    test('3: a readable name is returned byte-for-byte unchanged', () {
      for (final String name in <String>[
        'IMG_1234.jpg',
        '微信图片_20260107121500.jpg',
        'Screenshot 2026-11-02 at 15.30.12.png',
        'PXL_20261102_153012345.MP.jpg',
        'DSC_0001.JPG',
        'notes', // no extension at all
        '.nomedia', // leading dot is not an extension
        'trailing.', // a trailing dot is not an extension
      ]) {
        expect(
          mediaFileName(
            displayName: name,
            takenAtMillis: _at(2026, 11, 2, 15, 30, 12),
            mime: 'image/jpeg',
          ),
          name,
          reason: 'renaming a readable name would destroy information we did '
              'not create',
        );
      }
    });

    test('4: an all-digit name with NO capture time keeps its name', () {
      expect(
        mediaFileName(displayName: '1000055362.jpg', takenAtMillis: null),
        '1000055362.jpg',
      );
      // …and `0` means "the platform answered with nothing", not 1970.
      expect(
        mediaFileName(displayName: '1000055362.jpg', takenAtMillis: 0),
        '1000055362.jpg',
      );
      expect(
        mediaFileName(displayName: '1000055362.jpg', takenAtMillis: -1),
        '1000055362.jpg',
      );
    });

    test('5: same-second siblings get -2, -3 … before the extension', () {
      final int stamp = _at(2026, 11, 2, 15, 30, 12);
      final List<String> names = uniqueMediaFileNames(<PickedMedia>[
        PickedMedia(
            path: '/c/a/1000055362.jpg',
            displayName: '1000055362.jpg',
            takenAtMillis: stamp),
        PickedMedia(
            path: '/c/b/1000055361.jpg',
            displayName: '1000055361.jpg',
            takenAtMillis: stamp),
        PickedMedia(
            path: '/c/c/1000055360.jpg',
            displayName: '1000055360.jpg',
            takenAtMillis: stamp),
      ]);
      expect(names, <String>[
        '20261102_153012.jpg',
        '20261102_153012-2.jpg',
        '20261102_153012-3.jpg',
      ]);
    });

    test('5b: a clash with an untouched name is resolved the same way', () {
      final List<String> names = uniqueMediaFileNames(<PickedMedia>[
        const PickedMedia(path: '/c/a/IMG_1.jpg', displayName: 'IMG_1.jpg'),
        const PickedMedia(path: '/c/b/IMG_1.jpg', displayName: 'IMG_1.jpg'),
      ]);
      expect(names, <String>['IMG_1.jpg', 'IMG_1-2.jpg']);
    });

    test('an empty display name falls back to the cached file name', () {
      expect(
        uniqueMediaFileNames(<PickedMedia>[
          const PickedMedia(path: '/c/a/1000055362.jpg', displayName: ''),
        ]),
        <String>['1000055362.jpg'],
      );
    });

    test('splitMediaName / mediaSiblingPath keep both separators straight', () {
      expect(splitMediaName('Picture.JPG'), (stem: 'Picture', extension: '.JPG'));
      expect(splitMediaName('.nomedia'), (stem: '.nomedia', extension: ''));
      expect(mediaBaseName('/a/b/c.jpg'), 'c.jpg');
      expect(mediaBaseName(r'C:\tmp\c.jpg'), 'c.jpg');
      expect(mediaSiblingPath('/a/b/c.jpg', 'd.jpg'), '/a/b/d.jpg');
      expect(mediaSiblingPath(r'C:\tmp\c.jpg', 'd.jpg'), r'C:\tmp\d.jpg');
      expect(mediaSiblingPath('c.jpg', 'd.jpg'), 'd.jpg');
    });
  });

  group('applyMediaFileNames — the rename itself', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('lanlink-rename-');
    });

    tearDown(() async {
      if (root.existsSync()) {
        await root.delete(recursive: true);
      }
    });

    /// One fake "cached copy" of [name] with [bytes] bytes of content.
    File seed(String name, List<int> bytes) {
      final File file = File('${root.path}${Platform.pathSeparator}$name');
      file.writeAsBytesSync(bytes);
      return file;
    }

    test('6: the returned path is a REAL file, same bytes, new name', () async {
      final File first = seed('1000055362.jpg', <int>[1, 2, 3, 4, 5]);
      final File second = seed('1000055363.jpg', <int>[9, 8, 7]);
      final int stamp = _at(2026, 11, 2, 15, 30, 12);

      final List<String> paths = await applyMediaFileNames(<PickedMedia>[
        PickedMedia(
            path: first.path,
            displayName: '1000055362.jpg',
            takenAtMillis: stamp,
            mime: 'image/jpeg'),
        PickedMedia(
            path: second.path,
            displayName: '1000055363.jpg',
            takenAtMillis: stamp,
            mime: 'image/jpeg'),
      ]);

      expect(paths, hasLength(2));
      for (final String path in paths) {
        final File file = File(path);
        expect(file.existsSync(), isTrue,
            reason: 'a rename that answers a path pointing nowhere is worse '
                'than the numeric name: the message could not be sent');
      }
      expect(paths.map(mediaBaseName).toList(),
          <String>['20261102_153012.jpg', '20261102_153012-2.jpg']);
      expect(File(paths[0]).readAsBytesSync(), <int>[1, 2, 3, 4, 5]);
      expect(File(paths[1]).lengthSync(), 3);
      // The originals are gone — this was a rename, not a copy.
      expect(first.existsSync(), isFalse);
      expect(second.existsSync(), isFalse);
      // …and they stayed in the same directory as the copies.
      expect(File(paths[0]).parent.path, first.parent.path);
    });

    test('6b: a name that must not change is LEFT ALONE (same file, no rename)',
        () async {
      final File kept = seed('IMG_1234.jpg', <int>[4, 2]);
      final List<String> paths = await applyMediaFileNames(<PickedMedia>[
        PickedMedia(
            path: kept.path,
            displayName: 'IMG_1234.jpg',
            takenAtMillis: _at(2026, 11, 2, 15, 30, 12),
            mime: 'image/jpeg'),
      ]);
      expect(paths, <String>[kept.path]);
      expect(kept.existsSync(), isTrue);
      expect(kept.lengthSync(), 2);
    });

    test('6c: an empty pick answers an empty list, touching nothing', () async {
      expect(await applyMediaFileNames(const <PickedMedia>[]), isEmpty);
    });
  });
}
