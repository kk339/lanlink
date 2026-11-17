/// 0.2.33 — 「发送整个文件夹」 的**判断层**：走多深、发几个、跳过什么、什么时候
/// 必须停下来问用户。
///
/// 这些用例跑的是纯函数（[scanFolderForSending]），注入的是内存里的假目录树，
/// 所以它们描述的是**策略**而不是某台机器：桌面（`dart:io`）与 Android
/// （`DocumentsContract`，原生侧同一套数字）都必须满足同一组断言。
///
/// 最要紧的两条：
///  * **超限不截断**——201 个文件的目录必须整批拒绝，绝不能"悄悄发 200 个"；
///  * **跳过要计数**——隐藏文件与 0 字节文件不发，但少发了几个必须在确认框里
///    说得出来。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_core/lanlink_core.dart' show kMaxRelativePathChars;

import 'package:lanlink_app/data/real/receiver_path_budget.dart';
import 'package:lanlink_app/domain/folder_send.dart';

/// Builds a lister over an in-memory tree: `absolute path -> direct children`.
FolderLister _listerOf(Map<String, List<FolderEntry>> tree) {
  return (String path) async => tree[path] ?? const <FolderEntry>[];
}

FolderEntry _dir(String parent, String name) => FolderEntry(
      name: name,
      path: '$parent/$name',
      isDirectory: true,
    );

FolderEntry _file(String parent, String name, {int size = 1024}) => FolderEntry(
      name: name,
      path: '$parent/$name',
      isDirectory: false,
      size: size,
    );

void main() {
  test('★ criterion 1: three files, one of them one level down, all included',
      () async {
    const String root = '/素材';
    final FolderScan scan = await scanFolderForSending(
      root: root,
      list: _listerOf(<String, List<FolderEntry>>{
        root: <FolderEntry>[
          _file(root, 'a.jpg', size: 1000),
          _file(root, 'b.jpg', size: 2000),
          _dir(root, '2026'),
        ],
        '$root/2026': <FolderEntry>[_file('$root/2026', 'c.jpg', size: 3000)],
      }),
    );

    expect(scan.paths, <String>[
      '$root/a.jpg',
      '$root/b.jpg',
      '$root/2026/c.jpg',
    ]);
    expect(scan.totalBytes, 6000);
    expect(scan.availableCount, 3);
    expect(scan.tooMany, isFalse);
    expect(scan.skippedHidden, 0);
    expect(scan.skippedEmpty, 0);
  });

  test('★ criterion 2: 201 files is refused WHOLE — paths stop at 200 but the '
      'count tells the truth, so the caller can refuse the batch', () async {
    const String root = '/big';
    final FolderScan scan = await scanFolderForSending(
      root: root,
      list: _listerOf(<String, List<FolderEntry>>{
        root: <FolderEntry>[
          for (int i = 0; i < 201; i++) _file(root, 'p$i.jpg'),
        ],
      }),
    );

    expect(scan.tooMany, isTrue, reason: 'over the limit ⇒ the caller sends nothing');
    expect(scan.availableCount, 201,
        reason: 'the number shown to the user must be the real one, not 200');
    expect(scan.paths, hasLength(kFolderSendMaxFiles),
        reason: 'the scan still stops collecting at the limit — it just does '
            'not pretend that is all there was');
  });

  test('★ criterion 4: hidden entries and 0-byte files are skipped — and counted',
      () async {
    const String root = '/mix';
    final FolderScan scan = await scanFolderForSending(
      root: root,
      list: _listerOf(<String, List<FolderEntry>>{
        root: <FolderEntry>[
          _file(root, '.DS_Store', size: 6000),
          _dir(root, '.thumbnails'),
          _file(root, 'empty.jpg', size: 0),
          _file(root, 'real.jpg', size: 4000),
        ],
        // A hidden directory is not descended at all (its contents never count).
        '$root/.thumbnails': <FolderEntry>[
          _file('$root/.thumbnails', 'x.jpg'),
        ],
      }),
    );

    expect(scan.paths, <String>['$root/real.jpg']);
    expect(scan.skippedHidden, 2, reason: 'the dot-file AND the dot-directory');
    expect(scan.skippedEmpty, 1);
    expect(scan.availableCount, 1);
  });

  test('★ T03 (a): the relative path is root-relative, `/`-separated, and does '
      'not repeat the root name', () async {
    const String root = '/root';
    final FolderScan scan = await scanFolderForSending(
      root: root,
      list: _listerOf(<String, List<FolderEntry>>{
        root: <FolderEntry>[_file(root, 'a.txt'), _dir(root, 'sub')],
        '$root/sub': <FolderEntry>[
          _file('$root/sub', 'b.txt'),
          _dir('$root/sub', 'deep'),
        ],
        '$root/sub/deep': <FolderEntry>[_file('$root/sub/deep', 'c.txt')],
      }),
    );

    expect(scan.paths, <String>[
      '$root/a.txt',
      '$root/sub/b.txt',
      '$root/sub/deep/c.txt',
    ]);
    expect(
      <String?>[for (final FolderScanFile file in scan.files) file.relativePath],
      <String>['a.txt', 'sub/b.txt', 'sub/deep/c.txt'],
    );
    for (final FolderScanFile file in scan.files) {
      // The three things that would make the receiver build the wrong tree:
      // repeating the root name, a leading separator, and a platform separator.
      expect(file.relativePath, isNot(contains('root')));
      expect(file.relativePath!.startsWith('/'), isFalse,
          reason: 'a leading `/` reads as an absolute path — refused by 400');
      expect(file.relativePath, isNot(contains('\\')),
          reason: 'the wire form is `/` on every platform (docs/22 §4.3a)');
    }
    expect(<int>[for (final FolderScanFile file in scan.files) file.size],
        <int>[1024, 1024, 1024]);
  });

  test('★ depth: 6 levels are walked, the 7th is not — and the stop is counted',
      () async {
    // 0.2.38 raised the limit from 3 to 6 (a real delivery tree,
    // `2026/10/素材/角色/立绘/x.png`, is already 5 deep). This pins the **new**
    // number rather than dropping the old assertion: level 6 must be collected
    // (with its relative path intact) and level 7 must be both unentered and
    // counted.
    const String root = '/deep';
    final FolderScan scan = await scanFolderForSending(
      root: root,
      list: _listerOf(<String, List<FolderEntry>>{
        root: <FolderEntry>[_dir(root, 'l1'), _file(root, 'top.jpg')],
        '$root/l1': <FolderEntry>[_dir('$root/l1', 'l2')],
        '$root/l1/l2': <FolderEntry>[_dir('$root/l1/l2', 'l3')],
        '$root/l1/l2/l3': <FolderEntry>[_dir('$root/l1/l2/l3', 'l4')],
        '$root/l1/l2/l3/l4': <FolderEntry>[_dir('$root/l1/l2/l3/l4', 'l5')],
        '$root/l1/l2/l3/l4/l5': <FolderEntry>[_dir('$root/l1/l2/l3/l4/l5', 'l6')],
        // Level 6: collected.
        '$root/l1/l2/l3/l4/l5/l6': <FolderEntry>[
          _file('$root/l1/l2/l3/l4/l5/l6', 'deep-ok.jpg'),
          _dir('$root/l1/l2/l3/l4/l5/l6', 'l7'),
        ],
        // Level 7: would only be read by a 7-deep walk.
        '$root/l1/l2/l3/l4/l5/l6/l7': <FolderEntry>[
          _file('$root/l1/l2/l3/l4/l5/l6/l7', 'too-deep.jpg'),
        ],
      }),
    );

    expect(scan.paths, <String>[
      '$root/top.jpg',
      '$root/l1/l2/l3/l4/l5/l6/deep-ok.jpg',
    ]);
    expect(scan.skippedTooDeep, 1,
        reason: 'l6 is at depth 6, so l7 is not entered — and that is counted, '
            'not silently dropped');
    expect(
      scan.files.last.relativePath,
      'l1/l2/l3/l4/l5/l6/deep-ok.jpg',
      reason: 'six levels down, the relative path still has to be complete',
    );
  });

  // -------------------------------------------------------------------
  // CR-2 ② — the sender must not offer what the receiver will refuse.
  // -------------------------------------------------------------------
  test('★ a file whose path does not fit the receiver is skipped, the rest is '
      'sent', () async {
    // The receiver's rules (`core/lib/src/security/relative_path.dart`) refuse
    // the **whole batch** with `400 malformed prepare frame` when a single path
    // breaks them — over the character budget, too many segments, or a segment
    // that cleans away to nothing. Before this, the sender had no idea any
    // budget existed (its only limit was "depth 6"), so one long directory name
    // killed a 200-file folder *after* every file had been read and hashed, and
    // the failure it produced could not say why.
    const String root = '/mix';
    final String tooLong = 'x' * 190; // over the receiver's 180-character budget
    final FolderScan scan = await scanFolderForSending(
      root: root,
      list: _listerOf(<String, List<FolderEntry>>{
        root: <FolderEntry>[
          _file(root, 'ok-1.jpg'),
          _file(root, tooLong),
          _file(root, 'ok-2.jpg'),
        ],
      }),
      rejectsPath: receiverRejectsPath,
    );

    expect(scan.paths, <String>['$root/ok-1.jpg', '$root/ok-2.jpg'],
        reason: '★ the two normal files must still go — one oversized path may '
            'not take the whole batch with it');
    expect(scan.skippedPathTooLong, 1,
        reason: 'and the one that was dropped is counted, not silently lost');
    expect(scan.availableCount, 2,
        reason: 'a file the receiver cannot place is not one of "the 200 we '
            'were going to send"');
    expect(scan.tooMany, isFalse);
    expect(scan.totalBytes, 2048, reason: 'the skipped file is not in the total');
  });

  test('★ regression: a legal 6-deep, ~170-character path is not skipped',
      () async {
    // The boundary is the receiver's budget and nothing else. A tree that is as
    // deep as the walk allows and nearly as long as the budget allows must come
    // through untouched — a prefilter that quietly eats real files is worse than
    // the failure it replaces.
    const String root = '/deep';
    final String level = 'd' * 30; // 5 levels x 30 + 5 separators + 8 = 163
    final FolderScan scan = await scanFolderForSending(
      root: root,
      list: _listerOf(<String, List<FolderEntry>>{
        root: <FolderEntry>[_dir(root, level)],
        '$root/$level': <FolderEntry>[_dir('$root/$level', level)],
        '$root/$level/$level': <FolderEntry>[
          _dir('$root/$level/$level', level),
        ],
        '$root/$level/$level/$level': <FolderEntry>[
          _dir('$root/$level/$level/$level', level),
        ],
        '$root/$level/$level/$level/$level': <FolderEntry>[
          _dir('$root/$level/$level/$level/$level', level),
        ],
        '$root/$level/$level/$level/$level/$level': <FolderEntry>[
          _file('$root/$level/$level/$level/$level/$level', 'file.jpg'),
        ],
      }),
      rejectsPath: receiverRejectsPath,
    );

    expect(scan.files, hasLength(1));
    expect(scan.skippedPathTooLong, 0);
    final String rel = scan.files.single.relativePath!;
    expect(rel, '$level/$level/$level/$level/$level/file.jpg');
    expect(rel.length, 163,
        reason: 'six segments, comfortably inside 180 — the boundary is not a '
            'rounding of "about as long as a name may be"');
  });

  test('★ the budget is core\'s, not a second copy', () {
    // Two numbers called "180" in two packages is precisely how the sender and
    // the receiver drift apart. The predicate reads `kMaxRelativePathChars`
    // from `lanlink_core`, so this test would fail the moment it were copied.
    expect(receiverRejectsPath('a' * kMaxRelativePathChars), isFalse);
    expect(receiverRejectsPath('a' * (kMaxRelativePathChars + 1)), isTrue);
    // …and every other refusal the receiver can make is caught here too, because
    // the judgement itself is `normalizeRelativePath`.
    expect(receiverRejectsPath('a/b/c/d/e/f/g/h/i'), isTrue,
        reason: '9 segments — the receiver answers 400 for the whole batch');
    expect(receiverRejectsPath('a/.../b.bin'), isTrue,
        reason: 'a segment that cleans away to nothing is refused, not fixed');
    // `null` is "position unknown" (a flat send): nothing to judge.
    expect(receiverRejectsPath(null), isFalse);
  });

  test('an empty folder is empty, not an error', () async {
    final FolderScan scan = await scanFolderForSending(
      root: '/empty',
      list: _listerOf(<String, List<FolderEntry>>{}),
    );
    expect(scan.paths, isEmpty);
    expect(scan.isEmpty, isTrue);
    expect(scan.tooMany, isFalse);
    expect(scan.availableCount, 0);
  });

  test('a folder of only hidden / empty files also reads as empty', () async {
    const String root = '/nothing';
    final FolderScan scan = await scanFolderForSending(
      root: root,
      list: _listerOf(<String, List<FolderEntry>>{
        root: <FolderEntry>[
          _file(root, '.hidden'),
          _file(root, 'zero', size: 0),
        ],
      }),
    );
    expect(scan.isEmpty, isTrue);
    expect(scan.skippedHidden, 1);
    expect(scan.skippedEmpty, 1);
  });

  test('counting stops at the cap — a 2500-file folder does not take forever '
      'just to print a number', () async {
    const String root = '/huge';
    final FolderScan scan = await scanFolderForSending(
      root: root,
      list: _listerOf(<String, List<FolderEntry>>{
        root: <FolderEntry>[
          for (int i = 0; i < kFolderSendCountCap + 500; i++) _file(root, 'p$i'),
        ],
      }),
    );

    expect(scan.countCapped, isTrue);
    expect(scan.availableCount, kFolderSendCountCap);
    expect(scan.tooMany, isTrue);
    expect(scan.paths, hasLength(kFolderSendMaxFiles));
  });

  test('a directory that cannot be listed throws — it must not look empty', () async {
    // "Could not read" and "nothing in it" are different things to a user.
    expect(
      () => scanFolderForSending(
        root: '/denied',
        list: (String path) async => throw const _Boom(),
      ),
      throwsA(isA<_Boom>()),
    );
  });

  test('the limits are the documented ones', () {
    // 0.2.38: 3 → 6, a ruling (docs/22 §6·T03). The file and count limits below
    // are unchanged on purpose — depth is what was too shallow, not breadth.
    expect(kFolderSendMaxDepth, 6);
    expect(kFolderSendMaxFiles, 200);
    expect(kFolderSendCountCap, greaterThan(kFolderSendMaxFiles));
  });
}

class _Boom implements Exception {
  const _Boom();
}
