/// 0.2.33 — the 未发送成功 banner must stay closed across a **restart**.
///
/// The report: *"还是那个全部重试的那个东西，虽然会话退出再进来没有了，但是我退出软件
/// 重新进还是有的"*.
///
/// 0.2.30 made the dismissal process-wide (that fixed the conversation switch) and
/// explicitly accepted "restart brings it back". The user did not accept it, and he
/// was right: the failed messages are still in the history, so "这一批我处理过了"
/// must not expire with the process.
///
/// "Restart" here is honest: a **new** `UnsentDismissalStore` reading the same
/// fake file, a **new** controller, a **new** thread `State`. Nothing from the
/// previous run survives except the bytes on the "disk" — which is exactly what a
/// relaunch leaves behind.
///
/// Criteria:
/// 1. 3 failed → 忽略 → restart → the bar is **still gone**, the 3 messages are
///    still `failed`;
/// 2. after that restart, two NEW failures bring the bar back reading「2 条」;
/// 3. a successful 全部重试 also survives the restart (the old rows stay `failed`,
///    so the "已处理" record is the only thing that can explain them) — and the
///    document on "disk" is asserted, not just the pixels.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/unsent_dismissal_store.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';

import '../support/pump_app.dart';

const String _fingerprint = 'RR33';
const String _conversationId = 'c-restart';

PeerDevice _peer() => const PeerDevice(
      fingerprint: _fingerprint,
      alias: 'Rita',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// The app's `unsent_dismissals.json`, as one string.
class _Disk {
  String? content;
  int writes = 0;

  Future<String?> read() async => content;

  Future<void> write(String data) async {
    writes++;
    content = data;
  }

  UnsentDismissalStore open() =>
      UnsentDismissalStore(read: read, write: write);
}

/// Seeds one outgoing **failed file** message, transfer row included (the `error`
/// keeps the thread's 1 Hz progress poll off). [status] lets a test seed a
/// `done` row, which is how "the message left the failed state" is expressed.
void _seed(
  FakeBackend backend, {
  required String messageId,
  MessageStatus status = MessageStatus.failed,
}) {
  backend.repo.addMessage(
    id: messageId,
    conversationId: _conversationId,
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
  backend.repo.addTransfer(
    TransferProgress(
      fileId: 'f-$messageId',
      bytesDone: 0,
      bytesTotal: 5,
      error: status == MessageStatus.failed ? 'seeded-failure' : null,
    ),
  );
}

/// Holds the controller the stub built, so the test can drive it if needed.
class _Cradle {
  ConversationController? current;
}

/// Stands in for `DetailPane`'s conversation module: one controller per
/// selection, `load()`ed on arrival, disposed on the way out, thread re-keyed.
class _PaneStub extends StatefulWidget {
  const _PaneStub({
    required this.backend,
    required this.store,
    required this.cradle,
  });

  final FakeBackend backend;
  final UnsentDismissalStore store;
  final _Cradle cradle;

  @override
  State<_PaneStub> createState() => _PaneStubState();
}

class _PaneStubState extends State<_PaneStub> {
  ConversationController? _conversation;
  TransferOrchestrator? _orchestrator;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void dispose() {
    _conversation?.dispose();
    _orchestrator?.dispose();
    widget.cradle.current = null;
    super.dispose();
  }

  void _bind() {
    if (_conversation != null) {
      return;
    }
    final TransferOrchestrator orchestrator = TransferOrchestrator(
      repo: widget.backend.repo,
      transfer: widget.backend.transfer,
    );
    final ConversationController conversation = ConversationController(
      repo: widget.backend.repo,
      orchestrator: orchestrator,
      platform: widget.backend.platform,
      ids: widget.backend.ids,
      clock: widget.backend.clock,
      conversationId: _conversationId,
      dismissals: widget.store,
    );
    _orchestrator = orchestrator;
    _conversation = conversation;
    widget.cradle.current = conversation;
    unawaited(conversation.load());
  }

  @override
  Widget build(BuildContext context) {
    final ConversationController? conversation = _conversation;
    if (conversation == null) {
      return const SizedBox.shrink();
    }
    return ConversationThread(
      key: const ValueKey<String>('messages-$_conversationId'),
      controller: conversation,
      peer: _peer(),
    );
  }
}

void main() {
  late FakeBackend backend;
  late _Disk disk;
  late _Cradle cradle;
  late UnsentDismissalStore runStore;

  setUp(() {
    backend = FakeBackend();
    disk = _Disk();
    cradle = _Cradle();
    backend.repo.addConversation(
      id: _conversationId,
      deviceFingerprint: _fingerprint,
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
  });

  tearDown(() => backend.dispose());

  /// One **app run**: a fresh store loaded from the same file, then the pane.
  Future<void> launch(WidgetTester tester) async {
    useSurfaceSize(tester, const Size(900, 800));
    final UnsentDismissalStore store = disk.open();
    runStore = store;
    await store.load();
    await tester.pumpWidget(
      appWithScope(
        deps: testDeps(backend),
        child: Scaffold(
          body: _PaneStub(
            backend: backend,
            store: store,
            cradle: cradle,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Quits the app: the write is awaited (a real quit flushes the page cache the
  /// same way), the tree is torn down, and the controller is gone.
  Future<void> quit(WidgetTester tester) async {
    await runStore.flush();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(cradle.current, isNull,
        reason: 'the stub must really dispose the controller — a test that kept '
            'it alive would not be reproducing a restart at all');
  }

  testWidgets(
      '1: 3 条 failed → 忽略 → **restart** → the bar is still gone, and the 3 '
      'messages are still failed', (WidgetTester tester) async {
    for (final String id in <String>['m-1', 'm-2', 'm-3']) {
      _seed(backend, messageId: id);
    }

    await launch(tester);
    expect(find.text('3 条没有发送成功'), findsOneWidget);
    await tester.tap(find.byTooltip('忽略'));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有发送成功'), findsNothing);
    await quit(tester);

    expect(disk.writes, greaterThan(0), reason: 'the dismissal must reach the file');

    // ── restart ─
    await launch(tester);

    expect(
      find.textContaining('没有发送成功'),
      findsNothing,
      reason: '★ 这次的 bug：退出软件重新进，忽略必须仍然生效',
    );
    expect(find.text('全部重试'), findsNothing);

    final List<ChatMessage> after = backend.repo.history(_conversationId);
    expect(after.length, 3, reason: '忽略 ≠ 删除');
    expect(
      after.every((ChatMessage m) => m.status == MessageStatus.failed),
      isTrue,
      reason: '忽略 ≠ 重试：状态没被动过，三条气泡还各自带着「重新发送」',
    );
    expect(find.text('失败（可重新发送）'), findsNWidgets(3));
  });

  testWidgets(
      '2: after a restart, two NEW failures bring the bar back reading「2 条」',
      (WidgetTester tester) async {
    for (final String id in <String>['m-1', 'm-2', 'm-3']) {
      _seed(backend, messageId: id);
    }
    await launch(tester);
    await tester.tap(find.byTooltip('忽略'));
    await tester.pumpAndSettle();
    await quit(tester);

    // While the app was closed, two sends failed.
    _seed(backend, messageId: 'm-after-1');
    _seed(backend, messageId: 'm-after-2');

    await launch(tester);

    expect(
      find.text('2 条没有发送成功'),
      findsOneWidget,
      reason: '只数未忽略的：3 条已忽略的不能算进来（算全量就会写成 5 条，并重新把'
          '用户按下去的那三条摆到面前）',
    );
  });

  testWidgets(
      '3: a successful 全部重试 also survives a restart — the old rows stay '
      'failed, so the record on disk is what explains them',
      (WidgetTester tester) async {
    _seed(backend, messageId: 'm-1');
    _seed(backend, messageId: 'm-2');

    await launch(tester);
    expect(find.text('2 条没有发送成功'), findsOneWidget);

    await tester.tap(find.text('全部重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有发送成功'), findsNothing,
        reason: 'both were re-sent, so the batch is settled');
    expect(backend.repo.history(_conversationId).length, 4,
        reason: '2 old + 2 new');
    await quit(tester);

    // The document itself, not just the pixels.
    expect(disk.content, contains('"handled"'));
    expect(
      disk.content,
      contains('"messageId":"m-1"'),
      reason: 'the old row is still `failed` in the history, so it needs a '
          'record saying "a bulk run already re-sent this"',
    );

    await launch(tester);

    expect(
      find.textContaining('没有发送成功'),
      findsNothing,
      reason: 'restarting must not re-offer a batch the user already retried',
    );
    expect(backend.repo.history(_conversationId).length, 4,
        reason: 'and nothing was re-sent a second time');
  });
}
