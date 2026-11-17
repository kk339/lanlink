/// 0.2.33 — the 未发送成功 ✕ (and a successful 全部重试) must survive a **restart**.
///
/// The report: *"虽然会话退出再进来没有了，但是我退出软件重新进还是有的"*.
/// 0.2.30 fixed the conversation switch by making the store process-wide and
/// declared "restart brings the banner back" acceptable. That judgement was
/// wrong — the messages are still in the history, so "这一批我处理过了" has no
/// reason to expire with the process. The store now persists through two injected
/// functions ([DismissalReader] / [DismissalWriter]); this file owns the
/// persistence contract, with a fake "disk" that is just a `String`.
///
/// What is pinned here:
/// 1. a dismissal / a handled id round-trips through the document;
/// 2. **a broken document never breaks the app** — unreadable JSON, an unknown
///    version, or a throwing reader all mean "start empty", and the bad file is
///    **not** overwritten;
/// 3. a failed write is logged and swallowed (the session keeps working);
/// 4. the cap drops the **oldest** ids first, across conversations;
/// 5. housekeeping: ids whose message is no longer failing are pruned, and the
///    conversation's entry disappears with the last of them.
///
/// The visible half (banner really stays hidden after a "restart") lives in
/// `test/widget/retry_all_restart_test.dart`.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/unsent_dismissal_store.dart';

const String _fingerprint = 'UD33';

/// A fake persistence layer: one string, the way the app has one file.
class _Disk {
  String? content;

  /// What `read()` answers **instead of** [content] — models a read that was
  /// already in flight (i.e. a snapshot taken before a later write landed).
  String? readOverride;

  /// How many times a write reached the "disk".
  int writes = 0;

  /// Makes the next reads/writes fail (simulated IO error).
  bool failReads = false;
  bool failWrites = false;

  /// Every write, in order — so a test can assert "the corrupt file was left
  /// alone" as well as "the good one was replaced".
  final List<String> history = <String>[];

  Future<String?> read() async {
    if (failReads) {
      throw StateError('读失败（模拟 IO 错误）');
    }
    return readOverride ?? content;
  }

  Future<void> write(String data) async {
    if (failWrites) {
      throw StateError('写失败（模拟 IO 错误）');
    }
    writes++;
    content = data;
    history.add(data);
  }

  /// A store reading and writing this "disk" — one app run.
  UnsentDismissalStore open({
    int maxEntries = kMaxSuppressedIds,
    List<String>? logSink,
  }) =>
      UnsentDismissalStore(
        read: read,
        write: write,
        log: logSink?.add,
        maxEntries: maxEntries,
      );
}

/// Seeds one outgoing **failed file** message (the only kind the banner counts).
void _seed(
  FakeBackend backend, {
  required String conversationId,
  required String messageId,
  MessageStatus status = MessageStatus.failed,
}) {
  backend.repo.addMessage(
    id: messageId,
    conversationId: conversationId,
    direction: MessageDirection.outgoing,
    status: status,
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
    files: <FileAttachment>[
      FileAttachment(
        id: 'f-$messageId',
        messageId: messageId,
        fileName: 'one.bin',
        size: 5,
        sha256: '00',
        localPath: '/src/$messageId.bin',
      ),
    ],
  );
}

void main() {
  group('持久化：写入与读回', () {
    test('a dismissal survives "restart" — a NEW store reading the same file',
        () async {
      final _Disk disk = _Disk();

      final UnsentDismissalStore firstRun = disk.open();
      firstRun.dismiss(
        conversationId: 'c-a',
        messageIds: <String>['m-1', 'm-2'],
      );
      await firstRun.flush();
      expect(disk.writes, 1, reason: '一次忽略 = 一次写盘（不是每次 setState 都写）');
      expect(disk.content, isNotNull);

      // ── restart: brand-new object graph, same file.
      final UnsentDismissalStore secondRun = disk.open();
      expect(secondRun.isDismissed(conversationId: 'c-a', messageId: 'm-1'),
          isFalse,
          reason: 'a fresh store starts empty — nothing is loaded until load()');
      await secondRun.load();

      expect(
        secondRun.isDismissed(conversationId: 'c-a', messageId: 'm-1'),
        isTrue,
        reason: '★ 这次要修的就是它：点过忽略，重启后仍然是忽略',
      );
      expect(secondRun.isDismissed(conversationId: 'c-a', messageId: 'm-2'),
          isTrue);
      expect(secondRun.countFor('c-a'), 2);
    });

    test('ids a 全部重试 already re-sent survive too (same document)', () async {
      final _Disk disk = _Disk();

      final UnsentDismissalStore firstRun = disk.open();
      firstRun.markHandled(conversationId: 'c-a', messageIds: <String>['m-9']);
      await firstRun.flush();

      final UnsentDismissalStore afterRestart = disk.open();
      await afterRestart.load();

      expect(afterRestart.isHandled(conversationId: 'c-a', messageId: 'm-9'),
          isTrue);
      expect(
        afterRestart.suppresses(conversationId: 'c-a', messageId: 'm-9'),
        isTrue,
        reason: 'a handled row is not counted either — the banner must not '
            'reappear after a restart just because the run succeeded',
      );
      expect(
        afterRestart.dismissedFor('c-a'),
        isEmpty,
        reason: 'the two provenances stay distinguishable in the document',
      );
    });

    test('the document is human-readable and records both kinds', () async {
      final _Disk disk = _Disk();
      final UnsentDismissalStore store = disk.open();

      store.dismiss(conversationId: 'c-a', messageIds: <String>['m-1']);
      store.markHandled(conversationId: 'c-b', messageIds: <String>['m-2']);
      await store.flush();

      expect(
        disk.content,
        '{"version":1,'
        '"dismissed":[{"conversationId":"c-a","messageId":"m-1"}],'
        '"handled":[{"conversationId":"c-b","messageId":"m-2"}]}',
        reason: 'the user may well send us this file — a flat, ordered array of '
            'pairs is the most readable shape that still keeps insertion order',
      );
    });

    test('load() merges rather than clobbers (a dismissal that landed while the '
        'read was in flight)', () async {
      // The document on disk holds m-1; since then (and before the read resolved)
      // the user dismissed m-2. Neither may be lost.
      final _Disk disk = _Disk()
        ..content = '{"version":1,"dismissed":'
            '[{"conversationId":"c-a","messageId":"m-1"}],"handled":[]}'
        ..readOverride = '{"version":1,"dismissed":'
            '[{"conversationId":"c-a","messageId":"m-1"}],"handled":[]}';
      final UnsentDismissalStore store = disk.open();

      store.dismiss(conversationId: 'c-a', messageIds: <String>['m-2']);
      await store.load();

      expect(store.dismissedFor('c-a'), <String>{'m-2', 'm-1'});
    });
  });

  group('持久化：坏文件不阻断启动', () {
    test('garbage / illegal JSON → empty store, no throw, file NOT overwritten',
        () async {
      final List<String> log = <String>[];
      final _Disk disk = _Disk()..content = '这不是 JSON {{{';
      final UnsentDismissalStore store = disk.open(logSink: log);

      await store.load(); // must not throw

      expect(store.entryCount, 0);
      expect(store.length, 0);
      expect(disk.writes, 0,
          reason: 'the unreadable file is left where it is — overwriting it with '
              'an empty document would destroy whatever the user might still have');
      expect(log, isNotEmpty, reason: 'silent data loss is not an option');
    });

    test('a JSON array (wrong top-level type) is treated as corrupt', () async {
      final _Disk disk = _Disk()..content = '[{"conversationId":"c-a"}]';
      final UnsentDismissalStore store = disk.open();

      await store.load();

      expect(store.entryCount, 0);
    });

    test('an unknown (future) version is treated as corrupt, not guessed',
        () async {
      final List<String> log = <String>[];
      final _Disk disk = _Disk()
        ..content = '{"version":99,"dismissed":['
            '{"conversationId":"c-a","messageId":"m-1"}]}';
      final UnsentDismissalStore store = disk.open(logSink: log);

      await store.load();

      expect(store.isDismissed(conversationId: 'c-a', messageId: 'm-1'),
          isFalse);
      expect(log, isNotEmpty);
    });

    test('one malformed entry does not cost the rest of the document', () async {
      final _Disk disk = _Disk()
        ..content = '{"version":1,"dismissed":['
            '{"conversationId":"c-a"},'
            '{"conversationId":"c-a","messageId":"m-1"},'
            '{"conversationId":"","messageId":"m-2"}'
            '],"handled":[]}';
      final UnsentDismissalStore store = disk.open();

      await store.load();

      expect(store.dismissedFor('c-a'), <String>{'m-1'});
    });

    test('a throwing reader → empty store, no throw, one log line', () async {
      final List<String> log = <String>[];
      final _Disk disk = _Disk()..failReads = true;
      final UnsentDismissalStore store = disk.open(logSink: log);

      await store.load();

      expect(store.entryCount, 0);
      expect(log, hasLength(1));
    });

    test('a throwing writer is logged and swallowed (the session keeps working)',
        () async {
      final List<String> log = <String>[];
      final _Disk disk = _Disk()..failWrites = true;
      final UnsentDismissalStore store = disk.open(logSink: log);

      // Must not throw — the tap has to repaint a banner-free thread even when
      // the disk is full.
      store.dismiss(conversationId: 'c-a', messageIds: <String>['m-1']);
      await store.flush();

      expect(store.isDismissed(conversationId: 'c-a', messageId: 'm-1'), isTrue,
          reason: 'the in-memory state is still correct for this session');
      expect(log, hasLength(1));
    });

    test('no writer configured (Web build, existing tests) → no writes at all',
        () async {
      final UnsentDismissalStore store = UnsentDismissalStore();

      store.dismiss(conversationId: 'c-a', messageIds: <String>['m-1']);
      await store.flush();

      expect(store.isDismissed(conversationId: 'c-a', messageId: 'm-1'), isTrue);
      expect(store.entryCount, 1);
    });
  });

  group('持久化：上限与清理', () {
    test('over the cap the OLDEST ids are dropped first, across conversations',
        () async {
      final _Disk disk = _Disk();
      final UnsentDismissalStore store = disk.open(maxEntries: 3);

      store.dismiss(conversationId: 'c-a', messageIds: <String>['m-1']);
      store.dismiss(conversationId: 'c-b', messageIds: <String>['m-2']);
      store.dismiss(conversationId: 'c-a', messageIds: <String>['m-3']);
      store.dismiss(conversationId: 'c-c', messageIds: <String>['m-4']);

      await store.flush();
      expect(store.entryCount, 3);
      expect(store.isDismissed(conversationId: 'c-a', messageId: 'm-1'), isFalse,
          reason: 'the oldest one goes first');
      expect(store.isDismissed(conversationId: 'c-b', messageId: 'm-2'), isTrue);
      expect(store.isDismissed(conversationId: 'c-a', messageId: 'm-3'), isTrue);
      expect(store.isDismissed(conversationId: 'c-c', messageId: 'm-4'), isTrue);

      // The eviction is durable: the reloaded store sees the same three.
      final UnsentDismissalStore afterRestart = disk.open(maxEntries: 3);
      await afterRestart.load();
      expect(afterRestart.entryCount, 3);
      expect(
        afterRestart.isDismissed(conversationId: 'c-a', messageId: 'm-1'),
        isFalse,
      );
    });

    test('a conversation whose ids were all evicted leaves no empty entry',
        () async {
      final _Disk disk = _Disk();
      final UnsentDismissalStore store = disk.open(maxEntries: 2);

      store.dismiss(conversationId: 'c-a', messageIds: <String>['m-1']);
      store.dismiss(conversationId: 'c-b', messageIds: <String>['m-2']);
      store.dismiss(conversationId: 'c-b', messageIds: <String>['m-3']);
      await store.flush();

      expect(store.conversationIds, <String>['c-b']);
    });

    test('pruneConversation drops ids whose message is no longer failing, and '
        'removes the entry when the last one goes', () async {
      final _Disk disk = _Disk();
      final UnsentDismissalStore store = disk.open();

      store.dismiss(conversationId: 'c-a', messageIds: <String>['m-1', 'm-2']);
      store.markHandled(conversationId: 'c-a', messageIds: <String>['m-3']);
      await store.flush();

      // m-2 is no longer failed (it was deleted / resolved); m-1 and m-3 still are.
      await store.pruneConversation('c-a', relevant: <String>{'m-1', 'm-3'});
      expect(store.dismissedFor('c-a'), <String>{'m-1'});
      expect(store.handledFor('c-a'), <String>{'m-3'});

      // Now nothing is outstanding any more → the conversation's entry is gone.
      await store.pruneConversation('c-a', relevant: const <String>{});
      expect(store.countFor('c-a'), 0);
      expect(store.conversationIds, isEmpty);

      final UnsentDismissalStore afterRestart = disk.open();
      await afterRestart.load();
      expect(afterRestart.length, 0, reason: 'the pruned state is persisted');
    });

    test('pruneConversation keeps a suppression whose message is STILL failing '
        '(never resurrect the banner)', () async {
      final _Disk disk = _Disk();
      final UnsentDismissalStore store = disk.open();
      store.dismiss(conversationId: 'c-a', messageIds: <String>['m-1']);
      await store.flush();

      await store.pruneConversation('c-a', relevant: <String>{'m-1'});

      expect(
        store.isDismissed(conversationId: 'c-a', messageId: 'm-1'),
        isTrue,
        reason: 'forgetting a suppression while its 失败 bubble is still on '
            'screen is exactly the bug this store exists to fix',
      );
    });
  });

  group('重启（控制器层）', () {
    late FakeBackend backend;
    late _Disk disk;

    setUp(() {
      backend = FakeBackend();
      disk = _Disk();
      for (final String id in <String>['c-a', 'c-b']) {
        backend.repo.addConversation(
          id: id,
          deviceFingerprint: _fingerprint,
          createdAt: fixedEpoch,
          lastMessageAt: fixedEpoch,
        );
      }
    });

    tearDown(() => backend.dispose());

    /// One **app run**: a fresh store over the same file, loaded, then a
    /// controller over it. Returns both so a test can `await store.flush()`
    /// before pretending to quit.
    Future<(ConversationController, UnsentDismissalStore)> launch(
      String conversationId,
    ) async {
      final UnsentDismissalStore store = disk.open();
      await store.load();
      final ConversationController controller = ConversationController(
        repo: backend.repo,
        orchestrator: TransferOrchestrator(
          repo: backend.repo,
          transfer: backend.transfer,
        ),
        platform: backend.platform,
        ids: backend.ids,
        clock: backend.clock,
        conversationId: conversationId,
        dismissals: store,
      );
      await controller.load();
      return (controller, store);
    }

    test('criterion 1: 3 failed → 忽略 → restart → the banner stays away, and '
        'the 3 messages are still failed', () async {
      for (final String id in <String>['m-1', 'm-2', 'm-3']) {
        _seed(backend, conversationId: 'c-a', messageId: id);
      }

      final (ConversationController firstRun, UnsentDismissalStore firstStore) =
          await launch('c-a');
      expect(firstRun.unsentMessages.length, 3);
      expect(firstRun.dismissUnsent(), 3);
      expect(firstRun.unsentMessages, isEmpty);
      // Let the write land, then "quit".
      await firstStore.flush();
      expect(disk.writes, 1);
      firstRun.dispose();

      // ── restart ─ a brand-new store over the same file.
      final (ConversationController secondRun, _) = await launch('c-a');
      addTearDown(secondRun.dispose);

      expect(
        secondRun.unsentMessages,
        isEmpty,
        reason: '★ 我退出软件重新进还是有的 —— 重启后必须仍然忽略',
      );
      final List<ChatMessage> after = backend.repo.history('c-a');
      expect(after.length, 3);
      expect(
        after.every((ChatMessage m) => m.status == MessageStatus.failed),
        isTrue,
        reason: '忽略 ≠ 删除 / ≠ 重试',
      );
    });

    test('criterion 2: after a restart, two NEW failures bring the banner back',
        () async {
      for (final String id in <String>['m-1', 'm-2', 'm-3']) {
        _seed(backend, conversationId: 'c-a', messageId: id);
      }
      final (ConversationController firstRun, UnsentDismissalStore firstStore) =
          await launch('c-a');
      firstRun.dismissUnsent();
      await firstStore.flush();
      firstRun.dispose();

      _seed(backend, conversationId: 'c-a', messageId: 'm-after-1');
      _seed(backend, conversationId: 'c-a', messageId: 'm-after-2');

      final (ConversationController secondRun, _) = await launch('c-a');
      addTearDown(secondRun.dispose);

      expect(
        secondRun.unsentMessages.map((ChatMessage m) => m.id),
        <String>['m-after-1', 'm-after-2'],
        reason: '只数未忽略的：重启把 3 条旧的找回来了，但新的失败必须重新计数',
      );
    });

    test('a dismissal is still per conversation across a restart', () async {
      _seed(backend, conversationId: 'c-a', messageId: 'm-a1');
      _seed(backend, conversationId: 'c-b', messageId: 'm-b1');

      final (ConversationController firstRun, UnsentDismissalStore firstStore) =
          await launch('c-a');
      firstRun.dismissUnsent();
      await firstStore.flush();
      firstRun.dispose();

      final (ConversationController otherAfterRestart, _) = await launch('c-b');
      addTearDown(otherAfterRestart.dispose);

      expect(otherAfterRestart.unsentMessages.length, 1);
    });

    test('a successful 全部重试 also survives a restart (the old rows stay '
        'failed, so something has to remember them)', () async {
      _seed(backend, conversationId: 'c-a', messageId: 'm-1');
      _seed(backend, conversationId: 'c-a', messageId: 'm-2');

      final (ConversationController firstRun, UnsentDismissalStore firstStore) =
          await launch('c-a');
      expect(firstRun.unsentMessages.length, 2);
      // The fake peer takes both uploads; the old rows keep `failed`.
      await firstRun.resendUnsent(peer: _peer());
      expect(firstRun.unsentMessages, isEmpty,
          reason: 'the batch was re-sent, so nothing is outstanding');
      await firstStore.flush();
      firstRun.dispose();

      final (ConversationController secondRun, _) = await launch('c-a');
      addTearDown(secondRun.dispose);

      expect(
        secondRun.unsentMessages,
        isEmpty,
        reason: '重启后条不能又冒出来 —— 那两条旧行还是 failed，只有「已处理」的记录'
            '能解释它们',
      );
      expect(disk.content, contains('"handled"'));
    });
  });
}

PeerDevice _peer() => const PeerDevice(
      fingerprint: _fingerprint,
      alias: 'Rita',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );
