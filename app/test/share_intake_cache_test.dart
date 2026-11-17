/// The 待发送 half of the temporary-copy cleanup (0.2.23).
///
/// Two different gestures on the same row mean two different things, and only one
/// of them may delete the bytes:
///
/// * **取消** — the user says "I am not sending these". Nobody will ever need the
///   copies, so they go. Before 0.2.23 `discardDraft` cleared the fields and left
///   a full copy of every shared file in `cache/lanlink-picked/` forever.
/// * **发送** (`consumeDraft`) — the row is cleared, but whether the copies may be
///   freed depends on what the send actually did. That answer lives in
///   `ConversationController` (`SendOutcome.delivered`); deleting here would break
///   重新发送 for a send that failed or was queued.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/picked_cache.dart';
import 'package:lanlink_app/domain/share_inbox.dart';
import 'package:lanlink_app/ui/shell/share_intake.dart';
import 'package:lanlink_app/ui/shell/shell_controller.dart';

import 'support/fakes.dart';

/// A share inbox that hands over exactly one payload.
class _OneShotInbox implements ShareInboxPort {
  _OneShotInbox(this.map);

  final Map<String, String> map;
  final StreamController<SharedPayload> _incoming =
      StreamController<SharedPayload>.broadcast();
  bool _taken = false;

  @override
  bool get isSupported => true;

  @override
  Stream<SharedPayload> get incoming => _incoming.stream;

  @override
  Future<SharedPayload?> takeInitial() async {
    if (_taken) {
      return null;
    }
    _taken = true;
    return const SharedPayload(uris: <String>['content://media/1']);
  }

  @override
  Future<ShareImport> materialize(SharedPayload payload) async => ShareImport(
        paths: map.values.toList(),
        failures: const <ShareImportFailure>[],
      );

  void dispose() => _incoming.close();
}

/// Records what was asked of the cleaner.
class _RecordingCache implements PickedCachePort {
  final List<List<String>> discarded = <List<String>>[];

  @override
  Future<void> discard(Iterable<String> paths) async =>
      discarded.add(paths.toList());

  @override
  Future<void> clear({Set<String> keep = const <String>{}}) async {}
}

const String _copyPath =
    '/data/user/0/io.github.kk339.lanlink/cache/lanlink-picked/1a2b/clip.mp4';

void main() {
  late FakeBackend backend;
  late _OneShotInbox inbox;
  late _RecordingCache cache;
  late ShellController shell;
  late ShareIntake intake;

  setUp(() async {
    backend = FakeBackend();
    cache = _RecordingCache();
    inbox = _OneShotInbox(<String, String>{'content://media/1': _copyPath});
    final Conversation conversation = backend.repo.addConversation(
      id: 'c-share',
      createdAt: fixedEpoch,
    );
    shell = ShellController(
      repo: backend.repo,
      initialPeer: PeerDevice(
        fingerprint: '',
        alias: 'unused',
        kind: DeviceKind.unknown,
        conversationId: conversation.id,
      ),
    );
    intake = ShareIntake(
      inbox: inbox,
      shell: shell,
      pickedCache: cache,
    );
    await intake.start();
    // The import runs on a microtask (the stream listener), so let it settle.
    await pumpEventQueue();
  });

  tearDown(() {
    intake.dispose();
    shell.dispose();
    inbox.dispose();
    backend.dispose();
  });

  test('the share really produced a draft holding our temp copy', () {
    expect(intake.draft, isNotNull);
    expect(intake.draft!.paths, <String>[_copyPath]);
  });

  // ── 0.2.62 — 「先问发给谁」 ────────────────────────────────────────────────

  test('★ a share lands UNBOUND even though a conversation is selected (0.2.62)',
      () {
    // The setup selects a conversation (it is what `initialPeer` does), which is
    // exactly the situation 0.2.61 turned into "put it in that thread".
    expect(shell.selectedConversationId, isNotNull,
        reason: 'precondition: something IS open when the share arrives');

    expect(intake.draft!.conversationId, isNull,
        reason: '★ 不再默默落进当前会话 —— 目的地是用户的选择，不是推断');
    expect(intake.needsTarget, isTrue,
        reason: 'the shell can see, as state, that a question is outstanding');
  });

  test('★ the "ask the user" request fires once, not on every notification',
      () async {
    expect(intake.takeTargetRequest(), isTrue,
        reason: 'the shell is told to show the chooser');

    intake.attachTo(shell.selectedConversationId!);
    expect(intake.takeTargetRequest(), isFalse,
        reason: '★ answering it consumes the request — a rebuild must not stack '
            'a second sheet');
    expect(intake.needsTarget, isFalse);
    expect(intake.draft!.conversationId, shell.selectedConversationId);
  });

  test('★ 放弃「选择器」不是放弃文件：草稿和副本都还在', () {
    // What the shell does when the user cancels: nothing at all. This case pins
    // the consequence — no draft cleared, no copy freed, still asking.
    expect(intake.needsTarget, isTrue);
    expect(cache.discarded, isEmpty,
        reason: '★ nothing may be deleted before the user says "不要了"');
    expect(intake.draft!.paths, <String>[_copyPath],
        reason: 'the copy is still there for the user to send later');
  });

  test('a bound draft is not re-pointed by a later selection (bind once)', () {
    final String first = shell.selectedConversationId!;
    intake.attachTo(first);
    intake.attachTo('some-other-conversation');

    expect(intake.draft!.conversationId, first,
        reason: 'files staged for one device must never be moved to another');
  });

  test('取消 frees the temp copy behind the draft', () {
    intake.discardDraft();

    expect(intake.draft, isNull);
    expect(cache.discarded.single, <String>[_copyPath]);
  });

  test('发送 (consumeDraft) clears the row but frees nothing on its own', () {
    intake.consumeDraft();

    expect(intake.draft, isNull);
    expect(cache.discarded, isEmpty,
        reason: 'the controller decides, on the real SendOutcome — a failed or '
            'queued send still needs these files for 重新发送');
  });
}
