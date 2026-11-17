/// 0.2.33 — the wire contract of 「发送文件夹」 between Kotlin and Dart.
///
/// The native side answers with a map; [`AndroidFolderPicker.parseSendFolderReply`]
/// turns it into a decision. Every branch is a place where a wrong reading would
/// be silent:
///
/// * `ok` **without** a usable path must not become "a successful send of zero
///   files" (that is the shape of bug this project keeps deleting);
/// * `too_many` must keep the count and the cap flag, because they are the whole
///   message the user sees;
/// * anything unrecognised (a stale APK, a renamed key) must fail loudly in the
///   UI, never default to "send".
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/real/android_folder_picker.dart';
import 'package:lanlink_app/domain/folder_send.dart';

Map<Object?, Object?> _reply(Map<String, Object?> values) =>
    Map<Object?, Object?>.from(values);

void main() {
  test('a real answer carries the paths, the size and every skip count', () {
    final SendFolderSelection selection =
        AndroidFolderPicker.parseSendFolderReply(
      _reply(<String, Object?>{
        'result': 'ok',
        'paths': <String>['/cache/a.jpg', '/cache/b.jpg'],
        'totalBytes': 4096,
        'skippedHidden': 2,
        'skippedEmpty': 1,
        'skippedTooDeep': 3,
        'failed': 1,
        'folderName': '素材',
      }),
    );

    expect(selection.outcome, PickSendFolderOutcome.picked);
    expect(selection.paths, <String>['/cache/a.jpg', '/cache/b.jpg']);
    expect(selection.totalBytes, 4096);
    expect(selection.skippedHidden, 2);
    expect(selection.skippedEmpty, 1);
    expect(selection.skippedTooDeep, 3);
    expect(selection.failedCopies, 1);
    expect(selection.folderName, '素材');
    expect(selection.canSend, isTrue);
    expect(selection.fileCount, 2);
  });

  // CR-2 ② — the native walk has no notion of the receiver's 180-character
  // budget (SAF gives it tree URIs, not paths), so the same judgement the
  // desktop walk applies while scanning is applied here after the fact.
  test('★ a position the receiver cannot place is dropped from the batch and '
      'counted — the other files still go', () {
    final String tooLong = 'x' * 190;
    final SendFolderSelection selection =
        AndroidFolderPicker.parseSendFolderReply(
      _reply(<String, Object?>{
        'result': 'ok',
        'paths': <String>['/cache/a.jpg', '/cache/$tooLong', '/cache/b.jpg'],
        'relativePaths': <String>['a.jpg', tooLong, 'b.jpg'],
        'totalBytes': 4096,
        'folderName': '素材',
      }),
    );

    expect(selection.outcome, PickSendFolderOutcome.picked);
    expect(selection.paths, <String>['/cache/a.jpg', '/cache/b.jpg'],
        reason: '★ one bad position may not take the whole batch with it');
    expect(selection.relativePaths, <String>['a.jpg', 'b.jpg']);
    expect(selection.skippedPathTooLong, 1);
    expect(selection.availableCount, 2);
    expect(selection.canSend, isTrue);
  });

  test('★ a batch of nothing but unplaceable positions reads as empty, with the '
      'count that explains it', () {
    final String tooLong = 'x' * 190;
    final SendFolderSelection selection =
        AndroidFolderPicker.parseSendFolderReply(
      _reply(<String, Object?>{
        'result': 'ok',
        'paths': <String>['/cache/$tooLong'],
        'relativePaths': <String>[tooLong],
        'totalBytes': 4096,
      }),
    );
    expect(selection.outcome, PickSendFolderOutcome.empty);
    expect(selection.skippedPathTooLong, 1,
        reason: 'an empty batch still has to say why it is empty');
    expect(selection.canSend, isFalse);
  });

  test('★ "ok" with no usable path is EMPTY, never a zero-file success', () {
    for (final Object? paths in <Object?>[
      null,
      <String>[],
      <String>[''],
      'not-a-list',
    ]) {
      final SendFolderSelection selection =
          AndroidFolderPicker.parseSendFolderReply(
        _reply(<String, Object?>{'result': 'ok', 'paths': paths}),
      );
      expect(selection.outcome, PickSendFolderOutcome.empty,
          reason: 'paths=$paths must not read as a successful send');
      expect(selection.canSend, isFalse);
    }
  });

  test('a cancelled chooser is its own outcome — not an error', () {
    expect(
      AndroidFolderPicker.parseSendFolderReply(
        _reply(<String, Object?>{'result': 'cancelled'}),
      ).outcome,
      PickSendFolderOutcome.cancelled,
    );
  });

  test('★ too_many keeps the real count and the cap flag', () {
    final SendFolderSelection capped = AndroidFolderPicker.parseSendFolderReply(
      _reply(<String, Object?>{
        'result': 'too_many',
        'availableCount': 2000,
        'countCapped': true,
        'folderName': '相册',
      }),
    );
    expect(capped.outcome, PickSendFolderOutcome.tooMany);
    expect(capped.availableCount, 2000);
    expect(capped.countCapped, isTrue);
    expect(capped.folderName, '相册');
    expect(capped.canSend, isFalse);

    final SendFolderSelection exact = AndroidFolderPicker.parseSendFolderReply(
      _reply(<String, Object?>{
        'result': 'too_many',
        'availableCount': 300,
        'countCapped': false,
      }),
    );
    expect(exact.availableCount, 300);
    expect(exact.countCapped, isFalse);
  });

  test('empty carries the skip counts that explain it', () {
    final SendFolderSelection empty = AndroidFolderPicker.parseSendFolderReply(
      _reply(<String, Object?>{
        'result': 'empty',
        'skippedHidden': 4,
        'skippedEmpty': 2,
        'skippedTooDeep': 1,
        'folderName': '素材',
      }),
    );
    expect(empty.outcome, PickSendFolderOutcome.empty);
    expect(empty.skippedHidden, 4);
    expect(empty.skippedEmpty, 2);
    expect(empty.skippedTooDeep, 1);
  });

  test('numbers arriving as doubles (a JSON round-trip) are still numbers', () {
    final SendFolderSelection selection =
        AndroidFolderPicker.parseSendFolderReply(
      _reply(<String, Object?>{
        'result': 'too_many',
        'availableCount': 512.0,
      }),
    );
    expect(selection.availableCount, 512);
  });

  test('unsupported / failed / nonsense all end with nothing sent', () {
    expect(
      AndroidFolderPicker.parseSendFolderReply(
        _reply(<String, Object?>{'result': 'unsupported'}),
      ).outcome,
      PickSendFolderOutcome.unsupported,
    );
    final SendFolderSelection failed = AndroidFolderPicker.parseSendFolderReply(
      _reply(<String, Object?>{'result': 'failed', 'reason': 'provider 拒绝了'}),
    );
    expect(failed.outcome, PickSendFolderOutcome.failed);
    expect(failed.reason, 'provider 拒绝了');

    for (final Object? reply in <Object?>[
      null,
      'ok',
      _reply(<String, Object?>{}),
      _reply(<String, Object?>{'result': 'OK'}),
      _reply(<String, Object?>{'result': 'whatever'}),
    ]) {
      final SendFolderSelection selection =
          AndroidFolderPicker.parseSendFolderReply(reply);
      expect(selection.outcome, isNot(PickSendFolderOutcome.picked),
          reason: 'reply $reply must not be read as a choice');
      expect(selection.canSend, isFalse);
    }
  });

  // ---------------------------------------------------------------------
  // T03 (b) — the parallel `relativePaths` array (0.2.38).
  //
  // Every degraded case below asserts **three** things, not one:
  //   1. the outcome is still `picked` (a bad hierarchy is not a bad pick);
  //   2. **the files are still there** — `relativePath == null` must not be
  //      confused with "nothing was sent", which is how an implementation that
  //      simply discards the batch would also pass a lazier assertion;
  //   3. the positions all came back null.
  // ---------------------------------------------------------------------
  group('T03 (b): relativePaths', () {
    /// Asserts the degradation: every file kept, no position kept.
    void expectFlatButSent(
      SendFolderSelection selection,
      List<String> expectedPaths,
    ) {
      expect(selection.outcome, PickSendFolderOutcome.picked);
      expect(selection.canSend, isTrue);
      expect(selection.paths, expectedPaths,
          reason: '★ a reply without usable positions must still send every file');
      expect(selection.fileCount, expectedPaths.length);
      expect(selection.relativePaths, isNull);
      expect(selection.lostHierarchy, isTrue);
      for (final FolderScanFile file in selection.files) {
        expect(file.relativePath, isNull);
      }
    }

    const List<String> paths = <String>[
      '/cache/a.txt',
      '/cache/b.txt',
      '/cache/c.txt',
    ];

    test('an aligned array is zipped positionally', () {
      final SendFolderSelection selection =
          AndroidFolderPicker.parseSendFolderReply(
        _reply(<String, Object?>{
          'result': 'ok',
          'paths': paths,
          'relativePaths': <String>['a.txt', 'sub/b.txt', 'sub/deep/c.txt'],
          'folderName': '素材',
        }),
      );

      expect(selection.relativePaths,
          <String>['a.txt', 'sub/b.txt', 'sub/deep/c.txt']);
      expect(selection.lostHierarchy, isFalse);
      // Zipped *by index*, so the two arrays describe the same file.
      for (int index = 0; index < paths.length; index++) {
        expect(selection.files[index].path, paths[index]);
      }
    });

    test('★ missing → every file still sent, every position null', () {
      expectFlatButSent(
        AndroidFolderPicker.parseSendFolderReply(
          _reply(<String, Object?>{'result': 'ok', 'paths': paths}),
        ),
        paths,
      );
    });

    test('★ wrong length (shorter or longer) → all null, files still sent', () {
      for (final List<String> wrong in <List<String>>[
        <String>['a.txt'],
        <String>['a.txt', 'b.txt'],
        <String>['a.txt', 'b.txt', 'c.txt', 'd.txt'],
        <String>[],
      ]) {
        expectFlatButSent(
          AndroidFolderPicker.parseSendFolderReply(
            _reply(<String, Object?>{
              'result': 'ok',
              'paths': paths,
              'relativePaths': wrong,
            }),
          ),
          paths,
          // A partially-understood parallel array has no safe reading: sliding
          // one against the other is how file A gets recorded under file B's
          // name, which is far worse than a flat send.
        );
      }
    });

    test('★ any non-string entry → the whole batch is flat', () {
      for (final Object? bad in <Object?>[42, null, '', <String>['x']]) {
        expectFlatButSent(
          AndroidFolderPicker.parseSendFolderReply(
            _reply(<String, Object?>{
              'result': 'ok',
              'paths': paths,
              'relativePaths': <Object?>['a.txt', bad, 'c.txt'],
            }),
          ),
          paths,
        );
      }
    });

    test('★ relativePaths that is not a list at all → flat', () {
      for (final Object? notAList in <Object?>['a.txt', 7, <Object?, Object?>{}]) {
        expectFlatButSent(
          AndroidFolderPicker.parseSendFolderReply(
            _reply(<String, Object?>{
              'result': 'ok',
              'paths': paths,
              'relativePaths': notAList,
            }),
          ),
          paths,
        );
      }
    });

    test('★ an unusable path is dropped from BOTH arrays, so the pairing holds',
        () {
      // The host can emit an empty path (a copy that produced nothing). Dropping
      // it from `paths` alone would slide every later position by one; zipping
      // by index means the survivor keeps *its own* position.
      final SendFolderSelection selection =
          AndroidFolderPicker.parseSendFolderReply(
        _reply(<String, Object?>{
          'result': 'ok',
          'paths': <String>['', '/cache/b.txt', '/cache/c.txt'],
          'relativePaths': <String>['a.txt', 'sub/b.txt', 'sub/deep/c.txt'],
        }),
      );

      expect(selection.outcome, PickSendFolderOutcome.picked);
      expect(selection.paths, <String>['/cache/b.txt', '/cache/c.txt']);
      expect(selection.relativePaths, <String>['sub/b.txt', 'sub/deep/c.txt'],
          reason: 'b.txt must keep sub/b.txt — not a.txt');
    });
  });
}
