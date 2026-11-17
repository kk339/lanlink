/// A tiny append-only diagnostic log for the app.
///
/// Writes go through a buffered [IOSink] and are flushed right away, so logging
/// never blocks the event loop — this project has already been burned by a
/// "did something freeze the isolate?" question, and the log must not become
/// the thing that blocks it. The file is truncated once at start-up when it
/// exceeds [maxBytes], so it can run for weeks without eating the disk.
///
/// Why a **file** and not `print`: the bug we are chasing reproduces on a
/// user's own phone, so the evidence has to land somewhere the user can send
/// back. `print` only reaches a console they cannot easily reach.
///
/// **Layering (M4 §8.1):** `data/real/**` — uses `dart:io`, referenced only by
/// `bootstrap/create_deps_native.dart`, so the Web build never parses it.
library;

import 'dart:async';
import 'dart:io';

/// An append-only, timestamped log written to **one or more** files.
class AppLog {
  AppLog._(this._sinks, this.openedPaths);

  final List<IOSink> _sinks;

  /// The destinations that could actually be opened, in the order given.
  ///
  /// Exposed so the start-up line can name them: on Android the private
  /// directory is unreachable by the user, so the log is also written to the
  /// app's *external* files directory — and telling the user where it is beats
  /// making them ask.
  final List<String> openedPaths;

  /// Opens (creating it, and truncating an oversized one) the log at [path].
  ///
  /// A file larger than [maxBytes] is emptied once, here, rather than rotated:
  /// one recent run is all the diagnostics this tool needs, and truncation
  /// cannot leave a half-written rotation behind.
  static Future<AppLog> open(String path, {int maxBytes = 1 << 20}) =>
      openMany(<String>[path], maxBytes: maxBytes);

  /// Opens every [path] that can be written; the rest are skipped.
  ///
  /// A destination that cannot be opened (no external storage mounted, a
  /// permission the OS refuses) must **never** stop start-up, and must not cost
  /// us the other copies — the first path is expected to be the guaranteed
  /// private one, so losing a secondary only degrades reachability, not
  /// logging.
  static Future<AppLog> openMany(
    Iterable<String> paths, {
    int maxBytes = 1 << 20,
  }) async {
    final sinks = <IOSink>[];
    final opened = <String>[];
    for (final path in paths) {
      try {
        final File file = File(path);
        // Probe with an **awaitable** write before handing the file to a sink:
        // a failing `File.openWrite` reports itself as an *unhandled async*
        // error, which no try/catch here (nor the caller) could stop — that is
        // how a bad second destination could still have broken start-up. An
        // awaited write makes the failure catchable, so "skip it" is real.
        await file.writeAsString('', mode: FileMode.append);
        if (await file.length() > maxBytes) {
          await file.writeAsString('');
        }
        final IOSink sink = file.openWrite(mode: FileMode.append);
        // A broken log must never take the app down; ignore write/close errors.
        unawaited(sink.done.catchError((Object _) {}));
        sinks.add(sink);
        opened.add(path);
      } on Object {
        // Unwritable destination: skip it, keep the others.
      }
    }
    return AppLog._(sinks, opened);
  }

  /// The tail of the write chain: **exactly one write is in flight at a time**.
  ///
  /// `IOSink.flush()` binds the sink to a stream, so a second `writeln` while a
  /// flush is still outstanding throws `Bad state: StreamSink is bound to a
  /// stream`. Startup logs many lines back-to-back (one per interface
  /// candidate), so the writes are serialized here instead of fired
  /// concurrently — that crash took the whole app down at `createAppDeps`.
  Future<void> _chain = Future<void>.value();

  /// Appends one timestamped [message] as a single line to every open sink.
  ///
  /// **Synchronous, ordered and never throwing.** Callers are callbacks that
  /// cannot await and cannot handle an exception: logging must never be able to
  /// break the thing being logged, let alone stop start-up. The line is queued
  /// on [_chain]; every failure on the way to disk is swallowed.
  void log(String message) {
    try {
      final String line = '${DateTime.now().toIso8601String()}  $message';
      _chain = _chain.then((_) => _writeAll(line)).catchError((Object _) {});
    } on Object {
      // Diagnostics must never break the caller (see the doc above).
    }
  }

  /// Writes [line] to every sink in turn, awaiting each flush.
  Future<void> _writeAll(String line) async {
    for (final IOSink sink in _sinks) {
      try {
        sink.writeln(line);
        await sink.flush().catchError((Object _) {});
      } on Object {
        // One broken destination must not cost us the others.
      }
    }
  }

  /// Waits for every queued write, then closes each file (never throwing).
  Future<void> close() async {
    await _chain.catchError((Object _) {});
    for (final IOSink sink in _sinks) {
      try {
        await sink.close();
      } on Object {
        // A broken log sink must never make closing it throw.
      }
    }
  }
}
