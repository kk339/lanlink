/// The native [PlatformPorts]: file picking, filesystem probes, open/reveal and
/// settings persistence (M4 spec §1.6a / §2 / §8.2).
///
/// **Layering (M4 §8.1):** this is the only file that imports
/// `package:file_selector`; it lives in `data/real/**` and is referenced only by
/// `bootstrap/create_deps_native.dart`, so the Web build never parses it.
///
/// **Android file picking does not use `file_selector`**: its Android
/// implementation reads the whole picked file into memory (a `byte[]` sized to
/// the file, then a Dart `Uint8List`), which OOMs on a large video. On Android
/// picking goes through the streaming bridge in `android_file_picker.dart`
/// (64 KiB chunks + progress); every desktop OS keeps `file_selector` unchanged.
///
/// Open/reveal use `Process.run('explorer', …)` instead of a plugin (spec
/// §1.6a) — it is enough on Windows and keeps the dependency surface minimal.
/// That shell is **Windows-only**; on any other OS the call fails with a clear
/// message (opening a received file on mobile needs a platform Intent, which is
/// not wired yet — see the note in [openFile]).
///
/// Settings live in a small JSON file under the app's data directory (spec
/// §8.2 — `%LOCALAPPDATA%\lanlink` on Windows, the app-support directory on
/// Android/iOS; both chosen in `create_deps_native.dart`). The save directory
/// not being writable is surfaced as a [SettingsWriteException], never silently
/// swallowed (PRD §4.4).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart'
    show XFile, XTypeGroup, getDirectoryPath, openFiles;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:lanlink_core/lanlink_core.dart' show sha256FileHex;

import '../../domain/downloads_folder.dart'
    show kLanlinkDownloadsSubdirectory, normalizeDownloadsSubdirectory;
import '../../domain/drag_out.dart';
import '../../domain/folder_send.dart';
import '../../domain/media_file_name.dart';
import '../../domain/models.dart';
import '../../domain/platform_ports.dart';
import 'android_file_actions.dart';
import 'android_file_picker.dart';
import 'android_folder_picker.dart';
import 'receiver_path_budget.dart';

/// Extensions offered for [FileKind.image].
const XTypeGroup _imageGroup = XTypeGroup(
  label: 'images',
  extensions: <String>[
    'jpg',
    'jpeg',
    'png',
    'gif',
    'bmp',
    'webp',
    'heic',
    'heif',
    'tif',
    'tiff',
    'svg',
  ],
);

/// Extensions offered for [FileKind.video].
const XTypeGroup _videoGroup = XTypeGroup(
  label: 'videos',
  extensions: <String>[
    'mp4',
    'mov',
    'mkv',
    'avi',
    'webm',
    'm4v',
    'wmv',
    'flv',
    'ts',
  ],
);

/// Transient probe filename used to prove a directory is writable.
const String _probeName = '.lanlink-write-probe';

/// Schema version of the `settings.json` document (0.2.25, now 3).
///
/// **Why a version number at all:** 0.2.25 turned the receive-mode default on,
/// and a device that already ran an earlier build has `acceptByDefault: false`
/// literally written in its JSON — flipping the model default cannot reach it.
/// Without a marker, that stored `false` is indistinguishable from two very
/// different states:
///
///   * "the user chose to switch receiving off" — must be respected, and
///   * "the app's old default was off and the user never touched it" — must be
///     migrated to on, or the user is told the default changed and sees no
///     change at all.
///
/// v1 documents (the ones written by 0.2.24 and earlier) simply have no
/// `settingsVersion` key, which reads as version `0`. That is the whole
/// discriminator for [kAcceptByDefaultMigrationVersion]; the migration itself is
/// in [SystemPlatformPorts.loadSettings].
///
/// **v3 (0.2.54) added exactly one optional key, `manualPeers`.** It is
/// additive, so **no data migration step exists or is needed**: an absent key
/// reads as an empty list, and a v2 reader that met a v3 document would simply
/// ignore a key it does not know. The version is bumped because it records what
/// this build is able to *write*, which is what a future one-shot migration will
/// key off — see [kAcceptByDefaultMigrationVersion] for why that distinction has
/// to be explicit.
const int kSettingsDocumentVersion = 3;

/// **★ The gate for the 0.2.25 `acceptByDefault` migration — deliberately NOT
/// [kSettingsDocumentVersion].**
///
/// This constant is the part of the document version that is *semantic*: "below
/// this, a stored `acceptByDefault: false` is the old default and is
/// overruled". Pointing the gate at `kSettingsDocumentVersion` instead would tie
/// that one-time decision to every future bump, and v3 is exactly the bump where
/// that goes wrong: a v2 document written **by 0.2.25–0.2.53** can legitimately
/// hold `acceptByDefault: false`, because the user switched receiving off after
/// the upgrade. Treating it as "old" would silently turn receiving back on at
/// every restart — the same class of defect the migration exists to prevent,
/// pointing the other way. Bumping the document version must therefore never
/// re-arm this migration.
const int kAcceptByDefaultMigrationVersion = 2;

/// Hashes [path] through SHA-256 on a worker isolate.
///
/// **Deliberately a top-level function, not a closure at the call site.**
/// `Isolate.run` sends the closure *and the context object it captured*, and a
/// closure created inside a method shares that method's context with every other
/// closure in the same scope. One sibling closure using a local `Completer`, a
/// `Timer` or a stream subscription therefore makes the message unsendable:
///
///     Invalid argument(s): Illegal argument in isolate message:
///     object is unsendable - Library:'dart:async' Class: _AsyncCompleter
///
/// That only happens on the **real** path, which the suite's fake ports never
/// execute — hence this shape plus
/// `test/system_platform_ports_sha256_test.dart`, which calls the real port and
/// would catch a regression here.
Future<String> _hashFileOnWorkerIsolate(String path) =>
    Isolate.run<String>(() => sha256FileHex(File(path)));

/// [PlatformPorts] backed by `file_selector`, `dart:io` and a settings file.
class SystemPlatformPorts implements PlatformPorts {
  /// Creates the adapter.
  ///
  /// [settingsPath] is the JSON file (spec §8.2: `…\\lanlink\\settings.json`);
  /// [defaultAlias] / [defaultSaveDirectory] are the first-run fallbacks.
  SystemPlatformPorts({
    required String settingsPath,
    required String defaultAlias,
    required String defaultSaveDirectory,
  })  : _settingsPath = settingsPath,
        _defaultAlias = defaultAlias,
        _defaultSaveDirectory = defaultSaveDirectory;

  final String _settingsPath;
  final String _defaultAlias;
  final String _defaultSaveDirectory;

  /// The streaming Android picker — used **only** on Android (see [pickFiles]).
  static const AndroidFilePicker _androidPicker = AndroidFilePicker();

  /// The Android share sheet bridge — used **only** on Android (see
  /// [shareFile]).
  static const AndroidFileActions _androidFileActions = AndroidFileActions();

  /// The Android folder chooser (0.2.29) — used **only** on Android (see
  /// [pickDownloadsFolder]).
  static const AndroidFolderPicker _folderPicker = AndroidFolderPicker();

  /// The received-files sub-directory as of the last load/save (0.2.29).
  ///
  /// **Why the port keeps a copy.** The publish step (`ReceivedFilePublisher`,
  /// wired in `create_deps_native`) runs *after* a transfer and needs the folder
  /// **synchronously**, long after start-up, and the user can change it at any
  /// moment. Re-reading the document per publish would put a disk read on every
  /// received file; a value captured at construction would be the 0.2.23 defect
  /// again (the UI says 素材, the running app still writes `lanlink` until the
  /// next launch). So it is cached here — the object that owns the document — and
  /// refreshed in the two places the document changes: [loadSettings] and
  /// [saveSettings] (after a successful write, never before: a failed save must
  /// leave both the document *and* the live value on the old folder).
  String _receivedSubdirectory = kLanlinkDownloadsSubdirectory;

  @override
  String get receivedSubdirectory => _receivedSubdirectory;

  @override
  Future<DownloadsFolderChoice> pickDownloadsFolder() => _folderPicker.pick();

  /// Desktop can choose a directory with `file_selector`; Android through the
  /// native tree bridge. Web has neither (the fake answers `false` there).
  @override
  bool get supportsSendFolder =>
      Platform.isAndroid ||
      Platform.isWindows ||
      Platform.isMacOS ||
      Platform.isLinux;

  /// 「发送文件夹」: pick a directory, then answer **what would be sent** (0.2.33).
  ///
  /// Two very different mechanics behind one answer, on purpose:
  /// * **Android** — the native bridge walks the SAF tree and copies each file
  ///   into the app cache (a tree has no filesystem paths to hand to Dart), and
  ///   enforces the same limits;
  /// * **desktop** — `getDirectoryPath()` returns a real path, and the walk runs
  ///   here in Dart via [scanFolderForSending] over `dart:io`.
  ///
  /// The decision of what counts as "too many", "empty" and "skipped" is shared
  /// (`domain/folder_send.dart`), so both platforms refuse at the same numbers
  /// and phrase it the same way.
  ///
  /// Never throws: the chooser being cancelled, the folder being empty and the
  /// folder being over the limit are all ordinary answers.
  @override
  Future<SendFolderSelection> pickFolderForSending() async {
    if (_folderPicker.isSupported) {
      return _folderPicker.pickForSend();
    }
    if (!supportsSendFolder) {
      return const SendFolderSelection(
        outcome: PickSendFolderOutcome.unsupported,
      );
    }
    final String? directory;
    try {
      directory = await getDirectoryPath(
        confirmButtonText: '发送这个文件夹',
      );
    } on Object catch (error) {
      return SendFolderSelection(
        outcome: PickSendFolderOutcome.failed,
        reason: '$error',
      );
    }
    if (directory == null || directory.isEmpty) {
      return const SendFolderSelection.cancelled();
    }
    // The chooser only produces a path; **what will be sent** is answered by the
    // one shared walk below, exactly as it is for a dropped folder (0.2.36).
    return describeFolderForSending(directory);
  }

  /// `0.2.36` — the same answer as [pickFolderForSending] for a directory whose
  /// path the app already has (a folder **dropped** on the conversation).
  ///
  /// The scan and its mapping were lifted out of [pickFolderForSending] verbatim
  /// so both doors — the 「发送文件夹…」 menu item and a drop — go through one
  /// implementation. That is not tidiness: the limits ([kFolderSendMaxFiles],
  /// depth, hidden/empty skipping) and the wording of "too many / empty" only stay
  /// true while there is a single walk, and the next change to folder semantics
  /// will be one edit here.
  ///
  /// Android answers [PickSendFolderOutcome.unsupported]: a dropped path never
  /// exists there (the drop target is desktop-only) and a SAF tree is not a
  /// filesystem path, so the native walk in [pickFolderForSending] must not be
  /// bypassed with one.
  @override
  Future<SendFolderSelection> describeFolderForSending(String path) async {
    if (!supportsSendFolder || Platform.isAndroid) {
      return const SendFolderSelection(
        outcome: PickSendFolderOutcome.unsupported,
      );
    }
    final String folderName = _baseNameOf(path);
    try {
      final FolderScan scan = await scanFolderForSending(
        root: path,
        list: _listDirectory,
        // CR-2 ② — the receiver's budget, checked while walking rather than by
        // the receiver's `400` afterwards. `receiverRejectsPath` is the only
        // implementation (it asks core's `normalizeRelativePath`); see
        // `receiver_path_budget.dart` for why it is not in the domain layer.
        rejectsPath: receiverRejectsPath,
      );
      if (scan.tooMany) {
        return SendFolderSelection(
          outcome: PickSendFolderOutcome.tooMany,
          availableCount: scan.availableCount,
          countCapped: scan.countCapped,
          skippedPathTooLong: scan.skippedPathTooLong,
          folderName: folderName,
        );
      }
      if (scan.isEmpty) {
        return SendFolderSelection(
          outcome: PickSendFolderOutcome.empty,
          skippedHidden: scan.skippedHidden,
          skippedEmpty: scan.skippedEmpty,
          skippedTooDeep: scan.skippedTooDeep,
          skippedPathTooLong: scan.skippedPathTooLong,
          folderName: folderName,
        );
      }
      return SendFolderSelection(
        outcome: PickSendFolderOutcome.picked,
        // 0.2.38 — the whole `FolderScanFile` list, so each file keeps the
        // relative path the shared walk computed. `paths` is now a getter over
        // it, which is what makes "3 files declared, 2 paths carried" impossible
        // to express.
        files: scan.files,
        totalBytes: scan.totalBytes,
        skippedHidden: scan.skippedHidden,
        skippedEmpty: scan.skippedEmpty,
        skippedTooDeep: scan.skippedTooDeep,
        skippedPathTooLong: scan.skippedPathTooLong,
        availableCount: scan.availableCount,
        folderName: folderName,
      );
    } on Object catch (error) {
      // A directory that cannot be read must not look like "a folder with
      // nothing in it" — those are different things to the user.
      return SendFolderSelection(
        outcome: PickSendFolderOutcome.failed,
        folderName: folderName,
        reason: '$error',
      );
    }
  }

  /// The last path segment of [path] (for the confirmation dialog's title).
  String _baseNameOf(String path) {
    final int cut = path.lastIndexOf(Platform.pathSeparator);
    if (cut < 0 || cut == path.length - 1) {
      return path;
    }
    return path.substring(cut + 1);
  }

  /// Lists the direct children of [directory] for [scanFolderForSending].
  ///
  /// `followLinks: false`: a symlinked directory is reported as a link, not
  /// descended, so a self-referencing link cannot turn a 3-level walk into an
  /// infinite one. A child that disappears mid-walk is skipped rather than
  /// aborting the whole scan (that is what `_statOrNull` is for); a directory
  /// that cannot be listed at all still throws, and the caller reports it.
  Future<List<FolderEntry>> _listDirectory(String directory) async {
    final List<FileSystemEntity> children =
        await Directory(directory).list(followLinks: false).toList();
    final List<FolderEntry> entries = <FolderEntry>[];
    for (final FileSystemEntity child in children) {
      final String name = _baseNameOf(child.path);
      final FileSystemEntityType type =
          await FileSystemEntity.type(child.path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        entries.add(
          FolderEntry(
            name: name,
            path: child.path,
            isDirectory: true,
          ),
        );
        continue;
      }
      if (type != FileSystemEntityType.file) {
        // A socket / link / missing entry: not something we can send.
        continue;
      }
      final int size = await _lengthOrZero(child.path);
      entries.add(
        FolderEntry(
          name: name,
          path: child.path,
          isDirectory: false,
          size: size,
        ),
      );
    }
    return entries;
  }

  /// The size of [path], or 0 when it vanished between listing and stat.
  Future<int> _lengthOrZero(String path) async {
    try {
      return await File(path).length();
    } on Object {
      return 0;
    }
  }

  @override
  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  Future<void> shareFile(String path) async {
    if (_androidFileActions.isSupported) {
      await _androidFileActions.share(path);
      return;
    }
    // The UI only offers "分享" where `isMobile` is true (Android/iOS); iOS has
    // no bridge yet, so this stays honest rather than silently no-op.
    throw UnsupportedError(
      'shareFile needs the mobile share sheet; not available on '
      '${Platform.operatingSystem}',
    );
  }

  @override
  Future<Uint8List?> readVideoThumbnail(String path, {int? maxBytes}) async {
    if (Platform.isWindows) {
      try {
        return await _thumbnailChannel.invokeMethod<Uint8List>(
          'videoFrame',
          <String, Object>{'path': path, 'size': 640},
        );
      } on Object {
        // A missing handler (an older runner) and an unreadable file look the
        // same to the UI: no frame, so fall back to the type icon.
        return null;
      }
    }
    // Android keeps its MediaMetadataRetriever bridge; every other platform
    // returns `null`, so the UI falls back to the type icon (M5 §C).
    return _androidFileActions.videoThumbnail(path, maxBytes: maxBytes);
  }

  /// The runner's video-frame channel (docs/19 §9.5).
  ///
  /// Windows answers it with the **shell thumbnail** of the file — the same image
  /// Explorer shows — so the desktop can display what a video looks like without
  /// bundling a decoder. Registered in `windows/runner/thumbnail_channel.cpp`.
  static const MethodChannel _thumbnailChannel =
      MethodChannel('lanlink/thumbnail');

  /// Whether this build can drag a file **out** of the app (0.2.45).
  ///
  /// Windows only: the runner implements it with OLE (`DoDragDrop` over a
  /// `CF_HDROP` `IDataObject`), and OLE drag-and-drop has no equivalent that would
  /// let a Flutter file row hand a real file to *another program* on
  /// Android/iOS/Web. Answering `false` is what keeps the gesture from being built
  /// where it could not work.
  @override
  bool get supportsDragOut => Platform.isWindows;

  /// Runs a copy-only OLE drag for [paths] and reports the target's answer.
  ///
  /// Registered in `windows/runner/drag_out_channel.cpp`; the runner declares
  /// `DROPEFFECT_COPY` as the **only** allowed effect, so Explorer copies instead
  /// of moving the file (its default on one volume), and it logs the paths, the
  /// allowed effect and the final effect when `LANLINK_DRAG_OUT_LOG` is set.
  ///
  /// `null` from the channel means the runner answered without an effect, which
  /// no shipped runner does; it is treated as a broken contract rather than as
  /// "nothing happened", so it cannot pass for success.
  @override
  Future<DragOutEffect> startDrag(List<String> paths) async {
    if (!supportsDragOut) {
      throw UnsupportedError(
        'startDrag needs the Windows OLE drag source, which is not available on '
        '${Platform.operatingSystem}',
      );
    }
    if (paths.isEmpty) {
      throw DragOutException('至少要有一个文件路径');
    }
    String? raw;
    try {
      raw = await _dragOutChannel.invokeMethod<String>(
        'startDrag',
        <String, Object>{'paths': List<String>.of(paths)},
      );
    } on MissingPluginException catch (error) {
      // An older runner (or a non-Windows host): the answer must say so, not
      // pretend the drag ended with no effect.
      throw DragOutException('当前运行器不支持拖出（lanlink/drag_out 未注册）：$error');
    } on PlatformException catch (error) {
      // The runner's own words: "OleInitialize failed…", "DoDragDrop failed…".
      // `code` is the fallback when a message was not supplied.
      throw DragOutException(error.message ?? error.code);
    }
    if (raw == null) {
      throw DragOutException('通道没有返回结果，无法判断是否复制成功');
    }
    return parseDragOutEffect(raw);
  }

  /// The runner's drag-out channel (0.2.45).
  ///
  /// One method, `startDrag`, taking `{'paths': <String>[...]}` and answering one
  /// of `copy` / `none` / `canceled`. It **blocks** until the user lets go, by
  /// design: the platform thread is running the shell's modal drag loop.
  static const MethodChannel _dragOutChannel =
      MethodChannel('lanlink/drag_out');

  @override
  Stream<FilePickProgress> get pickProgress => _androidPicker.progress;

  @override
  Future<List<String>> pickFiles(FileKind kind) async {
    // Android: `file_selector_android` materialises the WHOLE picked file in
    // memory (a Java `byte[]` sized to the file, then a Dart `Uint8List` via
    // `XFile.fromData`), so picking a large video is an OutOfMemoryError. Our
    // own bridge copies the document into the app cache in 64 KiB chunks.
    if (_androidPicker.isSupported) {
      return _androidPicker.pick(mimeType: _androidMime(kind));
    }
    final Future<List<XFile>> pending;
    if (kind == FileKind.image) {
      pending = openFiles(acceptedTypeGroups: <XTypeGroup>[_imageGroup]);
    } else if (kind == FileKind.video) {
      pending = openFiles(acceptedTypeGroups: <XTypeGroup>[_videoGroup]);
    } else {
      pending = openFiles();
    }
    final files = await pending;
    return files.map((file) => file.path).toList(growable: false);
  }

  /// Android's gallery picker is the same bridge as [pickFiles] (0.2.53), so it
  /// exists exactly where that picker does.
  @override
  bool get supportsPickMedia => _androidPicker.isSupported;

  @override
  Future<List<String>> pickMedia() async {
    // Only reachable where `supportsPickMedia` is true; answering an empty list
    // anywhere else keeps a stray call harmless instead of throwing at the UI.
    if (!_androidPicker.isSupported) {
      return const <String>[];
    }
    // Two steps, both Android-side (0.2.53): the bridge brings back the picked
    // files **with their capture time and the system's display name**, then the
    // cached copies are renamed to something readable. The rest of the app only
    // ever sees paths, exactly as it does for 「文件」.
    final List<PickedMedia> picked = await _androidPicker.pickMedia();
    return applyMediaFileNames(picked);
  }

  /// The Android picker's MIME filter for [kind].
  String _androidMime(FileKind kind) => switch (kind) {
        FileKind.image => 'image/*',
        FileKind.video => 'video/*',
        FileKind.audio => 'audio/*',
        FileKind.any ||
        FileKind.installer ||
        FileKind.archive ||
        FileKind.document =>
          '*/*',
      };

  @override
  Future<bool> exists(String path) => File(path).exists();

  @override
  Future<bool> isDirectory(String path) => FileSystemEntity.isDirectory(path);

  @override
  Future<int> length(String path) => File(path).length();

  /// Hashes [path] on a **worker isolate**, never on the UI isolate.
  ///
  /// Hashing a 1 GiB file at the 5.5x-faster `package:crypto` rate is still
  /// ~10 s of solid CPU, which no frame can be drawn during — and it happens
  /// **before** the message row exists, so the user sees nothing at all for that
  /// whole time (measured: tap-to-bubble 11.5–15.5 s on 256 MiB before 0.2.12).
  ///
  /// `Isolate.run` costs 0.06–0.21 ms here, and it keeps `dart:isolate` out of
  /// `lanlink_core` (which stays platform-free). The Web build never reaches
  /// this file — `bootstrap/create_deps_native.dart` is only imported by the
  /// native entry point, and the Web build uses `fake_platform_ports`.
  @override
  Future<String> sha256Hex(String path) => _hashFileOnWorkerIsolate(path);

  @override
  Future<Uint8List?> readFileBytes(String path, {int? maxBytes}) async {
    try {
      if (path.isEmpty) {
        return null;
      }
      final File file = File(path);
      if (!await file.exists()) {
        return null;
      }
      // Size guard first: when the file exceeds the cap, return `null` instead
      // of reading (and never truncate — a truncated JPEG decodes into half an
      // image, which is worse than showing nothing; PRD §5).
      if (maxBytes != null && await file.length() > maxBytes) {
        return null;
      }
      return await file.readAsBytes();
    } on Object {
      // Unreadable / any IO error → `null`; the UI falls back to a type icon
      // rather than surfacing an error (never throw from here; spec §3.5).
      return null;
    }
  }

  @override
  Future<void> openFile(String path) async {
    // Android: hand the file to the system viewer / player (ACTION_VIEW). The
    // desktop shell below is Windows-only.
    if (_androidFileActions.isSupported) {
      await _androidFileActions.open(path);
      return;
    }
    _requireDesktopShell();
    await Process.run('explorer', <String>[path]);
  }

  @override
  Future<void> revealInFolder(String path) async {
    _requireDesktopShell();
    await Process.run('explorer', <String>['/select,', path]);
  }

  /// Android only (0.2.24): the folder a received file was published into can be
  /// opened with `DocumentsContract`, which has no desktop equivalent —
  /// `revealInFolder` already lands on the file there.
  @override
  bool get supportsViewInDownloads => _androidFileActions.isSupported;

  @override
  Future<ViewInDownloadsOutcome> viewInDownloads(
    String path, {
    String? subdirectory,
  }) =>
      _androidFileActions.viewInDownloads(path, subdirectory: subdirectory);

  @override
  Future<ViewInDownloadsOutcome> openDownloadsFolder({String? subdirectory}) =>
      _androidFileActions.openDownloadsFolder(subdirectory: subdirectory);

  /// `explorer` is a Windows program, so opening/revealing a file is a
  /// Windows-only capability here. On another OS the failure is made explicit
  /// (rather than a cryptic `ProcessException: executable not found`). Mobile
  /// needs a platform Intent / a plugin; that is a known gap, not wired yet.
  void _requireDesktopShell() {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'openFile / revealInFolder use the Windows shell (explorer), which is '
        'not available on ${Platform.operatingSystem}',
      );
    }
  }

  @override
  Future<AppSettings> loadSettings() async {
    final file = File(_settingsPath);
    if (!await file.exists()) {
      // **Fresh install** (0.2.25 criterion 1): there is no document at all, so
      // nothing has been stored and the model default applies — receiving is on.
      // No document is written here: the first user-driven change creates it,
      // exactly as before. `_defaults()` deliberately does not pass
      // `acceptByDefault`, so the one place the default is stated stays
      // `AppSettings`.
      return _defaults();
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return _defaults();
      }
      final alias = (decoded['alias'] as String?)?.trim();
      final saveDirectory = (decoded['saveDirectory'] as String?)?.trim();
      final acceptByDefault = decoded['acceptByDefault'];

      // ── 0.2.25 — the one-time migration ────────────────────────────────
      //
      // A document written by 0.2.24 or earlier carries no `settingsVersion`, so
      // it reads as version 0. Inside such a document a stored `false` is
      // genuinely ambiguous — it can be "the user switched receiving off" (the
      // toggle has persisted since P0-7) or "nobody ever touched it and the old
      // default was off" — and there is nothing on disk to tell the two apart.
      //
      // 0.2.25 shipped 「接收模式默认开着就行」, so the ambiguous case is resolved
      // towards ON, once: every document below v2 gets `acceptByDefault: true`
      // and is rewritten with `settingsVersion: 2`. The cost is that a user who
      // had deliberately turned receiving off under 0.2.24 sees it on again
      // after the upgrade; the alternative — leaving them off while the release
      // notes say the default changed — is the failure mode this project treats
      // as unacceptable ("用户以为改好了、其实还是关着"). One launch of surprise is
      // recoverable with one tap; a silently ignored change is not.
      //
      // Why "once" matters (criterion 3): the rewrite is what makes this
      // idempotent. From the next launch on the document is v2, so a `false` in
      // it can only come from the user switching receiving off *after* the
      // upgrade — and that is respected from then on. An implementation that
      // forced the value on every load would silently undo the user's choice on
      // every restart.
      final Object? rawVersion = decoded['settingsVersion'];
      // `num`, not `int`: a hand-edited `2.0` must not be read as version 0 and
      // re-migrate a document that is already current.
      final int version = rawVersion is num ? rawVersion.toInt() : 0;
      // ★ Gated on [kAcceptByDefaultMigrationVersion] (2), **not** on
      // [kSettingsDocumentVersion] (3): v3 only added the optional
      // `manualPeers` key, and a v2 document's `false` was written by 0.2.25+,
      // i.e. it is the user's own choice. See the constant's docstring.
      final bool needsMigration = version < kAcceptByDefaultMigrationVersion;

      final AppSettings settings = AppSettings(
        alias: (alias == null || alias.isEmpty) ? _defaultAlias : alias,
        saveDirectory: (saveDirectory == null || saveDirectory.isEmpty)
            ? _defaultSaveDirectory
            : saveDirectory,
        // v2 without the key, or with a non-bool: fall back to the model default
        // (on) rather than to a literal `false` — a hand-edited or truncated
        // document must not be able to resurrect the old default.
        acceptByDefault: needsMigration
            ? true
            : (acceptByDefault is bool ? acceptByDefault : true),
        // 0.2.29 — the received-files folder. Absent / blank / malformed all mean
        // "never chosen" ⇒ the shipped default, so an old document upgrades with
        // no migration step at all (see `normalizeDownloadsSubdirectory`).
        receivedSubdirectory:
            normalizeDownloadsSubdirectory(decoded['receivedSubdirectory'] as String?),
        // 0.2.54 — the addresses the user typed by hand. Absent (every document
        // written before this build) ⇒ empty; a malformed *entry* is dropped on
        // its own by `listFromJson` instead of failing the whole load, so one bad
        // address can never cost the user their alias and save folder.
        manualPeers: ManualPeerTarget.listFromJson(decoded['manualPeers']),
      );

      // The cached value the publish step reads must be in step with what was
      // just loaded — including for a document written by 0.2.28 (no key ⇒
      // default), which is the common upgrade path.
      _receivedSubdirectory = settings.receivedSubdirectory;

      if (needsMigration) {
        await _rewriteAsCurrentVersion(file, settings);
      }
      return settings;
    } on Object {
      // A corrupt settings file must not stop the app: fall back to defaults.
      return _defaults();
    }
  }

  /// Writes the migrated [settings] back with the current document version.
  ///
  /// **Best effort, and silent on failure, on purpose.** The migration changes a
  /// default, not user data, and the value it hands back is already the one the
  /// app will run with; a failed rewrite therefore costs nothing but repeats
  /// itself on the next launch (same result, still on). Throwing here would be
  /// worse: `loadSettings` failing means the app cannot start, which is a far
  /// bigger problem than a stale byte on disk. The one thing that must never
  /// happen — the user's later "off" being overruled — cannot happen either way,
  /// because that write goes through [saveSettings] and carries the version.
  Future<void> _rewriteAsCurrentVersion(File file, AppSettings settings) async {
    try {
      await _writeDocument(file, settings);
    } on Object {
      // No op: see the docstring. The migration is idempotent, so the next
      // launch simply tries again.
    }
  }

  @override
  Future<void> saveSettings(AppSettings settings) async {
    // The save directory must be writable; a failure is surfaced (spec §3.2).
    try {
      final directory = Directory(settings.saveDirectory);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      final probe = File(
        '${settings.saveDirectory}${Platform.pathSeparator}$_probeName',
      );
      await probe.writeAsString('', flush: true);
      if (await probe.exists()) {
        await probe.delete();
      }
    } on Object catch (error) {
      throw SettingsWriteException(
        '保存目录不可写：${settings.saveDirectory}（$error）',
      );
    }

    try {
      await _writeDocument(File(_settingsPath), settings);
    } on Object catch (error) {
      throw SettingsWriteException('无法写入设置文件：$_settingsPath（$error）');
    }
    // Only **after** the document is on disk: a failed write must not move the
    // live folder, or the running app would publish into a folder the next launch
    // does not know about (and the user would see their choice evaporate).
    _receivedSubdirectory =
        normalizeDownloadsSubdirectory(settings.receivedSubdirectory);
  }

  /// Serialises [settings] to [file] **with the current document version**.
  ///
  /// Every write carries `settingsVersion`, including the migration's rewrite and
  /// every later user-driven save — that is what turns "an old document" into a
  /// one-time condition instead of a permanent one. Kept separate from
  /// [saveSettings] because the migration must not run the save-directory
  /// writability probe: a device whose save directory has since gone away must
  /// still get its receive-mode migration.
  Future<void> _writeDocument(File file, AppSettings settings) async {
    await file.parent.create(recursive: true);
    final json = const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'settingsVersion': kSettingsDocumentVersion,
      'alias': settings.alias,
      'saveDirectory': settings.saveDirectory,
      'acceptByDefault': settings.acceptByDefault,
      // ★ 0.2.29 — **this line is load-bearing.** Leaving it out means "the user
      // changed their device name / flipped the receive switch" rewrites the
      // document **without** the chosen folder, and the next launch silently
      // returns to `lanlink`: the setting appears to clear itself for no reason,
      // weeks later, with nothing to point at. (Same class as the 0.2.23 save
      // directory that only took effect after a restart.) Blank normalises to the
      // default, so the document never carries an empty name.
      'receivedSubdirectory':
          normalizeDownloadsSubdirectory(settings.receivedSubdirectory),
      // ★ 0.2.54 — **this line is the whole feature.** The addresses the user
      // typed are what makes a blocked-discovery network survivable, and this
      // writer runs on every settings save — a rename, a toggle, a folder pick.
      // Omit it and the remembered addresses vanish the first time the user
      // touches anything unrelated, which is the same silent-loss shape as the
      // `receivedSubdirectory` note above (and 0.2.23's save directory).
      //
      // Invalid entries are skipped rather than written: the document must never
      // contain something its own reader (and the probe) would refuse, or the UI
      // would keep showing a target that disappears on the next launch.
      'manualPeers': <Object?>[
        for (final ManualPeerTarget target in settings.manualPeers)
          if (target.isValid) target.toJson(),
      ],
    });
    await file.writeAsString(json, flush: true);
  }

  AppSettings _defaults() => AppSettings(
        alias: _defaultAlias,
        saveDirectory: _defaultSaveDirectory,
      );
}
