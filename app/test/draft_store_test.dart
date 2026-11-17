/// Unit tests for the per-conversation composer draft store (0.2.27).
///
/// The store is the answer to *"我输入了一些东西但是没点发送，换到下一个会话再回来，
/// 输入的东西就没了"*. It is plain Dart — no widget tree, no clock, no disk — so
/// these tests are about the **contract** the UI code relies on:
/// 1. a saved draft is read back verbatim, per conversation id;
/// 2. blank / whitespace-only text is **not** a draft (an emptied composer must
///    come back empty, and the entry must not linger);
/// 3. `clear` really forgets, so a sent message leaves nothing behind.
///
/// The controller-level test at the bottom is the one that pins the production
/// wiring: two `ConversationController`s (i.e. two selections of the same
/// conversation) built **without** passing a store still share one.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/draft_store.dart';

void main() {
  group('ComposerDraftStore', () {
    test('a saved draft is read back exactly, and only for its conversation',
        () {
      final ComposerDraftStore store = ComposerDraftStore();

      store.save(conversationId: 'A', text: '你好');
      store.save(conversationId: 'B', text: 'hello');

      expect(store.draftFor('A'), '你好');
      expect(store.draftFor('B'), 'hello');
      // A conversation nobody typed into has **no** draft, not a stale one.
      expect(store.draftFor('C'), '');
      expect(store.hasDraft('C'), isFalse);
      expect(store.length, 2);
    });

    test('the raw text is kept (no trimming on the way in)', () {
      final ComposerDraftStore store = ComposerDraftStore();

      store.save(conversationId: 'A', text: '  你好  ');

      expect(store.draftFor('A'), '  你好  ',
          reason: 'a restored draft must be what the user actually typed');
    });

    test('an empty string removes the entry instead of storing a blank', () {
      final ComposerDraftStore store = ComposerDraftStore();
      store.save(conversationId: 'A', text: '你好');

      store.save(conversationId: 'A', text: '');

      expect(store.hasDraft('A'), isFalse);
      expect(store.draftFor('A'), '');
      expect(store.length, 0,
          reason: 'no entry may be left behind for an emptied composer');
    });

    test('a whitespace-only draft is not a draft (spaces are not text)', () {
      final ComposerDraftStore store = ComposerDraftStore();

      store.save(conversationId: 'A', text: '   ');
      store.save(conversationId: 'B', text: '\n\t ');

      expect(store.hasDraft('A'), isFalse);
      expect(store.hasDraft('B'), isFalse);
      expect(store.length, 0);
      expect(store.conversationIds, isEmpty);
    });

    test('typing spaces and then deleting them leaves nothing (criterion 3)',
        () {
      final ComposerDraftStore store = ComposerDraftStore();

      // What the listener sees, keystroke by keystroke.
      for (final String step in <String>[' ', '  ', '   ', '  ', ' ', '']) {
        store.save(conversationId: 'A', text: step);
      }

      expect(store.length, 0);
      expect(store.draftFor('A'), '');
    });

    test('clear forgets a draft and reports whether there was one', () {
      final ComposerDraftStore store = ComposerDraftStore();
      store.save(conversationId: 'A', text: '你好');

      expect(store.clear('A'), isTrue);
      expect(store.clear('A'), isFalse);
      expect(store.draftFor('A'), '');
    });

    test('clearAll empties the store', () {
      final ComposerDraftStore store = ComposerDraftStore()
        ..save(conversationId: 'A', text: 'a')
        ..save(conversationId: 'B', text: 'b');

      store.clearAll();

      expect(store.length, 0);
    });
  });

  group('ConversationController ↔ store', () {
    test('a new controller for the same conversation sees the draft '
        '(no store passed ⇒ the shared one, which is the production wiring)',
        () {
      // The shared instance outlives every controller, so a test that touches it
      // must leave it as it found it.
      addTearDown(ComposerDraftStore.shared.clearAll);
      ComposerDraftStore.shared.clearAll();

      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);
      backend.repo.addConversation(
        id: 'c-draft',
        deviceFingerprint: 'DD01',
        createdAt: fixedEpoch,
        lastMessageAt: fixedEpoch,
      );

      ConversationController build() => ConversationController(
            repo: backend.repo,
            orchestrator: TransferOrchestrator(
              repo: backend.repo,
              transfer: backend.transfer,
            ),
            platform: backend.platform,
            ids: backend.ids,
            clock: backend.clock,
            conversationId: 'c-draft',
          );

      final ConversationController first = build();
      expect(first.draftText, isEmpty);

      first.updateDraft('你好');
      // Disposed explicitly (not by a tear-down): this is the whole point of the
      // test — the draft has to outlive the controller that recorded it.
      first.dispose();

      // A *different* controller object — exactly what `DetailPane` builds when
      // the user comes back to this conversation.
      final ConversationController second = build();
      addTearDown(second.dispose);
      expect(second.draftText, '你好');
      expect(second.hasDraft, isTrue);
    });

    test('updateDraft never notifies (a keystroke must not repaint the thread)',
        () {
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);
      backend.repo.addConversation(
        id: 'c-quiet',
        deviceFingerprint: 'DD02',
        createdAt: fixedEpoch,
        lastMessageAt: fixedEpoch,
      );
      final ComposerDraftStore store = ComposerDraftStore();
      final ConversationController controller = ConversationController(
        repo: backend.repo,
        orchestrator: TransferOrchestrator(
          repo: backend.repo,
          transfer: backend.transfer,
        ),
        platform: backend.platform,
        ids: backend.ids,
        clock: backend.clock,
        conversationId: 'c-quiet',
        drafts: store,
      );
      addTearDown(controller.dispose);
      int notifications = 0;
      controller.addListener(() => notifications++);

      controller.updateDraft('h');
      controller.updateDraft('he');
      controller.updateDraft('hey');

      expect(notifications, 0,
          reason: 'the store is data, not a UI event — one notify per keystroke '
              'would rebuild the whole timeline to redraw one TextField');
      expect(store.draftFor('c-quiet'), 'hey');
    });

    test('discardDraft forgets this conversation and touches no other', () {
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);
      for (final String id in <String>['c-1', 'c-2']) {
        backend.repo.addConversation(
          id: id,
          deviceFingerprint: 'DD0$id',
          createdAt: fixedEpoch,
          lastMessageAt: fixedEpoch,
        );
      }
      final ComposerDraftStore store = ComposerDraftStore();
      ConversationController build(String id) => ConversationController(
            repo: backend.repo,
            orchestrator: TransferOrchestrator(
              repo: backend.repo,
              transfer: backend.transfer,
            ),
            platform: backend.platform,
            ids: backend.ids,
            clock: backend.clock,
            conversationId: id,
            drafts: store,
          );
      final ConversationController one = build('c-1');
      final ConversationController two = build('c-2');
      addTearDown(one.dispose);
      addTearDown(two.dispose);
      one.updateDraft('one');
      two.updateDraft('two');

      one.discardDraft();

      expect(one.draftText, isEmpty);
      expect(two.draftText, 'two');
    });
  });
}
