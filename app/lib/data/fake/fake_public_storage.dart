/// In-memory [PublicStoragePort] (tests / preview only).
///
/// Pure Dart (M4 §8.1): it imports only this app's `domain/`, so it is safe to
/// reach from a Web build and from any test.
library;

import '../../domain/public_storage.dart';

/// A [PublicStoragePort] whose answer a test decides.
///
/// * [setPublishedPath] — what a successful publish returns (default `null`,
///   i.e. "this platform has nothing to publish", the desktop behaviour);
/// * [failNextPublish] — make the next publish throw (a full disk, a
///   ROM-tightened permission, `MediaStore` unavailable);
/// * [calls] — every request in order, so a test can assert what was asked for.
class FakePublicStorage implements PublicStoragePort {
  /// Creates the fake.
  FakePublicStorage({String? publishedPath}) : _publishedPath = publishedPath;

  String? _publishedPath;
  Object? _nextError;

  /// Every `publishReceivedFile` request, in order (test convenience).
  ///
  /// [calls] keeps the folder too (0.2.29): the whole point of the setting is
  /// that the *next* received file lands in the newly chosen folder, so a test
  /// has to be able to read what was asked for without a device.
  final List<({
    String srcPath,
    String displayName,
    String? mime,
    String subdirectory,
  })> calls = <({
    String srcPath,
    String displayName,
    String? mime,
    String subdirectory,
  })>[];

  /// Sets the path a successful publish returns (`null` = nothing to do).
  void setPublishedPath(String? path) => _publishedPath = path;

  /// Makes the **next** publish throw [error] (consumed once).
  void failNextPublish(Object error) => _nextError = error;

  @override
  Future<String?> publishReceivedFile({
    required String srcPath,
    required String displayName,
    String? mime,
    required String subdirectory,
  }) async {
    calls.add((
      srcPath: srcPath,
      displayName: displayName,
      mime: mime,
      subdirectory: subdirectory,
    ));
    final Object? error = _nextError;
    if (error != null) {
      _nextError = null;
      throw error;
    }
    return _publishedPath;
  }
}
