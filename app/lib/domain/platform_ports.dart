/// Platform-capability port (spec §3.2): file picking, filesystem probes,
/// open/reveal and settings persistence.
///
/// **Layering (M4 §8.1):** pure Dart — merely declares the surface. The native
/// adapter (`data/real/system_platform_ports.dart`) is the only place that
/// imports `package:file_selector` / `dart:io`; the fake answers from memory.
///
/// [FileKind] and [AppSettings] live in `domain/models.dart` (spec §3.1).
library;

import 'dart:typed_data';

import 'drag_out.dart';
import 'folder_send.dart';
import 'models.dart';

/// Thrown when settings cannot be persisted.
///
/// The save directory not being writable is surfaced, **never** silently
/// swallowed (spec §3.2 / PRD §4.4).
class SettingsWriteException implements Exception {
  /// Creates the exception with a human-readable [message].
  SettingsWriteException(this.message);

  /// A human-readable reason.
  final String message;

  @override
  String toString() => 'SettingsWriteException: $message';
}

/// Thrown when picking a file fails (the picker or the copy behind it).
///
/// Surfaced by the UI — a failed pick must never look like "nothing happened".
class FilePickException implements Exception {
  /// Creates the exception with a human-readable [message].
  FilePickException(this.message);

  /// A human-readable reason.
  final String message;

  @override
  String toString() => 'FilePickException: $message';
}

/// Byte progress of an in-flight [PlatformPorts.pickFiles] preparation.
class FilePickProgress {
  /// Creates a progress sample.
  const FilePickProgress({required this.done, required this.total});

  /// Bytes copied so far.
  final int done;

  /// Total bytes, or a non-positive value when the provider did not declare it.
  final int total;

  /// Fraction copied (`0..1`), or `null` when [total] is unknown.
  double? get fraction => total > 0 ? (done / total).clamp(0.0, 1.0) : null;

  /// Whether this is a file big enough to warn the user about up front.
  bool get isLarge => total >= kLargePickedFileHintBytes;

  @override
  String toString() => 'FilePickProgress($done/$total)';
}

/// Files at or above this size get an explicit "this may take a while" note
/// while the platform copies them. It is a **heads-up, not a cap** — nothing is
/// refused for being large.
const int kLargePickedFileHintBytes = 64 * 1024 * 1024;

/// What the platform did with a [PlatformPorts.viewInDownloads] request
/// (0.2.24).
///
/// **An enum, not a `bool`.** The caller has to say *why* nothing opened:
/// "this ROM has no file manager" and "nothing has been published yet" are
/// different situations for the user, and the fallback (copy the path, say so)
/// is the same only because both are dead ends. A `bool` would collapse them
/// into `false` and invite a second, silent no-op — the failure shape this
/// project keeps deleting.
enum ViewInDownloadsOutcome {
  /// The folder opened. Nothing more to say to the user.
  opened,

  /// No installed app can open a folder (`resolveActivity` empty / the start
  /// threw `ActivityNotFoundException`) — a trimmed ROM, or a device with no
  /// document UI at all.
  noApp,

  /// `Download/lanlink` does not exist yet — nothing has been received on this
  /// phone since 0.2.19, so there is no folder to show.
  noDirectory,

  /// This platform has no such action (desktop / Web / iOS).
  unsupported,

  /// The platform was asked and something else went wrong; [String] reason is
  /// in the app log, and the user gets the same "path copied" fallback.
  failed,
}

/// What the **folder chooser** answered (0.2.29).
///
/// Same reasoning as [ViewInDownloadsOutcome]: the caller has to tell "the user
/// backed out" (say nothing) from "the user picked something we cannot use" (say
/// what is allowed) from "the platform has no chooser" — a `bool` would collapse
/// all three into "did not work", and cancelling is not a failure.
enum PickDownloadsFolderOutcome {
  /// The user chose a folder inside `Download`; see
  /// [DownloadsFolderChoice.subdirectory].
  picked,

  /// The user backed out (`RESULT_CANCELED`). **Not an error** — no message.
  cancelled,

  /// The pick was outside `Download` (or the `Download` root itself, which would
  /// scatter received files among the user's own downloads).
  invalid,

  /// This platform has no folder chooser (desktop / Web / iOS).
  unsupported,

  /// Something else went wrong (a `SecurityException` from the permission grant,
  /// a hostile ROM). [DownloadsFolderChoice.reason] carries the detail.
  failed,
}

/// The answer of [PlatformPorts.pickDownloadsFolder] (0.2.29).
///
/// A small class rather than a bare enum because a successful pick has to carry
/// the chosen name: [subdirectory] is set **iff** [outcome] is
/// [PickDownloadsFolderOutcome.picked], and it is a name relative to `Download/`
/// (`素材`, `素材/2026`) — never a `content://` URI and never an absolute path.
class DownloadsFolderChoice {
  /// Creates the answer.
  const DownloadsFolderChoice(
    this.outcome, {
    this.subdirectory,
    this.reason,
  });

  /// What happened.
  final PickDownloadsFolderOutcome outcome;

  /// The chosen folder, relative to `Download/`; non-null iff [outcome] is
  /// [PickDownloadsFolderOutcome.picked].
  final String? subdirectory;

  /// Why it failed, for [PickDownloadsFolderOutcome.failed].
  final String? reason;

  @override
  String toString() => 'DownloadsFolderChoice($outcome, '
      'subdirectory: $subdirectory, reason: $reason)';
}

/// The platform capabilities the UI needs (spec §1.3, port 6).
abstract interface class PlatformPorts {
  /// Opens the OS picker filtered to [kind] and returns the chosen paths
  /// (empty when the user cancels).
  ///
  /// Throws [FilePickException] when the pick itself fails. On platforms that
  /// must copy the picked file into app storage (Android), this can take
  /// seconds for a large file — see [pickProgress].
  Future<List<String>> pickFiles(FileKind kind);

  /// Opens the **system gallery picker** and returns the chosen paths (empty
  /// when the user cancels) — the 「照片」 door (0.2.53).
  ///
  /// Same contract as [pickFiles] (multi-select, cache copies, [pickProgress],
  /// [FilePickException] on failure); the only difference is **which** system
  /// surface opens: a gallery grouped by album rather than a folder tree. Photos
  /// are the one thing a phone user sends constantly and the one thing a file
  /// browser is worst at, which is why this is a second button rather than a
  /// filter on the first.
  ///
  /// **The names come back readable.** The system picker calls a photo
  /// `1000055362.jpg`, so implementations rename the cached copy when — and only
  /// when — the platform also reported a capture time
  /// (`lib/domain/media_file_name.dart` holds the rules, which are pure and unit
  /// tested). A name that is already readable is never touched, and a rename that
  /// would fail leaves the original name rather than a path pointing nowhere.
  ///
  /// Only ever called where [supportsPickMedia] is true.
  Future<List<String>> pickMedia();

  /// Whether this build offers the 「照片」 button at all (0.2.53).
  ///
  /// **Android only.** The gallery picker is a platform surface the host owns
  /// (`ACTION_PICK_IMAGES`, falling back to the document browser), and the
  /// desktop entry point has no bridge for it — `create_deps_native` wires the
  /// same picker on Windows/macOS/Linux, where [pickMedia] would have nothing to
  /// call. The composer keys the *existence* of that button off this getter, the
  /// same way the attachment menu keys 「在下载里查看」 off
  /// [supportsViewInDownloads]: a button that would do nothing is never built
  /// (docs/18 §8.2).
  bool get supportsPickMedia;

  /// Byte progress of an in-flight [pickFiles], for the UI.
  ///
  /// Android copies the chosen document into the app cache, so a large file
  /// takes time; the UI shows this so the wait is never silent. Emits nothing
  /// on platforms that pick in place.
  Stream<FilePickProgress> get pickProgress;

  /// Whether [path] exists.
  Future<bool> exists(String path);

  /// Whether [path] is a **directory** (docs/19 §9.8).
  ///
  /// A dropped folder is rejected rather than expanded: walking a tree is a
  /// different feature, and a drop that quietly sends nothing is the worst
  /// possible answer.
  Future<bool> isDirectory(String path);

  /// The length of the file at [path] in bytes.
  Future<int> length(String path);

  /// The uppercase-hex SHA-256 of the file at [path].
  Future<String> sha256Hex(String path);

  /// Opens [path] with the OS default handler (P1-2).
  Future<void> openFile(String path);

  /// Reveals [path] in the OS file manager (P1-2).
  Future<void> revealInFolder(String path);

  /// Whether this build offers 「在下载里查看」 at all (0.2.24).
  ///
  /// **Android only.** Desktop keeps [revealInFolder] (`explorer /select,`),
  /// which lands on the file itself; Web has no shell at all. The UI keys the
  /// *existence* of that menu row off this, so a button is never built on a
  /// platform that would answer [ViewInDownloadsOutcome.unsupported] — a tappable
  /// row that does nothing is the one shape that is never allowed (docs/18 §8.2).
  bool get supportsViewInDownloads;

  /// Shows the public `Download/lanlink` folder in the system file manager
  /// (0.2.24) — the Android answer to desktop's [revealInFolder].
  ///
  /// [path] is the received file the user is looking at. It is **not opened**:
  /// the folder that holds it is, because there is no stable cross-ROM way to
  /// select a single file in a file manager (see `MainActivity.viewInDownloads`).
  /// It still travels down, so the host's log line can name the file and so a
  /// path outside `Download/lanlink` is never silently treated as "close enough".
  ///
  /// Every outcome is **reported**, never thrown: a ROM with no folder handler
  /// is a normal device, not an exception, and the caller has a fallback prepared
  /// (copy the path, then say so). Implementations must not answer [opened] on a
  /// guess.
  ///
  /// [subdirectory] is the folder under `Download` the user configured (0.2.29),
  /// as a name relative to `Download/`; `null` means the shipped default.
  Future<ViewInDownloadsOutcome> viewInDownloads(
    String path, {
    String? subdirectory,
  });

  /// Opens the folder itself — the **no-file** form of [viewInDownloads]
  /// (0.2.26).
  ///
  /// **Why this is a second entry point instead of a made-up path.** The phone's
  /// settings page has a row 「文件保存位置」 that names a *folder*; there is no
  /// file behind it to pass. Handing [viewInDownloads] a synthesised path would
  /// mean inventing one, and the only path that would round-trip is
  /// `<dir>/<something>` — i.e. a file that does not exist. Worse, it would have
  /// to be a path that `isInLanlinkDownloadsFolder` accepts, and that predicate
  /// deliberately answers **false** for the folder itself ("the folder is not a
  /// file in the folder"). Rather than widen the predicate until it means two
  /// things, the port grows a second, honest verb.
  ///
  /// Outcomes are the same five values, and the caller's fallback is the same:
  /// on [ViewInDownloadsOutcome.noApp] / [ViewInDownloadsOutcome.noDirectory] copy
  /// the readable folder path (`Download/lanlink`, from
  /// `domain/downloads_folder.dart`) and say so.
  Future<ViewInDownloadsOutcome> openDownloadsFolder({String? subdirectory});

  /// The folder inside the platform's downloads root that received files are
  /// published into **right now** (0.2.29) — a name relative to that root
  /// (`lanlink`, `素材`, `素材/2026`), never a path and never a URI.
  ///
  /// Two readers, and they must agree:
  ///  * the publish step (`ReceivedFilePublisher` → [PublicStoragePort]),
  ///  * the attachment menu, which offers 「在下载里查看」 only for files that are
  ///    inside that folder ([isInLanlinkDownloadsFolder]).
  ///
  /// Permanent, **not** a Future: it is already-loaded state, and the publish path
  /// runs after every transfer (`ReceivedFilePublisher` is wired once at start-up
  /// and cannot await a settings read per file). Implementations keep it in step
  /// with the settings document — updated on load and **after a successful
  /// save**, never before, so a failed save cannot move the live folder.
  ///
  /// **Never blank.** A missing or malformed stored value normalises to the
  /// shipped default (`lanlink`), so no caller has to guess what `''` means.
  String get receivedSubdirectory;

  /// Asks the user to choose the folder received files are published into
  /// (0.2.29) — a folder **inside `Download`**, chosen through
  /// `ACTION_OPEN_DOCUMENT_TREE`.
  ///
  /// Android only; every other platform answers
  /// [PickDownloadsFolderOutcome.unsupported]. The chosen name is relative to
  /// `Download/`; nothing else about the pick leaks through this port (no URI, no
  /// absolute path), because the publish path stays `MediaStore` + `RELATIVE_PATH`
  /// and the database keeps storing real paths.
  ///
  /// The caller must **not** assume a pick happened: a cancel is
  /// [PickDownloadsFolderOutcome.cancelled] and must stay silent, and an
  /// [PickDownloadsFolderOutcome.invalid] pick must leave the stored setting
  /// untouched.
  Future<DownloadsFolderChoice> pickDownloadsFolder();

  /// Whether this platform can let the user pick a **folder to send** (0.2.33).
  ///
  /// Desktop uses `file_selector`'s `getDirectoryPath()`, Android its own
  /// `ACTION_OPEN_DOCUMENT_TREE` bridge plus a native walk of the tree. Web has
  /// neither, so the entry is **not built** there rather than built and inert.
  bool get supportsSendFolder;

  /// Lets the user pick a folder and answers everything the confirmation needs
  /// (0.2.33): which local files, how big, and what was skipped.
  ///
  /// The platform is also where the **limits** are enforced
  /// ([kFolderSendMaxDepth] / [kFolderSendMaxFiles]), because on Android the walk
  /// happens natively — but the decision of what "too many" means lives in
  /// `domain/folder_send.dart` and is applied on both sides, so a desktop and a
  /// phone refuse at exactly the same number.
  ///
  /// Never throws: a cancelled chooser, an empty folder and an over-limit folder
  /// are ordinary answers ([PickSendFolderOutcome]), not exceptions — the caller
  /// either says nothing or says what happened, and in both cases sends nothing.
  Future<SendFolderSelection> pickFolderForSending();

  /// Answers the same question as [pickFolderForSending] for a directory whose
  /// **path the app already has** — one the user dropped onto the conversation
  /// instead of choosing in a dialog (0.2.36).
  ///
  /// It exists so a drop and the 「发送文件夹…」 menu item reach the *same* walk,
  /// the *same* confirmation sheet and the *same* `sendPaths` call: one folder
  /// flow in the app, not two copies that drift. A caller must never walk the
  /// tree itself — the limits ([kFolderSendMaxFiles], depth, hidden/empty
  /// skipping) only stay true while there is a single implementation.
  ///
  /// Never throws. [PickSendFolderOutcome.unsupported] where a filesystem path
  /// cannot be walked (Web; Android, whose folders are SAF trees, not paths).
  Future<SendFolderSelection> describeFolderForSending(String path);

  /// Loads the persisted settings.
  Future<AppSettings> loadSettings();

  /// Persists [settings].
  ///
  /// Throws [SettingsWriteException] when the save directory is not writable.
  Future<void> saveSettings(AppSettings settings);

  /// Reads the whole file at [path] as bytes, or `null` when it cannot be read.
  ///
  /// [maxBytes] caps the read: when the file is larger, return `null` instead of
  /// truncating — a truncated JPEG decodes into half an image, which is worse
  /// than showing nothing. `null` means "no cap".
  Future<Uint8List?> readFileBytes(String path, {int? maxBytes});

  /// Whether this build runs on a **mobile** OS (Android / iOS).
  ///
  /// The UI keys the *file-action* wording off this: a phone offers
  /// 「打开 / 分享」, a desktop keeps 「打开文件 / 打开所在位置」 (M5 §E — the same
  /// intent, a different landing per platform). It is deliberately **not** a
  /// layout signal: layout stays width-driven (`ShellLayout`).
  bool get isMobile;

  /// Hands [path] to the OS **share sheet** (the mobile file action).
  ///
  /// Only ever offered where [isMobile] is true; on a platform with no share
  /// sheet this throws [UnsupportedError] rather than pretending to succeed.
  Future<void> shareFile(String path);

  /// **One** frame of the video at [path] as JPEG bytes (a cover), or `null`.
  ///
  /// Only ever read for a video. The whole video is **never** read — the platform
  /// extracts a single scaled frame. [maxBytes] caps the result; an over-cap (or
  /// unextractable) frame returns `null` so the caller falls back to the type
  /// icon (a video with no cover is fine; a broken image is not).
  Future<Uint8List?> readVideoThumbnail(String path, {int? maxBytes});

  /// Whether this build can drag files **out** of the app onto the desktop, into
  /// Explorer or into another program (0.2.45).
  ///
  /// **Windows only.** The implemented mechanism is Windows' own OLE drag source
  /// (a `CF_HDROP` `IDataObject` + `IDropSource` + `DoDragDrop`), which has no
  /// counterpart on Android/iOS (a phone drags nothing outside itself) and none on
  /// Web. The UI keys the *existence* of the gesture off this getter, so on any
  /// other platform the attachment rows stay exactly as they were — a swallow
  /// gesture that silently does nothing would be worse than no gesture at all
  /// (the same rule as [supportsViewInDownloads] / [supportsSendFolder]).
  bool get supportsDragOut;

  /// Runs a **copy-only** OS drag for [paths] and reports what the target did.
  ///
  /// [paths] must be the files' real local paths (`FileAttachment.localPath`) —
  /// never an id and never a relative name: the drop target is the filesystem, so
  /// the paths are the payload. A folder message passes **every** file of the
  /// message, and the caller must have already dropped the ones that are no
  /// longer on disk: a drag that starts with a path the shell cannot read is a
  /// gesture the user performs and nothing happens.
  ///
  /// **Only a copy ever happens.** Implementations must declare `DROPEFFECT_COPY`
  /// and nothing else, so a same-volume drop cannot move the user's file away from
  /// the message that still refers to it; a platform that answers `move` anyway is
  /// reported as a [DragOutException], never as success (see
  /// `domain/drag_out.dart`).
  ///
  /// The call **blocks until the user lets go** — that is what a drag is — which
  /// on the desktop means the platform thread runs the shell's modal loop. Callers
  /// must therefore not await it inside a build, and must re-check the paths
  /// afterwards: the target was free to move them.
  ///
  /// Throws [UnsupportedError] where [supportsDragOut] is false (Web, mobile) and
  /// [DragOutException] when the platform cannot start the drag at all (OLE
  /// initialisation failed, the runner has no such channel) or answers with an
  /// effect this app does not allow. A user cancelling ([DragOutEffect.canceled])
  /// and a drop onto nothing ([DragOutEffect.none]) are **ordinary answers**, not
  /// exceptions.
  Future<DragOutEffect> startDrag(List<String> paths);
}
