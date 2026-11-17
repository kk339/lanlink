/// **One** answer to "is this attachment's source file still on disk?" (0.2.48).
///
/// The defect this file answers: the same file used to get **three different
/// verdicts**, one per surface that draws it.
///
/// | surface | what it asked | consequence |
/// |---|---|---|
/// | the conversation timeline (`ConversationThread._probeSources`) | only `outgoing` messages in `failed` / `canceled`, through `canResend` | a `done` message whose file went away kept looking healthy |
/// | the 文件 tab (`ConversationFiles`) | **nothing** | every row stayed tappable, including files that were long gone |
/// | the 最近文件 page (`RecentFilesController`) | every attachment, every conversation | it was the only page telling the truth |
///
/// So one file could read 「已不在原位置」 on one page, stay normally clickable in
/// the same conversation's 文件 tab, and only be flagged in the timeline if its
/// message happened to have **failed** — while the state itself was `done`.
///
/// The rule is now a single sentence, and it is deliberately **not** about a
/// message's direction or status: *an attachment is unavailable exactly when its
/// `localPath` is not on disk.* That is the only fact all three surfaces can
/// share, and it is the fact the user is asking about when he taps 「打开」.
///
/// ## Why an object and not three copies of a loop
///
/// Each surface owns its **own instance**: the timeline and the 文件 tab are
/// separate `State`s (`DetailPane` re-keys them per conversation and per tab), and
/// the recent-files page is a controller. Sharing an *instance* across them would
/// mean a singleton, and a process-wide cache of "this file is gone" is the kind
/// of hidden state that makes one page's opinion leak into another's (and into
/// the next test in the same process). What is shared is the **judgement** —
/// [probeFiles] and [isOnDisk] — so the three answers come from one rule even
/// though they are three caches.
///
/// The disk itself is what makes the verdict survive things this object cannot:
/// see [probeFiles] and the note in `ConversationThread` about the 拖出 mark,
/// which used to be a `State` field and therefore died on every tab switch.
///
/// ## Layering (M4 §8.1)
///
/// Pure Dart: `domain/models.dart` + `domain/platform_ports.dart`, no
/// `package:flutter/*`, no `dart:io`. Unit-testable with a fake port.
library;

import 'models.dart';
import 'platform_ports.dart';

/// The last observed answer to "is this path on disk?" — see the library doc.
///
/// **Unknown ⇒ on disk.** Before the first probe a row must not be accused of
/// being gone: the timeline paints its bubbles on the frame the history arrives
/// and the probe answers a moment later, so "unknown" has to read as the
/// ordinary state. [isOnDisk] therefore defaults to `true`, and a file only ever
/// becomes unavailable on an **observed** miss ([probeFiles]) or an explicit
/// [markGone] from a caller that watched it disappear.
class SourceAvailability {
  /// Creates an empty cache (see the library doc for why it is not a singleton).
  SourceAvailability();

  /// Path → the last answer this instance observed.
  final Map<String, bool> _answers = <String, bool>{};

  /// Paths a caller **saw** disappear (a drag-out that moved the file, a tap on
  /// 「打开」 that found nothing). These outrank a later probe: we told the user
  /// the file is gone, and a stale `exists` (a cache hit, a path that a second
  /// device re-created) must not silently retract that while the row is on
  /// screen.
  final Set<String> _gone = <String>{};

  /// Whether [path] is on disk, as last observed (`null` / empty ⇒ `true`: there
  /// is no file to be wrong about).
  bool isOnDisk(String? path) {
    if (path == null || path.isEmpty) {
      return true;
    }
    return _answers[path] ?? true;
  }

  /// Whether **any** of [files] is off disk.
  ///
  /// The message-level form of the same rule, and the reason it can be derived
  /// instead of probed separately: the timeline draws one bubble per message and
  /// every operation that bubble still offers (打开 / 打开所在位置 / 重新发送)
  /// walks **all** of its attachments, so one missing file makes the row's whole
  /// story false. The 文件 tab and the recent-files page stay per-attachment —
  /// they draw one row per file — but they read the same [isOnDisk].
  bool anyUnavailable(Iterable<FileAttachment> files) {
    for (final FileAttachment file in files) {
      if (!isOnDisk(file.localPath)) {
        return true;
      }
    }
    return false;
  }

  /// Records that [path] is **gone**, permanently for this cache.
  ///
  /// Called from the two places that *watched* it happen: the attachment row's
  /// 「打开」 (the probe said the file is not there) and the drag-out post-check
  /// (`platform.startDrag` returned and the source no longer existed).
  void markGone(String path) {
    if (path.isEmpty) {
      return;
    }
    _gone.add(path);
    _answers[path] = false;
  }

  /// Probes every attachment in [files] and caches the answers.
  ///
  /// Deduplicated by path: a folder message can declare the same source twice
  /// (a re-sent file reuses its path), and one `exists` per distinct path is
  /// what the 最近文件 page already did for the whole database.
  ///
  /// A **throwing** `exists` counts as on disk. The port is called on every
  /// message of the conversation, so a host that cannot answer must not be
  /// allowed to turn a working attachment into a greyed-out row — the failure
  /// mode of a wrong "gone" (a file the user cannot open) is worse than a wrong
  /// "there" (a tap that reports the truth a moment later).
  Future<void> probeFiles(
    Iterable<FileAttachment> files,
    PlatformPorts platform,
  ) async {
    final Set<String> paths = <String>{};
    for (final FileAttachment file in files) {
      final String? path = file.localPath;
      if (path != null && path.isNotEmpty) {
        paths.add(path);
      }
    }
    for (final String path in paths) {
      if (_gone.contains(path)) {
        _answers[path] = false;
        continue;
      }
      bool onDisk;
      try {
        onDisk = await platform.exists(path);
      } on Object {
        onDisk = true;
      }
      _answers[path] = onDisk;
    }
  }
}
