/// The Android implementation of [ShareInboxPort] — the Dart half of "让 lanlink
/// 出现在系统分享列表里，并把分享进来的文件接住" (0.2.18).
///
/// Two channels:
///
///  * `lanlink/share_inbox` — the **inbound** share. Dart calls
///    `getInitialShare` once at start-up (the intent that launched the app) and
///    the host calls back `onShare` for every `onNewIntent` while the app is
///    already running. Both carry the same payload
///    (`{uris, mime, multiple}`), see [SharedPayload].
///  * `lanlink/file_picker` — **reused, not duplicated**, for the copy itself.
///    Method `copyUris` runs the *same* 64 KiB-chunked stream copy the picker
///    uses (`MainActivity.copyPickedUri`), so a 400 MB video from the gallery is
///    never read into memory. Its byte progress keeps flowing through
///    [AndroidFilePicker.progress], which the thread already listens to.
///
/// Nothing here runs on a non-Android platform: [isSupported] is
/// `Platform.isAndroid`, and every method short-circuits to an empty answer
/// otherwise (the Web build never compiles this file — it is reached only from
/// `create_deps_native.dart`).
///
/// **Layering (M4 §8.1):** `data/real/**` — the platform behind it is Kotlin.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../domain/share_inbox.dart';

/// The host channel that carries inbound shares.
const MethodChannel _shareChannel = MethodChannel('lanlink/share_inbox');

/// The picker's channel — reused here for its streaming copy (`copyUris`).
const MethodChannel _pickerChannel = MethodChannel('lanlink/file_picker');

/// The method the picker channel must expose for [AndroidShareInbox.materialize].
const String kCopyUrisMethod = 'copyUris';

/// Receives the files Android shares **into** lanlink.
class AndroidShareInbox implements ShareInboxPort {
  /// Creates the inbox.
  ///
  /// [enabled] overrides [isSupported]; it exists for tests, which run on a
  /// desktop VM where `Platform.isAndroid` is false but the method channel is
  /// stubbed — without it the whole class would be untestable off-device.
  ///
  /// [onLog] receives one line per interesting event (payload received, per-URI
  /// failure). Failures are logged **and** returned, never swallowed.
  AndroidShareInbox({bool? enabled, void Function(String message)? onLog})
      : _enabled = enabled ?? Platform.isAndroid,
        _onLog = onLog;

  final bool _enabled;
  final void Function(String message)? _onLog;

  /// Fan-out for `onShare` callbacks. Broadcast: the intake layer may attach,
  /// detach and re-attach across re-mounts, and a late listener must not steal
  /// from an early one.
  final StreamController<SharedPayload> _incoming =
      StreamController<SharedPayload>.broadcast();

  /// Guards [takeInitial] — "answers at most once" (see the port's doc).
  ///
  /// The host clears its own copy as well; this flag makes the guarantee hold
  /// even against a host (or a test double) that answers the same payload twice,
  /// which is exactly the "旋转屏幕别导入两遍" requirement.
  bool _initialTaken = false;

  /// Whether the host→Dart handler has been installed.
  bool _handlerInstalled = false;

  @override
  bool get isSupported => _enabled;

  @override
  Stream<SharedPayload> get incoming {
    _installHandler();
    return _incoming.stream;
  }

  @override
  Future<SharedPayload?> takeInitial() async {
    if (!_enabled) {
      return null;
    }
    if (_initialTaken) {
      // Second call: the launch share was already handed over.
      return null;
    }
    _initialTaken = true;
    // Listen before asking, so a share that arrives while the request is in
    // flight is delivered instead of being lost between the two channels.
    _installHandler();
    try {
      final Object? raw =
          await _shareChannel.invokeMethod<Object?>('getInitialShare');
      final SharedPayload? payload = SharedPayload.fromMap(raw);
      if (payload != null) {
        _log('启动分享：${payload.uris.length} 个文件（${payload.mime}）');
      }
      return payload;
    } on PlatformException catch (error) {
      _log('读取启动分享失败：${error.message ?? error.code}');
      return null;
    } on MissingPluginException {
      _log('分享通道不可用（不是 Android 构建）');
      return null;
    }
  }

  @override
  Future<ShareImport> materialize(SharedPayload payload) async {
    if (!_enabled || payload.isEmpty) {
      return const ShareImport.empty();
    }
    _installHandler();
    try {
      final List<Object?>? raw =
          await _pickerChannel.invokeMethod<List<Object?>>(
        kCopyUrisMethod,
        <String, Object?>{'uris': payload.uris},
      );
      return _parseCopyResult(raw, payload);
    } on PlatformException catch (error) {
      // The whole call failed (no bridge, no permission). Report **every** URI
      // as failed instead of dropping the batch: the user must be told.
      final String reason = error.message ?? error.code;
      _log('分享文件拷贝失败：$reason');
      return ShareImport(
        paths: const <String>[],
        failures: <ShareImportFailure>[
          for (final String uri in payload.uris)
            ShareImportFailure(uri: uri, reason: reason),
        ],
      );
    } on MissingPluginException {
      _log('分享文件拷贝的桥不可用');
      return ShareImport(
        paths: const <String>[],
        failures: <ShareImportFailure>[
          for (final String uri in payload.uris)
            ShareImportFailure(uri: uri, reason: '安卓拷贝文件的桥不可用'),
        ],
      );
    }
  }

  /// Turns the host's per-URI answer into a [ShareImport].
  ///
  /// The host answers **in the payload's order**, one entry per URI:
  /// `{uri, path}` on success, `{uri, error}` on failure. `paths` therefore
  /// keeps the sender's order (a test pins that), and a single failed URI never
  /// hides the others.
  ShareImport _parseCopyResult(List<Object?>? raw, SharedPayload payload) {
    if (raw == null) {
      _log('分享文件拷贝没有返回结果');
      return ShareImport(
        paths: const <String>[],
        failures: <ShareImportFailure>[
          for (final String uri in payload.uris)
            ShareImportFailure(uri: uri, reason: '宿主没有返回拷贝结果'),
        ],
      );
    }
    final List<String> paths = <String>[];
    final List<ShareImportFailure> failures = <ShareImportFailure>[];
    for (final Object? entry in raw) {
      if (entry is! Map) {
        continue;
      }
      final Object? rawUri = entry['uri'];
      final Object? rawPath = entry['path'];
      final Object? rawError = entry['error'];
      final String uri = rawUri is String ? rawUri : '';
      if (rawPath is String && rawPath.isNotEmpty && rawError == null) {
        paths.add(rawPath);
        continue;
      }
      final String reason =
          rawError is String && rawError.isNotEmpty ? rawError : '未知原因';
      failures.add(ShareImportFailure(uri: uri, reason: reason));
      _log('分享文件导入失败：$uri（$reason）');
    }
    return ShareImport(paths: paths, failures: failures);
  }

  /// Installs the host→Dart handler exactly once (`onShare`).
  void _installHandler() {
    if (_handlerInstalled || !_enabled) {
      return;
    }
    _handlerInstalled = true;
    _shareChannel.setMethodCallHandler(_onHostCall);
  }

  /// Receives `onShare` from `MainActivity.onNewIntent`.
  Future<Object?> _onHostCall(MethodCall call) async {
    if (call.method != 'onShare') {
      return null;
    }
    final SharedPayload? payload =
        SharedPayload.fromMap(call.arguments as Object?);
    if (payload == null) {
      // Text shares arrive as "no uris" and are deliberately ignored in this
      // version — logged, never thrown (the host logged its side already).
      _log('收到一条没有附件的分享，已忽略');
      return null;
    }
    _log('运行中分享：${payload.uris.length} 个文件（${payload.mime}）');
    _incoming.add(payload);
    return null;
  }

  void _log(String message) {
    _onLog?.call('SHARE $message');
  }
}
