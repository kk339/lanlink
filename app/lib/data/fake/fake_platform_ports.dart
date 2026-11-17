import 'dart:async';
import 'dart:typed_data';

import '../../domain/downloads_folder.dart'
    show kLanlinkDownloadsSubdirectory;
import '../../domain/drag_out.dart';
import '../../domain/folder_send.dart';
import '../../domain/media_file_name.dart';
import '../../domain/models.dart';
import '../../domain/platform_ports.dart';

/// In-memory [PlatformPorts] with every capability preset from a test.
///
/// Pure Dart (M4 §8.1): imports only this app's `domain/`. File picking,
/// existence, length, hashing, open/reveal and settings persistence are all
/// driven from in-memory maps so widget tests never touch the disk, the
/// `file_selector` plugin, or the OS.
class FakePlatformPorts implements PlatformPorts {
  /// Creates the fake. All maps default to empty; [settings] defaults to a
  /// benign value so `loadSettings()` is always answerable.
  FakePlatformPorts({
    Map<FileKind, List<String>>? picks,
    Map<String, bool>? existing,
    Map<String, int>? lengths,
    Map<String, String>? hashes,
    Map<String, Uint8List>? bytes,
    AppSettings? settings,
    bool mobile = false,
  })  : _picks = <FileKind, List<String>>{...?picks},
        _existing = <String, bool>{...?existing},
        _lengths = <String, int>{...?lengths},
        _hashes = <String, String>{...?hashes},
        _bytes = <String, Uint8List>{...?bytes},
        _settings = settings ??
            const AppSettings(
                alias: 'This device', saveDirectory: '/received') {
    _mobile = mobile;
  }

  final Map<FileKind, List<String>> _picks;
  final Map<String, bool> _existing;

  /// Paths the fake reports as directories (docs/19 §9.8 — a dropped folder).
  final Set<String> _directories = <String>{};

  /// Marks [path] as a directory, so a drop test can prove folders are refused.
  void setDirectory(String path) => _directories.add(path);
  final Map<String, int> _lengths;
  final Map<String, String> _hashes;
  final Map<String, Uint8List> _bytes;

  AppSettings _settings;
  String? _saveFailure;
  bool _mobile = false;

  /// The settings as they stand right now, **synchronously**.
  ///
  /// [loadSettings] is the port's async surface; this exists because
  /// `FakeBackend` has to seed the receiver with the same directory production
  /// seeds it with (`create_deps_native` passes `settings.saveDirectory` into
  /// `LanTransferService`), and doing that from an async call would make the
  /// whole fake container async for no gain.
  AppSettings get presetSettings => _settings;

  /// One-shot gate that parks the next [sha256Hex] (see [holdNextHash]).
  Completer<void>? _hashHold;

  /// Preset video-frame bytes, keyed by path (M5 §C — a `null` value means "no
  /// frame", so the UI falls back to the type icon).
  final Map<String, Uint8List> _videoThumbs = <String, Uint8List>{};

  /// Paths passed to [shareFile], in order.
  final List<String> shared = <String>[];

  @override
  bool get isMobile => _mobile;

  @override
  Future<void> shareFile(String path) async => shared.add(path);

  @override
  Future<Uint8List?> readVideoThumbnail(String path, {int? maxBytes}) async {
    final Uint8List? stored = _videoThumbs[path];
    if (stored == null) {
      return null;
    }
    if (maxBytes != null && stored.length > maxBytes) {
      return null;
    }
    return stored;
  }

  /// Paths passed to [openFile], in order.
  final List<String> opened = <String>[];

  /// Paths passed to [revealInFolder], in order.
  final List<String> revealed = <String>[];

  /// Paths passed to [viewInDownloads], in order (0.2.24).
  ///
  /// The list is *how many times and with what*; [viewInDownloadsOutcome] is what
  /// the platform answers back, so a test can drive both the success and the two
  /// dead-end fallbacks without a device.
  final List<String> viewInDownloadsRequests = <String>[];

  /// What [viewInDownloads] answers. Defaults to the honest desktop/unknown
  /// answer, [ViewInDownloadsOutcome.unsupported] — a test that wants the phone
  /// behaviour opts in with [setSupportsViewInDownloads].
  ViewInDownloadsOutcome viewInDownloadsOutcome =
      ViewInDownloadsOutcome.unsupported;

  /// Whether this fake claims a 「在下载里查看」 action exists (Android).
  bool _supportsViewInDownloads = false;

  /// Whether this fake claims a 「照片」 button exists (Android, 0.2.53).
  ///
  /// Defaults to **false**, the same rule as [supportsViewInDownloads] and
  /// [supportsSendFolder]: a test that wants the affordance has to say so, and
  /// the default is the answer a desktop tree must give.
  bool _supportsPickMedia = false;

  /// The sub-directories each [viewInDownloads] / [openDownloadsFolder] call
  /// asked for, in order (0.2.29) — `null` records "the caller sent no folder".
  final List<String?> viewInDownloadsSubdirectories = <String?>[];
  final List<String?> openDownloadsFolderSubdirectories = <String?>[];

  /// What [pickDownloadsFolder] answers (0.2.29). Defaults to "the user backed
  /// out", which is the only answer a test can rely on without setting anything
  /// up — and the one that must stay silent.
  DownloadsFolderChoice pickDownloadsFolderReply =
      const DownloadsFolderChoice(PickDownloadsFolderOutcome.cancelled);

  /// How many times [pickDownloadsFolder] was called (0.2.29).
  int pickDownloadsFolderCalls = 0;

  /// What [pickFolderForSending] answers (0.2.33). Defaults to "the user backed
  /// out" — the only answer that needs no setup and must stay silent — and
  /// [supportsSendFolder] defaults to **false**, because a test that wants the
  /// entry has to say so (the same rule as `setSupportsViewInDownloads`).
  SendFolderSelection sendFolderReply =
      const SendFolderSelection.cancelled();
  bool _supportsSendFolder = false;

  /// How many times [pickFolderForSending] was called (0.2.33).
  int pickSendFolderCalls = 0;

  /// One-shot gate that parks the next [pickFolderForSending] (0.2.33).
  ///
  /// Same trick as [holdNextHash]: with an instant fake answer the composer's
  /// 「正在读取文件夹…」 caption would be set and cleared inside one microtask, so
  /// a test could never observe it — and that caption is the whole answer to
  /// "the app looked frozen while it walked the folder".
  Completer<void>? _sendFolderHold;

  /// The sub-directory this fake reports as configured (0.2.29) — mirrors
  /// `AppSettings.receivedSubdirectory` after the last [saveSettings].
  @override
  String get receivedSubdirectory =>
      _normalizedReceivedSubdirectory(_settings.receivedSubdirectory);

  static String _normalizedReceivedSubdirectory(String raw) =>
      raw.trim().isEmpty ? kLanlinkDownloadsSubdirectory : raw.trim();

  /// How many times [openDownloadsFolder] was called (0.2.26).
  ///
  /// A plain count, not a list: that method takes no argument, so "with what"
  /// has no answer — the judgement is "the row asked the platform once, and did
  /// not ask anything else".
  int openDownloadsFolderCalls = 0;

  /// Test hook fired **inside** [openDownloadsFolder], before it answers — the
  /// same ordered-event-log trick as [onViewInDownloads], for the settings row
  /// whose fallback copies a path to the clipboard.
  void Function()? onOpenDownloadsFolder;

  /// Test hook fired **inside** [viewInDownloads], before it answers — lets a
  /// test build one ordered event log across the fake port and a mocked platform
  /// channel (clipboard), which is how "the copy happened *after* the platform
  /// said it could not open the folder" is asserted rather than assumed.
  void Function(String path)? onViewInDownloads;

  /// Paths passed to [readFileBytes], in order.
  ///
  /// Lets a test assert "the port was never called" (PRD §8-G28/G30) or that a
  /// cached thumbnail is not re-read (PRD §8-G3-1/G3-2).
  final List<String> readRequests = <String>[];

  @override
  Stream<FilePickProgress> get pickProgress =>
      const Stream<FilePickProgress>.empty();

  @override
  Future<List<String>> pickFiles(FileKind kind) async =>
      List<String>.of(_picks[kind] ?? const <String>[]);

  /// How many times [pickMedia] was called (0.2.53).
  ///
  /// Separate from the returned paths on purpose: "the button called the right
  /// port" and "what the port answered" are two different failures, and a test
  /// that only checked the sent message would pass even if the button had gone
  /// through [pickFiles] instead.
  int pickMediaCalls = 0;

  @override
  Future<List<String>> pickMedia() async {
    pickMediaCalls += 1;
    if (mediaPickDetails.isNotEmpty) {
      // Production renames the cache copies; the fake has no disk, so it answers
      // the same **names** in the same directories. The naming rules are the
      // same pure function (`lib/domain/media_file_name.dart`), which is why a
      // widget test can assert `20261102_153012.jpg` without a filesystem.
      final List<String> names = uniqueMediaFileNames(mediaPickDetails);
      return <String>[
        for (int index = 0; index < mediaPickDetails.length; index += 1)
          mediaSiblingPath(mediaPickDetails[index].path, names[index]),
      ];
    }
    return List<String>.of(mediaPick);
  }

  /// What [pickMedia] answers — the photos the gallery "returned" (0.2.53).
  ///
  /// Empty by default, which is also the cancel case: the user backed out of the
  /// picker, so nothing may be sent and nothing may be reported as an error.
  List<String> mediaPick = <String>[];

  /// What the gallery "returned" **with the facts only a device knows**
  /// (0.2.53): the system's display name and the capture time.
  ///
  /// When this is set it takes precedence over [mediaPick], and the fake answers
  /// the **renamed** paths (`20261102_153012.jpg`) the same way production does —
  /// minus the disk, which the fake never touches.
  List<PickedMedia> mediaPickDetails = <PickedMedia>[];

  @override
  Future<bool> exists(String path) async {
    // A host that cannot answer (0.2.52). The pump treats a throwing `exists`
    // as "present" — refusing to dial because a port was unavailable would be
    // worse than the dial it prevents — and this is how a test states that.
    final Object? failure = _existsFailure;
    if (failure != null) {
      throw failure;
    }
    return _existing[path] ?? true;
  }

  @override
  Future<bool> isDirectory(String path) async => _directories.contains(path);

  @override
  Future<int> length(String path) async => _lengths[path] ?? 0;

  @override
  Future<String> sha256Hex(String path) async {
    // A held hash parks here until the test releases it, which is the only way
    // to observe the "preparing" window (0.2.14): with an instant fake hash the
    // hint would be set and cleared inside one microtask.
    final Completer<void>? hold = _hashHold;
    if (hold != null) {
      _hashHold = null;
      await hold.future;
    }
    return _hashes[path] ?? _zeroHash;
  }

  @override
  Future<Uint8List?> readFileBytes(String path, {int? maxBytes}) async {
    readRequests.add(path);
    final Uint8List? stored = _bytes[path];
    if (stored == null) {
      return null; // nothing preset (or cleared) — models a missing/unreadable file
    }
    if (maxBytes != null && stored.length > maxBytes) {
      return null; // over the cap → null, never a truncated prefix (port §3.1)
    }
    return stored;
  }

  @override
  Future<void> openFile(String path) async => opened.add(path);

  @override
  Future<void> revealInFolder(String path) async => revealed.add(path);

  @override
  bool get supportsViewInDownloads => _supportsViewInDownloads;

  @override
  Future<ViewInDownloadsOutcome> viewInDownloads(
    String path, {
    String? subdirectory,
  }) async {
    viewInDownloadsRequests.add(path);
    viewInDownloadsSubdirectories.add(subdirectory);
    onViewInDownloads?.call(path);
    if (!_supportsViewInDownloads) {
      // Mirrors the real port: a platform with no such action answers
      // `unsupported` and never pretends to have opened anything.
      return ViewInDownloadsOutcome.unsupported;
    }
    return viewInDownloadsOutcome;
  }

  @override
  Future<ViewInDownloadsOutcome> openDownloadsFolder({
    String? subdirectory,
  }) async {
    openDownloadsFolderCalls += 1;
    openDownloadsFolderSubdirectories.add(subdirectory);
    onOpenDownloadsFolder?.call();
    if (!_supportsViewInDownloads) {
      return ViewInDownloadsOutcome.unsupported;
    }
    return viewInDownloadsOutcome;
  }

  @override
  Future<DownloadsFolderChoice> pickDownloadsFolder() async {
    pickDownloadsFolderCalls += 1;
    return pickDownloadsFolderReply;
  }

  @override
  bool get supportsSendFolder => _supportsSendFolder;

  @override
  bool get supportsPickMedia => _supportsPickMedia;

  @override
  Future<SendFolderSelection> pickFolderForSending() async {
    pickSendFolderCalls += 1;
    final Completer<void>? hold = _sendFolderHold;
    if (hold != null) {
      _sendFolderHold = null;
      await hold.future;
    }
    if (!_supportsSendFolder) {
      return const SendFolderSelection(
        outcome: PickSendFolderOutcome.unsupported,
      );
    }
    return sendFolderReply;
  }

  /// What [describeFolderForSending] answers for a dropped folder (0.2.36).
  ///
  /// Defaults to `cancelled` — the answer that needs no setup and stays silent —
  /// and, like the picker, it only answers `unsupported` when
  /// [supportsSendFolder] is off, so a test that exercises a folder drop has to
  /// switch the capability on explicitly.
  SendFolderSelection describeFolderReply =
      const SendFolderSelection.cancelled();

  /// Every path [describeFolderForSending] was called with, in order (0.2.36) —
  /// this is how a test proves a dropped directory went through the **folder**
  /// flow rather than being refused or sent as a loose file.
  final List<String> describedFolderPaths = <String>[];

  @override
  Future<SendFolderSelection> describeFolderForSending(String path) async {
    describedFolderPaths.add(path);
    if (!_supportsSendFolder) {
      return const SendFolderSelection(
        outcome: PickSendFolderOutcome.unsupported,
      );
    }
    return describeFolderReply;
  }

  @override
  Future<AppSettings> loadSettings() async => _settings;

  @override
  Future<void> saveSettings(AppSettings settings) async {
    final failure = _saveFailure;
    if (failure != null) {
      throw SettingsWriteException(failure);
    }
    _settings = settings;
  }

  // ── programmable control (test / preview only) ────────────────────────

  /// Sets what [pickFiles] returns for [kind].
  void setPickResult(FileKind kind, List<String> paths) =>
      _picks[kind] = List<String>.of(paths);

  /// Sets what [pickMedia] returns — the photos the gallery "returned" (0.2.53).
  ///
  /// An empty list is the **cancel** answer too: it is what the real bridge hands
  /// back when the user backs out, and the app must treat both the same way (no
  /// message, no error).
  void setMediaPick(List<String> paths) => mediaPick = List<String>.of(paths);

  /// Sets what [pickMedia] answers **with the device-only facts** (0.2.53).
  ///
  /// The fake then applies the real naming rules, so a test can drive
  /// "the system called it `1000055362.jpg` and it was taken at 15:30:12" and
  /// assert the message carries `20261102_153012.jpg`.
  void setMediaPickDetails(List<PickedMedia> picked) =>
      mediaPickDetails = List<PickedMedia>.of(picked);

  /// Sets whether this platform offers the 「照片」 button (0.2.53).
  ///
  /// Kept separate from [setMobile] for the same reason
  /// [setSupportsViewInDownloads] is: `isMobile` is Android **or iOS**, while the
  /// gallery bridge is Android only, and the test that matters most is "a tree
  /// with no phone affordances shows no such button".
  void setSupportsPickMedia(bool value) => _supportsPickMedia = value;

  /// Sets whether [path] is reported to exist.
  void setExists(String path, bool value) => _existing[path] = value;

  /// Makes every [exists] call throw [error] (0.2.52), i.e. a platform that
  /// cannot answer the question at all.
  void failExistsWith(Object error) => _existsFailure = error;

  Object? _existsFailure;

  /// Sets the byte length reported for [path].
  void setLength(String path, int value) => _lengths[path] = value;

  /// Sets the SHA-256 (uppercase hex) reported for [path].
  void setSha256(String path, String value) => _hashes[path] = value;

  /// Holds the next [sha256Hex] call until [gate] completes (0.2.14).
  ///
  /// Needs a real service for the "preparing" hint: with an instant fake hash
  /// the hint is set and cleared inside one microtask, so a widget test could
  /// never observe it.
  void holdNextHash(Completer<void> gate) => _hashHold = gate;

  /// Presets the bytes [readFileBytes] returns for [path] (test / preview only).
  ///
  /// Reads never touch the disk in the fake; a `path` with no bytes preset
  /// returns `null`, which also models a missing / unreadable file, and a preset
  /// longer than `maxBytes` returns `null` (over-cap, never truncated).
  void setBytes(String path, Uint8List bytes) => _bytes[path] = bytes;

  /// Forgets the bytes preset for [path], so a later read returns `null`.
  void clearBytes(String path) => _bytes.remove(path);

  /// Makes every [saveSettings] call throw a [SettingsWriteException].
  void failSaveWith(String message) => _saveFailure = message;

  /// Sets whether this device reports itself as mobile ([isMobile]) — drives the
  /// platform-dependent file actions (M5 §E).
  void setMobile(bool value) => _mobile = value;

  /// Sets whether the fake claims a 「发送文件夹」 entry (0.2.33).
  void setSupportsSendFolder(bool value) => _supportsSendFolder = value;

  /// Holds the next [pickFolderForSending] until [gate] completes (0.2.33).
  void holdNextSendFolderPick(Completer<void> gate) => _sendFolderHold = gate;

  /// Sets what [pickFolderForSending] answers (0.2.33).
  void setSendFolderReply(SendFolderSelection reply) => sendFolderReply = reply;

  /// Sets whether the fake claims a 「在下载里查看」 action (Android, 0.2.24).
  ///
  /// Kept separate from [setMobile] on purpose: `isMobile` is Android **or iOS**,
  /// while the folder action exists on Android only — a test that folded the two
  /// together could not express "a phone where this row must not appear".
  void setSupportsViewInDownloads(bool value) =>
      _supportsViewInDownloads = value;

  /// Presets the video-frame bytes [readVideoThumbnail] returns for [path].
  void setVideoThumbnail(String path, Uint8List bytes) =>
      _videoThumbs[path] = bytes;

  static const String _zeroHash =
      '0000000000000000000000000000000000000000000000000000000000000000';

  // ── drag-out (0.2.45) ─────────────────────────────────────────────────

  /// Whether this fake claims a drag-out gesture exists.
  ///
  /// Defaults to **false**, the same rule as [supportsViewInDownloads] and
  /// [supportsSendFolder]: a test that wants the gesture has to say so, and every
  /// existing test keeps the attachment rows it had before this feature existed.
  bool _supportsDragOut = false;

  /// Every `paths` list [startDrag] was called with, **in order**.
  ///
  /// This is the observable that criteria 1, 2 and 3 are written against: "the
  /// gesture reached the port, with these exact arguments" and "the port was never
  /// called at all" are both answered by its length.
  final List<List<String>> dragOutRequests = <List<String>>[];

  /// What [startDrag] answers. Defaults to the only success there is.
  DragOutEffect dragOutEffect = DragOutEffect.copy;

  /// When set, [startDrag] throws it instead of answering — this is how the
  /// "the platform reported `move`" contract violation is driven from a test
  /// without a broken runner.
  Object? dragOutError;

  /// Test hook fired **inside** [startDrag], after the call was recorded and
  /// before it answers.
  ///
  /// It is how "the file disappeared because the target moved it" is modelled: set
  /// `setExists(path, false)` here and the drag's own post-check sees it, which is
  /// the only way to test that half without the shell.
  void Function()? onStartDrag;

  /// One-shot gate that parks the next [startDrag] (same trick as
  /// [holdNextHash]): with an instant fake answer there is no moment in which a
  /// drag is "in flight", so a test could not observe the re-check ordering.
  Completer<void>? _dragOutHold;

  @override
  bool get supportsDragOut => _supportsDragOut;

  @override
  Future<DragOutEffect> startDrag(List<String> paths) async {
    // Recorded **before** the hold and before any throw: "the gesture reached the
    // platform with these paths" must be assertable even for a drag that then
    // failed, or a test could not tell "never called" from "called and refused".
    dragOutRequests.add(List<String>.of(paths));
    final Completer<void>? hold = _dragOutHold;
    if (hold != null) {
      _dragOutHold = null;
      await hold.future;
    }
    onStartDrag?.call();
    final Object? error = dragOutError;
    if (error != null) {
      throw error;
    }
    return dragOutEffect;
  }

  /// Sets whether the fake claims a drag-out gesture (0.2.45).
  void setSupportsDragOut(bool value) => _supportsDragOut = value;

  /// Sets what [startDrag] answers (0.2.45).
  void setDragOutEffect(DragOutEffect effect) => dragOutEffect = effect;

  /// Makes the next [startDrag] calls throw [error] (0.2.45) — e.g. the
  /// [DragOutException] a `move` answer produces.
  void failDragOutWith(Object error) => dragOutError = error;

  /// Clears [failDragOutWith] (0.2.45).
  void clearDragOutFailure() => dragOutError = null;

  /// Holds the next [startDrag] until [gate] completes (0.2.45).
  void holdNextDragOut(Completer<void> gate) => _dragOutHold = gate;
}
