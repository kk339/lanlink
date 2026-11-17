/// Widget tests for the phone-only media affordances (M5 §C/§D).
///
/// * **C** — a video gets a cover thumbnail on a **mobile** build only (the
///   desktop keeps its type icon); the frame is one extracted image, and a
///   missing/unreadable frame falls back to the icon without crashing.
/// * **D** — on a phone a bubble image/video thumbnail is **tap-to-open**.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/widgets/file_thumbnail.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';
import 'package:lanlink_app/ui/widgets/type_icon.dart';

import '../support/pump_app.dart';

/// A valid **1×1 transparent PNG** (an explicit byte table, per this project's
/// discipline — never `base64Decode`), so `Image.memory` decodes cleanly.
final Uint8List _frame = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0B, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0xDA, 0x63, 0x60, 0x00, 0x02, 0x00, //
  0x00, 0x05, 0x00, 0x01, 0xE9, 0xFA, 0xDC, 0xD8, //
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, //
  0xAE, 0x42, 0x60, 0x82, //
]);

Future<void> _pumpThumb(
  WidgetTester tester,
  FakeBackend backend,
  String name,
  String path,
) =>
    pumpApp(
      tester,
      Scaffold(
        body: Center(
          child: FileThumbnail(fileName: name, path: path, edge: 96),
        ),
      ),
      backend: backend,
      settle: true,
    );

void main() {
  // The thumbnail cache is **module-level** (keyed by path), so it would leak a
  // cover from one test into the next; start each from a clean cache.
  setUp(clearThumbnailCache);

  testWidgets(
      'C: a MOBILE video thumbnail renders its extracted cover (with a ▶ badge)',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform.setMobile(true);
    backend.platform.setVideoThumbnail('/src/clip.mp4', _frame);

    await _pumpThumb(tester, backend, 'clip.mp4', '/src/clip.mp4');

    expect(find.byType(Image), findsOneWidget); // the cover, not the icon
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
  });

  testWidgets(
      'C: a DESKTOP video now SHOWS the port\'s frame — the icon is only the '
      'fallback (docs/19 §9.5)', (WidgetTester tester) async {
    // ★ This test used to assert the opposite ("stays the type icon, desktop
    // unchanged"). That rule encoded a **capability** as a **platform**
    // assumption, and it aged badly: the desktop draws a 240px video card, so
    // suppressing the read could only ever produce a blown-up icon — the "large
    // empty block" the user reported on 2026-10-17. Windows now asks the shell
    // thumbnail service, so a frame is used wherever a port can supply one; a
    // port that cannot still falls back to the icon (the next test pins that).
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform.setVideoThumbnail('/src/clip.mp4', _frame);

    await _pumpThumb(tester, backend, 'clip.mp4', '/src/clip.mp4');

    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(TypeIcon), findsNothing);
  });

  testWidgets(
      'C: a DESKTOP video with no extractable frame still falls back to the icon '
      '— nothing is promised that is not there', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    // No frame preset → the port returns null → the honest fallback.

    await _pumpThumb(tester, backend, 'clip.mp4', '/src/clip.mp4');

    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsNothing);
    expect(find.byType(TypeIcon), findsOneWidget);
  });

  testWidgets(
      'C: a mobile video with no extractable frame falls back to the icon and '
      'never crashes', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform.setMobile(true);
    // No frame preset → readVideoThumbnail returns null.

    await _pumpThumb(tester, backend, 'clip.mp4', '/src/clip.mp4');

    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsNothing);
    expect(find.byType(TypeIcon), findsOneWidget);
  });

  testWidgets('D: on a phone a bubble image thumbnail is tap-to-open',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform.setMobile(true);
    backend.platform.setBytes('/received/photo.png', _frame);
    backend.repo.addConversation(
      id: 'c-d',
      deviceFingerprint: 'DD12',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-d',
      conversationId: 'c-d',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
      files: <FileAttachment>[
        FileAttachment(
          id: 'f-d',
          messageId: 'm-d',
          fileName: 'photo.png',
          size: _frame.length,
          mime: 'image/png',
          sha256: 'AA',
          localPath: '/received/photo.png',
        ),
      ],
    );

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: const PeerDevice(
        fingerprint: 'DD12',
        alias: 'Dave',
        kind: DeviceKind.desktop,
        isOnline: true,
        lastPort: 53317,
      ),
    );

    final Finder thumb = find.descendant(
      of: find.byType(MessageBubble),
      matching: find.byType(FileThumbnail),
    );
    expect(thumb, findsOneWidget);

    // The bubble's image thumbnail has no fixed size until its bytes decode (the
    // aspect branch sets only `cacheWidth`), so let the image decode before
    // tapping — otherwise the tap target is a 0×0 box.
    await settleImages(tester);

    await tester.tap(thumb);
    await tester.pumpAndSettle();
    expect(backend.platform.opened, <String>['/received/photo.png']);
  });
}
