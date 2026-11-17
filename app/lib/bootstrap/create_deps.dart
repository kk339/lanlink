/// Chooses the concrete [AppDeps] for the current platform.
///
/// On native (desktop/VM) `dart.library.io` exists -> the real adapters are
/// compiled. On any non-`dart:io` target the stub is compiled instead and **the
/// native imports are never even parsed** (neither `lanlink_core` nor
/// `lanlink_store` is safe to compile there). This app ships Windows + Android
/// only, so the stub branch is what keeps pure-Dart analysis/tests of
/// `domain/` + `ui/` free of native dependencies.
///
/// Both branches export the same top-level symbol:
/// `Future<AppDeps> createAppDeps()` (spec §3.4).
library;

export 'create_deps_stub.dart' if (dart.library.io) 'create_deps_native.dart';
