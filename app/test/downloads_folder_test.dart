/// 0.2.24 — the two pure pieces behind 「在下载里查看」:
/// `isInLanlinkDownloadsFolder` (is this path inside the folder 0.2.19 publishes
/// received files into?) and `AndroidFileActions.parseViewInDownloadsReply` (what
/// did the native side answer?).
///
/// Both are unit-tested here, off the widget tree, because both are **decisions**
/// and getting either wrong is silent: a wrong predicate makes the menu row
/// disappear (nothing fails), and a wrong parse maps "did not open" onto "opened"
/// (the user taps and nothing happens). `downloads_view_menu_test.dart` covers
/// what the user sees; this file covers the facts underneath it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/real/android_file_actions.dart';
import 'package:lanlink_app/domain/downloads_folder.dart';
import 'package:lanlink_app/domain/platform_ports.dart'
    show ViewInDownloadsOutcome;

void main() {
  group('isInLanlinkDownloadsFolder', () {
    test('accepts the path publishToDownloads actually returns', () {
      // The exact shape `MainActivity.publicDownloadsPath` builds:
      // getExternalStoragePublicDirectory(DOWNLOAD) + "lanlink" + name.
      expect(
        isInLanlinkDownloadsFolder(
          '/storage/emulated/0/Download/lanlink/clip.mp4',
        ),
        isTrue,
      );
    });

    test('accepts a duplicate-renamed file (the platform picked the name)',
        () {
      expect(
        isInLanlinkDownloadsFolder(
          '/storage/emulated/0/Download/lanlink/clip (1).mp4',
        ),
        isTrue,
      );
    });

    test('REJECTS the private directory — the file an older build kept', () {
      // The whole point of the path test: pre-0.2.19 rows point here, and the
      // folder action would open 下载/lanlink where that file simply is not.
      expect(
        isInLanlinkDownloadsFolder(
          '/data/user/0/io.github.kk339.lanlink/files/lanlink/received/clip.mp4',
        ),
        isFalse,
      );
    });

    test('rejects a sibling folder under Download', () {
      expect(
        isInLanlinkDownloadsFolder('/storage/emulated/0/Download/other/clip.mp4'),
        isFalse,
      );
      expect(
        isInLanlinkDownloadsFolder('/storage/emulated/0/Download/clip.mp4'),
        isFalse,
      );
    });

    test('rejects the folder itself — that is not a file in the folder', () {
      expect(
        isInLanlinkDownloadsFolder('/storage/emulated/0/Download/lanlink'),
        isFalse,
      );
    });

    test('rejects a name that merely starts with "lanlink"', () {
      expect(
        isInLanlinkDownloadsFolder(
          '/storage/emulated/0/Download/lanlink2/clip.mp4',
        ),
        isFalse,
      );
    });

    test('rejects the plural desktop spelling (Downloads/lanlink)', () {
      // On a desktop the received file lives in the save directory, and the
      // folder is spelled `Downloads` there. It must not look like the Android
      // folder — the platform gate would be the only thing stopping it, and a
      // predicate that already says "no" is the stronger answer.
      expect(
        isInLanlinkDownloadsFolder(r'C:\Users\me\Downloads\lanlink\clip.mp4'),
        isFalse,
      );
    });

    test('rejects an empty path', () {
      expect(isInLanlinkDownloadsFolder(''), isFalse);
    });
  });

  group('isInLanlinkDownloadsFolder with a CHOSEN folder (0.2.29)', () {
    test('accepts a file in the folder the user picked', () {
      expect(
        isInLanlinkDownloadsFolder(
          '/storage/emulated/0/Download/素材/clip.mp4',
          subdirectory: '素材',
        ),
        isTrue,
      );
    });

    test('accepts a nested folder — a file DIRECTLY inside it', () {
      expect(
        isInLanlinkDownloadsFolder(
          '/storage/emulated/0/Download/素材/2026/clip.mp4',
          subdirectory: '素材/2026',
        ),
        isTrue,
      );
      // …and a file one level deeper than the chosen folder is **not** in it:
      // the predicate answers "is this file inside exactly that folder", so
      // `素材/2026/01/clip.mp4` belongs to `素材/2026/01`. Saying yes here would
      // mean 「在下载里查看」 opened a folder that is not the file's own.
      expect(
        isInLanlinkDownloadsFolder(
          '/storage/emulated/0/Download/素材/2026/01/clip.mp4',
          subdirectory: '素材/2026',
        ),
        isFalse,
      );
    });

    test('★ REJECTS a file in the old default folder once the setting moved on',
        () {
      // The choice made: 「在下载里查看」 opens the folder that is configured NOW,
      // so a file left in `Download/lanlink` by an earlier build must not offer a
      // row that would open a different folder. Files from that era are in the
      // database with that path, and nothing else about them changes.
      expect(
        isInLanlinkDownloadsFolder(
          '/storage/emulated/0/Download/lanlink/clip.mp4',
          subdirectory: '素材',
        ),
        isFalse,
      );
    });

    test('a partial name match is not a match', () {
      expect(
        isInLanlinkDownloadsFolder(
          '/storage/emulated/0/Download/素材2/clip.mp4',
          subdirectory: '素材',
        ),
        isFalse,
      );
      expect(
        isInLanlinkDownloadsFolder(
          '/storage/emulated/0/Download/素材/clip.mp4',
          subdirectory: '素材/2026',
        ),
        isFalse,
      );
    });

    test('★ the folder ITSELF is still not a file in the folder', () {
      // The rule that makes the predicate useful for 「在下载里查看」. A picker
      // hands back folders, so it is tempting to relax it for them — that would
      // loosen the menu's judgement too, which is why it stays.
      expect(
        isInLanlinkDownloadsFolder(
          '/storage/emulated/0/Download/素材',
          subdirectory: '素材',
        ),
        isFalse,
      );
      expect(
        isInLanlinkDownloadsFolder(
          '/storage/emulated/0/Download/lanlink',
          subdirectory: 'lanlink',
        ),
        isFalse,
      );
      // A **path string cannot tell a sub-folder from a file name**, so
      // `…/素材/2026` with `素材` chosen reads as "the file 2026, in 素材". That is
      // the honest limit of a pure string test, and it is harmless: the menu only
      // ever receives `FileAttachment.localPath`, which is a file by definition.
      expect(
        isInLanlinkDownloadsFolder(
          '/storage/emulated/0/Download/素材/2026',
          subdirectory: '素材',
        ),
        isTrue,
        reason: 'indistinguishable from a file called 2026 — documented, not a bug',
      );
    });

    test('a malformed subdirectory falls back to the default, not to "everything"',
        () {
      // ''/'..' must not turn the predicate into "anywhere under Download".
      for (final String subdirectory in <String>['', '  ', '..', '/']) {
        expect(
          isInLanlinkDownloadsFolder(
            '/storage/emulated/0/Download/lanlink/clip.mp4',
            subdirectory: subdirectory,
          ),
          isTrue,
          reason: 'blank means the default folder',
        );
        expect(
          isInLanlinkDownloadsFolder(
            '/storage/emulated/0/Download/其他/clip.mp4',
            subdirectory: subdirectory,
          ),
          isFalse,
        );
      }
    });
  });

  group('AndroidFileActions.parseViewInDownloadsReply', () {
    test('maps every code MainActivity answers', () {
      expect(
        AndroidFileActions.parseViewInDownloadsReply(
          <Object?, Object?>{'result': 'opened'},
        ),
        ViewInDownloadsOutcome.opened,
      );
      expect(
        AndroidFileActions.parseViewInDownloadsReply(
          <Object?, Object?>{'result': 'no_app'},
        ),
        ViewInDownloadsOutcome.noApp,
      );
      expect(
        AndroidFileActions.parseViewInDownloadsReply(
          <Object?, Object?>{'result': 'no_directory'},
        ),
        ViewInDownloadsOutcome.noDirectory,
      );
      expect(
        AndroidFileActions.parseViewInDownloadsReply(
          <Object?, Object?>{'result': 'unsupported'},
        ),
        ViewInDownloadsOutcome.unsupported,
      );
      // `failed` carries an `error` next to the code; the code is what is read.
      expect(
        AndroidFileActions.parseViewInDownloadsReply(
          <Object?, Object?>{'result': 'failed', 'error': 'SecurityException'},
        ),
        ViewInDownloadsOutcome.failed,
      );
    });

    test('is never "opened" on a null / malformed / unknown reply', () {
      // A silent success is the one wrong answer: the user would be looking at
      // an unchanged screen with no message at all.
      for (final Object? reply in <Object?>[
        null,
        'opened',
        <Object?, Object?>{},
        <Object?, Object?>{'result': 'Opened'},
        <Object?, Object?>{'result': 'whatever_the_native_side_renamed_it_to'},
        <Object?, Object?>{'result': null},
      ]) {
        expect(
          AndroidFileActions.parseViewInDownloadsReply(reply),
          isNot(ViewInDownloadsOutcome.opened),
          reason: 'reply $reply must not be read as success',
        );
      }
    });
  });
}
