/// The "delete our temporary copies" port (0.2.23).
///
/// **The problem it fixes.** Android cannot hand a Dart process a live
/// `content://` URI, so every file the OS picker or the share sheet gives us is
/// first **copied** into `cacheDir/lanlink-picked/<uuid>/<name>`
/// (`MainActivity.copyPickedUri`) — a full second copy of the file, streamed in
/// 64 KiB chunks so a 1 GB video does not go through memory. Nothing ever
/// deleted it: `share_intake`'s `discardDraft` / `consumeDraft` cleared the
/// *fields* and left the bytes, and a picked-then-sent file stayed forever. Send
/// a 1 GB video and the phone's cache grows by 1 GB, which the OS eventually
/// reclaims by evicting the whole app's cache (or by refusing to install the
/// next update for lack of space).
///
/// **The rule this port must never break:** it deletes **only** directories it
/// can prove are its own — those under `<temp>/lanlink-picked/`. A path anywhere
/// else (the user's `Download` folder, a dropped desktop file, a photo the user
/// owns) is not ours to delete, and [discard] must leave it alone **silently**.
/// That is the judgement the acceptance criterion asks for: the copy goes, the
/// original stays.
///
/// **Layering (M4 §8.1):** pure Dart — this file only declares the surface. The
/// `dart:io` + `path_provider` half lives in `data/real/picked_cache.dart`; the
/// Web / test build gets [NoopPickedCache], exactly like the other optional
/// ports (`ShareInboxPort`).
library;

import 'models.dart';
import 'session_repository.dart';

/// The single directory name the platform side uses for these copies.
///
/// Declared here, in `domain/`, because **two** layers need to agree on it and
/// they may not import each other: the Android host writes
/// `cacheDir/lanlink-picked/<uuid>/` (`MainActivity.copyPickedUri`), and the
/// Dart cleaner must recognise it. One constant, one spelling — the same rule
/// `kStalledError` follows.
const String kPickedCacheDirectoryName = 'lanlink-picked';

/// Whether [path] is **shaped like one of this app's own temporary copies** —
/// i.e. it lives *inside* a `lanlink-picked/` directory (0.2.49).
///
/// **This is not a deletion guard, and it must never become one.** The authority
/// on "may we delete this?" is `PickedFileCache.owningDirectory`, which knows the
/// real temporary root and refuses anything outside it; this function has no root
/// to compare against (it is pure `domain/`, reachable from `ui/**`) and can only
/// answer "this path looks like ours".
///
/// It has exactly one caller — the message timeline, deciding whether a missing
/// attachment is **our own post-send cleanup** rather than a file the user or
/// another program lost (`ConversationController.discardedByUs`). Both halves of
/// that answer are deliberately on the safe side:
///
///  * a wrong `true` costs nothing worse than a warning that is not drawn (and the
///    user can still tap the row — it says 「文件已不在原位置」 out loud);
///  * a wrong `false` would put a red broken-link icon on **every file an Android
///    phone ever sent**, which is the defect this exists to prevent.
///
/// The file name itself does not count: `…/DCIM/lanlink-picked` is a *file* the
/// user owns, and only a directory in the middle of the path makes a copy ours —
/// the same reason `owningDirectory` refuses the root directory itself.
bool isPickedCachePath(String path) {
  if (path.isEmpty) {
    return false;
  }
  final List<String> segments = path.split(RegExp(r'[\\/]'));
  // The last segment is the file name; only an ancestor can be the directory.
  for (int i = 0; i < segments.length - 1; i += 1) {
    if (segments[i] == kPickedCacheDirectoryName) {
      return true;
    }
  }
  return false;
}

/// The source files the **offline queue still needs**, as stored paths.
///
/// This is the launch sweep's *retention set* (0.2.52). The premise the old
/// unconditional sweep rested on — "nothing in `lanlink-picked/` is ever the
/// only copy of anything" — has exactly one exception, and it is a real one:
/// a message that is **queued** (`pending`) has not been sent yet, so its copy
/// in the cache *is* the only bytes this app can still upload. Deleting it at
/// the next launch made the queue a lie: the row kept saying 排队中 while the
/// file it pointed at had been removed by us, and the failure named nothing.
///
/// The rule is derived from [MessageStatus.isTerminal], deliberately not from a
/// hand-written list: a status that is not terminal has an outcome still ahead
/// of it (`pending`, `awaitingConfirm`, `transferring`, and `failed` — which
/// offers 重新发送, and 重新发送 re-reads this very path).
///
/// A message whose attachment has no `localPath` contributes nothing; the
/// implementation refuses paths outside its own root anyway, so this set can be
/// handed over without filtering.
///
/// **★ `canceled` is deliberately NOT retained — do not "fix" this.**
/// `!isTerminal` also excludes `canceled`, and 0.2.22 gives a canceled message a
/// 重新发送 button, so keeping its copy would look like an omission. It is not:
///
/// * 0.2.23 exists because this cache grew without bound; retaining every
///   cancelled send forever brings half of that defect back, and a cancelled
///   message is by definition one the user *stopped* wanting;
/// * the cost is bounded and now honest — 取消 → 重启 → 重新发送 asks the user to
///   pick the file again, and says so (`kSourceMissingError`, drawn by
///   `_failureNote`). That is one extra tap, **not** a lost message: the message
///   row, its bubble and the button all survive; only the cached bytes do not.
///
/// The statuses that *do* matter are kept: `pending` / `awaiting_confirm` /
/// `transferring` / `failed` are all non-terminal, and those are the ones the
/// user never chose to abandon.
Set<String> resumableSourcePaths(SessionRepository repo) {
  final Set<MessageStatus> open = <MessageStatus>{
    for (final MessageStatus status in MessageStatus.values)
      // `canceled` included in the sweep on purpose — see the doc above.
      if (!status.isTerminal) status,
  };
  final Set<String> paths = <String>{};
  for (final ChatMessage message in repo.messagesByStatus(open)) {
    if (message.direction != MessageDirection.outgoing) {
      continue;
    }
    for (final FileAttachment file in repo.filesOf(message.id)) {
      final String? path = file.localPath;
      if (path != null && path.isNotEmpty) {
        paths.add(path);
      }
    }
  }
  return paths;
}

/// Deletes the app's own temporary copies of picked / shared files.
abstract interface class PickedCachePort {
  /// Deletes the per-file cache directory each of [paths] lives in.
  ///
  /// A path that is **not** one of our copies (anything outside
  /// `<temp>/lanlink-picked/`) is skipped: it is the user's file, not ours.
  /// A deletion failure is logged, never thrown — a cache sweep must not change
  /// the outcome of a send that has already succeeded.
  Future<void> discard(Iterable<String> paths);

  /// Deletes every copy under `<temp>/lanlink-picked/` **except** the ones a
  /// queued message still needs (the startup sweep).
  ///
  /// [keep] is the retention set — normally `resumableSourcePaths(repo)`. It is
  /// matched at **per-send-directory** granularity (`<root>/<uuid>/`), never
  /// file by file: the unit this port creates and deletes is the directory, and
  /// a half-deleted one (a name compared with the wrong separator, a symlinked
  /// parent) would be worse than either answer. A path in [keep] that does not
  /// live under our root is ignored, exactly like [discard] ignores it.
  ///
  /// With an empty [keep] the whole tree goes: nothing in that directory is the
  /// only copy of anything **unless a message is still waiting to upload it**,
  /// which is precisely what [keep] carries.
  Future<void> clear({Set<String> keep = const <String>{}});
}

/// The null object: a platform with no temporary copies of its own.
///
/// Desktop picks in place (`file_selector` hands back the real path) and the Web
/// build never touches the filesystem, so both answer every call with a no-op.
/// It exists so callers can depend on the port unconditionally and never branch
/// on "is there a cache at all".
class NoopPickedCache implements PickedCachePort {
  /// Creates the null object.
  const NoopPickedCache();

  @override
  Future<void> discard(Iterable<String> paths) async {}

  @override
  Future<void> clear({Set<String> keep = const <String>{}}) async {}
}
