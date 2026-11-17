/// Unit tests for the **folder tree** (`docs/22` §5.2 / T05, criteria (a) and (b)).
///
/// The tree is derived from `FileAttachment.relativePath` — the only hierarchy
/// data that exists — so these are pure-Dart tests: no widget, no repository. The
/// page is then only presentation, which is the point of keeping the loop out of
/// it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/domain/folder_tree.dart';
import 'package:lanlink_app/domain/models.dart';

FileAttachment _file(String name, {String? at, int size = 100}) =>
    FileAttachment(
      id: 'f-$name-$at',
      messageId: 'm-1',
      fileName: name,
      size: size,
      relativePath: at,
      // Deliberately a **saved** path that has nothing to do with `relativePath`:
      // after publishing, the hierarchy no longer exists on disk (Android flattens
      // it), so the tree must never be tempted to build one from `name`.
      localPath: '/downloads/$name',
    );

/// The names at one level, in the order the page will draw them.
List<String> _names(List<FolderEntry> entries) =>
    entries.map((FolderEntry e) => e.name).toList();

/// The entry called [name] in [entries].
FolderEntry _entry(List<FolderEntry> entries, String name) =>
    entries.firstWhere((FolderEntry e) => e.name == name);

void main() {
  test('★ criterion 2: a/b/sub/deep hierarchy — three levels, one entry each',
      () {
    final List<FolderEntry> root = buildFolderTree(<FileAttachment>[
      _file('a.bin', at: 'a.bin'),
      _file('b.bin', at: 'sub/b.bin'),
      _file('c.bin', at: 'sub/deep/c.bin'),
      _file('e.bin', at: 'sub/e.bin'),
    ]);

    // Root: the loose file + one directory.
    expect(_names(root), <String>['sub', 'a.bin']);
    expect(_entry(root, 'sub').isDirectory, isTrue);
    expect(_entry(root, 'a.bin').isDirectory, isFalse);

    // `sub`: two files (b, e) + one directory (deep).
    final List<FolderEntry> sub = _entry(root, 'sub').children;
    expect(_names(sub), <String>['deep', 'b.bin', 'e.bin']);

    // `deep`: the single file.
    final List<FolderEntry> deep = _entry(sub, 'deep').children;
    expect(_names(deep), <String>['c.bin']);
    expect(deep.single.isDirectory, isFalse);
  });

  test('criterion (a): a directory\'s size is the sum of its subtree',
      () {
    final List<FolderEntry> root = buildFolderTree(<FileAttachment>[
      _file('a.dll', at: 'data/a.dll', size: 10),
      _file('b.dll', at: 'data/b.dll', size: 32),
      _file('x.dll', at: 'x.dll', size: 7),
    ]);

    expect(root, hasLength(2), reason: 'one directory + one loose file');
    final FolderEntry data = _entry(root, 'data');
    expect(data.isDirectory, isTrue);
    expect(data.size, 42, reason: '10 + 32, rolled up');
    expect(data.childCount, 2);
    expect(_entry(root, 'x.dll').size, 7);
  });

  test('criterion (b): directories first, then names ascending, case-insensitive',
      () {
    final List<FolderEntry> root = buildFolderTree(<FileAttachment>[
      _file('zeta.txt', at: 'zeta.txt'),
      _file('Alpha.txt', at: 'Alpha.txt'),
      _file('beta.txt', at: 'beta.txt'),
      _file('zoo.txt', at: 'Zoo/zoo.txt'),
      _file('app.txt', at: 'app/app.txt'),
    ]);

    expect(_names(root), <String>['app', 'Zoo', 'Alpha.txt', 'beta.txt', 'zeta.txt'],
        reason: 'both directories first (app before Zoo), then the files by '
            'folded name (Alpha < beta < zeta)');
  });

  test('a null relativePath lands at the ROOT, under its file name', () {
    // Every pre-0.2.38 row is flat like this, and so are the loose members of a
    // multi-select. Dropping them would make files vanish from the page.
    final List<FolderEntry> root = buildFolderTree(<FileAttachment>[
      _file('loose.png'),
      _file('nested.png', at: 'sub/nested.png'),
    ]);

    expect(_names(root), <String>['sub', 'loose.png']);
    expect(_entry(root, 'loose.png').file?.fileName, 'loose.png');
  });

  test('paths are split on `/` only, and empty / dotted segments are dropped',
      () {
    // A stray leading or doubled separator must not create a nameless level; a
    // Windows-style `\` must not create one either (the sender always joins with
    // `/`, so a backslash is part of a *name*, not a separator).
    final List<FolderEntry> root = buildFolderTree(<FileAttachment>[
      _file('a.txt', at: '/sub//a.txt'),
      _file(r'b.txt', at: r'win\b.txt'),
    ]);

    // The name shown is the **file's own name** (`fileName`), and no `win`
    // directory was invented for the backslash — the whole thing is one segment.
    expect(_names(root), <String>['sub', 'b.txt']);
    expect(_names(_entry(root, 'sub').children), <String>['a.txt']);
  });

  test('an unknown size (-1) counts as 0, never as a negative total', () {
    final List<FolderEntry> root = buildFolderTree(<FileAttachment>[
      _file('unknown.bin', at: 'd/unknown.bin', size: -1),
      _file('known.bin', at: 'd/known.bin', size: 5),
    ]);
    expect(_entry(root, 'd').size, 5);
  });

  test('two files with the same relativePath are both kept', () {
    // A duplicate name is the sender's problem; losing one of them is ours.
    final List<FolderEntry> root = buildFolderTree(<FileAttachment>[
      _file('a.txt', at: 'sub/a.txt', size: 1),
      _file('a.txt', at: 'sub/a.txt', size: 2),
    ]);
    expect(_entry(root, 'sub').childCount, 2);
  });

  test('the input list is not mutated and an empty list yields an empty root',
      () {
    final List<FileAttachment> files = <FileAttachment>[
      _file('b.bin', at: 'z/b.bin'),
      _file('a.bin', at: 'z/a.bin'),
    ];
    final List<FileAttachment> before = List<FileAttachment>.of(files);
    buildFolderTree(files);
    expect(files, before, reason: 'pure: the caller keeps its order');

    expect(buildFolderTree(const <FileAttachment>[]), isEmpty);
  });
}
