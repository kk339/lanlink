/// Dragging a file **out** of the app (0.2.45) — the vocabulary the UI and the
/// platform port share.
///
/// **The contract, and why it is narrow.** Windows' own drag-and-drop can answer
/// a drop with four effects: copy, move, link, or nothing. This app only ever
/// asks for **copy** (`DROPEFFECT_COPY` is the single allowed effect the runner
/// passes to `DoDragDrop`), because the file a message points at is still needed
/// by the message: open, reveal-in-folder, 重新发送 and the attachment menu all
/// read the same `localPath`, so a shell that *moved* it away would quietly break
/// the row it came from. On one volume Explorer's default for a plain drag is
/// move — which is exactly the outcome a naive implementation would produce.
///
/// So the answer this app accepts is one of [DragOutEffect]'s **three** values,
/// and anything else is a defect, not a variant: [parseDragOutEffect] throws for
/// `move` (and for anything unknown) rather than folding it into [none]. Folding
/// it in would be the one thing worse than a failed drag — a failed drag the user
/// is not told about.
///
/// Pure Dart (M4 §8.1): no `dart:io`, no `package:flutter` — the same enum is
/// used by the real port, the fake, the timeline and the tests.
library;

/// What a finished drag-out did.
enum DragOutEffect {
  /// The drop target took a **copy** of the files. The only success there is.
  copy,

  /// The user let go where nothing accepted the drop (the desktop's empty
  /// background, another app that takes no files). Nothing happened; nothing is
  /// said — the user already saw the file not move.
  none,

  /// The user pressed `Esc` (or the drag was aborted). Silence, same as [none].
  canceled,
}

/// The runner answered with something this app never allows.
///
/// Two real causes, both of which must be **visible** rather than swallowed:
///
///  * the native side reported `move` (or `link`, or a code nobody knows) — the
///    copy-only contract was broken and the source file may be gone;
///  * the drag channel is missing (an older runner) or failed to initialise OLE —
///    a build-level problem, which is a bug report, not a user mistake.
///
/// The timeline catches this, tells the user 「拖出失败」, and **still re-checks the
/// paths** — because the one consequence that matters (a file that is no longer
/// there) is decided by the filesystem, not by the effect word.
class DragOutException implements Exception {
  /// Creates the exception with a human-readable [message].
  DragOutException(this.message);

  /// A sentence fit to be shown to the user as-is.
  final String message;

  @override
  String toString() => 'DragOutException: $message';
}

/// The runner's word for [DragOutEffect.copy].
const String kDragOutCopy = 'copy';

/// The runner's word for [DragOutEffect.none].
const String kDragOutNone = 'none';

/// The runner's word for [DragOutEffect.canceled].
const String kDragOutCanceled = 'canceled';

/// The word a broken drag source would answer with — never accepted.
const String kDragOutMove = 'move';

/// Maps the runner's answer to a [DragOutEffect], or throws [DragOutException].
///
/// **Exhaustive on purpose.** The three accepted words are matched one by one and
/// `move` has its own arm, so the "we only ever asked for a copy" rule is visible
/// at the place that reads the answer — not buried in the native code where a
/// regression could not be caught from Dart.
DragOutEffect parseDragOutEffect(String raw) {
  switch (raw) {
    case kDragOutCopy:
      return DragOutEffect.copy;
    case kDragOutNone:
      return DragOutEffect.none;
    case kDragOutCanceled:
      return DragOutEffect.canceled;
    case kDragOutMove:
      throw DragOutException('只允许复制，系统却报告了 move（源文件可能已被移走）');
    default:
      throw DragOutException('无法识别的返回结果：$raw');
  }
}
