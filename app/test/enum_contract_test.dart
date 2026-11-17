// Drift guard (M4 §9 / A2-19): the app's `domain/` enums must carry **exactly**
// the same wire strings as the frozen `lanlink_store` enums. If someone adds or
// renames a status/kind/direction on either side, this test fails first.
//
// This is a native-only test: it imports `package:lanlink_store` (whose barrel
// pulls in `dart:ffi` via `sqlite3`), which is fine under `flutter test` on the
// VM but is never compiled into the Web build — `test/` sits outside `lib/` and
// is excluded from `flutter build web`.
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/domain/models.dart' as app;
import 'package:lanlink_app/domain/text_limits.dart'
    show kMaxTextBytes, kPreviewMaxChars;
import 'package:lanlink_core/lanlink_core.dart' as core;
import 'package:lanlink_store/lanlink_store.dart' as store;

List<String> _sorted(Iterable<String> wires) => wires.toList()..sort();

void main() {
  group('enum contract: app wire values == store wire values', () {
    test('MessageDirection wires match exactly', () {
      expect(
        _sorted(app.MessageDirection.values.map((e) => e.wire)),
        _sorted(store.MessageDirection.values.map((e) => e.wire)),
        reason:
            'app.MessageDirection.wire must equal store.MessageDirection.wire',
      );
      expect(
        app.MessageDirection.values.length,
        store.MessageDirection.values.length,
      );
    });

    test('MessageKind wires match exactly', () {
      expect(
        _sorted(app.MessageKind.values.map((e) => e.wire)),
        _sorted(store.MessageKind.values.map((e) => e.wire)),
        reason: 'app.MessageKind.wire must equal store.MessageKind.wire',
      );
      expect(
        app.MessageKind.values.length,
        store.MessageKind.values.length,
      );
    });

    test('MessageStatus wires match exactly', () {
      expect(
        _sorted(app.MessageStatus.values.map((e) => e.wire)),
        _sorted(store.MessageStatus.values.map((e) => e.wire)),
        reason: 'app.MessageStatus.wire must equal store.MessageStatus.wire',
      );
      expect(
        app.MessageStatus.values.length,
        store.MessageStatus.values.length,
      );
    });

    test('every app wire is non-empty and unique (guards a typo like "done ")',
        () {
      for (final Iterable<String> wires in <Iterable<String>>[
        app.MessageDirection.values.map((e) => e.wire),
        app.MessageKind.values.map((e) => e.wire),
        app.MessageStatus.values.map((e) => e.wire),
      ]) {
        final List<String> list = wires.toList();
        expect(list.every((w) => w.isNotEmpty), isTrue);
        expect(list.toSet().length, list.length);
      }
    });

    test('app MessageStatus.isTerminal matches the store terminal set', () {
      expect(
        _sorted(
          app.MessageStatus.values
              .where((s) => s.isTerminal)
              .map((s) => s.wire),
        ),
        _sorted(store.terminalStatuses.map((s) => s.wire)),
        reason: 'terminal statuses must agree with store.terminalStatuses',
      );
    });

    test('the app text limit mirrors core kMaxTextBytes', () {
      expect(
        kMaxTextBytes,
        core.kMaxTextBytes,
        reason: 'app kMaxTextBytes must equal core kMaxTextBytes',
      );
    });

    test('the app preview limit mirrors store kPreviewMaxChars', () {
      expect(
        kPreviewMaxChars,
        store.kPreviewMaxChars,
        reason: 'app kPreviewMaxChars must equal store kPreviewMaxChars',
      );
    });
  });
}
