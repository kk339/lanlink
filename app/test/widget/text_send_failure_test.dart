/// 0.2.48 — a text send that throws must not eat what the user typed.
///
/// The defect: `_sendText` cleared the composer **first** and then awaited the
/// dispatch, and the callers invoked it through `unawaited(...)`:
///
/// ```dart
/// _composerController.clear();                        // gone already
/// await widget.controller.sendText(...);              // may throw
/// ```
///
/// On the throw path nothing else had happened — `ConversationController.sendText`
/// had also cleared the per-conversation draft **before** dialling — so the
/// paragraph existed nowhere: no bubble (no row was ever recorded), an empty
/// field, an empty draft, and not one word on screen. The file paths never had
/// this shape (they `try`/`catch` and print `发送失败：…`), which is what made the
/// asymmetry visible.
///
/// These cases pin the three halves of the fix: the text survives a failure, the
/// failure is **said**, and a successful send still clears the field (the reason
/// the clear was there in the first place).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/domain/draft_store.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';

// `FakeBackend` / `FakeSessionRepository` come from the barrel (it re-exports
// `data/fake/**` — spec §6), which is why they are not imported one by one.
import '../support/fakes.dart';
import '../support/pump_app.dart';

const String _conversationId = 'c-text-fail';
// Deliberately **not** containing 「发送失败」: the failure assertion below looks
// for that phrase, and `find.textContaining` also matches the `EditableText` —
// a fixture that spells it would match itself and hide the real message.
const String _text = '这段话不能因为发不出去就消失';

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'FF07',
      alias: '小甲',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// A repository whose `recordOutgoingText` throws — the one call that can make
/// `ConversationController.sendText` throw **before** any row exists.
///
/// That is the shape of the real failure too: the store write is the first thing
/// the dispatch does, so a database that cannot write means "no message, and (as
/// shipped) no text either".
class _ThrowingRepo extends FakeSessionRepository {
  _ThrowingRepo({required super.clock, required super.ids});

  /// How many times the write was attempted.
  int attempts = 0;

  @override
  SendHandle recordOutgoingText({
    required PeerDevice peer,
    required String text,
    required String nonce,
  }) {
    attempts += 1;
    throw StateError('写入会话记录失败');
  }
}

void main() {
  late FakeBackend backend;
  late _ThrowingRepo repo;
  late ConversationController controller;
  late ComposerDraftStore drafts;

  setUp(() {
    backend = FakeBackend();
    repo = _ThrowingRepo(clock: backend.clock, ids: backend.ids);
    drafts = ComposerDraftStore();
    controller = ConversationController(
      repo: repo,
      orchestrator: TransferOrchestrator(
        repo: repo,
        transfer: backend.transfer,
      ),
      platform: backend.platform,
      ids: backend.ids,
      clock: backend.clock,
      conversationId: _conversationId,
      drafts: drafts,
    );
  });

  tearDown(() {
    controller.dispose();
    backend.dispose();
  });

  Future<void> mount(WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1200, 900));
    // Loaded **before** the mount: an un-loaded controller sits at `Loading`, and
    // the thread's loading state spins forever (which `pumpAndSettle` refuses to
    // settle on).
    unawaited(controller.load());
    await pumpApp(
      tester,
      Scaffold(body: ConversationThread(controller: controller, peer: _peer())),
      backend: backend,
      settle: true,
    );
  }

  testWidgets(
      '★ 0.2.48 criterion 6: the dispatch throws — the composer still holds the '
      'text, the draft survives, and the failure is on screen',
      (WidgetTester tester) async {
    await mount(tester);

    await tester.enterText(find.byType(TextField), _text);
    await tester.pumpAndSettle();
    expect(controller.draftText, _text, reason: 'typed text is a draft');

    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(repo.attempts, 1, reason: 'the send really was attempted');
    // 1. The text is still there — in the field…
    expect(find.text(_text), findsOneWidget,
        reason: 'the field must keep what the user typed');
    // 2. …and still in the per-conversation draft, so switching away and back
    //    does not lose it either (this half lives in the controller).
    expect(controller.draftText, _text);
    // 3. And the app says what happened. Silence was the whole complaint.
    expect(find.textContaining('发送失败'), findsOneWidget);

    // Nothing was recorded, so there is no bubble pretending otherwise.
    expect(repo.history(_conversationId), isEmpty);
  });

  testWidgets(
      '★ 0.2.48 control: a send that works still empties the composer and the '
      'draft — the clear is moved, not removed',
      (WidgetTester tester) async {
    // A repository that behaves: the ordinary path must be unchanged.
    final FakeSessionRepository ok = FakeSessionRepository(
      clock: backend.clock,
      ids: backend.ids,
    );
    final ConversationController live = ConversationController(
      repo: ok,
      orchestrator: TransferOrchestrator(
        repo: ok,
        transfer: backend.transfer,
      ),
      platform: backend.platform,
      ids: backend.ids,
      clock: backend.clock,
      conversationId: _conversationId,
      drafts: drafts,
    );
    addTearDown(live.dispose);

    useSurfaceSize(tester, const Size(1200, 900));
    unawaited(live.load());
    await pumpApp(
      tester,
      Scaffold(body: ConversationThread(controller: live, peer: _peer())),
      backend: backend,
      settle: true,
    );

    await tester.enterText(find.byType(TextField), _text);
    await tester.pumpAndSettle();
    expect(live.draftText, _text);

    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(find.text(_text), findsNothing,
        reason: 'the composer is emptied once the message really left');
    expect(live.draftText, isEmpty, reason: 'and the draft goes with it');
    expect(find.textContaining('发送失败'), findsNothing);
    // The message is on the timeline: the clear happens only after a dispatch
    // that produced a row. `recordOutgoingText` opens the conversation itself, so
    // the row lives under the id the repository assigned, not the one we passed.
    final List<Conversation> conversations = ok.conversations();
    expect(conversations, hasLength(1));
    expect(ok.history(conversations.single.id), hasLength(1));
  });
}
