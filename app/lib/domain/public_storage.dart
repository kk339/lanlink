/// Public-storage port (0.2.19): "put a received file where the user can find
/// it".
///
/// **Why this exists.** The resident receiver streams an accepted upload into
/// the app's own directory (`getFilesDir()/lanlink/received` on Android). That
/// path is *correct* but *private*: the file manager, the gallery, the USB
/// mount and every other app are blind to it, so 复制文件路径 handed the user a
/// `/data/user/0/<pkg>/…` string they could not open anywhere. On desktop the
/// equivalent directory (`%LOCALAPPDATA%\lanlink\received`) is reachable through
/// Explorer, which is why this is an **Android-only** problem.
///
/// The fix is a *publish* step after verification: copy the verified bytes into
/// the public Downloads collection and hand back the path the platform really
/// used (a duplicate name is renamed by the platform, so the final name must be
/// **read back**, never guessed).
///
/// **Layering (M4 §8.1):** pure Dart — this file only declares the surface. The
/// native adapter (`data/real/android_public_storage.dart`) owns the
/// `MethodChannel`; the fake answers from memory.
library;

/// Thrown when the platform refused to publish a file (no space, MediaStore
/// unavailable, a ROM-tightened permission, …).
///
/// [message] is meant for the user-facing log line, so it is kept short and
/// concrete ("系统 Downloads 拒绝登记这个文件"), never a bare exception dump.
class PublicStorageException implements Exception {
  /// Creates the exception with a human-readable [message].
  const PublicStorageException(this.message);

  /// A human-readable reason.
  final String message;

  @override
  String toString() => 'PublicStorageException: $message';
}

/// Publishes one file into the platform's **user-visible** storage.
abstract interface class PublicStoragePort {
  /// Copies the file at [srcPath] into the public store under [displayName].
  ///
  /// [subdirectory] is the folder **inside** the platform's downloads root that
  /// the user chose (0.2.29) — `lanlink` for the shipped default, `素材` or
  /// `素材/2026` after a pick. It is a name relative to that root, never a path
  /// and never a URI: the platform turns it into a `RELATIVE_PATH`, which is what
  /// keeps the whole receive path working on real absolute paths.
  ///
  /// Returns the **actual** absolute path the platform wrote (e.g.
  /// `/storage/emulated/0/Download/lanlink/xxx.mp4`), or `null` when this
  /// platform needs no publishing step at all — a desktop's app-data directory
  /// is already reachable, so the caller must leave the file in place.
  ///
  /// Throws [PublicStorageException] when the publish was attempted and failed.
  /// The caller keeps the private path in that case and reports the failure;
  /// it must **never** treat a failure as "no file".
  ///
  /// A successful publish must not delete [srcPath]: removing the private copy
  /// is the Dart side's job (single responsibility — and it keeps this port's
  /// only side effect on the public side).
  Future<String?> publishReceivedFile({
    required String srcPath,
    required String displayName,
    String? mime,
    required String subdirectory,
  });
}

// 0.2.23 deleted `NoopPublicStorage` from this file: nothing in `lib/` or
// `test/` ever constructed it (the native wiring passes `AndroidPublicStorage`,
// whose own non-Android branch already answers `null`), so it was a second,
// unexercised spelling of "this platform has nothing to publish". A dead null
// object is worse than none — it reads as a supported configuration while
// quietly not being one.
