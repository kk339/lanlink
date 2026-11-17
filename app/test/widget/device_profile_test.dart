import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/device_profile.dart';
import 'package:lanlink_app/ui/theme.dart';
import 'package:lanlink_app/ui/widgets/device_row.dart';

import '../support/pump_app.dart';

/// A dialable peer for `initialPeer` — without one the conversation cannot be
/// opened, which is the shell tests' own requirement too.
PeerDevice _peer(String fingerprint,
        {required String alias, bool online = false}) =>
    PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: DeviceKind.desktop,
      isOnline: online,
      lastPort: 53317,
    );

/// 媒体与文件页 (docs/18 §3.1): the way in, the profile head, the media wall —
/// and, just as importantly, **what is deliberately not there**.
void main() {
  /// Opens the conversation, then the profile through the bar's entry.
  Future<void> openProfile(WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    // e16 carries 'Alice Laptop' plus a photo and a clip — the wall's first
    // filter is 图片, so an image must actually exist in the fixture.
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('AAAA1111', alias: 'Alice Laptop', online: true),
    );
    // The detail is open on mount, so the entry is directly reachable.
    expect(find.byType(DeviceRow), findsNothing);
  }

  testWidgets('entry: the conversation bar carries the way in, beside the name',
      (WidgetTester tester) async {
    await openProfile(tester);

    // RED before the entry existed: nothing on the conversation page led here.
    final Finder entry = find.byTooltip('媒体与文件');
    expect(entry, findsOneWidget, reason: 'the profile needs a way in (§3.1)');

    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(DeviceProfilePage), findsOneWidget);
  });

  testWidgets(
      'head + wall: the device name, the three filters, and the media '
      'cards with 「来源 时间」 headers', (WidgetTester tester) async {
    await openProfile(tester);
    await tester.tap(find.byTooltip('媒体与文件'));
    await tester.pumpAndSettle();

    // Head: the peer's own name (the reference shows it beside the ←).
    expect(
      find.descendant(
          of: find.byType(AppBar), matching: find.text('Alice Laptop')),
      findsOneWidget,
    );

    // Filters: exactly the three we have. **No 文字** — we have no
    // `FileKind.text`, and the wall's subject is files (§3.1, user-ruled).
    for (final String label in <String>['图片', '视频', '文件']) {
      expect(find.text(label), findsOneWidget, reason: '$label filter missing');
    }
    expect(find.text('文字'), findsNothing,
        reason: 'we have no text kind; the reference has four, we ship three');

    // The wall is a card flow with a grey source/time line above each card —
    // not a list row. The reference's own header format is `yyyy-MM-dd HH:mm`.
    expect(
      find.byWidgetPredicate((Widget w) =>
          w is Text &&
          RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$').hasMatch(w.data ?? '')),
      findsWidgets,
      reason: 'each card carries its message time in the header line',
    );
  });

  testWidgets(
      '★ the controls we have no capability for are ABSENT, not dead '
      '(docs/18 §3.1 + §8.2)', (WidgetTester tester) async {
    await openProfile(tester);
    await tester.tap(find.byTooltip('媒体与文件'));
    await tester.pumpAndSettle();

    // §3.1 rules these out for stated reasons; two of them (消息通知 / 自动接收)
    // are marked "做" on the ground that "我们有对应能力" — a ground that does not
    // hold (SettingsController has only *global* settings; the store has no
    // per-device preference). Shipping a switch that changes nothing is the one
    // shape this round keeps refusing, so they are absent like the rest.
    for (final String absent in <String>[
      '消息通知',
      '自动接收',
      '跨设备复制粘贴',
      '清空消息记录',
    ]) {
      expect(find.text(absent), findsNothing,
          reason: '$absent has no backing capability — it must not be painted');
    }
  });

  testWidgets(
      'the broken state is drawn from the dangerBroken slot (docs/18 '
      '§1.1: that slot exists for exactly this)', (WidgetTester tester) async {
    // A source that is gone: the wall must show the white card + the centred
    // orange glyph, not a broken thumbnail.
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e15ThumbnailFallback();
    addTearDown(backend.dispose);
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('E1500015', alias: 'Eve Laptop', online: true),
    );
    await tester.tap(find.byTooltip('媒体与文件'));
    await tester.pumpAndSettle();

    final Iterable<Icon> icons = tester
        .widgetList<Icon>(find.byType(Icon))
        .where((Icon icon) => icon.color == dangerBroken);
    expect(icons, isNotEmpty,
        reason:
            'a missing source paints the 损毁 glyph in the dangerBroken slot');
  });
}
