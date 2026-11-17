/// 0.2.29 — the two native-facing pieces of "the user picks the save folder":
/// the reply mapping (`AndroidFolderPicker.parsePickReply`) and the publisher's
/// per-publish folder.
///
/// Why these are unit-tested off-device: both are **decisions**, and each one can
/// be wrong in a way that looks like nothing happened.
///
/// * a mis-parsed pick reply either stores a folder that does not exist (files
///   land somewhere the user never looks) or silently treats "the user backed
///   out" as "the user chose something";
/// * a publisher that captured the folder at construction keeps writing the old
///   one until the app restarts — the 0.2.23 "the setting says 素材 but the files
///   go to lanlink" defect, which no UI test can see.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/fake_public_storage.dart';
import 'package:lanlink_app/data/real/android_folder_picker.dart';
import 'package:lanlink_app/domain/downloads_folder.dart'
    show
        downloadsFolderLabel,
        downloadsFolderPath,
        kLanlinkDownloadsSubdirectory,
        normalizeDownloadsSubdirectory;
import 'package:lanlink_app/domain/platform_ports.dart'
    show PickDownloadsFolderOutcome;
import 'package:lanlink_app/domain/received_file_publisher.dart';

void main() {
  group('AndroidFolderPicker.parsePickReply', () {
    test('a real pick carries the folder name, relative to Download/', () {
      final choice = AndroidFolderPicker.parsePickReply(
        <Object?, Object?>{'result': 'ok', 'subdirectory': '素材'},
      );
      expect(choice.outcome, PickDownloadsFolderOutcome.picked);
      expect(choice.subdirectory, '素材');
    });

    test('a nested pick keeps its relative path', () {
      expect(
        AndroidFolderPicker.parsePickReply(
          <Object?, Object?>{'result': 'ok', 'subdirectory': '素材/2026'},
        ).subdirectory,
        '素材/2026',
      );
    });

    test('"ok" without a name is a FAILURE, not an empty pick', () {
      // Storing `''` here would mean "default" and the user's pick would be
      // replaced by lanlink without a word — so a nameless ok must not pass.
      for (final Object? reply in <Object?>[
        <Object?, Object?>{'result': 'ok'},
        <Object?, Object?>{'result': 'ok', 'subdirectory': ''},
        <Object?, Object?>{'result': 'ok', 'subdirectory': '   '},
        <Object?, Object?>{'result': 'ok', 'subdirectory': 42},
      ]) {
        final choice = AndroidFolderPicker.parsePickReply(reply);
        expect(choice.outcome, PickDownloadsFolderOutcome.failed,
            reason: 'reply $reply must not be read as a choice');
        expect(choice.subdirectory, isNull);
      }
    });

    test('cancelled / invalid / failed map to their own outcomes', () {
      expect(
        AndroidFolderPicker.parsePickReply(
          <Object?, Object?>{'result': 'cancelled'},
        ).outcome,
        PickDownloadsFolderOutcome.cancelled,
      );
      final invalid = AndroidFolderPicker.parsePickReply(
        <Object?, Object?>{
          'result': 'invalid',
          'reason': '只能选择「下载」里的文件夹',
        },
      );
      expect(invalid.outcome, PickDownloadsFolderOutcome.invalid);
      expect(invalid.reason, '只能选择「下载」里的文件夹',
          reason: 'the reason is what the user is shown');
      final failed = AndroidFolderPicker.parsePickReply(
        <Object?, Object?>{'result': 'failed', 'reason': 'boom'},
      );
      expect(failed.outcome, PickDownloadsFolderOutcome.failed);
      expect(failed.reason, 'boom');
    });

    test('anything unrecognised is a failure — never a silent success', () {
      for (final Object? reply in <Object?>[
        null,
        'ok',
        <Object?, Object?>{},
        <Object?, Object?>{'result': 'OK'},
        <Object?, Object?>{'result': 'whatever'},
      ]) {
        expect(
          AndroidFolderPicker.parsePickReply(reply).outcome,
          isNot(PickDownloadsFolderOutcome.picked),
          reason: 'reply $reply must not be read as a choice',
        );
      }
    });
  });

  group('the folder helpers agree with each other', () {
    test('normalise keeps a real name and defaults everything unusable', () {
      expect(normalizeDownloadsSubdirectory('素材'), '素材');
      expect(normalizeDownloadsSubdirectory('  素材  '), '素材');
      expect(normalizeDownloadsSubdirectory('素材/2026'), '素材/2026');
      expect(normalizeDownloadsSubdirectory(r'素材\2026'), '素材/2026');
      expect(normalizeDownloadsSubdirectory(null), kLanlinkDownloadsSubdirectory);
      expect(normalizeDownloadsSubdirectory(''), kLanlinkDownloadsSubdirectory);
      expect(normalizeDownloadsSubdirectory(' / . / .. '),
          kLanlinkDownloadsSubdirectory);
    });

    test('label and path follow the same value', () {
      expect(downloadsFolderLabel('素材'), '下载 / 素材');
      expect(downloadsFolderPath('素材'), 'Download/素材');
      expect(downloadsFolderLabel(null), '下载 / lanlink');
      expect(downloadsFolderPath(''), 'Download/lanlink');
    });
  });

  group('ReceivedFilePublisher asks for the CURRENT folder', () {
    test('★ the folder is read at publish time, not captured at construction',
        () async {
      final FakePublicStorage storage = FakePublicStorage(
        publishedPath: '/storage/emulated/0/Download/素材/clip.mp4',
      );
      String current = 'lanlink';
      final ReceivedFilePublisher publisher = ReceivedFilePublisher(
        storage: storage,
        deleteLocalFile: (String path) async {},
        subdirectory: () => current,
      );

      await publisher.publish(
        srcPath: '/private/clip.mp4',
        displayName: 'clip.mp4',
        mime: 'video/mp4',
      );
      // The user picks a new folder while the app is running …
      current = '素材';
      await publisher.publish(
        srcPath: '/private/clip2.mp4',
        displayName: 'clip2.mp4',
        mime: 'video/mp4',
      );

      expect(
        storage.calls.map((({String srcPath, String displayName, String? mime, String subdirectory}) call) => call.subdirectory).toList(),
        <String>['lanlink', '素材'],
        reason: 'a captured folder would keep writing 下载/lanlink after the '
            'user chose 下载/素材 — the 0.2.23 defect in a new place',
      );
    });

    test('without a wired getter it defaults to the shipped folder', () async {
      final FakePublicStorage storage = FakePublicStorage(
        publishedPath: '/storage/emulated/0/Download/lanlink/clip.mp4',
      );
      final ReceivedFilePublisher publisher = ReceivedFilePublisher(
        storage: storage,
        deleteLocalFile: (String path) async {},
      );
      await publisher.publish(
        srcPath: '/private/clip.mp4',
        displayName: 'clip.mp4',
      );
      expect(storage.calls.single.subdirectory, kLanlinkDownloadsSubdirectory);
    });

    test('the recorded path is a real absolute path, never a content:// URI',
        () async {
      // Criterion 1 half: whatever folder the user picks, what goes into the
      // database is a path `File()` can open — that is the whole reason the
      // feature stops at "a folder inside Download".
      final FakePublicStorage storage = FakePublicStorage(
        publishedPath: '/storage/emulated/0/Download/素材/clip.mp4',
      );
      final ReceivedFilePublisher publisher = ReceivedFilePublisher(
        storage: storage,
        deleteLocalFile: (String path) async {},
        subdirectory: () => '素材',
      );
      final PublishedFile published = await publisher.publish(
        srcPath: '/private/clip.mp4',
        displayName: 'clip.mp4',
      );
      expect(published.path, '/storage/emulated/0/Download/素材/clip.mp4');
      expect(published.path, isNot(startsWith('content://')));
      expect(published.path, startsWith('/'));
    });
  });
}
