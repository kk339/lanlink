/// §3.3 本机信息弹层 (docs/18): the judgements, asserted on real routes.
///
/// **Probe first, assert second** — both prints below are meant to be read in the
/// run output, so a failure shows what was actually there rather than only that
/// an expectation was missed.
///
/// **"No QR" is asserted as "the sheet subtree contains no `Image`"**: we have no
/// QR widget type to look for, and a QR would necessarily be drawn as an image
/// or a custom paint. It is a **proxy**, chosen because it is the strongest
/// available check, not because it is exact.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/ui/shell/list_pane.dart';
import 'package:lanlink_app/ui/widgets/local_info_sheet.dart';

import '../support/pump_app.dart';

const String _alias = 'xmi';
const String _addr = '192.168.1.23';
const String _fp = 'AB12CD34EF56';
const int _port = 53317;

/// Opens the sheet the way the app does (the show-function), without the shell.
Future<void> _openDirectly(WidgetTester tester) async {
  await pumpApp(
    tester,
    Scaffold(
      body: Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () => showLocalInfoSheet(
            context,
            alias: _alias,
            address: _addr,
            port: _port,
            fingerprint: _fp,
          ),
          child: const Text('open'),
        ),
      ),
    ),
    settle: true,
  );
  await tester.tap(find.text('open'));
}

void main() {
  testWidgets('sheet: full-bleed, dimmed, comes UP from the bottom, no QR',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    await _openDirectly(tester);

    // A frame or two into the route, while it is still climbing.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final Rect early = tester.getRect(find.byType(BottomSheet));

    await tester.pumpAndSettle();
    final Rect settled = tester.getRect(find.byType(BottomSheet));
    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final ModalBarrier barrier =
        tester.widget<ModalBarrier>(find.byType(ModalBarrier).last);
    // ignore: avoid_print
    print('SHEETFULL early=$early settled=$settled screen=$screen '
        'barrier=${barrier.color}');

    // ① full-bleed: spans the whole screen width (not a floating card).
    //
    // ★ Anchored on **our own content**, not on the framework's `BottomSheet`:
    // reverse proof 2 showed why. Constraining the body to 400dp left the
    // `BottomSheet` surface at the full 600dp, so measuring *it* could never go
    // red — it was measuring the framework, not our layout. This measures the
    // sheet body we actually ship.
    expect(
      tester.getRect(find.byKey(kLocalInfoSheetKey)).width,
      screen.width,
    );
    // ② anchored to the bottom edge…
    expect(settled.bottom, screen.height);
    // ③ …and it got there by moving UP (its top was lower earlier).
    expect(
      early.top,
      greaterThan(settled.top),
      reason:
          'the sheet must slide up from below, early=$early settled=$settled',
    );
    // ④ the dimmed backdrop is the barrier we set.
    expect(barrier.color, const Color(0x24000000));
    // ⑤ the four fields are on it.
    expect(find.text(_alias), findsOneWidget);
    expect(find.text(_addr), findsOneWidget);
    expect(find.text('$_port'), findsOneWidget);
    expect(find.text(_fp), findsOneWidget);
    // ⑥ **No QR — judged on the *thing*, not on one way of drawing it.**
    //
    // The previous check was "no `Image` in the sheet", which was blind to the
    // likeliest implementation: an `Icon(Icons.qr_code)`. Material icons are
    // **font glyphs, not images**, so that check could never have gone red for
    // one — the same disease as ① (measuring the wrong object).
    //   1. semantic check — catches a QR that says what it is;
    //   2. visible-object count — catches *any* new visible object of either kind.
    //      ★ This is not an automatic verdict: if the number moves, a **human**
    //      must confirm what was added. It is a forced look, not a decision.
    // NB: dispose **inside the test body** — the framework verifies that every
    // SemanticsHandle is gone *before* `addTearDown` callbacks run, so
    // `addTearDown(handle.dispose)` fails at the end of the test.
    final SemanticsHandle handle = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel(RegExp('二维码|QR')),
      findsNothing,
      reason: 'the user ruled the QR out until a scan-to-pair landing exists',
    );
    final int visibleObjects = find
        .descendant(
          of: find.byKey(kLocalInfoSheetKey),
          matching: find.byWidgetPredicate(
            (Widget w) => w is Image || w is Icon,
          ),
        )
        .evaluate()
        .length;
    expect(
      visibleObjects,
      0,
      reason: 'the sheet carries no image and no icon today. If this number '
          'moved, a human must confirm what was added — do not just bump it.',
    );
    handle.dispose();
  });

  testWidgets('entry: the home status row is the way in, and nothing else is',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    // Nothing has opened it by itself.
    expect(find.byKey(kLocalInfoSheetKey), findsNothing);

    final Finder row = find.byType(NetworkStatusRow);
    expect(row, findsOneWidget, reason: 'the single entry must be on screen');
    await tester.tap(row);
    await tester.pumpAndSettle();

    final int opened = find.byKey(kLocalInfoSheetKey).evaluate().length;
    final bool placeholder = find.text('（未获取）').evaluate().isNotEmpty;
    // ignore: avoid_print
    print('SHEETENTRY opened=$opened addressIsPlaceholder=$placeholder');
    expect(find.byKey(kLocalInfoSheetKey), findsOneWidget);
  });
}
