/// Android file-action bridge (M5 §C/§D/§E, extended in 0.2.24) — **open**,
/// **share**, **video-frame** extraction and **show me the Downloads folder**,
/// all through the host.
///
/// On Android there is no "show me the file's folder", so the desktop
/// `openFile` / `revealInFolder` pair lands differently: **open** hands the file
/// to the system viewer / player, **share** hands it to the share sheet. Both go
/// out as a `FileProvider` `content://` URI (a `file://` URI would throw
/// `FileUriExposedException` on Android 7+). **videoThumbnail** extracts a single
/// scaled frame with `MediaMetadataRetriever` — the whole video is never read.
///
/// **0.2.24 added [viewInDownloads].** 0.2.19 publishes every received file into
/// the public `Download/lanlink` collection, and until now the user still had to
/// go find it. The desktop equivalent (`revealInFolder`) has no Android form at
/// all, so this is a **new** action rather than a translation of that one: it
/// opens the *folder* through `DocumentsContract` (`ACTION_VIEW` +
/// `MIME_TYPE_DIR`). A ROM without a document UI answers
/// [ViewInDownloadsOutcome.noApp] instead of doing nothing.
///
/// **Layering (M4 §8.1):** `data/real/**` — the platform behind it is Kotlin.
library;

import 'dart:io';

import 'package:flutter/services.dart';

import '../../domain/platform_ports.dart' show ViewInDownloadsOutcome;

const MethodChannel _channel = MethodChannel('lanlink/file_actions');

/// The Android host bridge for "do things with a local file".
class AndroidFileActions {
  /// Creates the bridge.
  const AndroidFileActions();

  /// Whether this bridge applies here (Android only).
  bool get isSupported => Platform.isAndroid;

  /// Hands [path] to the system's default viewer / player (ACTION_VIEW).
  Future<void> open(String path) => _invoke('open', path);

  /// Hands [path] to the system share sheet (ACTION_SEND).
  Future<void> share(String path) => _invoke('share', path);

  /// Opens the public `Download/lanlink` folder in the system file manager.
  ///
  /// Answers what the host said, mapped by [parseViewInDownloadsReply]; nothing
  /// is thrown and [ViewInDownloadsOutcome.opened] is never assumed. [path] is
  /// carried along for the host's log line — the folder is what opens.
  ///
  /// A **missing bridge** (Dart and the native side out of step, e.g. a stale
  /// APK) maps to [ViewInDownloadsOutcome.failed], not to
  /// [ViewInDownloadsOutcome.unsupported]: on Android the capability exists in
  /// principle, so telling the user "this system has no app for that" would be a
  /// wrong diagnosis of a packaging problem.
  Future<ViewInDownloadsOutcome> viewInDownloads(
    String path, {
    String? subdirectory,
  }) =>
      _openDownloads(path: path, subdirectory: subdirectory);

  /// Opens the folder **without** naming a file (0.2.26).
  ///
  /// The settings row 「文件保存位置」 names a directory and nothing else, so no
  /// path is sent at all — the `path` key is simply omitted from the arguments
  /// (not set to an empty string, not to a synthesised file name). The native
  /// side treats it as optional and only uses it for its log line; see
  /// `MainActivity.viewInDownloads`.
  Future<ViewInDownloadsOutcome> openDownloadsFolder({String? subdirectory}) =>
      _openDownloads(path: null, subdirectory: subdirectory);

  /// The one native call behind both [viewInDownloads] and
  /// [openDownloadsFolder].
  ///
  /// [subdirectory] travels **per call** (0.2.29) instead of being remembered in
  /// Kotlin: a native-side copy of the setting is the 0.2.23 defect waiting to
  /// happen again (UI says 素材, the process still holds `lanlink` until the next
  /// restart). Stateless native + a value on every call cannot drift.
  Future<ViewInDownloadsOutcome> _openDownloads({
    required String? path,
    String? subdirectory,
  }) async {
    if (!isSupported) {
      return ViewInDownloadsOutcome.unsupported;
    }
    final Map<Object?, Object?>? reply;
    try {
      reply = await _channel.invokeMethod<Map<Object?, Object?>>(
        'viewInDownloads',
        <String, Object?>{
          if (path != null && path.isNotEmpty) 'path': path,
          if (subdirectory != null && subdirectory.isNotEmpty)
            'subdirectory': subdirectory,
        },
      );
    } on MissingPluginException {
      return ViewInDownloadsOutcome.failed;
    } on PlatformException {
      return ViewInDownloadsOutcome.failed;
    }
    return parseViewInDownloadsReply(reply);
  }

  /// Maps the host's `{result: …}` reply to a [ViewInDownloadsOutcome].
  ///
  /// The wire values are the ones `MainActivity.viewInDownloads` answers:
  /// `opened` / `no_app` / `no_directory` / `unsupported` / `failed`. **Anything
  /// else — including a null reply, a reply that is not a map, or an unknown
  /// word — is [ViewInDownloadsOutcome.failed]**, i.e. "it did not open". The
  /// default must never be [ViewInDownloadsOutcome.opened]: a silent success is
  /// how the user ends up staring at a screen that did not change.
  ///
  /// Public so the mapping can be unit-tested without an Android runtime.
  static ViewInDownloadsOutcome parseViewInDownloadsReply(Object? reply) {
    final Object? code = reply is Map ? reply['result'] : null;
    return switch (code) {
      'opened' => ViewInDownloadsOutcome.opened,
      'no_app' => ViewInDownloadsOutcome.noApp,
      'no_directory' => ViewInDownloadsOutcome.noDirectory,
      'unsupported' => ViewInDownloadsOutcome.unsupported,
      'failed' => ViewInDownloadsOutcome.failed,
      _ => ViewInDownloadsOutcome.failed,
    };
  }

  /// Extracts **one** video frame as JPEG bytes, or `null`.
  ///
  /// [maxBytes] caps the result: an over-cap (or unextractable) frame returns
  /// `null` rather than a truncated image, so the caller falls back to the type
  /// icon — a video with no cover is fine, a broken image is not. Never throws:
  /// a failure is a quiet `null` (M5 §C "失败静默降级回图标，绝不许崩").
  Future<Uint8List?> videoThumbnail(String path, {int? maxBytes}) async {
    if (!isSupported) {
      return null;
    }
    try {
      return await _channel.invokeMethod<Uint8List>(
        'videoThumbnail',
        <String, Object?>{'path': path, 'maxBytes': maxBytes},
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Invokes a path-taking method, mapping "no bridge" to an honest error.
  Future<void> _invoke(String method, String path) async {
    if (!isSupported) {
      throw UnsupportedError('文件操作仅支持安卓：${Platform.operatingSystem}');
    }
    try {
      await _channel.invokeMethod<void>(
        method,
        <String, Object?>{'path': path},
      );
    } on MissingPluginException {
      throw UnsupportedError('安卓文件操作的桥不可用');
    }
  }
}
