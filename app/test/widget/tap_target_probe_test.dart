/// **Read-only probe**: prints the *real* hit box of every tappable control,
/// measured with `tester.getSize` — never read out of the source.
///
/// Why this exists: a tap target's size is a **layout** fact, not a fact about
/// what the code looks like. A `Row` can *say* 40 px and still hit-test 40, but
/// an `IconButton`'s hit box is its padded `constraints` (48 by default), and a
/// `Text` inside a `NavigationBar` is not itself tappable. Measuring the widget
/// tree is the only way to answer "how big is the thing the finger actually
/// hits?" — which is what Material's 48dp and Apple's 44pt minimums are about.
///
/// This is a **"待用素材" (material for a later decision), not a gate**: it
/// asserts nothing about its numbers, so it stays green whatever they turn out
/// to be. It changes no product code and mounts only fakes (no sockets, no
/// disk). Every line is prefixed `TAPBOX ` so the output can be grepped.
///
/// ---
///
/// ## ⚠️ Recorded ruling: **why two `GAP … = 0.0 dp` lines are NOT violations**
///
/// (Written down on 2026-10-14, at team-lead's request, **so the next reader
/// does not judge them by the letter of "separate targets by ≥8dp".**)
///
/// Material's spacing rule exists to stop *mis-taps between targets that are
/// genuinely separate*. The two `0.0 dp` cases are not that:
///
/// 1. the three bottom-bar destinations are the **adjacent cells of one
///    `NavigationBar`** — a single segmented control, not three controls that
///    happen to sit near each other; and
/// 2. the device rows are **list rows divided by a 1px hairline** — again how
///    Material's own `List` is built.
///
/// In both, the cell / row **is itself ≥48** (200×80 and 600×56 measured), so
/// **the mis-tap risk the rule targets does not exist here**. Taken literally,
/// "adjacent ⇒ 0dp ⇒ violation" would flag Material's own components.
///
/// **What this file does NOT claim**: it samples pairs, it is **not** a
/// whole-app proof that every pair is ≥8dp (only 4 pairs are measured).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/panes/file_detail.dart';
import 'package:lanlink_app/ui/shell/nav_rail.dart';
import 'package:lanlink_app/ui/widgets/device_row.dart';
import 'package:lanlink_app/ui/widgets/error_banner.dart';
import 'package:lanlink_app/ui/widgets/file_thumbnail.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';
import 'package:lanlink_app/ui/widgets/notice_banner.dart';

import '../support/pump_app.dart';

/// The Material / HIG verdict for a measured box (48dp / 44pt minimums).
String _verdict(Size s) {
  if (s.width >= 48 && s.height >= 48) {
    return 'OK   >=48dp';
  }
  if (s.width >= 44 && s.height >= 44) {
    return 'WARN 44-47 (HIG only)';
  }
  return 'UNDER <44';
}

/// The **real** hit box of [target].
///
/// Prefer the enclosing **button** (`IconButton` / `TextButton` / … / `ListTile`):
/// its *own* box is the target — an `IconButton` measures 48×48 even though the
/// ink circle inside it is only 40, and a tap 2px inside the 48 edge does fire
/// (proven by the `TAPIMG` probe below). Only when there is no enclosing button
/// do we fall back to the nearest ink/gesture area, which for a bare `InkWell`
/// row **is** the target.
Finder _hitBox(Finder target) {
  final Finder button = find.ancestor(
    of: target,
    matching: find.byWidgetPredicate(
      (Widget w) =>
          w is IconButton ||
          w is TextButton ||
          w is FilledButton ||
          w is OutlinedButton ||
          w is ElevatedButton ||
          w is ListTile,
    ),
  );
  if (button.evaluate().isNotEmpty) {
    return button.first;
  }
  final Finder ink = find.ancestor(
    of: target,
    matching: find.byWidgetPredicate(
      (Widget w) => w is InkWell || w is InkResponse || w is GestureDetector,
    ),
  );
  return ink.evaluate().isEmpty ? target : ink.first;
}

/// Prints one `TAPBOX <label> = <w> x <h> [<verdict>]` line for [target].
///
/// Missing targets print `<absent>` instead of failing: the probe reports what
/// is on screen, it does not demand a particular control exist.
void _probe(WidgetTester tester, String label, Finder target) {
  if (target.evaluate().isEmpty) {
    // ignore: avoid_print
    print('TAPBOX $label = <absent>');
    return;
  }
  final Finder box = _hitBox(target.first);
  final Size s = tester.getSize(box);
  // ignore: avoid_print
  print('TAPBOX $label = ${s.width.toStringAsFixed(1)} x '
      '${s.height.toStringAsFixed(1)}  [${_verdict(s)}]');
}

/// A finder for one bottom-bar destination label (not any same-named text).
Finder _tab(String label) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    );

/// Prints one `CHAIN <label>: Self=WxH <- Parent <- …` line: the hit box **and
/// its ancestor sizes**, which is what shows *why* a target came out small
/// (a parent that pins the height, etc.) — numbers only, no verdict.
void _chain(WidgetTester tester, String label, Finder target,
    {int depth = 14, bool raw = false}) {
  if (target.evaluate().isEmpty) {
    // ignore: avoid_print
    print('CHAIN $label = <absent>');
    return;
  }
  final Finder box = raw ? target.first : _hitBox(target.first);
  final Element self = box.evaluate().first;
  final RenderBox selfBox = self.renderObject! as RenderBox;
  final List<String> parts = <String>[
    '${self.widget.runtimeType}=${selfBox.size.width.toStringAsFixed(0)}x'
        '${selfBox.size.height.toStringAsFixed(0)}',
  ];
  int seen = 0;
  self.visitAncestorElements((Element e) {
    if (seen++ >= depth) {
      return false;
    }
    final RenderObject? ro = e.renderObject;
    parts.add(
      ro is RenderBox && ro.hasSize
          ? '${e.widget.runtimeType}=${ro.size.width.toStringAsFixed(0)}x'
              '${ro.size.height.toStringAsFixed(0)}'
          : '${e.widget.runtimeType}',
    );
    return true;
  });
  // ignore: avoid_print
  print('CHAIN $label: ${parts.join(' <- ')}');
}

/// Prints `GAP <label> = <dp> [<verdict>]`: the distance between two hit boxes.
///
/// Material's rule is about *separated* targets; adjacent cells that form one
/// segmented bar (a `NavigationBar`), or list rows divided by a hairline, are
/// adjacent **by design** — the number is reported either way, the verdict is
/// not a judgement of the design.
void _gap(WidgetTester tester, String label, Finder a, Finder b,
    {bool vertical = false}) {
  if (a.evaluate().isEmpty || b.evaluate().isEmpty) {
    // ignore: avoid_print
    print('GAP $label = <absent>');
    return;
  }
  final Rect ra = tester.getRect(_hitBox(a.first));
  final Rect rb = tester.getRect(_hitBox(b.first));
  final double gap = vertical ? rb.top - ra.bottom : rb.left - ra.right;
  // ignore: avoid_print
  print('GAP $label = ${gap.toStringAsFixed(1)} dp  '
      '[${gap >= 8 ? 'OK >=8' : 'UNDER <8'}]');
}

void main() {
  testWidgets('probe: the real hit box of every tappable control',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    // ── list state ─────────────────────────────────────────────────────────
    _probe(tester, 'top-bar ⋮', find.byTooltip('更多'));
    _probe(
        tester, 'device row', find.widgetWithText(DeviceRow, 'Alice Laptop'));
    _probe(tester, 'bottom tab 设备', _tab('设备'));
    _probe(tester, 'bottom tab 文件', _tab('文件'));
    _probe(tester, 'bottom tab 设置', _tab('设置'));

    // ── the 文件 tab (thumbnail) ───────────────────────────────────────────
    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    _probe(tester, 'file thumbnail', find.byType(FileThumbnail));

    // ── detail state (back / composer) ─────────────────────────────────────
    await tester.tap(find.byIcon(Icons.forum));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(DeviceRow, 'Alice Laptop'));
    await tester.pumpAndSettle();
    _probe(tester, 'back ←', find.byIcon(Icons.arrow_back));
    _probe(tester, 'detail ⋮', find.byTooltip('更多'));
    _probe(tester, 'attach 📎', find.byIcon(Icons.attach_file));
    _probe(tester, 'send ➤', find.byIcon(Icons.send));
  });

  testWidgets('probe: desktop-width hit boxes', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1280, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    _probe(tester, 'desktop middle-pane row',
        find.widgetWithText(DeviceRow, 'Alice Laptop').first);
    _probe(
      tester,
      'desktop nav-rail item',
      find
          .descendant(of: find.byType(NavRail), matching: find.byType(InkWell))
          .first,
    );
    _probe(tester, 'desktop top-bar ⋮', find.byTooltip('更多'));
  });

  testWidgets('probe: bubble action hit boxes', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));

    ChatMessage outgoing(MessageStatus status) => ChatMessage(
          id: 'm1',
          conversationId: 'c1',
          direction: MessageDirection.outgoing,
          kind: MessageKind.text,
          textBody: 'hi',
          createdAt: DateTime.utc(2026, 1, 7, 12),
          updatedAt: DateTime.utc(2026, 1, 7, 12),
          status: status,
        );

    // 取消 shows while a transfer can still be cancelled.
    await pumpApp(
      tester,
      Scaffold(
        body: MessageBubble(
          message: outgoing(MessageStatus.transferring),
          files: const <FileAttachment>[],
          onCancel: () {},
        ),
      ),
      settle: true,
    );
    _probe(tester, 'bubble 取消', find.text('取消'));

    // 重新发送 shows once the message has failed.
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpApp(
      tester,
      Scaffold(
        body: MessageBubble(
          message: outgoing(MessageStatus.failed),
          files: const <FileAttachment>[],
          onResend: () {},
        ),
      ),
      settle: true,
    );
    _probe(tester, 'bubble 重新发送', find.text('重新发送'));
  });

  testWidgets('probe: list rows — 最近文件 and 已归档', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e5PeerReinstalled();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    _probe(tester, 'row 最近文件 (FileTile)', find.byType(FileTile));

    await tester.tap(find.text('已归档'));
    await tester.pumpAndSettle();
    _probe(tester, 'row 已归档 (ListTile)', find.byType(ListTile));
  });

  testWidgets('probe: cause chains for the sub-minimum targets',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    await tester.tap(find.widgetWithText(DeviceRow, 'Alice Laptop'));
    await tester.pumpAndSettle();
    // Start each chain at the IconButton itself, so the app-level row/padding
    // that *could* pin the height shows up in the chain.
    Finder button(Finder icon) =>
        find.ancestor(of: icon, matching: find.byType(IconButton)).first;
    _chain(tester, 'back ← (IconButton)', button(find.byIcon(Icons.arrow_back)),
        raw: true);
    _chain(tester, 'attach 📎 (IconButton)',
        button(find.byIcon(Icons.attach_file)),
        raw: true);
    _chain(tester, 'send ➤ (IconButton)', button(find.byIcon(Icons.send)),
        raw: true);
  });

  testWidgets('probe: is the real back-button target 48 or 40?',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);
    await tester.tap(find.widgetWithText(DeviceRow, 'Alice Laptop'));
    await tester.pumpAndSettle();

    final Finder btn = find
        .ancestor(
          of: find.byIcon(Icons.arrow_back),
          matching: find.byType(IconButton),
        )
        .first;
    final Rect r = tester.getRect(btn);
    // ignore: avoid_print
    print('TAPIMG back: IconButton rect = ${r.width} x ${r.height}');
    // ignore: avoid_print
    print('TAPIMG back: detail open before = '
        '${find.byType(ConversationThread).evaluate().isNotEmpty}');

    // 2px in from the 48-box edge is INSIDE the button but OUTSIDE an inner
    // 40-box. If the detail closes, the responsive area really is 48.
    await tester.tapAt(Offset(r.left + 2, r.top + 2));
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('TAPIMG back: @edge+2 hit? = '
        '${find.byType(ConversationThread).evaluate().isEmpty}');
  });

  testWidgets('probe: edge taps for the two bare rows',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    // (The receive status bar probe was removed with the widget — docs/18.)

    // The 最近文件 row: tap 2px inside its own left edge.
    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    final Rect row = tester.getRect(find.byType(FileTile).first);
    await tester.tapAt(Offset(row.left + 2, row.center.dy));
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('TAPIMG file row: ${row.width.toStringAsFixed(0)}x'
        '${row.height.toStringAsFixed(0)} @left+2 hit? = '
        '${find.byType(FileDetail).evaluate().isNotEmpty}');
  });

  testWidgets('probe: gaps between adjacent targets',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    // Bottom bar: three destination cells side by side.
    _gap(tester, 'bottom 设备 -> 文件', _tab('设备'), _tab('文件'));
    _gap(tester, 'bottom 文件 -> 设置', _tab('文件'), _tab('设置'));

    // List rows, stacked (separated only by a hairline divider).
    final Finder rows = find.byType(DeviceRow);
    if (rows.evaluate().length >= 2) {
      _gap(tester, 'device rows (vertical)', rows.at(0), rows.at(1),
          vertical: true);
    }

    // Composer: the two icon buttons on the same row.
    await tester.tap(find.widgetWithText(DeviceRow, 'Alice Laptop'));
    await tester.pumpAndSettle();
    _gap(tester, 'composer 📎 -> ➤', find.byIcon(Icons.attach_file),
        find.byIcon(Icons.send));
  });

  testWidgets('probe: file-detail actions and settings buttons',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    // 文件 tab → a file row → the detail's three actions.
    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FileTile).first);
    await tester.pumpAndSettle();
    _probe(tester, 'file 打开', find.byIcon(Icons.open_in_new));
    _probe(tester, 'file 分享', find.byIcon(Icons.share));
    _probe(tester, 'file 位置', find.byIcon(Icons.folder_outlined));

    // 设置 tab → its actions.
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    _probe(tester, '设置 保存名称', find.text('保存名称'));
    _probe(tester, '设置 更改位置', find.text('更改位置'));
    _probe(tester, '设置 关于', find.text('关于我们'));
  });

  testWidgets('probe: banner buttons', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));

    await pumpApp(
      tester,
      Scaffold(body: ErrorBanner(message: 'x', onRetry: () {})),
      settle: true,
    );
    _probe(tester, 'error_banner 重试', find.text('重试'));

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpApp(
      tester,
      Scaffold(body: NoticeBanner(message: 'y', onDismiss: () {})),
      settle: true,
    );
    _probe(tester, 'notice_banner 知道了', find.text('知道了'));
  });

  testWidgets('probe: the mobile-only branches (分享 / 关于)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    // The mobile flag is what selects 打开 / 分享 and the 关于 row — without it
    // the non-mobile branches render and these two controls simply do not exist.
    backend.platform.setMobile(true);
    await pumpShell(tester, backend: backend, settle: true);

    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FileTile).first);
    await tester.pumpAndSettle();
    _probe(tester, 'mobile 打开', find.byIcon(Icons.open_in_new));
    _probe(tester, 'mobile 分享', find.byIcon(Icons.share));

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    _probe(tester, 'mobile 关于', find.text('关于我们'));
  });
}
