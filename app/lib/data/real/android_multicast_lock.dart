/// Android **multicast lock** (discovery on a phone).
///
/// Android's Wi-Fi stack drops multicast/broadcast frames unless a
/// `WifiManager.MulticastLock` is held, so the app cannot RECEIVE the peer
/// discovery announcements without one. The `CHANGE_WIFI_MULTICAST_STATE`
/// permission only allows taking the lock — the lock itself must be taken and
/// released, which is what this class does.
///
/// **Layering (M4 §8.1):** `data/real/**` — this is the only place that talks to
/// the Android host, over the `lanlink/multicast_lock` `MethodChannel` whose
/// handler is `MainActivity.kt`. On every non-Android OS it is a **no-op that
/// reports success**, so callers need no platform branch of their own.
library;

import 'dart:io';

import 'package:flutter/services.dart';

/// The channel `MainActivity` registers a handler for.
const MethodChannel _channel = MethodChannel('lanlink/multicast_lock');

/// Takes/releases the Android multicast lock.
class AndroidMulticastLock {
  /// Creates the helper.
  const AndroidMulticastLock();

  /// Whether a lock is meaningful here (Android only).
  bool get isSupported => Platform.isAndroid;

  /// Requests the lock.
  ///
  /// Returns `true` when the lock is held (or not needed on this OS), and
  /// `false` when it could **not** be taken — a missing/unavailable Wi-Fi
  /// service, or a platform error. The caller must surface a `false` (discovery
  /// may not work) rather than assume it succeeded.
  Future<bool> acquire() async {
    if (!isSupported) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>('acquire') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Releases the lock. Best-effort: returns `false` on failure (so the caller
  /// can log it) and never throws.
  Future<bool> release() async {
    if (!isSupported) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>('release') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
