/// Widget tests for the composer draft (0.2.27) — *"我输入了一些东西但是没点发送，
/// 换到下一个会话再回来，输入的东西就没了"*.
///
/// The four criteria this file pins down, each one falsifiable:
/// 1. A「你好」→ switch to B (field empty) → back to A ⇒ the field still says
///    「你好」;
/// 2. A「你好」→ **sent** → away and back ⇒ the field is empty (the draft was
///    dropped when the text became a message);
/// 3. whitespace is not a draft: spaces typed and deleted leave **no entry** in
///    the store;
/// 4. the text also survives the whole detail pane being **unmounted** (the
///    narrow-window "back to the list, then in again" path) — which is why the
///    store is process-wide rather than per controller.
///
/// `_DetailPaneStub` is a faithful stand-in for `DetailPane`'s conversation
/// wiring: **a fresh `ConversationController` per selection**, `load()`ed on
/// arrival, and the thread **re-keyed** per conversation id — the exact two
/// things that used to destroy the text.
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

import '../support/pump_app.dart';

PeerDevice _peer({bool online = true}) => PeerDevice(
      fingerprint: 'DD01',
      alias: 'Eve',
      kind: DeviceKind.desktop,
      isOnline: online,
      lastPort: 53317,
    );

void main() {
  late FakeBackend backend;

  setUp(() {
    backend = FakeBackend();
    for (final String id in <String>['c-a', 'c-b']) {
      backend.repo.addConversation(
        id: id,
        deviceFingerprint: 'DD01',
        createdAt: fixedEpoch,
        lastMessageAt: fixedEpoch,
      );
    }
  });

  tearDown(() => backend.dispose());

  /// Mounts the stub for [conversationId].
  ///
  /// Re-pumping the **same** tree shape keeps the stub's `State` alive, which is
  /// what makes a conversation switch a `didUpdateWidget` rather than a full
  /// remount — the same thing the shell does.
  Future<void> show(
    WidgetTester tester,
    String conversationId, {
    required ComposerDraftStore drafts,
  }) async {
    await tester.pumpWidget(
      appWithScope(
        deps: testDeps(backend),
        child: Scaffold(
          body: _DetailPaneStub(
            backend: backend,
            drafts: drafts,
            conversationId: conversationId,
            peer: _peer(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String composerText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('1: text typed in A is still there after visiting B and coming '
      'back', (WidgetTester tester) async {
    final ComposerDraftStore drafts = ComposerDraftStore();

    await show(tester, 'c-a', drafts: drafts);
    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    expect(drafts.draftFor('c-a'), '你好', reason: 'typing must reach the store');

    // A → B: a different conversation, therefore a **different** composer.
    await show(tester, 'c-b', drafts: drafts);
    expect(composerText(tester), isEmpty,
        reason: 'B has no draft, so its composer must be empty');

    // B → A: the reported defect. Before 0.2.27 this read `''`.
    await show(tester, 'c-a', drafts: drafts);
    expect(composerText(tester), '你好');
    expect(find.text('你好'), findsOneWidget);
  });

  testWidgets('1b: two conversations keep their own text (no cross-talk)',
      (WidgetTester tester) async {
    final ComposerDraftStore drafts = ComposerDraftStore();

    await show(tester, 'c-a', drafts: drafts);
    await tester.enterText(find.byType(TextField), 'A 的草稿');
    await tester.pump();

    await show(tester, 'c-b', drafts: drafts);
    await tester.enterText(find.byType(TextField), 'B 的草稿');
    await tester.pump();

    await show(tester, 'c-a', drafts: drafts);
    expect(composerText(tester), 'A 的草稿');

    await show(tester, 'c-b', drafts: drafts);
    expect(composerText(tester), 'B 的草稿');
  });

  testWidgets('2: a sent message drops the draft for good (criterion 2)',
      (WidgetTester tester) async {
    final ComposerDraftStore drafts = ComposerDraftStore();

    await show(tester, 'c-a', drafts: drafts);
    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    expect(drafts.draftFor('c-a'), '你好');

    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    // The text is now a bubble, and the composer is free for the next message.
    expect(backend.transfer.sentTexts.single.text, '你好');
    expect(composerText(tester), isEmpty);
    expect(drafts.hasDraft('c-a'), isFalse,
        reason: 'the draft must be gone the moment the text became a message');

    // Away and back: nothing may be resurrected into the composer.
    await show(tester, 'c-b', drafts: drafts);
    await show(tester, 'c-a', drafts: drafts);
    expect(composerText(tester), isEmpty);
  });

  testWidgets('3: whitespace is not a draft (criterion 3)',
      (WidgetTester tester) async {
    final ComposerDraftStore drafts = ComposerDraftStore();

    await show(tester, 'c-a', drafts: drafts);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(drafts.hasDraft('c-a'), isFalse,
        reason: 'three spaces must never be stored as a draft');

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(drafts.length, 0,
        reason: 'no entry may be left behind for a blank composer');

    await show(tester, 'c-b', drafts: drafts);
    await show(tester, 'c-a', drafts: drafts);
    expect(composerText(tester), isEmpty);
    expect(drafts.length, 0);
  });

  testWidgets('4: the draft survives the detail pane being unmounted '
      '(back to the list, then in again)', (WidgetTester tester) async {
    final ComposerDraftStore drafts = ComposerDraftStore();

    await show(tester, 'c-a', drafts: drafts);
    await tester.enterText(find.byType(TextField), '别丢了');
    await tester.pump();

    // The narrow-window path: the whole pane goes away (its controller is
    // disposed with it) and only the process-lived store remains.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    await show(tester, 'c-a', drafts: drafts);
    expect(composerText(tester), '别丢了');
  });

  testWidgets('the restored draft re-enables the send button on the first frame',
      (WidgetTester tester) async {
    final ComposerDraftStore drafts = ComposerDraftStore()
      ..save(conversationId: 'c-a', text: '待发送');

    await show(tester, 'c-a', drafts: drafts);

    final IconButton send = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.send),
        matching: find.byType(IconButton),
      ),
    );
    expect(send.onPressed, isNotNull,
        reason: 'a restored draft is sendable text — the button must not stay '
            'greyed out until the user types another character');
  });
}

/// Stands in for `DetailPane`'s conversation module: **one controller per
/// selection**, `load()`ed on arrival, and the thread keyed per conversation id.
///
/// Reproducing those two behaviours is the point — they are exactly what made
/// the composer text disappear, so a test that kept one controller alive
/// throughout would pass without the feature.
class _DetailPaneStub extends StatefulWidget {
  const _DetailPaneStub({
    required this.backend,
    required this.drafts,
    required this.conversationId,
    required this.peer,
  });

  final FakeBackend backend;
  final ComposerDraftStore drafts;
  final String conversationId;
  final PeerDevice peer;

  @override
  State<_DetailPaneStub> createState() => _DetailPaneStubState();
}

class _DetailPaneStubState extends State<_DetailPaneStub> {
  ConversationController? _conversation;
  String? _boundId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reconcile();
  }

  @override
  void didUpdateWidget(_DetailPaneStub oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reconcile();
  }

  @override
  void dispose() {
    _conversation?.dispose();
    super.dispose();
  }

  void _reconcile() {
    if (widget.conversationId == _boundId) {
      return;
    }
    _conversation?.dispose();
    _conversation = null;
    _boundId = widget.conversationId;
    final ConversationController conversation = ConversationController(
      repo: widget.backend.repo,
      orchestrator: TransferOrchestrator(
        repo: widget.backend.repo,
        transfer: widget.backend.transfer,
      ),
      platform: widget.backend.platform,
      ids: widget.backend.ids,
      clock: widget.backend.clock,
      conversationId: widget.conversationId,
      drafts: widget.drafts,
    );
    _conversation = conversation;
    unawaited(conversation.load());
  }

  @override
  Widget build(BuildContext context) {
    final ConversationController? conversation = _conversation;
    if (conversation == null) {
      return const SizedBox.shrink();
    }
    return ConversationThread(
      key: ValueKey<String>('messages-${widget.conversationId}'),
      controller: conversation,
      peer: widget.peer,
    );
  }
}
