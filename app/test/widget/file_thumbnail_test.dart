/// Widget tests for [FileThumbnail] (design §5.5 / T02; PRD §8-G27–G33).
///
/// The thumbnail is the one place the UI reads file bytes, and the one place a
/// *path-keyed* cache lives (spec §5.1). These tests pin both: which files read
/// the port at all, what happens when the port returns `null`, and that a repeat
/// render of the same path does **not** re-read.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/ui/widgets/file_thumbnail.dart';
import 'package:lanlink_app/ui/widgets/type_icon.dart';

import '../support/pump_app.dart';

/// A valid **1×1 transparent (RGBA) PNG**, so `Image.memory` decodes without
/// error (the port's thumbnail needs a real, decodable image).
///
/// Written as an **explicit byte table**, never `base64Decode` — the same
/// discipline as `_widePng` below (root-cause-A). NB: the base64 this replaced
/// was in fact **malformed** (a wrong IDAT length field, and thus a bad chunk
/// walk), yet no test noticed because they assert the `Image` **widget**'s
/// presence, not a successful decode (`FileThumbnail`'s `errorBuilder` renders a
/// plain error box, not a `TypeIcon`). This constant is now a clean, CRC-correct
/// PNG; the self-check below pins its signature and declared size.
final Uint8List _png = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // ‹8-byte PNG signature›
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR len=13, "IHDR"
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // width=1, height=1
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, // depth=8, colour=6 (RGBA)…
  0x89, 0x00, 0x00, 0x00, 0x0B, 0x49, 0x44, 0x41, // …IHDR CRC; IDAT len=11
  0x54, 0x78, 0xDA, 0x63, 0x60, 0x00, 0x02, 0x00, // "IDAT" + zlib stream
  0x00, 0x05, 0x00, 0x01, 0xE9, 0xFA, 0xDC, 0xD8, // …IDAT CRC
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, // IEND len=0, "IEND"
  0xAE, 0x42, 0x60, 0x82, // IEND CRC
]);

/// A valid **64×36** (16:9) PNG — a solid red left half and blue right half —
/// deliberately non-square, so a squashed decode is observable as a wrong aspect
/// ratio (the round-4 fix, design §13-偏离⑥).
///
/// Written as an **explicit byte table**, never `base64Decode`. A byte table has
/// no decode step at all, so a bad constant can never surface later as
/// `FormatException: Invalid encoding before padding …` inside a test that is
/// really about aspect ratios. The constant self-check below fails **here**,
/// once, if these bytes ever drift.
final Uint8List _widePng = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // ‹8-byte PNG signature›
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR len=13, "IHDR"
  0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x24, // width=64, height=36
  0x08, 0x02, 0x00, 0x00, 0x00, 0xB6, 0x6E, 0xAB, // depth=8, colour=2 (RGB)…
  0xC5, 0x00, 0x00, 0x00, 0x3B, 0x49, 0x44, 0x41, // …IHDR CRC; IDAT len=59
  0x54, 0x78, 0x9C, 0xED, 0xCF, 0xB1, 0x09, 0x00, // "IDAT" + zlib stream
  0x00, 0x0C, 0xC3, 0xB0, 0xFC, 0xFF, 0x74, 0x7A,
  0x45, 0x96, 0x22, 0xF0, 0x6C, 0x50, 0x9A, 0x4C,
  0x1B, 0xEF, 0xBB, 0xDE, 0x03, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0xBC, 0x03, 0x1C, // …IDAT CRC
  0x1A, 0x65, 0xF7, 0x79, 0xAC, 0xE7, 0x60, 0x47, // IEND len=0, "IEND"
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
  0xAE, 0x42, 0x60, 0x82, // IEND CRC
]);

void main() {
  setUp(clearThumbnailCache); // the cache is module-level (process-wide)

  // Constant self-check (root cause A): a drifting byte table must go red HERE,
  // once — not as an undecodable image inside the decode-dependent assertions
  // the constants feed (here and in `thumbnail_e2e_test.dart`). The signature and
  // the big-endian IHDR dimensions (bytes 16..23) pin the exact bytes without a
  // decoder. Both constants are checked: `_widePng` (64×36) and `_png` (1×1).
  test('the PNG constants are well-formed (constant self-check)', () {
    void checkPng(Uint8List bytes, {required int width, required int height}) {
      expect(
        bytes.sublist(0, 8),
        <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
        reason: 'PNG signature',
      );
      int be32(int offset) =>
          (bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      expect(be32(16), width, reason: 'IHDR width');
      expect(be32(20), height, reason: 'IHDR height');
    }

    expect(_widePng.length, 116);
    checkPng(_widePng, width: 64, height: 36);
    expect(_png.length, 68);
    checkPng(_png, width: 1, height: 1);
  });

  // NOTE (root cause A): the four tests below that seed `_png` assert only
  // "bytes present → an `Image` is rendered" — **not** that the bytes actually
  // decode. Bad bytes pass them too (`FileThumbnail`'s `errorBuilder` renders a
  // plain error box, not a `TypeIcon`, so `find.byType(Image)` and
  // `findsNothing(TypeIcon)` both still hold). The constant's *validity* is
  // pinned by the `the PNG constants are well-formed` self-check above — never
  // by these four.
  testWidgets('image with bytes renders Image.memory and reads the port once',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform.setBytes('/src/photo.png', _png);

    await pumpApp(
      tester,
      const FileThumbnail(
          fileName: 'photo.png', path: '/src/photo.png', edge: 40),
      backend: backend,
      settle: true,
    );

    expect(find.byType(Image), findsOneWidget); // G27
    expect(backend.platform.readRequests, <String>['/src/photo.png']);
    expect(find.byType(TypeIcon), findsNothing);
  });

  testWidgets('a non-image never reads the port and shows the type icon',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    await pumpApp(
      tester,
      const FileThumbnail(
          fileName: 'report.pdf', path: '/src/report.pdf', edge: 40),
      backend: backend,
      settle: true,
    );

    expect(find.byType(TypeIcon), findsOneWidget); // G28
    expect(find.byType(Image), findsNothing);
    expect(backend.platform.readRequests, isEmpty); // port NOT called
  });

  testWidgets('an unavailable image never reads the port (no needless IO)',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform
        .setBytes('/src/photo.png', _png); // present, but flagged gone

    await pumpApp(
      tester,
      const FileThumbnail(
        fileName: 'photo.png',
        path: '/src/photo.png',
        unavailable: true,
        edge: 40,
      ),
      backend: backend,
      settle: true,
    );

    expect(find.byType(TypeIcon), findsOneWidget); // G30
    expect(find.byType(Image), findsNothing);
    expect(backend.platform.readRequests, isEmpty);
  });

  testWidgets('a null / empty path never reads the port',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    await pumpApp(
      tester,
      const FileThumbnail(fileName: 'photo.png', edge: 40), // path == null
      backend: backend,
      settle: true,
    );

    expect(find.byType(TypeIcon), findsOneWidget);
    expect(backend.platform.readRequests, isEmpty);
  });

  testWidgets(
      'a null read falls back to the type icon (no broken image, no error)',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    // No bytes preset → readFileBytes returns null.
    await pumpApp(
      tester,
      const FileThumbnail(
          fileName: 'photo.png', path: '/src/photo.png', edge: 40),
      backend: backend,
      settle: true,
    );

    expect(find.byType(TypeIcon), findsOneWidget); // G29
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
    expect(backend.platform.readRequests.length, 1);
  });

  testWidgets(
      'the same path is not re-read on a second render (path-keyed cache)',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform.setBytes('/src/photo.png', _png);

    await pumpApp(
      tester,
      const FileThumbnail(
          fileName: 'photo.png', path: '/src/photo.png', edge: 40),
      backend: backend,
      settle: true,
    );
    expect(backend.platform.readRequests.length, 1);

    // A fresh widget for the same path must hit the cache, not the port.
    await tester.pumpWidget(
      appWithScope(
        child: const FileThumbnail(
          fileName: 'photo.png',
          path: '/src/photo.png',
          edge: 96,
        ),
        deps: testDeps(backend),
      ),
    );
    await tester.pumpAndSettle();
    expect(backend.platform.readRequests.length, 1); // G3-1: no growth
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('a failed read is negatively cached (not re-read)',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    // '/gone.png' has no bytes → the first read returns null and is cached.

    await pumpApp(
      tester,
      const FileThumbnail(fileName: 'gone.png', path: '/gone.png', edge: 40),
      backend: backend,
      settle: true,
    );
    expect(backend.platform.readRequests.length, 1);

    await tester.pumpWidget(
      appWithScope(
        child: const FileThumbnail(
            fileName: 'gone.png', path: '/gone.png', edge: 40),
        deps: testDeps(backend),
      ),
    );
    await tester.pumpAndSettle();
    expect(
        backend.platform.readRequests.length, 1); // G3-2: negative cache holds
    expect(find.byType(TypeIcon), findsOneWidget);
  });

  testWidgets('the rendered thumbnail is edge × edge',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform.setBytes('/src/photo.png', _png);

    await pumpApp(
      tester,
      // Centred so the thumbnail gets loose constraints (as it does in a row /
      // slot); as `home` it would be stretched to the full route size.
      const Center(
        child: FileThumbnail(
            fileName: 'photo.png', path: '/src/photo.png', edge: 40),
      ),
      backend: backend,
      settle: true,
    );

    // `getSize` here measures the [FileThumbnail]'s own box, which is `edge`
    // square in **every** state — the decoded image, the loading placeholder,
    // the type-icon fallback and the decode-failure slot all size to `edge`
    // (G31). This is what caught the widget letting Flutter's debug error widget
    // (a full-width `Stack`) take over the slot for undecodable bytes.
    expect(
        tester.getSize(find.byType(FileThumbnail)), const Size(40, 40)); // G31
  });

  testWidgets(
      'preserveAspect decodes by a SINGLE axis (the non-square source keeps its '
      'ratio, never squashed); the square branch keeps a fixed edge × edge box',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform.setBytes('/src/wide.png', _widePng);

    // preserveAspect: the box sizes to the image's own ratio within the cap.
    await pumpApp(
      tester,
      const Center(
        child: FileThumbnail(
          fileName: 'wide.png',
          path: '/src/wide.png',
          edge: 120,
          preserveAspect: true,
        ),
      ),
      backend: backend,
      settle: true,
    );
    await settleImages(
        tester); // decode on the real event loop before measuring

    // The decoded box keeps the source's 16:9, bounded by `edge`. RED before the
    // fix: the branch passed BOTH cacheWidth and cacheHeight, so the 64×36
    // source decoded to a 120×120 square and this ratio would have been 1.0.
    final Size shown = tester.getSize(find.byType(Image));
    expect(
        shown.width / shown.height, moreOrLessEquals(64 / 36, epsilon: 0.05));
    expect(shown.width, lessThanOrEqualTo(120 + 0.01));
    expect(shown.height, lessThanOrEqualTo(120 + 0.01));

    // …and deterministically, without relying on the decode: the box is driven
    // by the image's own ratio (no explicit width/height, `BoxFit.contain`) and
    // the decode asks for **one** axis only — the other is left to `dart:ui`,
    // which preserves the source ratio. This is the fix in three assertions.
    final Image image = tester.widget<Image>(find.byType(Image));
    expect(image.width, isNull);
    expect(image.height, isNull);
    expect(image.fit, BoxFit.contain);
    expect(image.image, isA<ResizeImage>());
    final ResizeImage provider = image.image as ResizeImage;
    expect(provider.width, isNotNull);
    expect(provider.height, isNull);
    expect(tester.takeException(), isNull);

    // The square branch keeps a fixed edge × edge box (the list row's slot),
    // with `BoxFit.cover` cropping the overflow rather than squashing it.
    await tester.pumpWidget(
      appWithScope(
        child: const Center(
          child: FileThumbnail(
            fileName: 'wide.png',
            path: '/src/wide.png',
            edge: 120,
          ),
        ),
        deps: testDeps(backend),
      ),
    );
    await settleImages(tester);
    expect(tester.getSize(find.byType(Image)), const Size(120, 120));
    final Image square = tester.widget<Image>(find.byType(Image));
    expect(square.width, 120);
    expect(square.height, 120);
    expect(square.fit, BoxFit.cover);
  });

  testWidgets('over-maxBytes is a null read, never a truncated image (G32)',
      (WidgetTester tester) async {
    // The port contract, exercised directly: 3 bytes requested with a 2-byte cap.
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    final Uint8List three = Uint8List.fromList(<int>[1, 2, 3]);
    backend.platform.setBytes('/src/big.png', three);

    expect(await backend.platform.readFileBytes('/src/big.png', maxBytes: 2),
        isNull);
    expect(await backend.platform.readFileBytes('/src/big.png', maxBytes: 3),
        three);
  });
}
