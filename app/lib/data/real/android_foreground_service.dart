/// Android **background keep-alive** (a foreground service).
///
/// Discovery timers, the multicast sockets and the resident HTTPS server all
/// live in the one main Dart isolate. Once the app is backgrounded, Android
/// freezes a *cached* app, so that isolate stops being scheduled: the 5s
/// announcements stop going out and every peer times us out as offline after
/// `PeerRegistry.offlineAfter` — the "在线一会儿就离线" report. A foreground
/// service raises the process's importance so the isolate keeps running
/// (docs/13 §4; the same fix LocalSend 1.18.0 shipped).
///
/// The service type is `connectedDevice`, never `dataSync` (capped at a
/// cumulative 6h/24 from Android 15 — fatal for "stay reachable").
///
/// **Layering (M4 §8.1):** `data/real/**` — the only place that talks to the
/// Android host, over the `lanlink/foreground_service` `MethodChannel` whose
/// handler is `MainActivity.kt`. On every non-Android OS it is a **no-op**, so
/// the desktop paths carry no platform branch and the Web build never parses
/// this file.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// The channel `MainActivity` registers a handler for.
const MethodChannel _channel = MethodChannel('lanlink/foreground_service');

/// How long to wait before re-reading the service's own `status`.
///
/// `startForegroundService` returns to Dart *before* the service's `onStartCommand`
/// runs, so a failure inside the service's own `startForeground` (an
/// `ForegroundServiceStartNotAllowedException`, a missing service-type
/// declaration) cannot be seen in the `start` reply. A short settle lets the
/// follow-up `status` read catch it — that is what keeps "起不来" visible.
const Duration _kStartSettle = Duration(milliseconds: 400);

/// Starts/stops the Android foreground service and reports whether the
/// background keep-alive is actually effective.
class AndroidForegroundService {
  /// Creates the helper.
  ///
  /// [onLog] receives every outcome (start / stop / failure / warning) so it
  /// lands in the on-device log file (`AppLog`).
  ///
  /// [enabled] overrides [isSupported]; it exists for tests, which run on a
  /// host that is not Android (the same seam `AndroidShareInbox(enabled:)`
  /// uses, so the two native adapters are testable the same way).
  AndroidForegroundService({this.onLog, bool? enabled})
      : _enabled = enabled ?? Platform.isAndroid;

  /// Optional diagnostics sink.
  final void Function(String message)? onLog;

  /// Whether the platform seam is live (see the [enabled] constructor flag).
  final bool _enabled;

  bool _started = false;
  String? _warning;

  /// Whether a foreground service is meaningful here (Android only).
  bool get isSupported => _enabled;

  /// A plain-language reason background keep-alive is degraded, or `null`.
  ///
  /// Set when the service could not be started, or when it runs without a
  /// visible notice (POST_NOTIFICATIONS denied on Android 13+). Surfaced by the
  /// UI — never silent.
  String? get warning => _warning;

  /// Whether the service is currently up (best effort).
  bool get isStarted => _started;

  /// Starts the service. Idempotent, and **never throws**: a failure is recorded
  /// in [warning] (and the log) so the UI can say so.
  Future<void> start() async {
    if (!isSupported || _started) {
      return;
    }
    try {
      final Map<String, Object?>? result =
          await _channel.invokeMapMethod<String, Object?>('start');
      if (result == null || result['started'] != true) {
        final String reason = (result?['error'] as String?) ?? '未知原因';
        _warn('后台保活未生效（$reason），息屏后可能掉线');
        return;
      }
      _started = true;
      onLog?.call('foreground service started');
      unawaited(_verifyStarted());
      await _resolveNotificationWarning();
    } on MissingPluginException {
      // The handler is absent (a host without this channel): nothing to do, and
      // not a warning — it is not a failure of the phone's background behaviour.
      onLog?.call('foreground service channel unavailable');
    } on PlatformException catch (error) {
      _warn('前台服务启动失败：${error.message ?? error.code}');
    }
  }

  /// Re-asserts the keep-alive, asking the **platform** instead of trusting our
  /// own latch.
  ///
  /// [start] is a one-shot: it sets `_started` and early-returns forever after.
  /// That is correct for "start it once at launch", and wrong for a resume —
  /// Android may have killed the service while the app was cached, and the
  /// process would then never get it back (`_started` still says true). The
  /// symptom is exactly "息屏一次之后就再也没回来，只能重启".
  ///
  /// So this reads the service's own `status` (`LanlinkForegroundService.
  /// isRunning`) and re-starts only when it is genuinely down, which makes it
  /// safe — and cheap — to call on every resume. Never throws: a failure is
  /// recorded in [warning] and the log, never raised into the UI.
  Future<void> ensureRunning() async {
    if (!isSupported) {
      return;
    }
    if (await _platformReportsRunning()) {
      // It really is up; make our latch agree with reality again.
      _started = true;
      return;
    }
    if (_started) {
      // The interesting case: we believed it was up and the platform disagrees.
      onLog?.call('foreground service is no longer running; re-asserting it');
    }
    _started = false;
    await start();
  }

  /// Whether the host says the service is up, or `false` when it cannot answer
  /// (a missing channel, a platform error — "cannot answer" is not "is up").
  Future<bool> _platformReportsRunning() async {
    try {
      final Map<String, Object?>? status =
          await _channel.invokeMapMethod<String, Object?>('status');
      return status?['running'] == true;
    } on Object {
      return false;
    }
  }

  /// Stops the service (best effort — it also dies with the process).
  Future<void> stop() async {
    if (!isSupported) {
      return;
    }
    _started = false;
    try {
      await _channel.invokeMapMethod<String, Object?>('stop');
      onLog?.call('foreground service stopped');
    } on Object {
      // Best effort: the service dies with the process anyway.
    }
  }

  /// Re-reads the service's own status after [_kStartSettle], to catch a start
  /// failure that happened *inside* the service (see [_kStartSettle]).
  ///
  /// Best effort, and never throws: a failed probe must not itself become an
  /// error, and the app must keep running either way.
  Future<void> _verifyStarted() async {
    await Future<void>.delayed(_kStartSettle);
    try {
      final Map<String, Object?>? status =
          await _channel.invokeMapMethod<String, Object?>('status');
      if (status?['running'] == true) {
        return;
      }
      final String? error = status?['error'] as String?;
      _started = false;
      _warn('前台服务未能保持运行${error == null ? '' : '（$error）'}，息屏后可能掉线');
    } on Object {
      // Best effort only.
    }
  }

  /// Ensures POST_NOTIFICATIONS is asked for, then records a warning when the
  /// notice cannot be shown.
  ///
  /// The keep-alive works either way — only the notice's visibility differs — so
  /// this degrades the **message**, never the function (a denied permission must
  /// not stop the app from running).
  Future<void> _resolveNotificationWarning() async {
    try {
      final bool granted =
          await _channel.invokeMethod<bool>('notificationPermission') ?? false;
      if (granted) {
        _warning = null;
        return;
      }
      // Ask once; the user's answer arrives whenever it arrives (non-blocking).
      await _channel.invokeMethod<bool>('requestNotificationPermission');
      final bool afterRequest =
          await _channel.invokeMethod<bool>('notificationPermission') ?? false;
      if (afterRequest) {
        _warning = null;
      } else {
        _warn('通知权限未授予：后台保活已开启但看不到通知，息屏后仍可能掉线');
      }
    } on Object {
      // The service is up; a permission probe failing must not become an error.
    }
  }

  void _warn(String message) {
    _warning = message;
    onLog?.call(message);
  }
}
