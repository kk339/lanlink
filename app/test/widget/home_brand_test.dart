import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'package:lanlink_app/app_info.dart';
import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/shell/list_pane.dart';

import '../support/png_probe.dart';
import '../support/pump_app.dart';

/// 首页品牌 (docs/18 §3.4) — **in the top bar since 0.2.9** — and the **one**
/// rescan entry (docs/19 §9.9).
///
/// History, because the ruling changed twice and the changes matter:
/// * docs/18 §3.4 copied the reference's round `＋` and deliberately dropped the
///   reference's second round button (扫码配对) — there is no scan-to-pair, so the
///   shape was not copied without its use.
/// * **2026-10-17 (docs/19 §9.9):** the `＋` is **removed**. It opened a
///   **one-item** menu ("添加其他设备") that called `home.rescan()`, while the phone's
///   top bar `⋮` already offers 「重新扫描」 calling the same thing — two entries for
///   one action, one of them behind an extra tap.
/// * **0.2.9:** the brand row itself is **gone**. The brand moved **into the top
///   bar** — the user's own icon artwork (`assets/brand/mark.png`) beside
///   `kAppName` — so the product name is painted once, in the bar, instead of a
///   bar saying 设备 above a row saying lanlink. The logo is now a **real asset**;
///   the coloured square this row drew was a stand-in for a logo that did not
///   exist yet.
/// * Both older rulings **still stand**: no `＋`, and no scan button anywhere.
///
/// The test that used to prove "the ＋ actually rescans" is **kept, moved to the
/// surviving entry**: "tappable" is still not "called".
void main() {
  /// Mounts the phone shell at a phone width. With [initialPeer] the shell opens
  /// on that conversation **instead of** the list (a phone shows one pane), so
  /// the "the home list is up" check is skipped there on purpose.
  Future<FakeBackend> pumpHome(
    WidgetTester tester, {
    PeerDevice? initialPeer,
  }) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: initialPeer,
    );
    if (initialPeer == null) {
      expect(find.byType(ListPane), findsOneWidget,
          reason: 'the home list is up');
    }
    return backend;
  }

  /// The images inside the top bar (never `find.byType(Image)` unscoped: a
  /// thumbnail in the list is an `Image` too).
  Finder barImages() => find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(Image),
      );

  testWidgets(
      '★ the brand is in the TOP BAR: the mark + the product name, exactly once',
      (WidgetTester tester) async {
    await pumpHome(tester);

    // 1) The product name is painted, and it is painted **inside the bar**.
    final Finder name = find.text(kAppName);
    expect(name, findsOneWidget,
        reason: 'the bar carries the product name (docs/18 §3.4)');
    expect(
      find.descendant(of: find.byType(AppBar), matching: name),
      findsOneWidget,
      reason: 'the name must live in the top bar, not in a row under it',
    );
    final Rect bar = tester.getRect(find.byType(AppBar));
    expect(bar.contains(tester.getCenter(name)), isTrue,
        reason: 'the name is geometrically inside the bar');

    // 2) …with the user's mark beside it: a real bundled asset, 24x24.
    expect(barImages(), findsOneWidget, reason: 'one mark, in the bar');
    final Image mark = tester.widget<Image>(barImages());
    expect(
      mark.image,
      isA<AssetImage>().having(
        (AssetImage image) => image.assetName,
        'assetName',
        'assets/brand/mark.png',
      ),
      reason: 'the mark is the bundled artwork, not a drawn placeholder',
    );
    expect(tester.getSize(barImages()), const Size(24, 24));

    // 3) ★ The list starts at the status row — **nothing sits above it**.
    //
    // This is the assertion that can actually tell the new tree from the old
    // one. The naive version ("the ListPane contains no Image") could not: the
    // removed `_brandRow` drew `Container(24x24, color: accent)` + a `Text`,
    // i.e. **zero** `Image` widgets, so putting that row back left it green
    // (caught by the lead's review, 0.2.10). Geometry cannot lie: the removed
    // row pushed the status line down inside the pane.
    //
    // Verified by putting `_brandRow` back at its old call site: this line goes
    // red (measured statusTop = paneTop + 44.0), then green again when it is
    // removed (statusTop == paneTop, delta 0.0).
    final Rect pane = tester.getRect(find.byType(ListPane));
    final Rect status = tester.getRect(find.byType(NetworkStatusRow));
    expect(
      status.top,
      moreOrLessEquals(pane.top, epsilon: 0.5),
      reason: 'the status row is the first thing in the list — no brand row '
          'above it (it moved into the bar, 0.2.9)',
    );

    // 4) docs/19 §9.9 — the ＋ duplicated the ⋮'s 重新扫描 and is gone.
    expect(find.byTooltip('添加其他设备'), findsNothing);
    expect(find.byIcon(Icons.add), findsNothing);
    // The reference's second round button (scan/取景框). We have no scan-to-pair,
    // so it must not be painted (§3.4: "抄了形状、没抄用途") — still true.
    expect(find.byTooltip('扫码配对'), findsNothing);
  });

  testWidgets(
      '★ the conversation DETAIL bar is the peer\'s name and NO brand mark '
      '(a mark over a person reads as "this person belongs to my brand")',
      (WidgetTester tester) async {
    // The regression this guards is cheap to introduce: wrap the brand `Row`
    // around every branch of the bar title and the list still looks right while
    // every conversation now claims to belong to the product.
    await pumpHome(
      tester,
      initialPeer: const PeerDevice(
        fingerprint: 'AAAA1111',
        alias: 'Alice Laptop',
        kind: DeviceKind.desktop,
        isOnline: true,
        lastPort: 53317,
      ),
    );
    expect(find.byType(ListPane), findsNothing,
        reason: 'a phone shows the detail INSTEAD of the list');

    // The title is plain text: the peer's name.
    final Widget? title = tester.widget<AppBar>(find.byType(AppBar)).title;
    expect(title, isA<Text>(), reason: 'the detail title is plain text');
    expect((title! as Text).data, 'Alice Laptop');

    // …and no mark, and no product name, anywhere in the bar.
    expect(barImages(), findsNothing,
        reason: 'the brand icon must not appear above a peer\'s name');
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text(kAppName)),
      findsNothing,
    );
  });

  testWidgets(
      '★ the bar title is NOT announced as an image (the mark is decorative)',
      (WidgetTester tester) async {
    // 0.2.10. Before the fix, `Image` wrapped itself in
    // `Semantics(image: true, label: '')`, which **merged into the AppBar title
    // node** and gave it `isImage` — a screen reader announced
    // "lanlink, image, header". `excludeFromSemantics: true` is what removes it;
    // a `semanticLabel` would have created a second node instead (read twice).
    final SemanticsHandle handle = tester.ensureSemantics();
    try {
      await pumpHome(tester);

      final SemanticsNode bar = tester.getSemantics(find.byType(AppBar));
      // ignore: avoid_print
      print('BRANDSEMANTICS ${bar.toStringDeep()}');
      expect(_imageNodeCount(bar), 0,
          reason: 'nothing in the top bar is an image to a screen reader');
      // …and the name is still there, so the fix did not silence the title.
      expect(
        find.descendant(
            of: find.byType(AppBar), matching: find.text(kAppName)),
        findsOneWidget,
      );
    } finally {
      // `addTearDown` is too late: the framework verifies that every handle is
      // disposed *before* tear-downs run ("A SemanticsHandle was active at the
      // end of the test").
      handle.dispose();
    }
  });

  testWidgets(
      '★ the mark is really published: `flutter.assets` lists assets/brand/, and '
      'the PNG is 96px with a TRANSPARENT background',
      (WidgetTester tester) async {
    // A widget test cannot see the launcher icon, but it CAN see the three
    // things that silently break the in-app mark: an asset directory that
    // pubspec never publishes (the image then fails at runtime while every test
    // still passes), a file whose pixel size is not what the code assumes, and —
    // the one this whole re-render was for — a **plate baked into the PNG**, which
    // turns the 24dp slot into a white square on the bar.
    //
    // All three checks are deliberately narrow (0.2.10, after review):
    // * the assets list is **parsed out of the YAML**, not substring-searched —
    //   `assets/brand/` appears three times in pubspec.yaml (one declaration,
    //   two comments), so `contains()` stayed green with the declaration
    //   deleted;
    // * the size comes from the IHDR;
    // * the transparency comes from the actual alpha channel.
    final Object? pubspec = loadYaml(File('pubspec.yaml').readAsStringSync());
    expect(pubspec, isA<Map<Object?, Object?>>());
    final Object? flutter = (pubspec! as Map<Object?, Object?>)['flutter'];
    expect(flutter, isA<Map<Object?, Object?>>());
    final Object? assets = (flutter! as Map<Object?, Object?>)['assets'];
    expect(assets, isA<List<Object?>>(),
        reason: '`flutter: assets:` must be a list of paths');
    expect(assets! as List<Object?>, contains('assets/brand/'),
        reason: 'the directory must be declared under `flutter: assets:`');

    final File mark1x = File('assets/brand/mark.png');
    final File mark2x = File('assets/brand/mark@2x.png');
    expect(mark1x.existsSync(), isTrue, reason: 'assets/brand/mark.png');
    expect(mark2x.existsSync(), isTrue, reason: 'assets/brand/mark@2x.png');

    final PngProbe mark = PngProbe.read(mark1x);
    final PngProbe markHi = PngProbe.read(mark2x);
    // ignore: avoid_print
    print('BRANDASSET mark=${mark.width}x${mark.height} '
        'corners=${mark.cornerAlphas} '
        'opaque=${(100 * mark.opaqueFraction).toStringAsFixed(1)}% '
        'ink=${mark.inkBounds} | 2x=${markHi.width}x${markHi.height}');

    expect(<double>[mark.widthPx, mark.heightPx], <double>[96, 96],
        reason: '96px is 4x the 24dp slot the bar draws it at');
    expect(<double>[markHi.widthPx, markHi.heightPx], <double>[192, 192],
        reason: 'the @2x copy must be exactly twice the 1x one');

    expect(mark.cornerAlphas, <int>[0, 0, 0, 0],
        reason: 'transparent background: a plate here paints a white square '
            'behind the mark in the top bar');
    expect(mark.opaqueFraction, lessThan(0.85),
        reason: 'a mark on a transparent canvas is a minority of the pixels; '
            '~all of them means the plate leaked back in');
  });

  testWidgets(
      '★ the ⋮\'s 重新扫描 actually TRIGGERS a rescan — "tappable" is not "called"',
      (WidgetTester tester) async {
    // This is the assertion that used to sit on the ＋ menu. The menu closed
    // either way, so "it closes" would pass even for a no-op handler; the counter
    // on the fake is what makes the call observable.
    final FakeBackend backend = await pumpHome(tester);
    final FakePeerDiscovery discovery = backend.discovery;
    expect(discovery.rescanCount, 0, reason: 'nothing rescanned yet');

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新扫描'));
    await tester.pumpAndSettle();

    expect(discovery.rescanCount, 1,
        reason: 'the surviving entry must map to our real capability (rescan)');
  });
}

/// How many nodes in [node]'s subtree carry the "this is an image" semantics
/// flag (0 = the whole bar is text/buttons, as it should be).
int _imageNodeCount(SemanticsNode node) {
  int count = node.getSemanticsData().flagsCollection.isImage ? 1 : 0;
  bool visit(SemanticsNode child) {
    count += _imageNodeCount(child);
    return true;
  }

  node.visitChildren(visit);
  return count;
}
