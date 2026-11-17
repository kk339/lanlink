/// **A bubble's width may not depend on whether it is the newest message**
/// (0.2.47).
///
/// The user, on a phone: *"我发的第一个文字消息会让气泡变得很长，第二消息会让第一个消息恢复
/// 正常大小，但是第二个又变长了"*. Root cause, measured not guessed: `_footer()` returned
/// an `Align` — and `Align` without a `widthFactor` is as wide as its parent allows —
/// so inside the card's `Column` it made the **whole bubble** take the full width
/// whenever a footer existed. On a phone the footer exists only on the newest message
/// (「已完成」 is drawn on the last bubble, `docs/19` §9-A) and on anything not `done`.
/// The same sentence therefore measured **449.28** as the last message and **38.25**
/// a message later.
///
/// The fix is in the shared place (`message_bubble.dart`), not in the text bubble:
/// the phone's status row moved **out of the card**, exactly where the desktop has
/// always had it, so no message kind can be widened by its own chrome again. This
/// file pins that, per kind, at both positions, on both surfaces.
///
/// | kind | phone width (latest == not latest) |
/// |---|---|
/// | text `好` | **38.25** (content, nowhere near the 449.28 cap) |
/// | long text | **449.28** (wrapped at the cap, unchanged) |
/// | one file | **180.25** |
/// | two files | **123.25** |
/// | folder card | **449.28** — full width **by design** since 0.2.40 |
/// | image / video | **240** — the thumbnail's fixed edge, by design |
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
import 'package:lanlink_app/ui/widgets/file_tile.dart';
import 'package:lanlink_app/ui/widgets/status_chip.dart';

import '../support/pump_app.dart';

/// The bubble's width cap on a 600 dp phone: `576 × 0.78` (the pane, not the window).
const double _phoneCap = 449.28;

/// The text used for the "short" cases — one ideograph, i.e. narrower than the
/// 已完成 chip that used to stretch the bubble.
const String _short = '好';

/// A long body: wraps well past the cap, so its width is the cap at any position.
final String _long = '这是一段很长的文字' * 12;

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'CC01',
      alias: '小甲',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// What the single message under test is.
enum _Kind { textShort, textLong, fileOne, fileTwo, folder, media }

List<FileAttachment> _filesOf(_Kind kind) => switch (kind) {
      _Kind.fileOne => const <FileAttachment>[
          FileAttachment(
            id: 'f0',
            messageId: 'm-1',
            fileName: 'notes.txt',
            size: 12,
            sha256: 'AA',
            localPath: '/d/notes.txt',
          ),
        ],
      _Kind.fileTwo => const <FileAttachment>[
          FileAttachment(
            id: 'f0',
            messageId: 'm-1',
            fileName: 'a.txt',
            size: 12,
            sha256: 'AA',
            localPath: '/d/a.txt',
          ),
          FileAttachment(
            id: 'f1',
            messageId: 'm-1',
            fileName: 'b.txt',
            size: 34,
            sha256: 'BB',
            localPath: '/d/b.txt',
          ),
        ],
      _Kind.folder => const <FileAttachment>[
          FileAttachment(
            id: 'f0',
            messageId: 'm-1',
            fileName: 'a.jpg',
            size: 100,
            sha256: 'AA',
            localPath: '/d/a.jpg',
            relativePath: 'a.jpg',
          ),
        ],
      _Kind.media => const <FileAttachment>[
          FileAttachment(
            id: 'f0',
            messageId: 'm-1',
            fileName: 'v.mp4',
            size: 999,
            sha256: 'AA',
            localPath: '/d/v.mp4',
            mime: 'video/mp4',
          ),
        ],
      _ => const <FileAttachment>[],
    };

/// The anchor that identifies the row's **content**, so `_card()` is the bubble's
/// own box and not some inner Container.
Finder _anchor(_Kind kind) => switch (kind) {
      _Kind.fileOne || _Kind.fileTwo => find.byType(FileTile).first,
      _Kind.folder => find.byIcon(Icons.folder),
      _Kind.media => find.byIcon(Icons.play_circle_fill),
      _Kind.textShort => find.text(_short),
      _Kind.textLong => find.text(_long),
    };

/// The bubble's card (fill + padding + the content).
Finder _card(_Kind kind) =>
    find.ancestor(of: _anchor(kind), matching: find.byType(Container)).first;

/// Mounts one message of [kind]; with [latest] false a newer text message follows,
/// which is exactly what removes the `已完成` footer.
Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required bool mobile,
  required _Kind kind,
  required bool latest,
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
  final List<FileAttachment> files = _filesOf(kind);
  backend.repo.addMessage(
    id: 'm-1',
    conversationId: 'c-1',
    direction: MessageDirection.incoming,
    status: MessageStatus.done,
    kind: files.isEmpty ? MessageKind.text : MessageKind.file,
    textBody: switch (kind) {
      _Kind.textShort => _short,
      _Kind.textLong => _long,
      _ => null,
    },
    folderName: kind == _Kind.folder ? '素材' : null,
    folderFiles: kind == _Kind.folder ? 1 : 0,
    files: files,
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
  );
  if (!latest) {
    backend.repo.addMessage(
      id: 'm-2',
      conversationId: 'c-1',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.text,
      textBody: '之后的一条',
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
    Scaffold(body: ConversationThread(controller: controller, peer: _peer())),
    backend: backend,
    settle: true,
  );
}

/// The card's size for [kind] at the two positions — the pair every case compares.
Future<(Size, Size)> _latestVersusOld(
  WidgetTester tester, {
  required Size size,
  required bool mobile,
  required _Kind kind,
}) async {
  await _pump(tester, size: size, mobile: mobile, kind: kind, latest: true);
  final Size latest = tester.getSize(_card(kind));

  await tester.pumpWidget(const SizedBox.shrink());
  await _pump(tester, size: size, mobile: mobile, kind: kind, latest: false);
  final Size older = tester.getSize(_card(kind));

  return (latest, older);
}

void main() {
  testWidgets(
      '★ criterion 1+2: the same sentence is the SAME width as the newest message and '
      'as an older one — and it is the sentence\'s width, not the cap',
      (WidgetTester tester) async {
    final (Size latest, Size older) = await _latestVersusOld(
      tester,
      size: const Size(600, 1200),
      mobile: true,
      kind: _Kind.textShort,
    );

    // The bug, in one assertion: these two used to be 449.28 and 38.25.
    expect(latest.width, older.width,
        reason: 'a bubble may not resize itself when the next message arrives');
    expect(latest.width, closeTo(38.25, 0.01),
        reason: 'one ideograph + 12 dp padding each side — content width');
    expect(latest.height, older.height,
        reason: 'the 已完成 row lives under the bubble now, so not even the height '
            'depends on the position');

    // ★ The reverse mistake — "just make everything full width" — is not a fix.
    expect(latest.width, lessThan(_phoneCap / 2),
        reason: 'a short message must stay short');
  });

  testWidgets(
      '★ criterion 3: long text still wraps AT the cap, unchanged by the fix',
      (WidgetTester tester) async {
    final (Size latest, Size older) = await _latestVersusOld(
      tester,
      size: const Size(600, 1200),
      mobile: true,
      kind: _Kind.textLong,
    );
    expect(latest.width, closeTo(_phoneCap, 0.01));
    expect(older.width, closeTo(_phoneCap, 0.01));
    expect(latest.width, older.width);
    expect(latest.height, greaterThan(older.height ~/ 2),
        reason: 'a long body still wraps; this is the regression guard, not the '
            'bug — the height legitimately differs by nothing now, so assert the '
            'width only if this ever looks wrong');
  });

  testWidgets(
      '★ criterion 4: one file, two files, a folder card and a video — each the same '
      'width at both positions', (WidgetTester tester) async {
    // A phone folder card is full width **by design** (0.2.40: the user asked for
    // one shape) and a media card is its thumbnail's fixed 240 — both are asserted
    // as such rather than being "un-stretched" like the rest.
    for (final (_Kind kind, double expected) combo in <(_Kind, double)>[
      (_Kind.fileOne, 180.25),
      (_Kind.fileTwo, 123.25),
      (_Kind.folder, _phoneCap),
      (_Kind.media, 240.0),
    ]) {
      final (Size latest, Size older) = await _latestVersusOld(
        tester,
        size: const Size(600, 1200),
        mobile: true,
        kind: combo.$1,
      );
      expect(latest.width, closeTo(combo.$2, 0.01), reason: '${combo.$1}: latest');
      expect(older.width, closeTo(combo.$2, 0.01), reason: '${combo.$1}: older');
      expect(latest.width, older.width,
          reason: '${combo.$1} must not resize when a newer message arrives');
    }
  });

  testWidgets(
      '★ criterion 5: the DESKTOP was already correct — pin it so a future fix cannot '
      'break it', (WidgetTester tester) async {
    final (Size latest, Size older) = await _latestVersusOld(
      tester,
      size: const Size(1400, 1000),
      mobile: false,
      kind: _Kind.textShort,
    );
    // On the desktop the footer has always been the `below` row **outside** the
    // card, which is why this bug never appeared there.
    expect(latest.width, closeTo(38.25, 0.01));
    expect(latest.width, older.width);
  });

  testWidgets(
      '★ the structural guard: the status chip is NOT inside the bubble on a phone — '
      'that is what keeps *every* kind honest, not just the text one',
      (WidgetTester tester) async {
    await _pump(
      tester,
      size: const Size(600, 1200),
      mobile: true,
      kind: _Kind.fileOne,
      latest: true,
    );

    final Finder chip = find.byType(StatusChip);
    expect(chip, findsOneWidget, reason: 'the newest bubble still says 已完成');
    expect(
      find.descendant(of: _card(_Kind.fileOne), matching: chip),
      findsNothing,
      reason: 'the chip is a remark **under** the bubble (as on the desktop). Put '
          'it back inside and the card becomes the widest child of its own column, '
          'which is precisely the 0.2.47 bug.',
    );
    // …and it is placed under the card, not floating somewhere else.
    expect(tester.getRect(chip).top,
        greaterThanOrEqualTo(tester.getRect(_card(_Kind.fileOne)).bottom));
  });
}
