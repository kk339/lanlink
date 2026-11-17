/// Widget tests for the right pane's **`文件` tab** — the per-conversation
/// attachment list (PRD §4 / §10 E20–E22; design §8.3).
///
/// Deliberately distinct from the middle-pane 最近文件 list: this one is scoped
/// to the selected conversation and is fed by the pure
/// `domain/selectors.dart::buildConversationFiles` (no search, no date grouping,
/// no `sourceMissing` probe). E22 pins that the two are **different data
/// sources** — under one fake data set their row counts differ.
///
/// Every test mounts the one entry point, `ShellPage` (via `pumpShell`), and
/// picks the pane through its test-only parameters.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/format.dart';
import 'package:lanlink_app/ui/panes/conversation_files.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';
import 'package:lanlink_app/ui/widgets/file_thumbnail.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';
import 'package:lanlink_app/ui/widgets/type_icon.dart';

import '../support/pump_app.dart';

/// The peer handed to `ShellPage(initialPeer: …)` so the right pane binds the
/// bound conversation `c-e20-a` (see `Scenarios.e20ConversationFiles`).
PeerDevice _boundPeer() => const PeerDevice(
      fingerprint: 'E2000020',
      alias: 'Eve Laptop',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// One [FileTile] row per [`ConversationFiles`] item (E20 / E22).
int _conversationFileRows(WidgetTester tester) => find
    .descendant(
      of: find.byType(ConversationFiles),
      matching: find.byType(FileTile),
    )
    .evaluate()
    .length;

/// Opens the right pane's `文件` tab.
Future<void> _openFilesTab(WidgetTester tester) async {
  await tester.tap(find.text(RightTab.files.label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'E20 the 文件 tab lists every attachment of the bound conversation, once '
      '(count == Σ history files)', (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e20ConversationFiles();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _boundPeer(),
    );
    await _openFilesTab(tester);

    expect(find.byType(ConversationFiles), findsOneWidget);
    // No omission, no duplication: exactly Σ history(msg).length rows…
    expect(_conversationFileRows(tester), Scenarios.e20BoundFileCount);
    // …and each of the bound conversation's three attachments appears exactly
    // once (multi-file message included).
    for (final String name in <String>['photo.png', 'notes.pdf', 'clip.mp4']) {
      expect(
        find.descendant(
          of: find.byType(ConversationFiles),
          matching: find.widgetWithText(FileTile, name),
        ),
        findsOneWidget,
        reason: name,
      );
    }
    // The *other* conversation's attachment never leaks in.
    expect(find.text('other.txt'), findsNothing);
  });

  testWidgets('E21 every row shows name + size + direction + time',
      (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e20ConversationFiles();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _boundPeer(),
    );
    await _openFilesTab(tester);

    // Name + size, rendered through `ui/format.dart` (so no locale coupling):
    // 2048 → 2.0 KB, 1024 → 1.0 KB, 4096 → 4.0 KB.
    expect(find.text('photo.png'), findsOneWidget);
    expect(find.text('2.0 KB'), findsWidgets);
    expect(find.text('1.0 KB'), findsWidgets);
    expect(find.text('4.0 KB'), findsWidgets);

    // Direction + time trailer `收到/发出 · HH:mm`, built with the same
    // formatters the row uses (no hard-coded clock / timezone). The **outgoing**
    // trailer appears **twice**: `m-e20-a1` is a two-file message (by design,
    // E20), so its two rows — `photo.png` and `notes.pdf` — share that one
    // message's direction and time. That is data semantics, not a render quirk.
    expect(
      find.text('${directionText(MessageDirection.outgoing)} · '
          '${timeText(fixedEpoch)}'),
      findsNWidgets(2),
    );
    expect(
      find.text('${directionText(MessageDirection.incoming)} · '
          '${timeText(fixedEpoch.add(const Duration(minutes: 1)))}'),
      findsOneWidget,
    );

    // Leading slot: a real thumbnail widget for the image **and for the video**
    // (video joined that gate later — `FileTile._leading` admitted images only,
    // so `clip.mp4` used to render a bare type icon; see
    // `conversation_video_cover_test.dart`). `notes.pdf` still gets an icon.
    expect(
      find.descendant(
        of: find.byType(ConversationFiles),
        matching: find.byType(FileThumbnail),
      ),
      findsNWidgets(2), // photo.png + clip.mp4
    );
    expect(
      find.descendant(
        of: find.byType(ConversationFiles),
        matching: find.byType(TypeIcon),
      ),
      findsWidgets,
    );
  });

  testWidgets(
      'E22 empty conversation → 本会话还没有文件; the tab is a DIFFERENT data '
      'source from 最近文件 (the counts differ)', (WidgetTester tester) async {
    final FakeBackend backend = Scenarios.e20ConversationFiles();
    addTearDown(backend.dispose);

    // (a) The bound conversation's `文件` tab: 3 rows.
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _boundPeer(),
    );
    await _openFilesTab(tester);
    final int conversationRows = _conversationFileRows(tester);
    expect(conversationRows, Scenarios.e20BoundFileCount);

    // (b) The middle-pane 最近文件 list over the SAME fake data: 4 rows. The two
    // are different sources, so the counts must differ.
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpShell(
      tester,
      initialModule: ShellModule.recentFiles,
      backend: backend,
      settle: true,
    );
    final int recentRows = find.byType(FileTile).evaluate().length;
    expect(recentRows, Scenarios.e20RecentFileCount);
    expect(recentRows, isNot(conversationRows));

    // (c) A conversation with no files shows the empty copy — never a blank pane.
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: const PeerDevice(
        fingerprint: 'E2NOROWS',
        alias: 'Nobody',
        kind: DeviceKind.desktop,
        lastPort: 53317,
      ),
    );
    await _openFilesTab(tester);
    expect(find.byType(ConversationFiles), findsOneWidget);
    expect(find.text('本会话还没有文件'), findsOneWidget);
  });
}
