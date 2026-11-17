/// Android folder-chooser bridge (0.2.29) — "let the user pick the folder
/// received files land in".
///
/// **The shape of the feature, and why it is a *chooser* on top of MediaStore
/// rather than free choice.** 0.2.19 publishes every verified file into the
/// public Downloads collection with `RELATIVE_PATH`. Letting the user write into
/// an arbitrary SAF tree would turn the landing spot from a **path** into a
/// `content://` URI, and six platform capabilities (`exists`, `openFile`,
/// `shareFile`, video thumbnails, byte reads, 「在下载里查看」) plus three
/// string-only uses (copy path, details sheet, the pre-resend probe) all assume
/// an absolute path a `File()` can open — they would not fail loudly, they would
/// quietly degrade into "the files are gone". So the picker exists, but it only
/// **chooses a folder inside `Download`**, and the write still goes through
/// `MediaStore` with a derived `RELATIVE_PATH`. The database keeps storing real
/// paths, and nothing above this file learns about URIs.
///
/// **Layering (M4 §8.1):** `data/real/**` — the platform behind it is Kotlin
/// (`MainActivity.pickDownloadsFolder`), reached through the channel
/// `lanlink/folder_picker`.
library;

import 'dart:io';

import 'package:flutter/services.dart';

import '../../domain/folder_send.dart';
import 'receiver_path_budget.dart';
import '../../domain/platform_ports.dart'
    show DownloadsFolderChoice, PickDownloadsFolderOutcome;

/// The `lanlink/folder_picker` channel name (mirrored in `MainActivity.kt`).
const String kFolderPickerChannel = 'lanlink/folder_picker';

/// The Android host bridge for "ask the user which folder to save into".
class AndroidFolderPicker {
  /// Creates the bridge.
  const AndroidFolderPicker();

  static const MethodChannel _channel = MethodChannel(kFolderPickerChannel);

  /// Whether this bridge applies here (Android only).
  bool get isSupported => Platform.isAndroid;

  /// Starts `ACTION_OPEN_DOCUMENT_TREE` and reports what came back.
  ///
  /// Never throws: a chooser that cannot start is a normal outcome for the
  /// caller (it shows a message and changes nothing), not a crash.
  Future<DownloadsFolderChoice> pick() async {
    if (!isSupported) {
      return const DownloadsFolderChoice(
        PickDownloadsFolderOutcome.unsupported,
      );
    }
    final Map<Object?, Object?>? reply;
    try {
      reply = await _channel.invokeMethod<Map<Object?, Object?>>('pick');
    } on MissingPluginException {
      // Dart and the native side out of step (a stale APK): report it as a
      // failure, not as "this phone has no chooser" — the phone may well have one.
      return const DownloadsFolderChoice(
        PickDownloadsFolderOutcome.failed,
        reason: '安卓目录选择通道不可用（应用与原生版本不一致）',
      );
    } on PlatformException catch (error) {
      return DownloadsFolderChoice(
        PickDownloadsFolderOutcome.failed,
        reason: error.message ?? error.code,
      );
    }
    return parsePickReply(reply);
  }

  /// Lets the user pick **any** folder and answers what would be sent (0.2.33).
  ///
  /// Deliberately a **second method on the same channel**, not a flag on [pick]:
  /// the two operations have opposite validation rules (a save folder must live
  /// under `Download`; a folder to send may be anywhere) and folding them into
  /// one call is how the save-folder rule quietly becomes "anywhere".
  ///
  /// The host does the whole job — walk the tree, apply the limits, copy every
  /// file into the app cache — because a SAF tree has no filesystem paths for
  /// Dart to read. What comes back is a plain list of local paths plus the
  /// counts the confirmation dialog needs.
  Future<SendFolderSelection> pickForSend() async {
    if (!isSupported) {
      return const SendFolderSelection(
        outcome: PickSendFolderOutcome.unsupported,
      );
    }
    final Map<Object?, Object?>? reply;
    try {
      reply = await _channel.invokeMethod<Map<Object?, Object?>>('pickForSend');
    } on MissingPluginException {
      return const SendFolderSelection(
        outcome: PickSendFolderOutcome.failed,
        reason: '安卓目录选择通道不可用（应用与原生版本不一致）',
      );
    } on PlatformException catch (error) {
      return SendFolderSelection(
        outcome: PickSendFolderOutcome.failed,
        reason: error.message ?? error.code,
      );
    }
    return parseSendFolderReply(reply);
  }

  /// Maps the host's reply for `pickForSend` to a [SendFolderSelection].
  ///
  /// Wire shapes (`MainActivity.startSendFolderPick`):
  /// * `{result: "ok", paths: [...], relativePaths: [...], totalBytes,
  ///    skippedHidden, skippedEmpty, skippedTooDeep, failed, folderName}`;
  /// * `{result: "cancelled"}`;
  /// * `{result: "empty", folderName, skippedHidden, skippedEmpty, skippedTooDeep}`;
  /// * `{result: "too_many", availableCount, countCapped, folderName}`;
  /// * `{result: "failed", reason}`.
  ///
  /// **`relativePaths` (0.2.38) is optional and parallel to `paths`.** It is
  /// read positionally and all-or-nothing: absent, wrong length, or containing a
  /// non-string makes the whole batch flat (`relativePath == null` on every
  /// file). The files are still sent — losing the hierarchy is a degradation,
  /// never a reason to drop a file the user chose.
  ///
  /// **`ok` with no usable path is read as `empty`**, never as a successful send
  /// of zero files: a send that reports success and moves nothing is the exact
  /// shape of bug this project keeps deleting.
  ///
  /// Public so the mapping can be unit-tested without an Android runtime.
  static SendFolderSelection parseSendFolderReply(Object? reply) {
    final Object? code = reply is Map ? reply['result'] : null;
    final Object? reason = reply is Map ? reply['reason'] : null;
    final Object? folderName = reply is Map ? reply['folderName'] : null;
    final int skippedHidden = _intOf(reply, 'skippedHidden');
    final int skippedEmpty = _intOf(reply, 'skippedEmpty');
    final int skippedTooDeep = _intOf(reply, 'skippedTooDeep');
    switch (code) {
      case 'ok':
        // CR-2 ② — the native walk answers with positions the receiver may not
        // accept (SAF has no 180-character notion). The same judgement the
        // desktop walk applies while scanning is applied here, after the fact:
        // the too-long files leave the batch and are **counted**, so the rest
        // still go instead of the receiver answering one `400` for the lot.
        final ({
          List<FolderScanFile> files,
          int skippedPathTooLong,
          int skippedBytes,
        }) budgeted = applyReceiverPathBudget(_filesOf(reply));
        final List<FolderScanFile> files = budgeted.files;
        if (files.isEmpty) {
          return SendFolderSelection(
            outcome: PickSendFolderOutcome.empty,
            skippedHidden: skippedHidden,
            skippedEmpty: skippedEmpty,
            skippedTooDeep: skippedTooDeep,
            skippedPathTooLong: budgeted.skippedPathTooLong,
            folderName: folderName is String ? folderName : null,
          );
        }
        // The host's `totalBytes` covers the whole walk, so the skipped bytes
        // have to come back out: 「共 X MB」 must describe what is being sent.
        // (Per-file `size` is `0` on this platform today — `_filesOf` — so the
        // subtraction is a no-op until the host starts reporting them; it stays
        // because the alternative is a total that silently includes files the
        // batch does not contain.)
        final int declaredTotal = _intOf(reply, 'totalBytes');
        final int totalBytes = declaredTotal - budgeted.skippedBytes;
        return SendFolderSelection(
          outcome: PickSendFolderOutcome.picked,
          files: files,
          totalBytes: totalBytes < 0 ? 0 : totalBytes,
          skippedHidden: skippedHidden,
          skippedEmpty: skippedEmpty,
          skippedTooDeep: skippedTooDeep,
          skippedPathTooLong: budgeted.skippedPathTooLong,
          failedCopies: _intOf(reply, 'failed'),
          availableCount: files.length,
          folderName: folderName is String ? folderName : null,
        );
      case 'cancelled':
        return const SendFolderSelection.cancelled();
      case 'empty':
        return SendFolderSelection(
          outcome: PickSendFolderOutcome.empty,
          skippedHidden: skippedHidden,
          skippedEmpty: skippedEmpty,
          skippedTooDeep: skippedTooDeep,
          folderName: folderName is String ? folderName : null,
        );
      case 'too_many':
        return SendFolderSelection(
          outcome: PickSendFolderOutcome.tooMany,
          availableCount: _intOf(reply, 'availableCount'),
          countCapped: reply is Map && reply['countCapped'] == true,
          folderName: folderName is String ? folderName : null,
        );
      case 'unsupported':
        return const SendFolderSelection(
          outcome: PickSendFolderOutcome.unsupported,
        );
      case 'failed':
        return SendFolderSelection(
          outcome: PickSendFolderOutcome.failed,
          reason: reason is String && reason.isNotEmpty ? reason : null,
        );
      default:
        return const SendFolderSelection(
          outcome: PickSendFolderOutcome.failed,
          reason: '系统返回了无法识别的结果',
        );
    }
  }

  static int _intOf(Object? reply, String key) {
    final Object? value = reply is Map ? reply[key] : null;
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return 0;
  }

  /// Pairs the host's `paths` with its optional, parallel `relativePaths`
  /// (0.2.38).
  ///
  /// **Positional, and all-or-nothing.** The two arrays are zipped by index, so
  /// an entry is dropped from *both* when its path is unusable — that keeps
  /// `paths[i]` and `relativePaths[i]` describing the same file instead of
  /// sliding one array against the other. A pair that slid would deliver file A
  /// under file B's directory, which is far worse than losing the hierarchy.
  ///
  /// [FolderScanFile.size] is `0` here: the host reports only `totalBytes`, and
  /// inventing a per-file number would be a second, wrong answer.
  static List<FolderScanFile> _filesOf(Object? reply) {
    final Object? rawPaths = reply is Map ? reply['paths'] : null;
    if (rawPaths is! List) {
      return const <FolderScanFile>[];
    }
    final List<String>? relatives = _relativePathsOf(reply, rawPaths.length);
    final List<FolderScanFile> files = <FolderScanFile>[];
    for (int index = 0; index < rawPaths.length; index++) {
      final Object? path = rawPaths[index];
      if (path is! String || path.isEmpty) {
        continue;
      }
      files.add(
        FolderScanFile(
          path: path,
          relativePath: relatives == null ? null : relatives[index],
          size: 0,
        ),
      );
    }
    return files;
  }

  /// The host's `relativePaths`, or `null` when the whole batch must be treated
  /// as flat.
  ///
  /// `null` for **any** of: the key is absent, it is not a list, its length does
  /// not match `paths`, or any entry is not a non-empty string. All four are the
  /// same answer on purpose — a partially-understood parallel array has no safe
  /// interpretation, and "some files have a level" is not a state the wire can
  /// express (`docs/22` §3.3).
  static List<String>? _relativePathsOf(Object? reply, int expectedLength) {
    final Object? raw = reply is Map ? reply['relativePaths'] : null;
    if (raw is! List || raw.length != expectedLength) {
      return null;
    }
    final List<String> relatives = <String>[];
    for (final Object? entry in raw) {
      if (entry is! String || entry.isEmpty) {
        return null;
      }
      relatives.add(entry);
    }
    return relatives;
  }

  /// Maps the host's `{result: …}` reply to a [DownloadsFolderChoice].
  ///
  /// Wire values (`MainActivity.pickDownloadsFolder` / `onActivityResult`):
  /// * `{result: "ok", subdirectory: "素材"}` → [PickDownloadsFolderOutcome.picked];
  /// * `{result: "cancelled"}` → [PickDownloadsFolderOutcome.cancelled];
  /// * `{result: "invalid", reason: …}` → [PickDownloadsFolderOutcome.invalid];
  /// * `{result: "failed", reason: …}` → [PickDownloadsFolderOutcome.failed];
  /// * anything else (null reply, unknown word, `ok` **without** a name) →
  ///   [PickDownloadsFolderOutcome.failed]. A reply that claims success but
  ///   carries no folder must never be read as "the user picked something" —
  ///   the caller would then store an empty setting and silently move files to
  ///   the default folder.
  ///
  /// Public so the mapping can be unit-tested without an Android runtime.
  static DownloadsFolderChoice parsePickReply(Object? reply) {
    final Object? code = reply is Map ? reply['result'] : null;
    final Object? reason = reply is Map ? reply['reason'] : null;
    switch (code) {
      case 'ok':
        final Object? subdirectory =
            reply is Map ? reply['subdirectory'] : null;
        if (subdirectory is String && subdirectory.trim().isNotEmpty) {
          return DownloadsFolderChoice(
            PickDownloadsFolderOutcome.picked,
            subdirectory: subdirectory.trim(),
          );
        }
        return const DownloadsFolderChoice(
          PickDownloadsFolderOutcome.failed,
          reason: '系统没有返回所选的文件夹',
        );
      case 'cancelled':
        return const DownloadsFolderChoice(PickDownloadsFolderOutcome.cancelled);
      case 'invalid':
        return DownloadsFolderChoice(
          PickDownloadsFolderOutcome.invalid,
          reason: reason is String && reason.isNotEmpty ? reason : null,
        );
      case 'failed':
        return DownloadsFolderChoice(
          PickDownloadsFolderOutcome.failed,
          reason: reason is String && reason.isNotEmpty ? reason : null,
        );
      default:
        return const DownloadsFolderChoice(
          PickDownloadsFolderOutcome.failed,
          reason: '系统返回了无法识别的结果',
        );
    }
  }
}
