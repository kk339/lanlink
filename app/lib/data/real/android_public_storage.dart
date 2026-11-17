/// Android public-storage bridge (0.2.19) — the channel that copies a received
/// file into the public `Download/lanlink` collection.
///
/// **Why it is needed.** The resident receiver writes into the app's private
/// directory (`/data/user/0/<pkg>/files/lanlink/received`). That path is real
/// but invisible: no file manager, no gallery, no USB mount can open it. This
/// bridge asks the Android host to copy the file through `MediaStore.Downloads`
/// with `RELATIVE_PATH = Download/lanlink`, so it lands where every other
/// download on the phone lands.
///
/// **Layering (M4 §8.1):** `data/real/**` — the platform behind it is Kotlin
/// (`MainActivity.publishToDownloads`), reached through the channel
/// `lanlink/public_storage`.
///
/// **The returned path is the host's, verbatim.** A duplicate name is renamed
/// by the platform (`x (1).mp4`), so the host reads the *actual* stored name
/// back and returns the full path. This adapter never re-assembles a path from
/// the requested name — a guessed name is exactly how 复制文件路径 would hand
/// out a path that does not open.
library;

import 'dart:io';

import 'package:flutter/services.dart';

import '../../domain/public_storage.dart';

/// The `lanlink/public_storage` channel name (mirrored in `MainActivity.kt`).
const String kPublicStorageChannel = 'lanlink/public_storage';

/// The Android host bridge for "put this file where the user can find it".
class AndroidPublicStorage implements PublicStoragePort {
  /// Creates the bridge.
  const AndroidPublicStorage();

  static const MethodChannel _channel =
      MethodChannel(kPublicStorageChannel);

  /// Whether this bridge applies here (Android only).
  ///
  /// On every other platform there is nothing to publish: the desktop app-data
  /// directory is already reachable through the OS file manager.
  bool get isSupported => Platform.isAndroid;

  @override
  Future<String?> publishReceivedFile({
    required String srcPath,
    required String displayName,
    String? mime,
    required String subdirectory,
  }) async {
    if (!isSupported) {
      // Desktop / iOS: "leave the file in place". Null is the documented
      // no-op answer, and it keeps desktop behaviour identical to 0.2.18.
      return null;
    }
    final Map<Object?, Object?>? reply;
    try {
      reply = await _channel.invokeMethod<Map<Object?, Object?>>(
        'publish',
        <String, Object?>{
          'srcPath': srcPath,
          'displayName': displayName,
          'mime': mime,
          // 0.2.29 — the folder inside `Download` the user chose, sent with every
          // publish. The host turns it into `RELATIVE_PATH`; it is a name, not a
          // path and not a URI, so nothing downstream has to learn a new type.
          'subdirectory': subdirectory,
        },
      );
    } on MissingPluginException {
      throw const PublicStorageException('安卓导出通道不可用（应用与原生版本不一致）');
    } on PlatformException catch (error) {
      throw PublicStorageException(error.message ?? error.code);
    }

    final Object? path = reply?['path'];
    if (path is String && path.isNotEmpty) {
      return path;
    }
    final Object? error = reply?['error'];
    throw PublicStorageException(
      error is String && error.isNotEmpty ? error : '系统没有返回导出后的路径',
    );
  }
}
