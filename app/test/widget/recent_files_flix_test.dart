/// docs/18 §3.2 — the 最近文件 page aligned with the reference: **underline
/// filter tabs** (seven of them, 文档 kept on purpose) and **one white card per
/// date group**, with **air between the rows and between the groups**.
///
/// ★ The card's inner hairline was **removed on the lead's judgement, and the
/// reference is INCONCLUSIVE**: it is downscaled (~486px for a ~1080px phone),
/// so a 1px line would be invisible in it either way. The criterion below
/// therefore asserts the *current behaviour* (whitespace separation) — it is
/// **not** a measured claim about Flix. On the on-device watch-list.
///
/// These criteria assert the *new* structure, not "it still works": the old page
/// used `ChoiceChip`s, so a test that only taps a tab would have passed before
/// and after — and would have measured nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/selectors.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';
import 'package:lanlink_app/ui/theme.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

/// `2026-01-<day>T12:00:00Z` — one fixed instant per local day.
DateTime _instant(int day) => DateTime.utc(2026, 1, day, 12);

FileAttachment _file(String id, String messageId, String name) =>
    FileAttachment(
      id: id,
      messageId: messageId,
      fileName: name,
      size: 2048,
      sha256: '00',
      localPath: '/src/$name',
    );

/// One conversation: two files on day 2 (one group of two rows) and one on day 1
/// (a group of one) — so "N rows → N-1 hairlines" is observable.
FakeBackend _fixture() {
  final FakeBackend backend = FakeBackend();
  backend.repo.addConversation(
    id: 'c1',
    deviceFingerprint: 'AAAA1111',
    createdAt: _instant(1),
  );
  backend.repo.addMessage(
    id: 'm1',
    conversationId: 'c1',
    direction: MessageDirection.outgoing,
    status: MessageStatus.done,
    createdAt: _instant(2),
    files: <FileAttachment>[_file('f1', 'm1', 'photo.png')],
  );
  backend.repo.addMessage(
    id: 'm2',
    conversationId: 'c1',
    direction: MessageDirection.incoming,
    status: MessageStatus.done,
    createdAt: _instant(2),
    files: <FileAttachment>[_file('f2', 'm2', 'clip.mp4')],
  );
  backend.repo.addMessage(
    id: 'm3',
    conversationId: 'c1',
    direction: MessageDirection.outgoing,
    status: MessageStatus.done,
    createdAt: _instant(1),
    files: <FileAttachment>[_file('f3', 'm3', 'report.pdf')],
  );
  return backend;
}

/// The underline colour the tab labelled [label] draws under itself.
///
/// Walks up from the label to its nearest decorated box, which is exactly the
/// tab's underline container (the bar is always laid out, transparent when the
/// tab is not selected — so this reads "how it looks", not "whether it exists").
Color? _underlineOf(WidgetTester tester, String label) {
  final Finder boxes =
      find.ancestor(of: find.text(label), matching: find.byType(Container));
  for (final Element element in boxes.evaluate()) {
    final Decoration? decoration = (element.widget as Container).decoration;
    if (decoration is BoxDecoration && decoration.border is Border) {
      return (decoration.border! as Border).bottom.color;
    }
  }
  return null;
}

Finder _cardOf(int day) =>
    find.byKey(ValueKey<String>('recent-card-${localDateKey(_instant(day))}'));

Finder _groupOf(int day) =>
    find.byKey(ValueKey<String>('recent-group-${localDateKey(_instant(day))}'));

Future<FakeBackend> _pump(WidgetTester tester, Size size) async {
  useSurfaceSize(tester, size);
  final FakeBackend backend = _fixture();
  addTearDown(backend.dispose);
  await pumpShell(
    tester,
    backend: backend,
    settle: true,
    initialModule: ShellModule.recentFiles,
  );
  return backend;
}

void main() {
  testWidgets('筛选排 = 7 项，且「文档」在（用户裁定保留，不照参考图的 6 个删）',
      (WidgetTester tester) async {
    await _pump(tester, const Size(600, 800));

    for (final String label in <String>[
      '全部',
      '图片',
      '视频',
      '音频',
      '安装包',
      '压缩包',
      '文档',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '缺少筛选项「$label」');
    }
  });

  testWidgets('选中态 = 蓝色下划线（切换后跟着走，不是靠颜色堆）', (WidgetTester tester) async {
    await _pump(tester, const Size(600, 800));

    // Selected by default: 全部 carries the slot-coloured bar…
    expect(_underlineOf(tester, '全部'), statusNetwork);
    // …and an unselected neighbour carries a transparent one (laid out, so no
    // pixel shifts when the selection moves).
    expect(_underlineOf(tester, '图片'), Colors.transparent);

    await tester.tap(find.text('文档'));
    await tester.pumpAndSettle();

    expect(_underlineOf(tester, '文档'), statusNetwork);
    expect(_underlineOf(tester, '全部'), Colors.transparent);
  });

  testWidgets('日期分组各自成一张白卡，组间留白 = kCardGap', (WidgetTester tester) async {
    await _pump(tester, const Size(600, 800));

    // Each group is its own card, filled with the card slot…
    for (final int day in <int>[2, 1]) {
      expect(_cardOf(day), findsOneWidget);
      final BoxDecoration decoration =
          (tester.widget<Container>(_cardOf(day)).decoration! as BoxDecoration);
      expect(decoration.color, kCardSurface);
      expect(decoration.borderRadius, BorderRadius.circular(kRadiusCard));
    }

    // …and the air between two groups is exactly kCardGap: measured from the
    // older group's header up to the newer group's card bottom.
    final double measured =
        tester.getRect(_groupOf(1)).top - tester.getRect(_cardOf(2)).bottom;
    expect(measured, closeTo(kCardGap, 0.6));
  });

  testWidgets('卡内行间是「留白」而不是 1px 线（看图后改的 —— 见报告 ③）',
      (WidgetTester tester) async {
    await _pump(tester, const Size(600, 800));

    // No hairline anywhere inside a card…
    expect(
      find.descendant(of: _cardOf(2), matching: find.byType(Divider)),
      findsNothing,
    );
    // …and the two rows of one card are separated by air: the second row starts
    // strictly below the first row's bottom.
    final Finder rows =
        find.descendant(of: _cardOf(2), matching: find.byType(FileTile));
    expect(rows, findsNWidgets(2));
    final double gap =
        tester.getRect(rows.at(1)).top - tester.getRect(rows.at(0)).bottom;
    expect(gap, greaterThan(0), reason: 'rows are separated by whitespace');
  });

  testWidgets('同一组件在电脑端（紧凑宽）也是白卡 + 下划线 —— 这处改动两端都可见',
      (WidgetTester tester) async {
    // The page is a **shared** widget, so the alignment shows on the desktop
    // too; this asserts that rather than assuming it.
    await _pump(tester, const Size(900, 800));

    expect(_cardOf(2), findsOneWidget);
    expect(_underlineOf(tester, '全部'), statusNetwork);
    expect(find.text('文档'), findsOneWidget);
  });
}
