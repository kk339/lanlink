/// **0.2.37 — the phone's media bubble is the desktop's media bubble.**
///
/// The user sent two screenshots of *the same* video message and asked:
/// **"按电脑的那种气泡来"**. What differed:
///
/// | | phone (was wrong) | desktop (right) |
/// |---|---|---|
/// | thumbnail | inside a **light-blue bubble**, 12 dp inset all round | bare rounded thumbnail, nothing around it |
/// | file name | **inside** that bubble, at the bottom | **below** the thumbnail, in the description colour |
/// | status | inside the bubble | below, on the meta line |
///
/// The cause was one expression — `mediaCard = desktop && _isSingleMedia()` — so a
/// phone media message took the ordinary padded bubble path and printed its
/// caption inside the coloured box. It is `_isSingleMedia()` on both surfaces now,
/// and on the phone the name / status / notes are drawn **below** the bare card
/// (leaving them inside would put the card's fill back on screen as a coloured
/// strip under the image).
///
/// What each case proves:
/// * **A** — phone: the card has **no padding** and its rectangle is exactly the
///   thumbnail's, i.e. not one pixel of bubble fill is visible around the image
///   (stronger than "the colour is null": the fill is *covered*, which is also
///   why it can stay in the decoration for the loading/error box to sit on); the
///   name is **outside** and **below** it, and the status follows the name;
/// * **B** — desktop: every number unchanged, pinned, with the 0.2.36 values in
///   the comment so the comparison is on the record rather than in a chat log;
/// * **C** — the phone's **text** and **file-row** bubbles keep their coloured,
///   12 dp-padded bubble: only the media class changed;
/// * **D** — the thumbnail is still tap-to-open on the phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/widgets/file_thumbnail.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';
import 'package:lanlink_app/ui/widgets/status_chip.dart';

import '../support/pump_app.dart';

const String _videoName = 'lv_0_20260613154253.mp4';

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'CC01',
      alias: 'Eve',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// The whole message row under test: one attachment of [kind].
FileAttachment _attachment(String id, String name, String mime) =>
    FileAttachment(
      id: id,
      messageId: 'm-1',
      fileName: name,
      size: 8388608,
      sha256: 'AA',
      localPath: r'C:\recv\' '$name',
      mime: mime,
    );

/// Mounts the shell with one message carrying [files].
Future<FakeBackend> _pump(
  WidgetTester tester, {
  required Size size,
  required bool mobile,
  MessageKind kind = MessageKind.file,
  List<FileAttachment> files = const <FileAttachment>[],
  String? textBody,
  MessageDirection direction = MessageDirection.incoming,
}) async {
  useSurfaceSize(tester, size);
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.repo.addConversation(
    id: 'c-1',
    deviceFingerprint: 'CC01',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.repo.addMessage(
    id: 'm-1',
    conversationId: 'c-1',
    direction: direction,
    status: MessageStatus.done,
    kind: kind,
    textBody: textBody,
    files: files,
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
  );
  backend.platform.setMobile(mobile);
  await pumpShell(tester, backend: backend, settle: true, initialPeer: _peer());
  return backend;
}

/// The bubble's card: the nearest [Container] above [child]. That is the box that
/// carries the fill, the radius and the padding — the thing the user called
/// "气泡".
Finder _cardAbove(Finder child) =>
    find.ancestor(of: child, matching: find.byType(Container)).first;

Color? _cardFill(WidgetTester tester, Finder card) {
  final Container box = tester.widget<Container>(card);
  final Decoration? decoration = box.decoration;
  return decoration is BoxDecoration ? decoration.color : null;
}

void main() {
  testWidgets(
      '★ A: phone — a single video is a BARE card: no bubble inset, no fill '
      'visible around it, and the name sits below it', (WidgetTester tester) async {
    await _pump(
      tester,
      size: const Size(600, 1200),
      mobile: true,
      files: <FileAttachment>[_attachment('f-1', _videoName, 'video/mp4')],
    );

    final Finder thumb = find.byType(FileThumbnail);
    final Finder card = _cardAbove(thumb);
    final Rect cardRect = tester.getRect(card);
    final Rect thumbRect = tester.getRect(thumb);

    // 1. No bubble padding — this is the 12 dp that made the thumbnail look
    //    "packed inside a blue box".
    expect(tester.widget<Container>(card).padding, EdgeInsets.zero,
        reason: 'a media card must be edge-to-edge like the desktop one');
    // 2. …and therefore **not one pixel** of the card is visible around it. This
    //    is the assertion that fails if someone re-adds padding or a border
    //    without changing the colour: the fill is only invisible because it is
    //    completely covered, and that is exactly what the rectangle says.
    expect(cardRect, thumbRect,
        reason: 'the card and the thumbnail must be the same rectangle, or a '
            'ring of bubble fill shows around the video');
    expect(cardRect.width, 240.0,
        reason: 'the phone card is the thumbnail edge, not the wider box it used '
            'to be ($cardRect vs 349.3 × 306.0 on 0.2.36)');

    // 3. The name is outside the card and below it (0.2.36: inside, at the foot
    //    of the coloured box).
    final Finder name = find.text(_videoName);
    expect(
      find.descendant(of: card, matching: name),
      findsNothing,
      reason: 'the file name used to be printed inside the bubble',
    );
    final Rect nameRect = tester.getRect(name);
    expect(nameRect.top, greaterThanOrEqualTo(cardRect.bottom));
    expect(nameRect.left, cardRect.left,
        reason: 'left-aligned with the thumbnail, the way the desktop does it');

    // 4. The status follows the name, also outside the card.
    final Finder chip = find.byType(StatusChip);
    expect(chip, findsOneWidget);
    expect(find.descendant(of: card, matching: chip), findsNothing);
    expect(tester.getRect(chip).top, greaterThanOrEqualTo(nameRect.bottom));
    expect(find.text('已完成'), findsOneWidget,
        reason: 'the status stays readable — it did not become a casualty of '
            'moving the meta row out of the bubble');

    // 5. The whole row got 24 dp shorter (306 → 282 on a 600 dp phone): the 12 dp
    //    inset on each side of the old blue box is gone, and nothing new was
    //    added in its place.
    expect(tester.getSize(find.byType(MessageBubble)), const Size(576.0, 282.0));
  });

  testWidgets(
      '★ B: desktop — the same message, every number unchanged from 0.2.36',
      (WidgetTester tester) async {
    await _pump(
      tester,
      size: const Size(1400, 1000),
      mobile: false,
      files: <FileAttachment>[_attachment('f-1', _videoName, 'video/mp4')],
    );

    // Measured on 0.2.36 before this change, and again after: identical.
    expect(tester.getRect(_cardAbove(find.byType(FileThumbnail))),
        const Rect.fromLTRB(542.0, 189.0, 782.0, 429.0),
        reason: 'the desktop media card (240 × 240 at the pane\'s left edge)');
    expect(tester.getRect(find.byType(FileThumbnail)),
        const Rect.fromLTRB(542.0, 189.0, 782.0, 429.0));
    expect(tester.getRect(find.text(_videoName)),
        const Rect.fromLTRB(542.0, 433.0, 762.0, 449.0),
        reason: 'the name below the card, 4 dp under it, capped at 220 wide');
    expect(find.byType(FileTile), findsNothing,
        reason: 'a single video is a hero card, not a file row — on both surfaces');
  });

  testWidgets(
      '★ C: phone — TEXT and FILE-ROW bubbles are untouched: same coloured, '
      '12 dp-padded bubble as before', (WidgetTester tester) async {
    // A text message.
    await _pump(
      tester,
      size: const Size(600, 1200),
      mobile: true,
      kind: MessageKind.text,
      textBody: '这是一段文字',
    );
    final Finder textCard = _cardAbove(find.text('这是一段文字'));
    expect(tester.widget<Container>(textCard).padding, const EdgeInsets.all(12));
    expect(_cardFill(tester, textCard), isNotNull,
        reason: 'the phone text bubble keeps its fill — only the media class '
            'lost the box (the user complained about the video, not the text)');

    // A file ROW (a .txt goes down the `FileTile` path, not the hero card).
    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(
      tester,
      size: const Size(600, 1200),
      mobile: true,
      files: <FileAttachment>[_attachment('f-2', 'notes.txt', 'text/plain')],
    );
    final Finder rowCard = _cardAbove(find.byType(FileTile));
    expect(tester.widget<Container>(rowCard).padding, const EdgeInsets.all(12),
        reason: 'a file row is still a bubble with padding, not a bare card');
    expect(_cardFill(tester, rowCard), isNotNull);
  });

  testWidgets(
      'D: phone — the bare thumbnail is still tap-to-open', (WidgetTester tester) async {
    final FakeBackend backend = await _pump(
      tester,
      size: const Size(600, 1200),
      mobile: true,
      files: <FileAttachment>[_attachment('f-1', _videoName, 'video/mp4')],
    );

    await tester.tap(find.byType(FileThumbnail));
    await tester.pumpAndSettle();

    expect(backend.platform.opened, <String>[r'C:\recv\' '$_videoName'],
        reason: 'dropping the bubble chrome must not drop the tap target');
  });

  testWidgets(
      'E: phone — an OUTGOING video gets the same bare card, aligned to the right '
      'like the rest of its own bubble', (WidgetTester tester) async {
    // The screenshots the user sent are incoming; his own sent videos take the
    // other branch of the bubble, so "the shape is fixed" has to be proved there
    // too.
    await _pump(
      tester,
      size: const Size(600, 1200),
      mobile: true,
      direction: MessageDirection.outgoing,
      files: <FileAttachment>[_attachment('f-1', _videoName, 'video/mp4')],
    );

    final Finder thumb = find.byType(FileThumbnail);
    final Finder card = _cardAbove(thumb);
    final Rect cardRect = tester.getRect(card);
    expect(tester.widget<Container>(card).padding, EdgeInsets.zero);
    expect(cardRect, tester.getRect(thumb));
    expect(cardRect.right, 588.0,
        reason: 'flush with the pane\'s right edge (600 - 12 dp row padding)');

    final Rect nameRect = tester.getRect(find.text(_videoName));
    expect(nameRect.top, greaterThanOrEqualTo(cardRect.bottom));
    expect(nameRect.right, cardRect.right,
        reason: 'an outgoing meta line is right-aligned under the card');
    expect(find.descendant(of: card, matching: find.text(_videoName)),
        findsNothing);
  });
}
