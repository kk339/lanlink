/// End-to-end thumbnail tests through the real panes (PRD §8-G27 / design §5).
///
/// `test/widget/file_thumbnail_test.dart` pins the widget's own contract
/// (G27–G33); this file drives the **integration**: an image file renders a real
/// `Image.memory` inside a message bubble, a recent-files row and the file-detail
/// preview — and each keeps the right shape:
///
/// * a bubble's single image keeps the source ratio (not squashed) — the round-4
///   device fix (design §13-偏离⑥);
/// * a list row stays a square, cropped thumbnail (fixed row height);
/// * the detail preview keeps the ratio within its 320px cap.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/file_detail.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';
import 'package:lanlink_app/ui/widgets/file_thumbnail.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';

import '../support/pump_app.dart';

/// A valid **64×36** (16:9) PNG — a solid red left half and blue right half —
/// deliberately non-square, so a squashed decode is observable as a wrong aspect
/// ratio.
///
/// Written as an **explicit byte table**, never `base64Decode` (root cause A): a
/// byte table has no decode step, so a bad constant can never surface as a
/// `FormatException` inside a ratio assertion. The self-check in `main` fails
/// once, here, if these bytes drift. (Identical bytes live in
/// `file_thumbnail_test.dart` — the two files stay independent on purpose.)
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

const String _path = '/received/wide.png';

/// The 16:9 ratio of [_widePng] (64 / 36).
const double _wideRatio = 64 / 36;

FileAttachment _image(String id, String messageId) => FileAttachment(
      id: id,
      messageId: messageId,
      fileName: 'wide.png',
      size: _widePng.length,
      mime: 'image/png',
      sha256: 'AA',
      localPath: _path,
    );

PeerDevice _peer(String fingerprint, {required String alias}) => PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

void main() {
  setUp(clearThumbnailCache); // the byte cache is module-level (process-wide)

  // Constant self-check (root cause A): fail here, once, if the byte table
  // drifts — rather than letting an undecodable image surface as a mysterious
  // ratio failure inside the three tests below.
  test('_widePng is a well-formed 64×36 PNG (constant self-check)', () {
    expect(_widePng.length, 116);
    expect(
      _widePng.sublist(0, 8),
      <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
    );
    int be32(int offset) =>
        (_widePng[offset] << 24) |
        (_widePng[offset + 1] << 16) |
        (_widePng[offset + 2] << 8) |
        _widePng[offset + 3];
    expect(be32(16), 64); // IHDR width
    expect(be32(20), 36); // IHDR height
  });

  testWidgets(
      'a single-image bubble renders the real image and keeps its 16:9 ratio '
      '(G27)', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(800, 1400));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform.setBytes(_path, _widePng);
    backend.repo.addConversation(
      id: 'c-t',
      deviceFingerprint: 'TT01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-t',
      conversationId: 'c-t',
      direction: MessageDirection.outgoing,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      files: <FileAttachment>[_image('f-t', 'm-t')],
    );

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('TT01', alias: 'Tina'),
    );
    await settleImages(
        tester); // decode on the real event loop before measuring

    expect(find.byType(Image), findsOneWidget);
    final Size size = tester.getSize(find.byType(Image));
    // The image is displayed at its own ratio, not squashed to a square, and is
    // capped at the 240px bubble edge.
    expect(
        size.width / size.height, moreOrLessEquals(_wideRatio, epsilon: 0.05));
    expect(size.width, lessThanOrEqualTo(240 + 0.01));
    expect(size.height, lessThanOrEqualTo(240 + 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a recent-files row keeps a square, cropped 40×40 thumbnail (G27)',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform.setBytes(_path, _widePng);
    backend.repo.addConversation(
      id: 'c-r',
      deviceFingerprint: 'RR01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-r',
      conversationId: 'c-r',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      files: <FileAttachment>[_image('f-r', 'm-r')],
    );

    await pumpShell(
      tester,
      initialModule: ShellModule.recentFiles,
      backend: backend,
      settle: true,
    );
    await settleImages(tester);

    // The row's leading slot is a real thumbnail, and the list row keeps its
    // constant square size (the non-square source is cropped by `BoxFit.cover`,
    // never squashed — the round-4 fix).
    expect(find.byType(FileTile), findsOneWidget);
    expect(find.byType(Image), findsWidgets);
    expect(tester.getSize(find.byType(Image).first), const Size(40, 40));
  });

  testWidgets(
      'the file-detail preview keeps its 16:9 ratio within the 320px cap (G27)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1200, 900));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform.setBytes(_path, _widePng);
    backend.repo.addConversation(
      id: 'c-d',
      deviceFingerprint: 'DD01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-d',
      conversationId: 'c-d',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      files: <FileAttachment>[_image('f-d', 'm-d')],
    );

    await pumpShell(
      tester,
      initialModule: ShellModule.recentFiles,
      backend: backend,
      settle: true,
    );

    await tester.tap(find.widgetWithText(FileTile, 'wide.png'));
    await tester.pumpAndSettle();
    await settleImages(tester);

    expect(find.byType(FileDetail), findsOneWidget);
    final Finder preview = find.descendant(
      of: find.byType(FileDetail),
      matching: find.byType(Image),
    );
    expect(preview, findsOneWidget);
    final Size size = tester.getSize(preview);
    expect(
        size.width / size.height, moreOrLessEquals(_wideRatio, epsilon: 0.05));
    expect(size.width, lessThanOrEqualTo(320 + 0.01));
    expect(size.height, lessThanOrEqualTo(320 + 0.01));
  });
}
