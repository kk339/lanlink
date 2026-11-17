/// The native [PickedCachePort]: remove the app's own copies of picked / shared
/// files (0.2.23).
///
/// **Layering (M4 §8.1):** `data/real/**` — the only layer allowed to import
/// `dart:io` / `path_provider`. Referenced only by
/// `bootstrap/create_deps_native.dart`, so the Web build never parses it.
///
/// **Why no `MethodChannel`.** The Android host writes these copies into
/// `context.cacheDir/lanlink-picked/<uuid>/`, and `path_provider`'s
/// `getTemporaryDirectory()` answers exactly `context.cacheDir` — so the Dart
/// side already knows the root and can delete with `dart:io`. A channel method
/// would add a second implementation of the same rule (and a second place for
/// "which directory is ours" to drift), for no capability gain.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/picked_cache.dart';
import '../../domain/session_repository.dart';

/// Deletes `<temporary directory>/lanlink-picked/**`, and nothing else.
class PickedFileCache implements PickedCachePort {
  /// Creates the cleaner.
  ///
  /// [temporaryDirectory] is injectable so a test can point the sweep at a real
  /// temporary tree it created itself (the default is `path_provider`, which a
  /// unit test has no plugin for). [onLog] receives one line per deletion
  /// failure — the diagnostic channel the user can read back; nothing here is
  /// allowed to throw into a caller.
  PickedFileCache({
    Future<Directory> Function()? temporaryDirectory,
    void Function(String message)? onLog,
  })  : _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
        _onLog = onLog;

  final Future<Directory> Function() _temporaryDirectory;
  final void Function(String message)? _onLog;

  @override
  Future<void> discard(Iterable<String> paths) async {
    final String? root = await _root();
    if (root == null) {
      return;
    }
    final Set<String> directories = <String>{};
    for (final String path in paths) {
      final String? owner = owningDirectory(root: root, path: path);
      if (owner != null) {
        directories.add(owner);
      }
    }
    for (final String directory in directories) {
      await _deleteTree(directory);
    }
  }

  @override
  Future<void> clear({Set<String> keep = const <String>{}}) async {
    final String? root = await _root();
    if (root == null) {
      return;
    }
    // ★ 0.2.52 — **the retention set.** A queued message's copy is the only
    // bytes this app can still upload, so it must survive the launch sweep; the
    // set is turned into per-send *directories* here, once, so the loop below
    // only ever compares one normalised path with another.
    final Set<String> keptDirectories = <String>{};
    for (final String path in keep) {
      final String? owner = owningDirectory(root: root, path: path);
      if (owner != null) {
        keptDirectories.add(p.normalize(owner));
      }
    }

    final List<FileSystemEntity> entries;
    try {
      final Directory directory = Directory(root);
      if (!await directory.exists()) {
        return;
      }
      entries = await directory.list(followLinks: false).toList();
    } on Object catch (error) {
      _log('CACHE 列不出缓存目录，跳过清理（$root，$error）');
      return;
    }

    for (final FileSystemEntity entry in entries) {
      final String path = p.normalize(entry.path);
      if (keptDirectories.contains(path)) {
        _log('CACHE 启动清理保留（还在排队）：$path');
        continue;
      }
      await _deleteTree(path);
    }

    // The old behaviour — the whole tree goes — is kept for the ordinary case:
    // with nothing retained the root itself is a leftover rather than a useful
    // directory. Only an *empty* root is removed, so a retained copy always has
    // a parent to live in.
    await _deleteIfEmpty(root);
  }

  /// Deletes [path] when it is an empty directory, and stays silent when it is
  /// not (something is still in it — that something was retained on purpose).
  Future<void> _deleteIfEmpty(String path) async {
    try {
      final Directory directory = Directory(path);
      if (!await directory.exists()) {
        return;
      }
      if (await directory.list(followLinks: false).isEmpty) {
        await directory.delete();
      }
    } on Object {
      // A cache directory that cannot be tidied is not an error worth a line.
    }
  }

  /// The per-send cache directory [path] belongs to, or `null` when [path] is
  /// **not** one of this app's copies.
  ///
  /// This is the function the whole safety story rests on, so it is pure,
  /// static and directly testable:
  ///
  /// * a path outside [root] → `null` (the user's own file — never touched);
  /// * [root] itself → `null` (the sweep directory is [clear]'s business);
  /// * `<root>/<uuid>/…` → `<root>/<uuid>` (exactly one per-send directory).
  ///
  /// `..` cannot escape: [p.normalize] collapses it **before** the containment
  /// test, so `<root>/../../sdcard/DCIM/x.jpg` normalises to a path outside
  /// [root] and is refused.
  static String? owningDirectory({required String root, required String path}) {
    if (path.isEmpty) {
      return null;
    }
    final String normalizedRoot = p.normalize(p.absolute(root));
    final String candidate = p.normalize(p.absolute(path));
    if (candidate == normalizedRoot || !p.isWithin(normalizedRoot, candidate)) {
      return null;
    }
    final List<String> segments = p.split(p.relative(candidate, from: normalizedRoot));
    if (segments.isEmpty) {
      return null;
    }
    final String top = segments.first;
    if (top.isEmpty || top == '.' || top == '..') {
      return null;
    }
    return p.join(normalizedRoot, top);
  }

  /// `<temporary directory>/lanlink-picked`, or `null` when the platform cannot
  /// tell us its temporary directory (nothing to clean then, and nothing to
  /// guess at — guessing a root is how a cleaner deletes somebody else's data).
  Future<String?> _root() async {
    try {
      final Directory temporary = await _temporaryDirectory();
      return p.join(temporary.path, kPickedCacheDirectoryName);
    } on Object catch (error) {
      _log('CACHE 取不到临时目录，跳过清理（$error）');
      return null;
    }
  }

  /// Deletes [path] recursively if it exists; a failure is logged, never thrown.
  ///
  /// Both shapes are handled, because since 0.2.52 the sweep walks the **entries**
  /// of the cache root instead of the root itself: an entry is normally a
  /// per-send directory, but a stray file dropped directly into
  /// `lanlink-picked/` (older builds, a half-finished copy) is still ours and
  /// must go. Deleting a symlink removes the link, never its target
  /// (`followLinks: false`), for the same reason [owningDirectory] normalises
  /// before answering.
  Future<void> _deleteTree(String path) async {
    try {
      final FileSystemEntityType type =
          await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return;
      }
      if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else {
        await File(path).delete();
      }
      _log('CACHE 已清理：$path');
    } on Object catch (error) {
      _log('CACHE 清理失败（不影响发送）：$path（$error）');
    }
  }

  void _log(String message) {
    final void Function(String message)? sink = _onLog;
    if (sink == null) {
      return;
    }
    try {
      sink(message);
    } on Object {
      // A broken log must never break a send.
    }
  }
}

/// The **launch sweep**, with the offline queue's retention set wired in
/// (0.2.52).
///
/// One function, because the two halves belong together and must never be
/// called separately: [resumableSourcePaths] answers "which copies a queued
/// message still needs", `PickedCachePort.clear` deletes the rest. The defect
/// this closes was exactly the two being separate — the sweep ran
/// unconditionally at boot and deleted the source of every queued message, so a
/// message that had been carefully preserved across the restart could never be
/// sent and said nothing about why.
///
/// **When the queue cannot be read, nothing is deleted.** A store that throws
/// here (a locked database, a schema from a newer build) must not be allowed to
/// turn into an empty retention set — that would delete precisely the files the
/// unreadable queue was waiting on. Keeping a cache directory for one more
/// launch costs space; deleting a queued source costs the message.
///
/// Not awaited by the caller on purpose (see `create_deps_native`): a cache
/// sweep must never delay the first frame, and nothing in this file throws.
Future<void> sweepLaunchCopies({
  required PickedCachePort cache,
  required SessionRepository repo,
  void Function(String message)? onLog,
}) async {
  Set<String> keep;
  try {
    keep = resumableSourcePaths(repo);
  } on Object catch (error) {
    _logSweep(onLog, 'CACHE 读不到排队消息，本次跳过启动清理：$error');
    return;
  }
  if (keep.isNotEmpty) {
    _logSweep(onLog, 'CACHE 启动清理保留 ${keep.length} 个排队中的源文件');
  }
  await cache.clear(keep: keep);
}

/// [onLog], wrapped so a throwing sink cannot break the sweep — the same rule
/// every logging callback in this app follows.
void _logSweep(void Function(String message)? onLog, String message) {
  if (onLog == null) {
    return;
  }
  try {
    onLog(message);
  } on Object {
    // Diagnostics never break a caller.
  }
}
