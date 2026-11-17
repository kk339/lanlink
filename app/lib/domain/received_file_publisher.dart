/// The "publish a received file, then record the public path" policy (0.2.19).
///
/// **Where it sits in the receive flow.** The core receiver has already written
/// and SHA-256-verified the bytes into the private directory when this runs.
/// The event is published **after** verification and **before** the
/// `TransferOrchestrator` records it, so the row the database keeps — and
/// therefore the path 复制文件路径 hands out — is the public one.
///
/// **Layering (M4 §8.1):** pure Dart. The two side effects are injected:
/// * [PublicStoragePort] — the platform copy (Android `MediaStore.Downloads`);
/// * [DeleteLocalFile] — removing the private copy afterwards, which the
///   platform-bound caller supplies from `dart:io` (this file must stay
///   Web-safe, so it never imports it).
///
/// That injection is also what makes the whole policy testable with a fake
/// store and a fake deleter — no device, no `MediaStore`.
library;

import 'package:path/path.dart' as p;

import 'downloads_folder.dart' show kLanlinkDownloadsSubdirectory;
import 'models.dart';
import 'public_storage.dart';

/// Removes the private copy of a file that has just been published.
typedef DeleteLocalFile = Future<void> Function(String path);

/// The outcome of publishing one file.
///
/// **One field carries the verdict: [error].** 0.2.19 also had an `exported`
/// flag, but no production code ever read it — the only two facts the caller
/// needs are "which path do I record" ([path]) and "why not" ([error]) — so
/// 0.2.23 deleted it rather than leave a second, unused spelling of the same
/// state (a flag that says `true` while the failure is being reported is exactly
/// how the interface starts lying).
class PublishedFile {
  /// Creates the outcome.
  const PublishedFile({required this.path, this.error});

  /// The path that must be recorded: the public one when the publish succeeded,
  /// otherwise the unchanged private source path.
  final String path;

  /// The reason publishing failed, or `null` (success, or nothing to do).
  final String? error;

  /// Whether publishing was attempted and failed.
  bool get failed => error != null;

  @override
  String toString() => 'PublishedFile(path: $path, error: $error)';
}

/// Publishes verified received files to the user-visible store.
class ReceivedFilePublisher {
  /// Wires the policy.
  ///
  /// [storage] is the platform copy, [deleteLocalFile] removes the private copy
  /// after a successful publish, and [onLog] receives one line per outcome (the
  /// app's diagnostic log — the channel the user can actually read back).
  ///
  /// [subdirectory] answers "which folder inside `Download` should it land in?"
  /// at **publish time** (0.2.29). It is a function, not a value, because the
  /// user can change the folder while the app runs: a captured string would keep
  /// writing the old folder until the next launch — exactly the "the setting says
  /// 素材 but the files go to lanlink" defect 0.2.23 fixed for the desktop save
  /// directory. Defaults to the shipped folder, so the policy's own tests (which
  /// do not care about folders) keep working.
  const ReceivedFilePublisher({
    required PublicStoragePort storage,
    required DeleteLocalFile deleteLocalFile,
    void Function(String message)? onLog,
    String Function() subdirectory = _defaultSubdirectory,
  })  : _storage = storage,
        _deleteLocalFile = deleteLocalFile,
        _onLog = onLog,
        _subdirectory = subdirectory;

  /// The shipped default, as a top-level tear-off so the constructor default
  /// stays `const`.
  static String _defaultSubdirectory() => kLanlinkDownloadsSubdirectory;

  final PublicStoragePort _storage;
  final DeleteLocalFile _deleteLocalFile;
  final void Function(String message)? _onLog;
  final String Function() _subdirectory;

  /// Publishes the file at [srcPath] and returns the path to record.
  ///
  /// Three outcomes, all reported — never an exception escaping to the caller
  /// (a receive must still be recorded even when the export failed, otherwise
  /// the file would exist on disk with no history entry at all):
  ///
  /// * **exported** — [PublishedFile.path] is the platform's actual public path
  ///   and the private copy has been deleted (a failed delete only logs: the
  ///   public copy is already the recorded one);
  /// * **nothing to do** — [PublicStoragePort] answered `null` (desktop/Web):
  ///   the private path is returned untouched, exactly the 0.2.18 behaviour;
  /// * **failed** — [PublishedFile.path] is the unchanged private path,
  ///   [PublishedFile.error] carries the reason and one log line is written.
  Future<PublishedFile> publish({
    required String srcPath,
    required String displayName,
    String? mime,
    String? subdirectory,
  }) async {
    final String? exportedPath;
    try {
      exportedPath = await _storage.publishReceivedFile(
        srcPath: srcPath,
        displayName: displayName,
        mime: mime,
        // Read here, not at construction: the folder can change mid-session and
        // the next received file must follow the new one immediately. A caller
        // that already worked out a nested path (a folder arrival, 0.2.38) passes
        // it in; everyone else gets the configured folder, unchanged.
        subdirectory: subdirectory ?? _subdirectory(),
      );
    } on Object catch (error) {
      final String reason = _reasonOf(error);
      _log('PUBLISH 导出失败：$displayName（$reason），文件仍在应用内部');
      return PublishedFile(path: srcPath, error: reason);
    }

    if (exportedPath == null || exportedPath.isEmpty) {
      // No publishing step on this platform: leave everything as it was.
      return PublishedFile(path: srcPath);
    }

    // The public copy is the record of truth from here on; a leftover private
    // copy is a wasted byte, not a lost file — so a delete failure is logged,
    // never allowed to undo a successful publish.
    try {
      await _deleteLocalFile(srcPath);
    } on Object catch (error) {
      _log('PUBLISH 已导出，但内部临时文件删除失败：$srcPath（${_reasonOf(error)}）');
    }

    _log('PUBLISH 已导出：$displayName → $exportedPath');
    return PublishedFile(path: exportedPath);
  }

  /// Publishes [transfer]'s file and returns the event to record.
  ///
  /// A publish that succeeds replaces `savedPath` **and** `fileName`
  /// (`fileId` / `size` / `sha256` / `mime` and the sender are carried over
  /// verbatim, so the message id, the de-duplication key and the bubble's
  /// metadata are unaffected by where the file physically landed).
  ///
  /// **Why `fileName` moves too (0.2.23).** Android renames a duplicate on
  /// publish (`x.mp4` → `x (1).mp4`) and the platform's answer is the only
  /// authority on the final name. 0.2.22 recorded the public path but kept the
  /// original name, so receiving the same file twice left the disk holding
  /// `x (1).mp4` while the bubble said `x.mp4` — the name the user then copies
  /// out of the UI is not a file that exists. The basename of the published path
  /// *is* the name on disk, by construction.
  ///
  /// A **failed** publish additionally carries [PublishedFile.error] into
  /// [ReceivedTransfer.publishError], which is what the UI turns into
  /// 「已收到，但没能导出到「下载」」 instead of silently claiming 已完成.
  Future<ReceivedTransfer> publishTransfer(ReceivedTransfer transfer) async {
    final IncomingFile file = transfer.file;
    final PublishedFile published = await publish(
      srcPath: file.savedPath,
      displayName: file.fileName,
      mime: file.mime,
      // 0.2.38 — a folder arrival keeps its place in the tree on the *public*
      // side too, so `下载/lanlink/素材/data/` instead of everything in one heap.
      subdirectory: subdirectoryFor(transfer),
    );
    if (published.path == file.savedPath) {
      // Nothing moved: either there was nothing to do, or the export failed and
      // the file stays where it is — the failure is reported, never hidden.
      return published.failed
          ? transfer.copyWith(publishError: published.error)
          : transfer;
    }
    final String publishedName = p.basename(published.path);
    return ReceivedTransfer(
      file: IncomingFile(
        fileId: file.fileId,
        fileName: publishedName.isEmpty ? file.fileName : publishedName,
        size: file.size,
        sha256: file.sha256,
        savedPath: published.path,
        mime: file.mime,
        // ★ **Must be carried explicitly.** This constructor is a hand-written
        // field-by-field rebuild, so a field that is not listed here does not
        // error — it silently becomes `null`. Adding `relativePath` to
        // `IncomingFile` and forgetting this line would make every *successfully
        // published* file lose its position, and only on Android: on desktop
        // `published.path == file.savedPath` returns above and this code never
        // runs. Local tests would stay green while the phone shows a flat folder.
        relativePath: file.relativePath,
      ),
      sender: transfer.sender,
      // Same trap, same reason: the folder descriptor is what the store uses to
      // keep this message a folder rather than N loose files.
      sessionId: transfer.sessionId,
      folderName: transfer.folderName,
      folderFiles: transfer.folderFiles,
    );
  }

  /// The `subdirectory` a received file should be published into (0.2.38).
  ///
  /// `<configured folder>/<folder name>/<dirname of relativePath>`, skipping the
  /// empty parts:
  /// * a plain arrival (`folderName == null`) → just the configured folder, i.e.
  ///   the pre-0.2.38 behaviour byte for byte;
  /// * `lanlink` + `素材` + `data/a.bin` → `lanlink/素材/data`;
  /// * `lanlink` + `素材` + `a.bin` (a file at the folder's root) → `lanlink/素材`.
  ///
  /// `/` is used literally and the segments are split on `/` rather than through
  /// `p.dirname`: `relativePath` is the **wire/database** form (always `/`,
  /// `docs/22` §4.3a), so the platform's own separator rules must not be allowed
  /// to reinterpret it.
  ///
  /// The result is a *name* relative to the platform's downloads root — never a
  /// path, never a URI. On Android it becomes a `RELATIVE_PATH`, whose own
  /// `sanitizeSubdirectory` splits and drops `.`/`..` again: two layers, on
  /// purpose, because this one may have been built from a peer's string.
  String subdirectoryFor(ReceivedTransfer transfer) {
    final String base = _subdirectory();
    final String? folderName = transfer.folderName;
    if (folderName == null || folderName.isEmpty) {
      return base;
    }
    final List<String> parts = <String>[base, folderName];
    final String? relativePath = transfer.file.relativePath;
    if (relativePath != null && relativePath.isNotEmpty) {
      final int cut = relativePath.lastIndexOf('/');
      if (cut > 0) {
        for (final String segment in relativePath.substring(0, cut).split('/')) {
          if (segment.isNotEmpty && segment != '.' && segment != '..') {
            parts.add(segment);
          }
        }
      }
    }
    return parts.where((String part) => part.isNotEmpty).join('/');
  }

  /// A short, user-legible reason for [error].
  String _reasonOf(Object error) =>
      error is PublicStorageException ? error.message : '$error';

  /// Writes one diagnostic line; logging must never break the receive path.
  void _log(String message) {
    final void Function(String message)? sink = _onLog;
    if (sink == null) {
      return;
    }
    try {
      sink(message);
    } on Object {
      // A broken log must not cost the user their file record.
    }
  }
}
