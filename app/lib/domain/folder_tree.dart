/// The **folder tree** behind the directory page — pure Dart, one function
/// (`docs/22` §5.2 / T05).
///
/// A folder message is one row in `messages` plus N rows in `files`, and each of
/// those files carries the sender's `relativePath` (`sub/deep/c.bin`). That is
/// the only hierarchy information that exists anywhere — the wire has no
/// directory objects, and the saved paths are flat on Android by design
/// (`Download/<子目录>/`, `docs/22` §4.3). So the tree is **derived**, and it is
/// derived here rather than inside the page: a widget that owned this loop could
/// not be tested without pumping one, and the two views that need it (the page
/// and the size roll-up) would slowly disagree.
///
/// **Layering (§8.1):** imports nothing but `models.dart` — no Flutter, no
/// `dart:io`, no `package:path`. Paths are split on `/` by hand on purpose:
/// `package:path` would normalise against the *host* separator, and a Windows
/// `\` arriving in a `relativePath` must never be treated as a directory
/// boundary by accident (the sender always joins with `/`, `docs/22` §3.2).
library;

import 'models.dart';

/// One row of a directory: either a sub-folder or a file.
///
/// A **file** node holds the [FileAttachment] itself, so the page can open it
/// (`localPath` — never `relativePath`, see [FolderEntry.isDirectory]) and show
/// its size/time without a second lookup.
class FolderEntry {
  /// Creates an entry. Use [FolderEntry.file] / [FolderEntry.directory].
  const FolderEntry._({
    required this.name,
    required this.isDirectory,
    required this.size,
    this.file,
    this.children = const <FolderEntry>[],
  });

  /// A file row.
  factory FolderEntry.file(FileAttachment file) => FolderEntry._(
        name: file.fileName,
        isDirectory: false,
        size: file.size < 0 ? 0 : file.size,
        file: file,
      );

  /// A directory row whose [size] is the sum of everything below it.
  factory FolderEntry.directory(String name, List<FolderEntry> children) =>
      FolderEntry._(
        name: name,
        isDirectory: true,
        size: children.fold<int>(0, (int sum, FolderEntry e) => sum + e.size),
        children: children,
      );

  /// The last path segment — what the row prints.
  final String name;

  /// Whether this is a sub-folder (`Icons.folder`, and tapping it goes **down**
  /// instead of opening a file).
  final bool isDirectory;

  /// Bytes: the file's own size, or the rolled-up size of a directory.
  ///
  /// `size < 0` on the wire means "unknown" (E7) and is counted as **0** here —
  /// the page never prints a negative number, and a sum of unknowns is honestly
  /// "at least this much", which is why the card itself does not use this to
  /// decide anything.
  final int size;

  /// The attachment behind a file row; `null` for a directory.
  ///
  /// **Never derive a path from [name] or from `relativePath`** — open the file
  /// with `file.localPath` (`docs/22` §5.2: after publishing, `relativePath`
  /// no longer points at the disk).
  final FileAttachment? file;

  /// Children of a directory, already sorted (see [buildFolderTree]); empty for
  /// a file.
  final List<FolderEntry> children;

  /// The number of entries directly inside this directory (0 for a file).
  int get childCount => children.length;

  @override
  String toString() => 'FolderEntry($name, dir: $isDirectory, size: $size, '
      'children: ${children.length})';
}

/// Builds the tree of [files] and returns the **root** level, already sorted.
///
/// Rules, each of which a test pins:
/// * a `relativePath` is split on `/`; a leading/trailing/doubled `/` is dropped
///   (`/a//b` and `a/b` are the same path);
/// * `relativePath == null` (a flat member — every pre-0.2.38 row, and the
///   loose files of an old send) lands at the **root**, under its `fileName`.
///   Dropping it would silently hide files from the page;
/// * a **directory sorts before a file**, then by name, case-insensitively —
///   which is why `data/` sits on top in the reference screenshot;
/// * two files with the same `relativePath` are both kept (a duplicate name is
///   the sender's problem; losing one is ours);
/// * an empty file name (`relativePath: ''`) is ignored rather than becoming a
///   nameless row.
///
/// The result is a fresh tree — [files] is not mutated, and the nested lists are
/// safe to keep across rebuilds.
List<FolderEntry> buildFolderTree(List<FileAttachment> files) {
  final _DirNode root = _DirNode.root();
  for (final FileAttachment file in files) {
    final List<String> segments = _segments(file.relativePath, file.fileName);
    if (segments.isEmpty) {
      continue;
    }
    _DirNode dir = root;
    for (final String segment in segments.take(segments.length - 1)) {
      dir = dir.subdirectory(segment);
    }
    dir.files.add(file);
  }
  return _materialize(root);
}

/// Splits a `relativePath` into its segments, falling back to [fileName].
List<String> _segments(String? relativePath, String fileName) {
  final String source =
      (relativePath == null || relativePath.trim().isEmpty)
          ? fileName
          : relativePath;
  final List<String> out = <String>[];
  for (final String raw in source.split('/')) {
    final String segment = raw.trim();
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    out.add(segment);
  }
  return out;
}

/// One directory while the tree is being built (a mutable scratch node).
class _DirNode {
  _DirNode(this.name);

  _DirNode.root() : name = '';

  final String name;
  final Map<String, _DirNode> dirs = <String, _DirNode>{};
  final List<FileAttachment> files = <FileAttachment>[];

  _DirNode subdirectory(String segment) =>
      dirs.putIfAbsent(segment, () => _DirNode(segment));
}

/// Turns a scratch node into the immutable, sorted [FolderEntry] list.
List<FolderEntry> _materialize(_DirNode node) {
  final List<FolderEntry> out = <FolderEntry>[
    for (final _DirNode child in node.dirs.values)
      FolderEntry.directory(child.name, _materialize(child)),
    for (final FileAttachment file in node.files) FolderEntry.file(file),
  ];
  out.sort(_byDirectoryThenName);
  return out;
}

/// Directories first, then by name, case-insensitively (`docs/22` §5.2).
///
/// The `name` comparison is the **folded** one so `Data` and `data` cannot end up
/// in different halves of the list; equal names keep their build order, which is
/// what makes the function deterministic without relying on a stable sort.
int _byDirectoryThenName(FolderEntry a, FolderEntry b) {
  if (a.isDirectory != b.isDirectory) {
    return a.isDirectory ? -1 : 1;
  }
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
