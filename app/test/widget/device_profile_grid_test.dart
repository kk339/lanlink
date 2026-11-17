/// 0.2.28 — the 设备资料 media wall **adapts to a desktop width**.
///
/// The user's report: *"电脑会话的那个文件分类适配做的不行，看起来像是直接把手机
/// 上的放到电脑上，导致很多东西看着放大了许多"*. The wall's column count was the
/// literal `2` in `(maxWidth - 2·padding) / 2`, so the card edge was a function
/// of the window width and nothing else — and since the page is a **pushed,
/// full-window route**, a 1400×1000 desktop measured each square at 685×685.
///
/// These tests pin the four things that can go wrong with making it a grid:
///
///  1. wide: **more columns**, never a bigger card — and no `RenderFlex
///     overflow` while the 「来源 时间」 line keeps the time whole on one line;
///  2. wide: the three filters (图片 / 视频 / 文件) all lay out the same way, so
///     the grid is the wall's shape, not the image filter's;
///  3. narrow (the phone page): **not one number moves** — the edge is still
///     `(width - 2·padding) / 2` and each row still carries one square;
///  4. a big wall scrolls to the end with the last card **fully** visible (the
///     classic grid bug: an aspect ratio that clips the last row).
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/device_profile.dart';
import 'package:lanlink_app/ui/theme.dart';
import 'package:lanlink_app/ui/widgets/file_thumbnail.dart';

import '../support/pump_app.dart';

/// The desktop surface the brief names. `1400×1000` resolves to
/// `ShellLayout.wide`; note the pushed page is the **whole window** wide
/// (1400), not the 896 right pane — the route is on the root `Navigator`.
const Size _desktop = Size(1400, 1000);

/// A dialable peer for `initialPeer` — without one no conversation opens and the
/// 媒体与文件 entry (where the wall lives) is never built.
PeerDevice _peer(String fingerprint, {required String alias}) => PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// One conversation with [images] pictures, [videos] clips and [documents]
/// documents — one file per message, so every card has its own 「来源 时间」.
FakeBackend _backend({
  required int images,
  required int videos,
  required int documents,
  String alias = 'Alice Laptop',
}) {
  final FakeBackend backend = FakeBackend(
    devices: <PeerDevice>[_peer('AAAA1111', alias: alias)],
  );
  final Conversation conversation = backend.repo.addConversation(
    id: 'c-grid',
    deviceFingerprint: 'AAAA1111',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  final List<(String, String, String)> specs = <(String, String, String)>[
    for (int i = 0; i < images; i++)
      ('photo-$i.png', 'image/png', 'f-img-$i'),
    for (int i = 0; i < videos; i++)
      ('clip-$i.mp4', 'video/mp4', 'f-vid-$i'),
    for (int i = 0; i < documents; i++)
      ('doc-$i.pdf', 'application/pdf', 'f-doc-$i'),
  ];
  for (int i = 0; i < specs.length; i++) {
    final (String name, String mime, String id) = specs[i];
    backend.repo.addMessage(
      id: 'm-$i',
      conversationId: conversation.id,
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      createdAt: fixedEpoch.add(Duration(minutes: i)),
      files: <FileAttachment>[
        FileAttachment(
          id: id,
          messageId: 'm-$i',
          fileName: name,
          size: 2048,
          sha256: 'AA',
          mime: mime,
          localPath: '/received/$name',
        ),
      ],
    );
  }
  return backend;
}

/// Mounts the shell and opens 设备资料 through the entry.
Future<void> _openWall(WidgetTester tester, FakeBackend backend) async {
  addTearDown(backend.dispose);
  await pumpShell(
    tester,
    backend: backend,
    settle: true,
    initialPeer: _peer('AAAA1111', alias: 'Alice Laptop'),
  );
  await tester.tap(find.byTooltip('媒体与文件'));
  await tester.pumpAndSettle();
  expect(find.byType(DeviceProfilePage), findsOneWidget);
}

/// The squares currently mounted on the wall, in build order.
Finder _wallSquares() => find.descendant(
      of: find.byType(DeviceProfilePage),
      matching: find.byType(FileThumbnail),
    );

/// How many squares share the **first** row — i.e. the grid's column count.
int _columnsOnScreen(WidgetTester tester) {
  final Finder squares = _wallSquares();
  final int count = squares.evaluate().length;
  expect(count, greaterThan(0), reason: 'the wall drew nothing');
  final double firstTop = tester.getTopLeft(squares.first).dy;
  int columns = 0;
  for (int i = 0; i < count; i++) {
    if ((tester.getTopLeft(squares.at(i)).dy - firstTop).abs() < 0.5) {
      columns++;
    }
  }
  return columns;
}

/// Taps one of the three wall filters.
Future<void> _tapFilter(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byType(DeviceProfilePage),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}

/// The `yyyy-MM-dd HH:mm` paragraph of the card currently at the top left.
Finder _firstTimeText() => find
    .descendant(
      of: find.byType(DeviceProfilePage),
      matching: find.textContaining(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')),
    )
    .first;

void main() {
  // ── 1. wide: more columns, capped edge, intact meta line ─────────────────

  testWidgets(
      '1400×1000: the wall is a GRID — 6 columns of 218.3 squares (was 2 '
      'columns of 685), and nothing overflows', (WidgetTester tester) async {
    useSurfaceSize(tester, _desktop);
    await _openWall(
      tester,
      _backend(images: 12, videos: 6, documents: 7),
    );

    final int columns = _columnsOnScreen(tester);
    final double side = tester.getSize(_wallSquares().first).width;
    final double top = tester.getTopLeft(_wallSquares().first).dy;

    debugPrint('[0.2.28] 1400×1000 wall: columns=$columns, '
        'edge=${side.toStringAsFixed(2)}, first square top='
        '${top.toStringAsFixed(1)}');

    // The report's own numbers: 1370 available / (240 + 12) ⇒ 6 columns.
    expect(columns, greaterThanOrEqualTo(4),
        reason: 'a 1400-wide desktop must show at least four files per row');
    expect(columns, 6);
    expect(side, lessThanOrEqualTo(kWallCardMaxSide),
        reason: 'the extra width goes to more columns, never to a bigger card');
    // Exactly the grid formula: (1370 - 5·12) / 6.
    expect(side, closeTo((1400 - kListRowPadding * 2 - 5 * kWallCardGap) / 6,
        0.01));
    // RED before 0.2.28: this was (1400 - 30) / 2 = 685.
    expect(side, lessThan(685 / 2), reason: 'not the phone card blown up 2.4×');

    expect(tester.takeException(), isNull,
        reason: 'no RenderFlex overflow at any of these widths');

    // The 「来源 时间」 line: one line, time whole and not ellipsised.
    final Finder time = _firstTimeText();
    final RenderParagraph paragraph =
        tester.renderObject<RenderParagraph>(time);
    final Size timeSize = tester.getSize(time);
    debugPrint('[0.2.28] 1400×1000 meta line: time text '
        '${timeSize.width.toStringAsFixed(1)}×'
        '${timeSize.height.toStringAsFixed(1)}, '
        'ellipsised=${paragraph.didExceedMaxLines}, '
        'maxLines=${paragraph.maxLines}');
    expect(paragraph.didExceedMaxLines, isFalse,
        reason: 'the time may not be cut (nor wrapped): it is 16 fixed-width '
            'characters, the one thing on the card that must stay whole');
    expect(paragraph.maxLines, 1);
    // One line of bodyMedium, not two: the whole point of the ban on squeezing.
    expect(timeSize.height, lessThan(2 * 14 * 1.45),
        reason: 'the meta line must stay a single line on a wide card');
    // Scoped to the card: the paragraph keeps its intrinsic width even when the
    // FittedBox has to scale the paint down to fit the column.
    expect(timeSize.width, greaterThan(200),
        reason: 'the whole yyyy-MM-dd HH:mm is laid out');

    // And the name has a real column left of the time (it is ellipsised only
    // under the test font, which is ~2× the real one).
    final double cardRight =
        tester.getTopLeft(_wallSquares().first).dx + side;
    expect(tester.getTopRight(time).dx,
        closeTo(cardRight, 0.5 + kListRowPadding),
        reason: 'the time sits at the card\'s right edge');
  });

  // ── 2. all three filters, same grid ──────────────────────────────────────

  testWidgets(
      'the three filters each lay out on the same grid (图片 12 / 视频 6 / '
      '文件 7), with no overflow in any of them', (WidgetTester tester) async {
    useSurfaceSize(tester, _desktop);
    await _openWall(
      tester,
      _backend(images: 12, videos: 6, documents: 7),
    );

    for (final String label in <String>['图片', '视频', '文件']) {
      await _tapFilter(tester, label);
      final int columns = _columnsOnScreen(tester);
      final double side = tester.getSize(_wallSquares().first).width;
      debugPrint('[0.2.28] 1400×1000 $label: columns=$columns, '
          'edge=${side.toStringAsFixed(2)}');
      expect(columns, 6, reason: '$label must use the same grid');
      expect(side, lessThanOrEqualTo(kWallCardMaxSide));
      expect(tester.takeException(), isNull,
          reason: '$label must not overflow its cards');
    }
  });

  // ── 3. the phone page: not one number moves ──────────────────────────────

  testWidgets(
      '600×1200 phone: still the shipped 2-column measure — edge 285.0, one '
      'square per row — and the 「来源 时间」 line now ends on the CARD\'s edge, '
      'not the row\'s (0.2.59: 285.0, was 570.0)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 1200));
    await _openWall(
      tester,
      _backend(images: 12, videos: 6, documents: 7),
    );

    final Finder squares = _wallSquares();
    final double side = tester.getSize(squares.first).width;
    final Offset origin = tester.getTopLeft(squares.first);
    final double step = tester.getTopLeft(squares.at(1)).dy - origin.dy;

    debugPrint('[0.2.28] 600×1200 phone: edge=${side.toStringAsFixed(2)} '
        '(shipped formula (600 - 30) / 2 = 285.0), first square at '
        '(${origin.dx.toStringAsFixed(1)},${origin.dy.toStringAsFixed(1)}), '
        'row step=${step.toStringAsFixed(1)}');

    // The shipped formula, to the pixel — the wide path must not leak into it.
    expect(side, (600 - kListRowPadding * 2) / 2);
    expect(side, 285.0);
    // …and the shipped shape: one square per row, flush with the left padding.
    expect(origin.dx, kListRowPadding);
    expect((tester.getTopLeft(squares.at(1)).dy - origin.dy),
        closeTo(285.0 + 38.0, 1.0),
        reason: 'one square per row: the row step is the edge plus the 38-px '
            'meta line, exactly as before the change');
    // The meta line is now the **card's** width, so the time ends on the card's
    // trailing edge — 300.0 here (15 + 285), where it used to end on the row's
    // trailing padding (585.0) with a card-sized hole in between (0.2.59).
    final RenderParagraph time = tester.renderObject<RenderParagraph>(
        _firstTimeText());
    debugPrint('[0.2.28] 600×1200 meta line: time '
        '${tester.getSize(_firstTimeText()).width.toStringAsFixed(1)} wide, '
        'starts at ${tester.getTopLeft(_firstTimeText()).dx.toStringAsFixed(1)}, '
        'right edge ${tester.getTopRight(_firstTimeText()).dx.toStringAsFixed(1)}');
    expect(time.didExceedMaxLines, isFalse);
    expect(tester.getTopRight(_firstTimeText()).dx,
        closeTo(origin.dx + side, 0.5),
        reason: 'the time ends on the card\'s own right edge (0.2.59) — it used '
            'to end on the row\'s, 285 px to the right of the card');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '320 wide: still 2 columns of 145, no overflow, time whole',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(320, 800));
    await _openWall(tester, _backend(images: 4, videos: 0, documents: 0));

    final double side = tester.getSize(_wallSquares().first).width;
    final Offset origin = tester.getTopLeft(_wallSquares().first);
    final double step = tester.getTopLeft(_wallSquares().at(1)).dy - origin.dy;
    debugPrint('[0.2.28] 320: edge=${side.toStringAsFixed(2)} '
        '(shipped formula (320 - 30) / 2 = 145.0), first square at '
        '(${origin.dx.toStringAsFixed(1)},${origin.dy.toStringAsFixed(1)}), '
        'row step=${step.toStringAsFixed(1)}');
    expect(side, (320 - kListRowPadding * 2) / 2);
    expect(side, 145.0);
    // The pre-0.2.28 numbers, to the pixel: (15,140) and a 145 + 38 row step.
    expect(origin.dx, kListRowPadding);
    expect(origin.dy, 140.0);
    expect(step, closeTo(145.0 + 38.0, 1.0));

    final RenderParagraph time =
        tester.renderObject<RenderParagraph>(_firstTimeText());
    expect(time.didExceedMaxLines, isFalse,
        reason: 'the time is not truncated even on the narrowest surface');
    // ⚠️ This is the **paragraph**, not the meta line (0.2.59 narrowed the line
    // to the card's 145 px): `FittedBox` lays its child out unbounded and only
    // scales the *paint*, so the paragraph keeps its ~228 px intrinsic width
    // while what is drawn fits inside the card. Reading it here is how the
    // "never ellipsised, never wrapped" rule stays observable.
    expect(tester.getSize(_firstTimeText()).width,
        greaterThan(side),
        reason: 'the time text is laid out whole and then scaled down to fit the '
            'card — never cut with an ellipsis, never wrapped to a second line');
    expect(tester.takeException(), isNull,
        reason: 'no RenderFlex overflow at 320');
  });

  // ── 4. a big wall scrolls to the end, last card complete ─────────────────

  testWidgets('25 files on 1400: the last card is fully visible after scrolling',
      (WidgetTester tester) async {
    useSurfaceSize(tester, _desktop);
    // 40 files = 6 columns × 7 rows ⇒ a wall taller than the 1000-px window, so
    // the last row really is below the fold (with 25 the whole wall fits).
    await _openWall(tester, _backend(images: 40, videos: 0, documents: 0));

    // The newest file is first (`buildConversationFiles` orders newest first),
    // so the **oldest** image — photo-0.png — is the last card of 图片.
    final Finder last = find.descendant(
      of: find.byType(DeviceProfilePage),
      matching: find.byWidgetPredicate(
        (Widget w) => w is FileThumbnail && w.fileName == 'photo-0.png',
      ),
    );
    expect(last, findsNothing, reason: 'it starts below the fold');

    final Finder wall = find.descendant(
      of: find.byType(DeviceProfilePage),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(last, 400, scrollable: wall);
    await tester.pumpAndSettle();

    final Rect card = tester.getRect(last);
    final Rect viewport = tester.getRect(wall.first);
    debugPrint('[0.2.28] 25 files @1400: last card '
        '${card.width.toStringAsFixed(1)}×${card.height.toStringAsFixed(1)} '
        'at y ${card.top.toStringAsFixed(1)}..${card.bottom.toStringAsFixed(1)}, '
        'viewport bottom ${viewport.bottom.toStringAsFixed(1)}');

    expect(card.bottom, lessThanOrEqualTo(viewport.bottom),
        reason: 'the last row must not be clipped by a wrong aspect ratio');
    expect(card.height, greaterThanOrEqualTo(_wallColumnsEdge(tester)));
    expect(tester.takeException(), isNull);
  });
}

/// The edge of the squares currently on screen (helper for the last assertion).
double _wallColumnsEdge(WidgetTester tester) =>
    tester.getSize(_wallSquares().first).width;
