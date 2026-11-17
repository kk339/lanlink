/// The **inbound share** port (0.2.18): files another app shared **into**
/// lanlink from the system share sheet.
///
/// The user's report ("相册里点分享，分享列表里找半天也没找到咱这个软件") was a
/// missing feature, not a bug: the manifest only registered `MAIN/LAUNCHER`, so
/// Android had no reason to list lanlink as a share target, and even if it had,
/// nothing read the incoming intent. This port is the Dart half of the answer —
/// the Android host (`MainActivity.kt`, channel `lanlink/share_inbox`) is the
/// other half.
///
/// **Why a port and not the adapter directly:** `AppDeps` (and therefore the
/// whole `ui/**` layer) is pure Dart — it must stay importable from the Web
/// build, where `dart:io` does not exist. So the seam is declared here, in
/// `domain/`, and the only implementation that touches `dart:io` /
/// `MethodChannel` lives in `data/real/android_share_inbox.dart`.
///
/// **Layering (M4 §8.1):** pure Dart — `dart:async` and nothing else. No
/// `dart:io`, no `package:flutter/services.dart`, no `lanlink_*`.
library;

import 'dart:async';

/// One share handed to lanlink by another app.
///
/// The shape is **fixed by the Android side** (`MainActivity.extractShare`) and
/// parsed here with [fromMap], so the payload contract lives in exactly one
/// place on the Dart side too:
///
/// ```json
/// { "uris": ["content://…"], "mime": "video/mp4", "multiple": true }
/// ```
class SharedPayload {
  /// Creates a payload.
  const SharedPayload({
    required this.uris,
    this.mime = '*/*',
    this.multiple = false,
  });

  /// The `content://` (or `file://`) URIs the sender offered, in its order.
  ///
  /// **Order is meaningful**: [ShareInboxPort.materialize] returns local paths
  /// in the same order, so "the third one failed" stays identifiable.
  final List<String> uris;

  /// The intent's MIME type (`*/*` when the sender declared none).
  final String mime;

  /// Whether the sender used `ACTION_SEND_MULTIPLE`.
  final bool multiple;

  /// Whether this payload carries nothing worth importing.
  bool get isEmpty => uris.isEmpty;

  /// Parses the host's payload map, or returns `null` when it is not one.
  ///
  /// Tolerant on purpose: a malformed or empty payload must degrade to "nothing
  /// was shared", never to an exception on the start-up path.
  static SharedPayload? fromMap(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Object? rawUris = raw['uris'];
    if (rawUris is! List) {
      return null;
    }
    final List<String> uris = <String>[
      for (final Object? entry in rawUris)
        if (entry is String && entry.isNotEmpty) entry,
    ];
    if (uris.isEmpty) {
      return null;
    }
    final Object? rawMime = raw['mime'];
    final Object? rawMultiple = raw['multiple'];
    return SharedPayload(
      uris: uris,
      mime: rawMime is String && rawMime.isNotEmpty ? rawMime : '*/*',
      multiple: rawMultiple is bool ? rawMultiple : uris.length > 1,
    );
  }

  @override
  String toString() => 'SharedPayload(${uris.length} uri(s), mime=$mime, '
      'multiple=$multiple)';
}

/// One URI that could **not** be copied into app storage.
///
/// Failures are reported **per URI** instead of failing the whole batch: a
/// share of five photos where one was already deleted must still deliver the
/// other four, and the user (and the log) must be able to tell which one was
/// dropped and why.
class ShareImportFailure {
  /// Creates a failure.
  const ShareImportFailure({required this.uri, required this.reason});

  /// The URI that failed, exactly as the sender supplied it.
  final String uri;

  /// Why it failed — the host's message, or a plain-language fallback.
  final String reason;

  @override
  String toString() => 'ShareImportFailure($uri: $reason)';
}

/// The outcome of [ShareInboxPort.materialize].
///
/// [paths] holds the **successful** local paths in the sender's original order;
/// [failures] names every URI that did not make it. Both together always cover
/// the whole payload, so nothing is silently dropped.
class ShareImport {
  /// Creates an outcome.
  const ShareImport({required this.paths, required this.failures});

  /// An outcome with nothing in it (unsupported platform, empty payload).
  const ShareImport.empty()
      : paths = const <String>[],
        failures = const <ShareImportFailure>[];

  /// Local file-system paths, in the same order as the payload's `uris`.
  final List<String> paths;

  /// The URIs that could not be copied.
  final List<ShareImportFailure> failures;

  /// Whether at least one file made it into app storage.
  bool get hasFiles => paths.isNotEmpty;

  /// Whether every URI failed (or there was nothing to do).
  bool get allFailed => paths.isEmpty && failures.isNotEmpty;

  @override
  String toString() =>
      'ShareImport(${paths.length} path(s), ${failures.length} failure(s))';
}

/// The platform capability: "another app shared files with us".
///
/// One implementation exists today (`AndroidShareInbox`); the Web / test build
/// gets [NoopShareInbox], so the UI can depend on the port unconditionally.
abstract interface class ShareInboxPort {
  /// Whether this platform can receive shares at all.
  bool get isSupported;

  /// The share that **launched** the app, or `null` when there is none.
  ///
  /// **Answers at most once**: the second call returns `null` even if the host
  /// still had a payload, because importing the same share twice would create
  /// two identical drafts — and, after the user sends, two files. That is the
  /// anti-duplicate guarantee the UI relies on.
  Future<SharedPayload?> takeInitial();

  /// Shares that arrive **while the app is already running**.
  ///
  /// Broadcast on purpose: the intake layer is a `ChangeNotifier` that survives
  /// re-mounts, and a listener that attaches late must not steal events from
  /// one that attaches early.
  Stream<SharedPayload> get incoming;

  /// Copies every URI into app-private storage and returns the local paths.
  ///
  /// **Streaming, never in memory**: Android share sheets routinely hand over
  /// several-hundred-megabyte videos, so the copy goes through the same 64 KiB
  /// chunked bridge the file picker uses (`lanlink/file_picker`, method
  /// `copyUris`). A URI that fails is reported in
  /// [ShareImport.failures] and the rest still complete.
  Future<ShareImport> materialize(SharedPayload payload);
}

/// The null object: a platform that cannot receive shares (Web, desktop, tests).
///
/// It exists so `AppDeps.shareInbox` is **non-nullable** and the UI never has to
/// branch on "is there an inbox at all" — the same reason `create_deps_stub`
/// wires in-memory fakes instead of throwing.
class NoopShareInbox implements ShareInboxPort {
  /// Creates the null object.
  const NoopShareInbox();

  @override
  bool get isSupported => false;

  @override
  Stream<SharedPayload> get incoming => const Stream<SharedPayload>.empty();

  @override
  Future<SharedPayload?> takeInitial() async => null;

  @override
  Future<ShareImport> materialize(SharedPayload payload) async =>
      const ShareImport.empty();
}
