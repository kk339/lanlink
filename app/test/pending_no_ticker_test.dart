/// A queued message must not keep the 1 Hz progress poll spinning (0.2.40).
///
/// `_hasLiveTransfer` asks "is anything moving that the bar should repaint?".
/// It skipped only terminal statuses, and `pending` is not terminal — so a
/// message queued for an offline peer (transfer row at `0 / total`, no error,
/// i.e. byte-for-byte identical to a live upload) answered **yes**, and the
/// ticker ran once a second until the peer came back. On a bubble that draws no
/// progress bar, that is pure idle work — and it was how this was found: the
/// `flutter_test` invariant "a Timer is still pending after the widget tree was
/// disposed" fired in the outbox-pump widget tests.
///
/// `pending` is the one non-terminal status that means *nothing is running*, so
/// it belongs on the same side of the line as `done`/`canceled`/`rejected`/
/// `failed`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/draft_store.dart';
import 'package:lanlink_app/domain/models.dart';

import 'support/fakes.dart';

const String _kConversationId = 'c-ticker';

/// A backend with one conversation and one message at [status], with a single
/// attachment whose transfer row sits at `0 / 12` and carries no error — the
/// exact shape that makes "live" and "queued" indistinguishable by bytes.
({FakeBackend backend, ConversationController controller}) _build(
  MessageStatus status,
) {
  final FakeBackend backend = FakeBackend();
  backend.repo.addConversation(
    id: _kConversationId,
    deviceFingerprint: 'AAAA1111',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.repo.addMessage(
    id: 'm-1',
    conversationId: _kConversationId,
    direction: MessageDirection.outgoing,
    status: status,
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
    files: <FileAttachment>[
      FileAttachment(
        id: 'f1',
        messageId: 'm-1',
        fileName: 'notes.txt',
        size: 12,
        sha256: 'AA',
        localPath: '/d/notes.txt',
      ),
    ],
  );
  return (
    backend: backend,
    controller: ConversationController(
      repo: backend.repo,
      orchestrator:
          TransferOrchestrator(repo: backend.repo, transfer: backend.transfer),
      platform: backend.platform,
      ids: backend.ids,
      clock: backend.clock,
      conversationId: _kConversationId,
      drafts: ComposerDraftStore(),
    ),
  );
}

void main() {
  // `_hasLiveTransfer` is private and the ticker is a real `Timer.periodic`, so
  // the judgement has to be behavioural: **an empty widget tree plus fake time**
  // is the smallest setup that can tell "a timer is firing" from "nothing is".
  // A pivot on the timer itself would have to read a private field, i.e. assert
  // the implementation instead of the behaviour.

  testWidgets('1. a lone queued message does not keep the progress poll alive',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final ({FakeBackend backend, ConversationController controller}) built =
        _build(MessageStatus.pending);
    final ConversationController controller = built.controller;

    await controller.load();
    // Attached *after* `load` so its own repaint is not counted: everything
    // observed from here on can only come from the ticker.
    int notifies = 0;
    controller.addListener(() => notifies += 1);

    await tester.pump(const Duration(seconds: 2));

    expect(notifies, 0,
        reason: 'a queued message paints no progress and moves no byte — the '
            '1 Hz repaint it used to force is pure idle work (and it never '
            'stopped while the peer stayed away)');

    controller.dispose();
    built.backend.dispose();
  });

  testWidgets('2. a transferring message still polls (no regression)',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final ({FakeBackend backend, ConversationController controller}) built =
        _build(MessageStatus.transferring);
    final ConversationController controller = built.controller;

    await controller.load();
    int notifies = 0;
    controller.addListener(() => notifies += 1);

    await tester.pump(const Duration(seconds: 2));

    expect(notifies, greaterThanOrEqualTo(1),
        reason: 'the ticker exists to turn progress writes into repaints; '
            'excluding `pending` must not silence a live upload');

    controller.dispose();
    built.backend.dispose();
  });

  testWidgets('3. a queued message that the pump starts DOES poll again',
      (WidgetTester tester) async {
    // The other half of the rule: excluding `pending` may only ever remove idle
    // work. The moment the send actually starts, a repository event must re-arm
    // the ticker — otherwise the fix would have re-introduced "进度条像卡住".
    await tester.pumpWidget(const SizedBox.shrink());
    final ({FakeBackend backend, ConversationController controller}) built =
        _build(MessageStatus.pending);
    final ConversationController controller = built.controller;

    await controller.load();
    int notifies = 0;
    controller.addListener(() => notifies += 1);
    await tester.pump(const Duration(seconds: 2));
    expect(notifies, 0);

    // What the outbox pump writes when it resumes the queued row.
    expect(
      built.backend.repo.setStatus(
        messageId: 'm-1',
        from: MessageStatus.pending,
        to: MessageStatus.awaitingConfirm,
      ),
      isTrue,
    );
    // The repository event is delivered asynchronously to the controller.
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(notifies, greaterThanOrEqualTo(1),
        reason: 'the resume is a `MessageStatusUpdated` event, and `_onEvent` '
            're-arms the poll on it — that is what makes excluding `pending` '
            'safe rather than a one-way door');

    controller.dispose();
    built.backend.dispose();
  });
}
