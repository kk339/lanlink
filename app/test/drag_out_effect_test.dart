/// The copy-only contract of a drag-out, at the one place that reads it
/// (0.2.45, criterion 4).
///
/// `parseDragOutEffect` is the seam between "what the Windows runner said" and
/// "what the app is willing to believe": a copy, a drop on nothing, a cancel — and
/// nothing else. A `move` must be a **failure**, not a variant, because the runner
/// only ever allows `DROPEFFECT_COPY`, so a move can only mean the file was carried
/// away from the message that still points at it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/domain/drag_out.dart';

void main() {
  test('the three allowed answers map to their enum value', () {
    expect(parseDragOutEffect(kDragOutCopy), DragOutEffect.copy);
    expect(parseDragOutEffect(kDragOutNone), DragOutEffect.none);
    expect(parseDragOutEffect(kDragOutCanceled), DragOutEffect.canceled);
  });

  test('`move` is rejected — only a copy was ever allowed', () {
    expect(
      () => parseDragOutEffect(kDragOutMove),
      throwsA(
        isA<DragOutException>().having(
          (DragOutException error) => error.message,
          'message',
          contains('只允许复制'),
        ),
      ),
    );
  });

  // A `link` (or any future effect word) is just as unacceptable as `move`: the
  // target accepted a drop this app never offered, so it cannot be reported as
  // "the user dropped the file".
  test('any other effect word is rejected too', () {
    for (final String raw in <String>['link', 'COPY', '', 'copy ']) {
      expect(
        () => parseDragOutEffect(raw),
        throwsA(isA<DragOutException>()),
        reason: 'unexpected acceptance of "$raw"',
      );
    }
  });

  test('the enum has no `move` member to fall back on', () {
    // Pinned as a list: adding `move` to [DragOutEffect] would reopen exactly the
    // hole this file is about (a moved source reported as success).
    expect(
      DragOutEffect.values.map((DragOutEffect effect) => effect.name).toList(),
      <String>['copy', 'none', 'canceled'],
    );
  });
}
