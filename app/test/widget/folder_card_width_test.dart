/// The **desktop folder card's width floor** (0.2.39).
///
/// The user, after using 0.2.38 on a real desktop: *"文件夹那个……效果看着挺好的挺不错
/// 的，就是唯一一个小问题是电脑显示的看着有点短，手机上感觉合适的"*. The card
/// shrink-wraps its content, and the content is two short lines — so a one-file
/// folder (`放这看` / `110 KB · 1 个文件`) drew a **229.6 dp** card in a ~700 dp message
/// column: 21 % of the row, beside file rows that fill it, reading like a stray
/// line. The phone never had the problem (its card is stretched to the bubble cap,
/// 449.3 of 576), which is exactly the split the user described.
///
/// The fix is a **floor on the desktop only** (`kFolderCardMinWidth = 320`), applied
/// to the card **box** — the rectangle the user sees, padding included — and
/// clamped to the pane's own cap so a narrow desktop cannot be overrun.
///
/// These numbers are pinned exactly, before/after where the case is a regression:
/// the "before" ones were measured on the 0.2.38 tree with the same fixture.
///
/// **★ The phone has two shapes, and neither is new (measured on 0.2.38 and on
/// 0.2.39, identical):**
///
/// | phone, 600×1200 | width × height |
/// |---|---|
/// | the **newest** message | **449.28 × 62** |
/// | an **older** one | **449.28 × 62** |
///
/// The cause is not the name: on the phone the status footer sits **inside** the
/// card and `_footer` returns an `Align`, which takes the full width the bubble is
/// offered — so the card is stretched. When the footer is `null` (`done` **and**
/// not the last message) nothing stretches it, and the card shrink-wraps to its two
/// short lines, exactly like the desktop did before 0.2.39's floor. The last four
/// cases below pin all of it, so any future change to either shape is visible.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/draft_store.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';
import 'package:lanlink_app/ui/widgets/status_chip.dart';

import '../support/pump_app.dart';

const String _shortName = '放这看';
const String _longName = 'lanlink-电脑版-0.2.33-正式版';

/// The bubble's width cap at 1400×1000 (`min(pane × 0.78, 460)`).
const double _desktopCap = 460;

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'CC01',
      alias: '小甲',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// Mounts the thread with one folder message: [arrived] files of 110 KB, declared
/// [declared] (so `arrived < declared` adds the `已收到 x/y` line and its extra
/// height).
Future<FakeBackend> _pump(
  WidgetTester tester, {
  required Size size,
  required bool mobile,
  required String name,
  int arrived = 1,
  int declared = 1,
  /// Whether this folder message is the **newest** in the thread. A newer message
  /// removes the `已完成` footer, and with it the only thing that stretches the
  /// phone card (`docs/19` §9-A shows the chip on the last bubble only).
  bool newest = true,
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
    kind: MessageKind.file,
    folderName: name,
    folderFiles: declared,
    files: <FileAttachment>[
      for (int i = 0; i < arrived; i++)
        FileAttachment(
          id: 'f$i',
          messageId: 'm-1',
          fileName: 'f$i.bin',
          size: 110 * 1024,
          sha256: 'AA',
          localPath: '/d/f$i.bin',
          relativePath: 'f$i.bin',
        ),
    ],
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
  );
  if (!newest) {
    backend.repo.addMessage(
      id: 'm-newer',
      conversationId: 'c-1',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.text,
      textBody: '更晚的一条',
      createdAt: fixedEpoch.add(const Duration(minutes: 5)),
      updatedAt: fixedEpoch.add(const Duration(minutes: 5)),
    );
  }
  backend.platform.setMobile(mobile);
  final ConversationController controller = ConversationController(
    repo: backend.repo,
    orchestrator: TransferOrchestrator(
      repo: backend.repo,
      transfer: backend.transfer,
    ),
    platform: backend.platform,
    ids: backend.ids,
    clock: backend.clock,
    conversationId: 'c-1',
    drafts: ComposerDraftStore(),
  );
  addTearDown(controller.dispose);
  unawaited(controller.load());
  await pumpApp(
    tester,
    Scaffold(
      body: ConversationThread(controller: controller, peer: _peer()),
    ),
    backend: backend,
    settle: true,
  );
  return backend;
}

/// The **card box** — the Container that draws the bubble's fill and padding.
Finder _card() => find
    .ancestor(of: find.byIcon(Icons.folder), matching: find.byType(Container))
    .first;

void main() {
  testWidgets(
      '★ criterion 1: desktop — a SHORT-named folder card is exactly 320 dp wide '
      '(it was 229.6 before)',
      (WidgetTester tester) async {
    await _pump(
      tester,
      size: const Size(1400, 1000),
      mobile: false,
      name: _shortName,
    );

    final Rect card = tester.getRect(_card());
    expect(card.width, 320.0,
        reason: 'kFolderCardMinWidth — an exact value, not "wider than before"');
    // The card is still left-aligned on the bubble's own box.
    expect(card.left, 38.0);

    // …and the height is untouched: 12 + 20 (name) + 2 + 16 (meta) + 12.
    expect(card.height, 62.0,
        reason: 'the floor is a width, not a size — the height must not move');
    expect(find.text('110 KB · 1 个文件'), findsOneWidget);
  });

  testWidgets(
      '★ criterion 2: desktop — a LONG name still grows the card, and never past '
      'the bubble cap', (WidgetTester tester) async {
    await _pump(
      tester,
      size: const Size(1400, 1000),
      mobile: false,
      name: _longName,
      arrived: 12,
      declared: 20,
    );

    final Rect card = tester.getRect(_card());
    expect(card.width, greaterThan(320.0),
        reason: 'a long name must not be squeezed to the floor');
    expect(card.width, lessThanOrEqualTo(_desktopCap),
        reason: 'the floor is clamped by the pane cap, not added on top of it');
    // Measured (0.2.38 top, 0.2.39 bottom): 369.5 both times — the floor changed
    // nothing for a card that was already wider than it.
    expect(card.width, 369.5);

    // ★ criterion 3: the height of the **12-of-20** card is still 82.
    expect(card.height, 82.0,
        reason: '0.2.39 must not "fix" the width by changing the height');
    expect(find.text('已收到 12/20'), findsOneWidget);
  });

  testWidgets(
      'criterion 3 (short name, still receiving): 320 wide and 82 tall — the '
      'floor did not collapse the extra line', (WidgetTester tester) async {
    await _pump(
      tester,
      size: const Size(1400, 1000),
      mobile: false,
      name: _shortName,
      arrived: 12,
      declared: 20,
    );

    final Rect card = tester.getRect(_card());
    expect(card.width, 320.0);
    expect(card.height, 82.0);
  });

  testWidgets(
      '★ criterion 4 (red line): phone — the card is byte-for-byte what it was '
      '(449.28, with the 已完成 chip now BELOW the card)', (WidgetTester tester) async {
    await _pump(
      tester,
      size: const Size(600, 1200),
      mobile: true,
      name: _shortName,
    );
    // Measured on 0.2.38 before this change, and again after: identical.
    // (`449.28`, not a round number: it is the bubble cap 460 minus the 12 dp row
    // padding on each side and the avatar column — a float, so `closeTo`.)
    expect(tester.getRect(_card()).width, closeTo(449.28, 0.01));
    // 0.2.47: the `已完成` row lives under the card now, so a complete 1/1 folder
    // card is 62 tall instead of 84 — the **width**, which is what this file is
    // about, did not move.
    expect(tester.getRect(_card()).height, 62.0);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(
      tester,
      size: const Size(600, 1200),
      mobile: true,
      name: _longName,
      arrived: 12,
      declared: 20,
    );
    expect(tester.getRect(_card()).width, closeTo(449.28, 0.01),
        reason: 'the phone card is stretched by the bubble cap, not by the name');
    expect(tester.getRect(_card()).height, 82.0);
  });

  testWidgets(
      'the floor is clamped to the pane: a narrow desktop pane does not overflow',
      (WidgetTester tester) async {
    // 420 dp is a compact layout: the cap there is well under 320, and a floor of
    // a flat 320 would overflow the bubble. It must shrink instead.
    await _pump(
      tester,
      size: const Size(420, 900),
      mobile: false,
      name: _shortName,
    );

    final Rect card = tester.getRect(_card());
    expect(card.width, lessThan(320.0),
        reason: 'the floor cannot be larger than the space the bubble has');
    expect(tester.takeException(), isNull,
        reason: 'no RenderFlex/paint overflow from the floor');
  });

  testWidgets(
      '★ criterion 2 (CONTRACT CHANGE, 0.2.40): an OLDER phone folder card is now '
      '449.28 wide like every other folder card — it used to shrink to 229.60 '
      'because nothing was there to stretch it',
      (WidgetTester tester) async {
    await _pump(
      tester,
      size: const Size(600, 1200),
      mobile: true,
      name: _shortName,
      newest: false,
    );

    final Rect card = tester.getRect(_card());
    // was 229.60 × 62 on 0.2.38 **and** 0.2.39 (measured on both trees); the width
    // is now the bubble's own cap, so the shape no longer depends on `showStatus`.
    expect(card.width, closeTo(449.28, 0.01),
        reason: 'every phone folder card is the bubble width now — that is the '
            'whole point of 0.2.40');
    expect(card.height, 62.0,
        reason: 'the height still follows the content: no footer ⇒ no extra line');

    // …and the cause of the old bug is still asserted where it happens: this
    // bubble has **no** status chip, so nothing stretches it any more.
    final Finder folderBubble = find
        .ancestor(of: find.byIcon(Icons.folder), matching: find.byType(MessageBubble))
        .first;
    expect(
      find.descendant(of: folderBubble, matching: find.byType(StatusChip)),
      findsNothing,
      reason: 'still no footer on this bubble — the card fills the width on its '
          'own now, instead of borrowing the footer\'s Align',
    );
  });

  testWidgets(
      'phone, outgoing: the same two shapes, right-aligned',
      (WidgetTester tester) async {
    await _pump(
      tester,
      size: const Size(600, 1200),
      mobile: true,
      name: _shortName,
      direction: MessageDirection.outgoing,
    );
    final Rect newest = tester.getRect(_card());
    expect(newest.width, closeTo(449.28, 0.01));
    expect(newest.height, 62.0,
        reason: 'the 已完成 row is under the card since 0.2.47');
    expect(newest.right, 588.0, reason: 'flush with the pane, minus the row padding');

    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(
      tester,
      size: const Size(600, 1200),
      mobile: true,
      name: _shortName,
      direction: MessageDirection.outgoing,
      newest: false,
    );
    final Rect older = tester.getRect(_card());
    // 0.2.40: the *width* no longer depends on the footer — only the height does.
    expect(older.width, closeTo(449.28, 0.01));
    expect(older.height, 62.0);
    expect(older.right, 588.0);
  });

  testWidgets(
      '★ criterion 5: two folder messages in ONE thread — one old, one new — are the '
      'same width (this is the case that catches "two shapes" coming back)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 1200));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-1',
      deviceFingerprint: 'CC01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    // Older folder (`放这看`), then a newer folder — so only the second one gets a
    // `已完成` footer, which is exactly the asymmetry that used to change widths.
    backend.repo.addMessage(
      id: 'm-old',
      conversationId: 'c-1',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.file,
      folderName: _shortName,
      folderFiles: 1,
      files: <FileAttachment>[_oneFile('old')],
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-new',
      conversationId: 'c-1',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.file,
      folderName: '另一个文件夹',
      folderFiles: 1,
      files: <FileAttachment>[_oneFile('new')],
      createdAt: fixedEpoch.add(const Duration(minutes: 5)),
      updatedAt: fixedEpoch.add(const Duration(minutes: 5)),
    );
    backend.platform.setMobile(true);
    final ConversationController controller = ConversationController(
      repo: backend.repo,
      orchestrator: TransferOrchestrator(
        repo: backend.repo,
        transfer: backend.transfer,
      ),
      platform: backend.platform,
      ids: backend.ids,
      clock: backend.clock,
      conversationId: 'c-1',
      drafts: ComposerDraftStore(),
    );
    addTearDown(controller.dispose);
    unawaited(controller.load());
    await pumpApp(
      tester,
      Scaffold(
        body: ConversationThread(controller: controller, peer: _peer()),
      ),
      backend: backend,
      settle: true,
    );

    final Rect oldCard = tester.getRect(_cardAboveText(_shortName));
    final Rect newCard = tester.getRect(_cardAboveText('另一个文件夹'));
    expect(oldCard.width, closeTo(newCard.width, 0.01),
        reason: 'a folder is a container message: its shape may not depend on '
            'whether a status footer happens to be under it');
    expect(oldCard.width, closeTo(449.28, 0.01));
    expect(newCard.width, closeTo(449.28, 0.01));
    // Both are complete 1/1 folders, so both are 62 tall; the point of the case is
    // that the **widths** agree, and they do.
    expect(oldCard.height, 62.0);
    expect(newCard.height, 62.0);
  });

  testWidgets(
      '★ criterion 3 (red line): the phone TEXT and FILE-ROW bubbles keep their exact '
      'widths — the folder sizing must not leak to other kinds',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 1200));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-1',
      deviceFingerprint: 'CC01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-row',
      conversationId: 'c-1',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.file,
      files: const <FileAttachment>[
        FileAttachment(
          id: 'f-row',
          messageId: 'm-row',
          fileName: 'notes.txt',
          size: 12,
          sha256: 'AA',
          localPath: '/d/notes.txt',
        ),
      ],
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-text',
      conversationId: 'c-1',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.text,
      textBody: '这是一段文字',
      createdAt: fixedEpoch.add(const Duration(minutes: 5)),
      updatedAt: fixedEpoch.add(const Duration(minutes: 5)),
    );
    backend.platform.setMobile(true);
    final ConversationController controller = ConversationController(
      repo: backend.repo,
      orchestrator: TransferOrchestrator(
        repo: backend.repo,
        transfer: backend.transfer,
      ),
      platform: backend.platform,
      ids: backend.ids,
      clock: backend.clock,
      conversationId: 'c-1',
      drafts: ComposerDraftStore(),
    );
    addTearDown(controller.dispose);
    unawaited(controller.load());
    await pumpApp(
      tester,
      Scaffold(
        body: ConversationThread(controller: controller, peer: _peer()),
      ),
      backend: backend,
      settle: true,
    );

    // 0.2.47 — the text bubble now shrink-wraps like everything else: its width is
    // the sentence's, not the bubble cap's. (Before 0.2.47 this was 449.28 × 66
    // because the `已完成` footer stretched the card; that is the bug the user
    // reported, and it is why this number changed.)
    final Rect text = tester.getRect(
      find.ancestor(of: find.text('这是一段文字'), matching: find.byType(Container)).first,
    );
    expect(text.width, closeTo(109.5, 0.01),
        reason: 'the five ideographs\' own advance + the 12 dp padding on each side '
            '— content width, nowhere near the 449.28 cap');
    expect(text.height, 44.0);

    final Rect row = tester.getRect(
      find.ancestor(of: find.byType(FileTile), matching: find.byType(Container)).first,
    );
    expect(row.width, closeTo(180.25, 0.01),
        reason: 'a file row still shrink-wraps — 0.2.40 changes folder cards only');
    expect(row.height, 72.0);
  });
}

/// The card box of the folder named [name].
Finder _cardAboveText(String name) => find
    .ancestor(of: find.text(name), matching: find.byType(Container))
    .first;

/// One 110 KB attachment for [tag].
FileAttachment _oneFile(String tag) => FileAttachment(
      id: 'f-$tag',
      messageId: 'm-$tag',
      fileName: '$tag.bin',
      size: 110 * 1024,
      sha256: 'AA',
      localPath: '/d/$tag.bin',
      relativePath: '$tag.bin',
    );
