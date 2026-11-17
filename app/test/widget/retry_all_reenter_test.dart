/// 0.2.30 — the 未发送成功 banner's ✕ must **survive leaving the conversation**.
///
/// The report: *"之前不是说给全部重试那个部分整一个忽略按钮吗，但是我发现如果退出这个
/// 会话界面重新进来，还是会显示全部重试"*.
///
/// Root cause: 0.2.26 held the ignored ids in a `Set` field on
/// `ConversationController`, and `DetailPane._reconcileConversation` builds a
/// **new** controller for every conversation selection — so walking out of the
/// thread disposed the ids with the object, and walking back in built a
/// controller that had never heard of them.
///
/// A test that reused one controller would therefore prove nothing. `_PaneStub`
/// below reproduces the real lifecycle instead:
/// * a **fresh `ConversationController` per selection**, `load()`ed on arrival,
///   disposed on the way out (exactly what the pane does);
/// * the thread **re-keyed** per conversation id, so its `State` is rebuilt too;
/// * "exit" = unmounting the pane entirely (`pumpWidget(SizedBox.shrink())`),
///   which is what a narrow window's ← back to the list does.
///
/// Criteria covered here:
/// 1. 3 failed → 忽略 → bar gone → **exit → re-enter** → bar still absent, and the
///    3 messages are still `failed` (toast-free, nothing deleted);
/// 2. 忽略 → 2 new failures arrive → re-enter → bar is back and reads「2 条」
///    (only the un-ignored ones are counted);
/// 3. the dismissal is per conversation: ignoring in A does not hide B's bar.
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

const String _fingerprint = 'RR30';
const String _conversationId = 'c-reenter';
const String _otherConversationId = 'c-reenter-other';

PeerDevice _peer() => const PeerDevice(
      fingerprint: _fingerprint,
      alias: 'Rita',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// Seeds one outgoing **failed file** message, transfer row included.
///
/// The `error` on the transfer row is what keeps the thread's 1 Hz progress poll
/// off (the same reason `retry_all_test.dart` seeds it): a live poll would make
/// `pumpAndSettle` time out and leave a pending timer at teardown.
void _seed(
  FakeBackend backend, {
  required String messageId,
  String conversationId = _conversationId,
}) {
  backend.repo.addMessage(
    id: messageId,
    conversationId: conversationId,
    direction: MessageDirection.outgoing,
    status: MessageStatus.failed,
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
      error: 'seeded-failure',
    ),
  );
}

/// Holds the controller the stub built most recently, so a test can drive it.
class _Cradle {
  ConversationController? current;
}

/// Stands in for `DetailPane`'s conversation module (see the library doc).
class _PaneStub extends StatefulWidget {
  const _PaneStub({
    required this.backend,
    required this.store,
    required this.cradle,
    required this.conversationId,
  });

  final FakeBackend backend;
  final UnsentDismissalStore store;
  final _Cradle cradle;
  final String conversationId;

  @override
  State<_PaneStub> createState() => _PaneStubState();
}

class _PaneStubState extends State<_PaneStub> {
  ConversationController? _conversation;
  TransferOrchestrator? _orchestrator;
  String? _boundId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reconcile();
  }

  @override
  void didUpdateWidget(_PaneStub oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reconcile();
  }

  @override
  void dispose() {
    _conversation?.dispose();
    _orchestrator?.dispose();
    widget.cradle.current = null;
    super.dispose();
  }

  void _reconcile() {
    if (widget.conversationId == _boundId) {
      return;
    }
    _conversation?.dispose();
    _orchestrator?.dispose();
    _conversation = null;
    _orchestrator = null;
    _boundId = widget.conversationId;
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
      conversationId: widget.conversationId,
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
      key: ValueKey<String>('messages-${widget.conversationId}'),
      controller: conversation,
      peer: _peer(),
    );
  }
}

void main() {
  late FakeBackend backend;
  late UnsentDismissalStore store;
  late _Cradle cradle;

  setUp(() {
    backend = FakeBackend();
    // One store for the whole test = one process in production.
    store = UnsentDismissalStore();
    cradle = _Cradle();
    for (final String id in <String>[_conversationId, _otherConversationId]) {
      backend.repo.addConversation(
        id: id,
        deviceFingerprint: _fingerprint,
        createdAt: fixedEpoch,
        lastMessageAt: fixedEpoch,
      );
    }
  });

  tearDown(() => backend.dispose());

  /// Mounts the pane for [conversationId] (a **new** controller each time the id
  /// changes, and a new one after every unmount — that is the point).
  Future<void> enter(
    WidgetTester tester,
    String conversationId, {
    Size size = const Size(900, 800),
  }) async {
    useSurfaceSize(tester, size);
    await tester.pumpWidget(
      appWithScope(
        deps: testDeps(backend),
        child: Scaffold(
          body: _PaneStub(
            backend: backend,
            store: store,
            cradle: cradle,
            conversationId: conversationId,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Leaves the thread entirely: the pane is gone, so its controller (and every
  /// field on it) is disposed — the narrow-window ← back to the list path.
  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(cradle.current, isNull,
        reason: 'the stub must really let go of the controller, otherwise this '
            'test would not reproduce the reported path at all');
  }

  testWidgets(
      '1: 3 条 failed → 忽略 → bar gone → 退出会话再进来 → bar STILL gone (and '
      'nothing was deleted)', (WidgetTester tester) async {
    _seed(backend, messageId: 'm-1');
    _seed(backend, messageId: 'm-2');
    _seed(backend, messageId: 'm-3');

    await enter(tester, _conversationId);
    expect(find.text('3 条没有发送成功'), findsOneWidget);
    expect(find.byTooltip('忽略'), findsOneWidget);

    await tester.tap(find.byTooltip('忽略'));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有发送成功'), findsNothing,
        reason: 'the tap hides this batch');

    // ── exit ─ the controller is disposed, taking its fields with it.
    await leave(tester);
    // ── re-enter ─ a brand-new controller + a brand-new thread State.
    await enter(tester, _conversationId);

    expect(
      find.textContaining('没有发送成功'),
      findsNothing,
      reason: '★ 这次的 bug：退出再进来，忽略必须仍然生效。报的就是这条',
    );
    expect(find.text('全部重试'), findsNothing);

    // 忽略 ≠ 删除 / ≠ 重试: the three messages are all still there, still failed,
    // each still offering its own 重新发送.
    final List<ChatMessage> after = backend.repo.history(_conversationId);
    expect(after.length, 3);
    expect(
      after.every((ChatMessage m) => m.status == MessageStatus.failed),
      isTrue,
    );
    expect(find.text('失败（可重新发送）'), findsNWidgets(3));
  });

  testWidgets(
      '2: after 忽略, two NEW failures bring the bar back on re-entry, and it '
      'counts only the un-ignored ones', (WidgetTester tester) async {
    _seed(backend, messageId: 'm-1');
    _seed(backend, messageId: 'm-2');
    _seed(backend, messageId: 'm-3');

    await enter(tester, _conversationId);
    await tester.tap(find.byTooltip('忽略'));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有发送成功'), findsNothing);

    await leave(tester);

    // While the user was away, two more sends failed.
    _seed(backend, messageId: 'm-after-1');
    _seed(backend, messageId: 'm-after-2');

    await enter(tester, _conversationId);

    expect(
      find.text('2 条没有发送成功'),
      findsOneWidget,
      reason: '只数没被忽略的：3 条已忽略的不能算进来（算全量就会写成 5 条，并重新把'
          '用户按下去的那三条摆到面前）',
    );
    expect(find.text('全部重试'), findsOneWidget);
  });

  testWidgets('3: the dismissal belongs to its conversation — the other '
      'device’s bar is untouched', (WidgetTester tester) async {
    _seed(backend, messageId: 'm-1');
    _seed(backend, messageId: 'm-2');
    // Distinct ids (a message id is unique across the store); that the *key* is
    // the (conversation, message) PAIR is pinned in
    // `test/unsent_dismissal_store_test.dart`, where the same ids are reused in
    // two conversations on purpose.
    _seed(backend, messageId: 'm-other-1', conversationId: _otherConversationId);
    _seed(backend, messageId: 'm-other-2', conversationId: _otherConversationId);

    await enter(tester, _conversationId);
    await tester.tap(find.byTooltip('忽略'));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有发送成功'), findsNothing);

    // Switching conversation is a new controller too — same mechanism.
    await enter(tester, _otherConversationId);
    expect(
      find.text('2 条没有发送成功'),
      findsOneWidget,
      reason: '另一台设备的失败还等着用户处理，不能被这次忽略带走',
    );
  });
}
