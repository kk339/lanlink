/// docs/18 §7.2 ① + U7 — the phone "白卡" list.
///
/// **Two independent criteria, deliberately not fused:**
///
/// 1. **the card exists** — a rounded `kCardSurface` container at [kCardHeight]
///    with [kCardGap] of air between cards instead of an inter-row hairline.
///    This is the only gate on "has the card been implemented";
/// 2. **the viewport fits ≥6** — computed from the *measured* card height and
///    gap, so it measures the viewport's **capacity**.
///
/// ★ The first draft of ② counted the rendered rows. That was **measuring the
/// wrong object**: with a 3-device fixture it was red no matter what, and with a
/// 10-device one it went green without proving anything about the layout — "≥6"
/// would have been a statement about the fixture, not about the screen. The
/// formula below is fixture-independent, and ① is what keeps it honest.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/ui/shell/list_pane.dart';
import 'package:lanlink_app/ui/theme.dart';
import 'package:lanlink_app/ui/widgets/device_row.dart';

import '../support/pump_app.dart';

/// The rounded surface a card paints inside [row], or `null`.
///
/// The card is the row's only `Container` carrying a `BoxDecoration` with a
/// corner radius, so this finds it without hard-coding a colour — which lets the
/// same helper read the light *and* the dark fill.
BoxDecoration? cardDecoration(WidgetTester tester, Finder row) {
  for (final Element element in find
      .descendant(of: row, matching: find.byType(Container))
      .evaluate()) {
    final Decoration? decoration = (element.widget as Container).decoration;
    if (decoration is BoxDecoration && decoration.borderRadius != null) {
      return decoration;
    }
  }
  return null;
}

/// The list viewport's rectangle — the box the cards scroll inside.
Rect listViewport(WidgetTester tester) => tester.getRect(
      find.descendant(
        of: find.byType(ListPane),
        matching: find.byType(ListView),
      ),
    );

void main() {
  testWidgets('窄屏首页：设备行是白卡（卡底色 + 卡高 + 卡间留白）(docs/18 §7.2 ①)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    final Finder rows = find.byType(DeviceRow);
    expect(rows, findsWidgets);

    // ① The card: a rounded container filled with the card surface.
    final BoxDecoration? maybeCard = cardDecoration(tester, rows.first);
    expect(maybeCard, isNotNull, reason: 'a phone device row must be a card');
    final BoxDecoration card = maybeCard!;
    expect(card.color, kCardSurface);
    expect(
      card.borderRadius,
      BorderRadius.circular(kRadiusCard),
      reason: 'the card radius reuses kRadiusCard (12) — no separate slot',
    );

    // …at the pinned grade, not the wide row's 56.
    expect(tester.getRect(rows.first).height, kCardHeight);

    // …with air between two cards — not a 1px separator line.
    final Rect first = tester.getRect(rows.at(0));
    final Rect second = tester.getRect(rows.at(1));
    expect(
      second.top - first.bottom,
      greaterThanOrEqualTo(kCardGap),
      reason: 'cards are separated by kCardGap of air, never by a hairline',
    );
  });

  testWidgets('窄屏首页：列表视口容量 ≥ 6 张完整卡（下限，与夹具台数无关）(docs/18 §7.2 U7)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    final Finder rows = find.byType(DeviceRow);
    expect(rows.evaluate().length, greaterThanOrEqualTo(2),
        reason: 'reading the gap needs two consecutive cards');

    // ★ Measured, not assumed: both numbers come from the rendered tree, so a
    // change to the card grade is caught even if the constants are not edited.
    final Rect viewport = listViewport(tester);
    final double cardHeight = tester.getRect(rows.at(0)).height;
    final double cardGap =
        tester.getRect(rows.at(1)).top - tester.getRect(rows.at(0)).bottom;

    expect(
      viewport.height / (cardHeight + cardGap),
      greaterThanOrEqualTo(6),
      reason: 'docs/18 §7.2 U7: a screen must show at least six complete cards '
          '(${viewport.height} / ($cardHeight + $cardGap)) — a lower bound, so a '
          'later status line may take a slot; never assert an exact count here',
    );
  });

  testWidgets('窄屏首页：深色主题下卡底不是纯白 (docs/18 §8.2)', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);
    await pumpShell(
      tester,
      backend: backend,
      theme: buildDarkTheme(),
      settle: true,
    );

    final BoxDecoration? card =
        cardDecoration(tester, find.byType(DeviceRow).first);
    expect(card, isNotNull);
    expect(
      card!.color,
      isNot(kCardSurface),
      reason: 'a pure-white card glares over the dark list surface',
    );
    expect(card.color, const Color(0xFF2A2B2F));
    // The geometry is theme-independent: the dark card is the same card.
    expect(tester.getRect(find.byType(DeviceRow).first).height, kCardHeight);
  });

  testWidgets(
      '0.2.10: 系统大字号不裁字 —— 卡在 2 倍字号长高且两行字都在卡内，1 倍仍是 67.0',
      (WidgetTester tester) async {
    // The defect this guards: the card used to be a hard `height: kCardHeight`,
    // so a large system font scale pushed the two text lines out of a fixed
    // 67px box (7 px of RenderFlex overflow at 2x, 43 px at 3x — measured at
    // 320/360/412) and the alias/summary were cut off. The card is now a
    // `minHeight`, so it grows with its content.
    //
    // The 1x shape is unchanged: the *first* test in this file already pins
    // `height == kCardHeight`, and the number is printed here too, so a "fix"
    // that quietly made every card taller at 1x would show up in both places.
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    useSurfaceSize(tester, const Size(412, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    final Finder row = find.byType(DeviceRow).first;
    final Rect card = tester.getRect(row);
    final Finder texts = find.descendant(of: row, matching: find.byType(Text));
    final List<double> bottoms = <double>[
      for (int i = 0; i < texts.evaluate().length; i++)
        tester.getRect(texts.at(i)).bottom,
    ];
    final double lowest = bottoms.reduce((double a, double b) => a > b ? a : b);

    // ignore: avoid_print
    print('BIGFONT 2x card=${card.height.toStringAsFixed(1)} '
        'texts=${texts.evaluate().length} lowestTextBottom=${lowest.toStringAsFixed(1)} '
        'cardBottom=${card.bottom.toStringAsFixed(1)} kCardHeight=$kCardHeight');

    // 1) No RenderFlex overflow anywhere.
    expect(tester.takeException(), isNull,
        reason: 'a large font scale must not overflow the card');
    // 2) The card actually grew (the pin is a minimum, not the height).
    expect(card.height, greaterThan(kCardHeight),
        reason: 'at 2x the card must be taller than the 67px grade');
    // 3) Nothing is cut: every line ends inside the card.
    expect(lowest, lessThanOrEqualTo(card.bottom + 0.5),
        reason: 'the summary line must not be clipped by the card');
  });

  testWidgets('0.2.10: 1 倍字号卡高仍是 67.0（量出来的，不是常量回读）',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(412, 800));
    final FakeBackend backend = Scenarios.e14NarrowFold();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    final Rect card = tester.getRect(find.byType(DeviceRow).first);
    // ignore: avoid_print
    print('BIGFONT 1x card=${card.height}');
    expect(card.height, 67.0,
        reason: 'minHeight must not change the 1x card: the pinned grade is 67');
  });
}
