/// Gate for "a video sent into the conversation shows a **cover**, not a bare
/// icon" (the user's report; team-lead ruling: 方案 A).
///
/// **Red before the fix.** `FileTile._leading` gated its thumbnail on
/// `FileClass.image` only, so a video fell through to a plain `TypeIcon` —
/// `message_bubble` sends every non-image to `others → _fileRow → FileTile`.
/// `FileThumbnail` itself already supported video (`_shouldLoad` returns
/// `mobile` for video, `:252` adds the ▶, `:274` falls back to the icon), so the
/// blocker was the upstream gate, not missing behaviour.
///
/// The desktop case is **measured, not assumed**: `_playBadge`
/// (`file_thumbnail.dart:252`) is *not* platform-gated, so widening the gate is
/// expected to change the desktop row too. The second test prints and pins
/// whatever it actually renders.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/widgets/file_thumbnail.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';
import 'package:lanlink_app/ui/widgets/type_icon.dart';

import '../support/pump_app.dart';

ChatMessage _videoMessage() => ChatMessage(
      id: 'm1',
      conversationId: 'c1',
      direction: MessageDirection.outgoing,
      kind: MessageKind.file,
      createdAt: DateTime.utc(2026, 1, 7, 12),
      updatedAt: DateTime.utc(2026, 1, 7, 12),
      status: MessageStatus.done,
    );

FileAttachment _video() => const FileAttachment(
      id: 'f1',
      messageId: 'm1',
      fileName: 'clip.mp4',
      size: 1024,
      sha256: '00',
      localPath: '/src/clip.mp4',
      mime: 'video/mp4',
    );

void main() {
  testWidgets('mobile: a conversation video attachment renders a cover + ▶',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform.setMobile(true);

    await pumpApp(
      tester,
      Scaffold(
        body: MessageBubble(
          message: _videoMessage(),
          files: <FileAttachment>[_video()],
          isMobile: true,
        ),
      ),
      backend: backend,
      settle: true,
    );

    // 1. The row reaches the thumbnail at all (this is the assertion that was
    //    red before the fix: a video used to land on a bare TypeIcon).
    expect(
      find.byType(FileThumbnail),
      findsOneWidget,
      reason: 'a video attachment must route to FileThumbnail, not a bare icon',
    );

    // 2. The ▶ badge is present (`_playBadge`, file_thumbnail.dart:252).
    expect(
      find.byIcon(Icons.play_circle_fill),
      findsOneWidget,
      reason: 'a video reads as a video',
    );

    // 3. The only TypeIcon left is the *thumbnail's* fallback (a failed decode
    //    renders one inside FileThumbnail) — there is no bare row icon.
    expect(
      find.descendant(
        of: find.byType(FileThumbnail),
        matching: find.byType(TypeIcon),
      ),
      findsOneWidget,
      reason: 'the remaining TypeIcon must be the thumbnail fallback, '
          'not a bare row icon',
    );
  });

  testWidgets('desktop: a video row — measure what it renders now',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    // Deliberately NOT mobile.

    await pumpApp(
      tester,
      Scaffold(
        body: MessageBubble(
          message: _videoMessage(),
          files: <FileAttachment>[_video()],
        ),
      ),
      backend: backend,
      settle: true,
    );

    final int thumbs = find.byType(FileThumbnail).evaluate().length;
    final int plays = find.byIcon(Icons.play_circle_fill).evaluate().length;
    final int icons = find.byType(TypeIcon).evaluate().length;
    // ignore: avoid_print
    print(
        'DESKTOP video row: FileThumbnail=$thumbs play=$plays TypeIcon=$icons');

    // `_shouldLoad` is decided by **capability, not platform** (file_thumbnail.dart
    // :166-180), so on desktop it is TRUE too — the frame comes from the Windows
    // shell thumbnail (windows/runner/thumbnail_channel.cpp:175). What falls back
    // here is the *bytes*, not the platform: the fake has no frame for
    // `/src/clip.mp4`, so this row renders the TypeIcon. `_playBadge` is not
    // platform-gated either, so a ▶ shows on desktop as well.
    expect(
      find.byType(FileThumbnail),
      findsOneWidget,
      reason: 'the row is the thumbnail widget (which falls back to the icon)',
    );
    expect(
      find.byIcon(Icons.play_circle_fill),
      findsOneWidget,
      reason: 'file_thumbnail.dart:252 is not platform-gated, so the ▶ shows '
          'on desktop as well',
    );
  });

  // ── §4 of docs/18: the big-cover route, on the narrow layout only ──────────

  testWidgets('narrow: a video takes the BIG-cover path',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform.setMobile(true);

    await pumpApp(
      tester,
      Scaffold(
        body: MessageBubble(
          message: _videoMessage(),
          files: <FileAttachment>[_video()],
          isMobile: true,
        ),
      ),
      backend: backend,
      settle: true,
    );

    final Size big = tester.getSize(find.byType(FileThumbnail));
    // ignore: avoid_print
    print('NARROW video: FileThumbnail=$big  (row path would be ~40 wide)');

    // The discriminator is the **size**, not mere existence: a small row
    // thumbnail and a big cover are both `FileThumbnail`.
    expect(
      big.width,
      greaterThan(200),
      reason: 'the big-cover path caps at _singleImageEdge (240), got $big',
    );
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
  });

  testWidgets('wide: a video ALSO takes the big-cover path (§4 exception)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    // NOT mobile — this is the wide/desktop host.

    await pumpApp(
      tester,
      Scaffold(
        body: MessageBubble(
          message: _videoMessage(),
          files: <FileAttachment>[_video()],
        ),
      ),
      backend: backend,
      settle: true,
    );

    expect(find.byType(FileThumbnail), findsOneWidget);
    final Size s = tester.getSize(find.byType(FileThumbnail));
    // ignore: avoid_print
    print('WIDE video: FileThumbnail=$s  (both ends: the big path)');
    // ★ APPROVED EXCEPTION to §7.1's "wide is byte-identical" contract —
    //   **what changed**: a video now routes to `_imageGrid` (a big cover) on the
    //     wide layout too, instead of the small `FileTile` row (40dp).
    //   **why**: the user ruled "两端都改" — on the desktop an image was already a
    //     big thumbnail, so a video sitting in a row was the inconsistency.
    //   **who approved**: the user, relayed by team-lead (2026-10-14).
    //   Every OTHER wide assertion still has to match its baseline (§7.1).
    expect(
      s.width,
      greaterThan(200),
      reason: 'both ends now take the big-cover path (_singleImageEdge 240), '
          'got $s',
    );
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    // The old "it stays the row's leading slot" assertion is **gone on purpose**:
    // the video no longer lives in a `FileTile` at all — that is the exception,
    // not a weakened check (the size assertion above is strictly stronger).
  });

  // ── §4 through the REAL entry chain: ShellPage → conversation → bubble ──────
  // The cases above construct a `MessageBubble` directly, so a break in the real
  // call site (`conversation_thread.dart`) would never turn them red. These go
  // through the one real mount point (`pumpShell`) at both widths.

  /// Binds the e20 conversation `c-e20-a` (it carries `photo.png`, `notes.pdf`
  /// and `clip.mp4` — one image and one video).
  PeerDevice boundPeer() => const PeerDevice(
        fingerprint: 'E2000020',
        alias: 'Eve Laptop',
        kind: DeviceKind.desktop,
        isOnline: true,
        lastPort: 53317,
      );

  Future<void> openBoundConversation(WidgetTester tester, Size size) async {
    useSurfaceSize(tester, size);
    final FakeBackend backend = Scenarios.e20ConversationFiles();
    addTearDown(backend.dispose);
    backend.platform.setMobile(true);
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: boundPeer(),
    );
  }

  /// How many thumbnails are laid out at the **big-cover** width.
  int bigThumbnails(WidgetTester tester) => find
      .byType(FileThumbnail)
      .evaluate()
      .where((Element e) => (e.renderObject! as RenderBox).size.width > 200)
      .length;

  testWidgets('real shell, narrow: the conversation video is a big cover',
      (WidgetTester tester) async {
    await openBoundConversation(tester, const Size(600, 800));

    expect(find.byType(ConversationThread), findsOneWidget);
    final List<String> sizes = <String>[
      for (final Element e in find.byType(FileThumbnail).evaluate())
        (e.renderObject! as RenderBox).size.toString(),
    ];
    // ignore: avoid_print
    print(
        'SHELL narrow: rows(FileTile)=${find.byType(FileTile).evaluate().length} '
        'thumbnails=$sizes big=${bigThumbnails(tester)}');

    // The e20 conversation carries **3 attachments**: one image (`photo.png`),
    // one video (`clip.mp4`) and one plain file (`notes.pdf`). Counted on the
    // real page, not inferred: the two media are big covers, and the plain file
    // must still take the `_fileRow` path — that is the other half of §4.
    expect(
      bigThumbnails(tester),
      2,
      reason: 'photo.png and clip.mp4 must both be big covers, '
          'thumbnails were $sizes',
    );
    expect(
      find.widgetWithText(FileTile, 'notes.pdf'),
      findsOneWidget,
      reason:
          'a non-image, non-video attachment must still go through _fileRow',
    );
  });

  testWidgets('real shell, wide: the conversation video is a big cover too',
      (WidgetTester tester) async {
    await openBoundConversation(tester, const Size(1280, 800));

    expect(find.byType(ConversationThread), findsOneWidget);
    final List<String> sizes = <String>[
      for (final Element e in find.byType(FileThumbnail).evaluate())
        (e.renderObject! as RenderBox).size.toString(),
    ];
    // ignore: avoid_print
    print(
        'SHELL wide:   rows(FileTile)=${find.byType(FileTile).evaluate().length} '
        'thumbnails=$sizes big=${bigThumbnails(tester)}');

    // §4's approved exception: the wide layout takes the same route — and the
    // same page-level split holds (2 media covers + `notes.pdf` as a row).
    expect(
      bigThumbnails(tester),
      2,
      reason: 'both ends take the big-cover path (§4), '
          'thumbnails were $sizes',
    );
    expect(
      find.widgetWithText(FileTile, 'notes.pdf'),
      findsOneWidget,
      reason:
          'a non-image, non-video attachment must still go through _fileRow',
    );
  });
}
