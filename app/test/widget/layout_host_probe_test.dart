/// Host-container probe for the ③ spacing pass.
///
/// **Why this exists** (the rule adopted after the ③ pre-view): changing a gap
/// or a padding *looks* local, but its **host** may be size-constrained — a
/// `SwitchListTile` has a minimum height, a nav item has a fixed height, a list
/// row is held to a spec. So: **measure the host's real size before the change,
/// and again after**, instead of asserting "it should be fine".
///
/// This file only prints (`HOST <label> = W x H`); it asserts nothing, so it is
/// green before and after — the *numbers* are the deliverable, read by diffing
/// the two runs.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/shell/nav_rail.dart';
import 'package:lanlink_app/ui/widgets/error_banner.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';
import 'package:lanlink_app/ui/widgets/notice_banner.dart';

import '../support/pump_app.dart';

/// Prints the size of the widget [target] resolves to.
void _host(WidgetTester tester, String label, Finder target) {
  if (target.evaluate().isEmpty) {
    // ignore: avoid_print
    print('HOST $label = <absent>');
    return;
  }
  final Size s = tester.getSize(target.first);
  // ignore: avoid_print
  print('HOST $label = ${s.width.toStringAsFixed(1)} x '
      '${s.height.toStringAsFixed(1)}');
}

void main() {
  testWidgets('hosts: nav item and the settings switch tile',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true);

    // Settings tab → the receive switch lives in a SwitchListTile.
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    _host(tester, 'SwitchListTile', find.byType(SwitchListTile));

    // Desktop rail item (nav_rail.dart:78 sits inside it).
    await tester.pumpWidget(const SizedBox.shrink());
    useSurfaceSize(tester, const Size(1280, 800));
    await pumpShell(tester, backend: backend, settle: true);
    _host(
      tester,
      'nav item',
      find
          .descendant(of: find.byType(NavRail), matching: find.byType(InkWell))
          .first,
    );
  });

  testWidgets('hosts: a message bubble and the two banners',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));

    ChatMessage text() => ChatMessage(
          id: 'm1',
          conversationId: 'c1',
          direction: MessageDirection.incoming,
          kind: MessageKind.text,
          textBody: 'hello there',
          createdAt: DateTime.utc(2026, 1, 7, 12),
          updatedAt: DateTime.utc(2026, 1, 7, 12),
          status: MessageStatus.done,
        );

    await pumpApp(
      tester,
      Scaffold(
        // In a scroll view the bubble is given unbounded height, so it reports
        // its *content* size instead of stretching to the whole body (a bare
        // `Scaffold(body:)` made it read 800 — the screen, not the bubble).
        body: SingleChildScrollView(
          child:
              MessageBubble(message: text(), files: const <FileAttachment>[]),
        ),
      ),
      settle: true,
    );
    _host(tester, 'message bubble', find.byType(MessageBubble));

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpApp(
      tester,
      Scaffold(body: ErrorBanner(message: 'x', onRetry: () {})),
      settle: true,
    );
    _host(tester, 'error banner', find.byType(ErrorBanner));

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpApp(
      tester,
      Scaffold(body: NoticeBanner(message: 'y', onDismiss: () {})),
      settle: true,
    );
    _host(tester, 'notice banner', find.byType(NoticeBanner));
  });

  testWidgets('hosts: what an AppBar leading costs the title',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));

    // The same AppBar shape the phone shell uses: no implicit leading, a
    // single-line ellipsised title. Measured with and without an explicit
    // `leading`, so the delta is the real cost of moving ← up there.
    Future<void> show({Widget? leading, String title = 'Alice Laptop'}) =>
        pumpApp(
          tester,
          Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: false,
              leading: leading,
              title: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            body: const SizedBox.shrink(),
          ),
          settle: true,
        );

    await show();
    final Rect without = tester.getRect(find.text('Alice Laptop'));

    await tester.pumpWidget(const SizedBox.shrink());
    await show(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () {},
      ),
    );
    final Rect with1 = tester.getRect(find.text('Alice Laptop'));

    // ignore: avoid_print
    print('APPBAR title.left  without=${without.left}  with=${with1.left}  '
        'delta=${with1.left - without.left}');
    // ignore: avoid_print
    print('APPBAR title.width without=${without.width}  with=${with1.width}  '
        'delta=${without.width - with1.width}');

    // The case that actually decides it: an alias long enough to need the room.
    const String longAlias =
        'Alice Laptop (DESKTOP-9F2K1L) — the one by the window';
    await tester.pumpWidget(const SizedBox.shrink());
    await show(title: longAlias);
    final Rect longWithout = tester.getRect(find.text(longAlias));

    await tester.pumpWidget(const SizedBox.shrink());
    await show(
      title: longAlias,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () {},
      ),
    );
    final Rect longWith = tester.getRect(find.text(longAlias));

    // ignore: avoid_print
    print('APPBAR long title.width without=${longWithout.width}  '
        'with=${longWith.width}  lost=${longWithout.width - longWith.width}');
  });
}
