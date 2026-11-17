/// Web fallback for [spawnHashWorker]: there is no `dart:isolate` in a browser,
/// so no worker can be spawned and the inline path is used.
///
/// This file is the **default** branch of the conditional import in
/// `isolate_hasher.dart` (`if (dart.library.io) 'hash_worker_isolate.dart'`), so
/// it is the one a `flutter build web` compiles. It must therefore stay free of
/// `dart:isolate` **and** of `dart:io` — importing either would break the Web
/// build of `lanlink_core`, which is otherwise platform-independent.
///
/// The throw is not an error path to be caught here: `IsolateHasher` treats a
/// failed spawn as "this platform has no worker" and hashes inline, which is the
/// pre-0.2.16 behaviour. On Web that costs nothing extra: the receiver there is a
/// preview build, not the transfer path.
library;

import 'hash_worker.dart';

/// Throws [UnsupportedError]; see the library doc.
Future<HashWorkerBackend> spawnHashWorker() async {
  throw UnsupportedError(
    'no dart:isolate on this platform: hash inline instead',
  );
}
