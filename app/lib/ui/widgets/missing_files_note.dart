import 'package:flutter/material.dart';

/// 「N 个未收到」 — how many files of one `prepare` session were **never
/// delivered** (0.2.38, made provable in 0.2.42, extended to flat batches in
/// 0.2.52).
///
/// **One sentence, one style, one place.** This line is printed on two different
/// surfaces for the *same* fact:
///
/// * inside a **folder card** (`message_bubble.dart`'s `notes` block) — a folder
///   that stalled with 3 of 5 files;
/// * under a **flat multi-select bubble** (`conversation_thread.dart`) — a batch
///   that declared 8 files and delivered 3. Since 0.2.51 that batch is **one**
///   message, so the shortfall has nowhere else to show: before the fold it was
///   five missing bubbles, which the eye caught on its own.
///
/// The two must not drift apart, which is why the string and the ramp live here
/// rather than being written out twice. They are the **same** slot as
/// `publishNote` / `failureNote` — a remark on a `done` message, not a failure —
/// hence `bodySmall` in `onSurfaceVariant`, never the error colour.
///
/// The widget takes a **count**, never a message: *whether* the row is earned
/// (`declared - arrived`, and only after `kFolderQuietPeriod` of silence) is
/// decided by `selectors.dart::missingFolderFiles` in the caller, and `0` simply
/// draws nothing — 「0 个未收到」 is not a sentence anybody should read.
class MissingFilesNote extends StatelessWidget {
  /// Creates the note for [count] files that will not arrive.
  ///
  /// [count] must be the number `missingFolderFiles` returned; a value `<= 0`
  /// renders an empty box (see [build]) so a caller that forgot to gate cannot
  /// invent a line.
  const MissingFilesNote({super.key, required this.count});

  /// Files that will not arrive. `> 0` for anything to be drawn.
  final int count;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (count <= 0) {
      return const SizedBox.shrink();
    }
    // `SelectionContainer.disabled` for the same reason as every other note: the
    // timeline owns **one** `SelectionArea`, and a diagnosis is not something the
    // user typed — dragging from a bubble must not pick this up.
    return SelectionContainer.disabled(
      child: Text(
        '$count 个未收到',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
