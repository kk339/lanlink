/// 0.2.24 — the visible half of 全部重试: the 未发送成功 banner above the
/// composer and what one tap on it does.
///
/// The rule the banner keeps (and this file pins each half of):
/// * it appears only when the thread really has **≥ 2** failed/cancelled file
///   messages — one is the case the bubble's own 重新发送 already covers, and a
///   second entry there would be noise;
/// * it stays out of the way while anything is sending (a hash in progress, a
///   pick/cache copy, or a row actually `transferring`);
/// * a tap re-sends **serially** through the existing single-message path, so the
///   old rows keep their `failed` status, skips what has no source file left,
///   and answers with one sentence.
///
/// The thread is mounted **directly** (not through `ShellPage`), the same way
/// `cancel_ui_test.dart` does it: the shell's E2 startup sweep
/// (`failInterruptedMessages`) rewrites every leftover `transferring` row, so a
/// live `transferring` message has to be *produced* by a real send rather than
/// seeded.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/transfer_service.dart';
import 'package:lanlink_app/domain/unsent_dismissal_store.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';

import '../support/pump_app.dart';

const String _fingerprint = 'RR25';
const String _conversationId = 'c-retry-all-ui';

PeerDevice _peer() => const PeerDevice(
      fingerprint: _fingerprint,
      alias: 'Rita',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

FakeBackend _newBackend() {
  final FakeBackend backend = FakeBackend(
    devices: <PeerDevice>[_peer()],
    online: <DiscoveredPeer>[
      DiscoveredPeer(
        fingerprint: _fingerprint,
        alias: 'Rita',
        kind: DeviceKind.desktop,
        address: '192.168.1.25',
        port: 53317,
        isOnline: true,
        lastSeen: fixedEpoch,
      ),
    ],
  );
  backend.repo.addConversation(
    id: _conversationId,
    deviceFingerprint: _fingerprint,
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  return backend;
}

/// Seeds one outgoing file message in [status], sourced at [path].
///
/// The transfer row gets an `error`, which is what a real failed send leaves
/// behind (`markSendFailed`) — and it is also what keeps the thread's 1 Hz
/// progress poll **off**: `_hasLiveTransfer` reads "a non-terminal message with
/// bytes still to go and no error" as a live upload, and a poll that never stops
/// would make `pumpAndSettle` time out (and leave a pending timer at teardown).
void _seed(
  FakeBackend backend, {
  required String messageId,
  required MessageStatus status,
  String path = '/src/one.bin',
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
        localPath: path,
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

void main() {
  late FakeBackend backend;
  late TransferOrchestrator orchestrator;
  late ConversationController controller;

  setUp(() {
    backend = _newBackend();
    orchestrator = TransferOrchestrator(
      repo: backend.repo,
      transfer: backend.transfer,
    );
    controller = ConversationController(
      repo: backend.repo,
      orchestrator: orchestrator,
      platform: backend.platform,
      ids: backend.ids,
      clock: backend.clock,
      conversationId: _conversationId,
      // 0.2.30: dismissals are process-wide now (the fix for "退出会话再进来 忽略就
      // 没了"), so each test gets its own store. They all reuse this conversation
      // id and the ids `m-1 … m-12`, and a shared store would let test 7's 忽略
      // pre-ignore test 8's seed — a false green instead of a failure.
      dismissals: UnsentDismissalStore(),
    );
  });

  tearDown(() {
    controller.dispose();
    orchestrator.dispose();
    backend.dispose();
  });

  /// Mounts the real thread under the fake scope, inside a `Scaffold` (the
  /// banner's summary is a [SnackBar], which needs a [ScaffoldMessenger]).
  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1200, 900),
    bool settle = true,
  }) async {
    useSurfaceSize(tester, size);
    await pumpApp(
      tester,
      Scaffold(body: ConversationThread(controller: controller, peer: _peer())),
      backend: backend,
      settle: settle,
    );
  }

  /// Pumps a bounded number of frames — never `pumpAndSettle`, because a live
  /// transfer legitimately keeps scheduling frames (the 1 Hz progress poll).
  Future<void> pumpFrames(WidgetTester tester, {int count = 20}) async {
    for (int i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Produces a **real** failed send in the thread (0.2.26 tests).
  ///
  /// `sendPaths` + a failing `prepare`: the failure reaches the controller the
  /// way a device's does (a `MessageAdded` then a `MessageStatusUpdated`), not by
  /// being seeded into the repository behind its back — which is the only way to
  /// prove that a *later* failure re-arms the dismissed banner.
  Future<void> newFailedSend(
    WidgetTester tester, {
    required String path,
  }) async {
    backend.transfer.failNextPrepare(StateError('link reset'));
    await controller.sendPaths(peer: _peer(), paths: <String>[path]);
    await pumpFrames(tester, count: 6);
  }

  testWidgets(
    '1: 3 条 failed → the bar reads 3 条没有发送成功, 全部重试 adds 3 NEW messages, '
    'the old 3 keep `failed`, and the bar goes away',
    (WidgetTester tester) async {
      _seed(backend, messageId: 'm-1', status: MessageStatus.failed);
      _seed(
        backend,
        messageId: 'm-2',
        status: MessageStatus.failed,
        path: '/src/two.bin',
      );
      _seed(
        backend,
        messageId: 'm-3',
        status: MessageStatus.failed,
        path: '/src/three.bin',
      );
      await controller.load();
      await mount(tester);

      expect(
        find.text('3 条没有发送成功'),
        findsOneWidget,
        reason: 'the count is the whole point: one bar instead of three taps',
      );
      expect(find.text('全部重试'), findsOneWidget);

      await tester.tap(find.text('全部重试'));
      await pumpFrames(tester);

      final List<ChatMessage> after = backend.repo.history(_conversationId);
      expect(after.length, 6, reason: '3 old + 3 re-sent (each a NEW message)');
      expect(
        after.where((ChatMessage m) => m.status == MessageStatus.failed).length,
        3,
        reason: 'the three original rows must NOT be rewritten by a re-send',
      );
      expect(
        after.where((ChatMessage m) => m.status == MessageStatus.done).length,
        3,
        reason: 'the three new messages did go through',
      );
      expect(
        find.text('全部重试'),
        findsNothing,
        reason: 'the bar must disappear: there is nothing left to retry',
      );
      expect(find.textContaining('没有发送成功'), findsNothing);
      expect(
        find.text('已重新发送 3 条'),
        findsOneWidget,
        reason: 'a batch that says nothing is the silent-button defect again',
      );
    },
  );

  testWidgets(
    '2: a single failed message shows NO bar — the bubble’s 重新发送 is enough',
    (WidgetTester tester) async {
      _seed(backend, messageId: 'm-only', status: MessageStatus.failed);
      await controller.load();
      await mount(tester);

      expect(
        find.text('全部重试'),
        findsNothing,
        reason: 'one message is not a batch; a bar here would be noise',
      );
      expect(find.textContaining('没有发送成功'), findsNothing);
      expect(
        find.text('重新发送'),
        findsOneWidget,
        reason: 'the single-message entry is still there — that is the path a '
            'one-off failure keeps using',
      );
    },
  );

  testWidgets(
    '3: 2 条 failed with one source file deleted → only one is re-sent and the '
    'summary says 跳过 1 条',
    (WidgetTester tester) async {
      _seed(backend, messageId: 'm-here', status: MessageStatus.failed);
      _seed(
        backend,
        messageId: 'm-gone',
        status: MessageStatus.failed,
        path: '/src/gone.bin',
      );
      backend.platform.setExists('/src/gone.bin', false);
      await controller.load();
      await mount(tester);

      expect(
        find.text('2 条没有发送成功'),
        findsOneWidget,
        reason: 'a message whose source is gone is still one the user sees as '
            '没有发送成功 — it has to be counted, then skipped out loud',
      );

      await tester.tap(find.text('全部重试'));
      await pumpFrames(tester);

      expect(
        backend.repo.history(_conversationId).length,
        3,
        reason: '2 old + 1 re-sent: the message with no source file sends '
            'nothing at all',
      );
      expect(find.textContaining('跳过 1 条'), findsOneWidget);
      expect(find.textContaining('源文件已不在'), findsOneWidget);
    },
  );

  testWidgets(
    '4: a second tap while the run is live does nothing — the message count '
    'never doubles',
    (WidgetTester tester) async {
      _seed(backend, messageId: 'm-1', status: MessageStatus.failed);
      _seed(
        backend,
        messageId: 'm-2',
        status: MessageStatus.failed,
        path: '/src/two.bin',
      );
      _seed(
        backend,
        messageId: 'm-3',
        status: MessageStatus.failed,
        path: '/src/three.bin',
      );
      await controller.load();
      await mount(tester);

      // Park the first upload so the run is still going when the user taps
      // again — which is exactly the frame a fast double tap lands in.
      final Completer<void> hold = Completer<void>();
      backend.transfer.holdNextUpload(hold);

      await tester.tap(find.text('全部重试'));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('正在重新发送…'),
        findsOneWidget,
        reason: 'the bar must show it is working, not sit there as a dead button',
      );
      expect(
        tester.widget<TextButton>(find.widgetWithText(TextButton, '全部重试'))
            .onPressed,
        isNull,
        reason: 'the button is disabled while the run is live',
      );

      // The second tap: same place, one frame later. It must be a no-op.
      await tester.tap(find.text('全部重试'));
      await tester.pump();

      await tester.runAsync(() async {
        hold.complete();
      });
      await pumpFrames(tester);

      expect(
        backend.repo.history(_conversationId).length,
        6,
        reason: '3 old + 3 new. Nine would be the doubled-send defect',
      );
      expect(backend.transfer.preparedSessions.length, 3,
          reason: 'one session per message, never two per message');
    },
  );

  testWidgets(
    '5a: a live transfer hides the bar, and it comes back once the send is over',
    (WidgetTester tester) async {
      _seed(backend, messageId: 'm-1', status: MessageStatus.failed);
      _seed(
        backend,
        messageId: 'm-2',
        status: MessageStatus.failed,
        path: '/src/two.bin',
      );
      backend.platform.setPickResult(FileKind.any, const <String>['/src/big.mov']);
      backend.platform.setLength('/src/big.mov', 1000);
      backend.platform.setSha256('/src/big.mov', '00');
      await controller.load();
      await mount(tester);

      expect(find.text('2 条没有发送成功'), findsOneWidget);

      final Completer<void> hold = Completer<void>();
      backend.transfer.holdNextUpload(hold);
      final Future<SendOutcome?> sending =
          controller.pickAndSend(peer: _peer(), kind: FileKind.any);
      for (int i = 0; i < 5; i++) {
        await tester.pump();
      }

      expect(find.text('传输中'), findsWidgets,
          reason: 'the upload is held, so a send really is in flight');
      expect(
        find.text('全部重试'),
        findsNothing,
        reason: 'offering 全部重试 next to a running upload is noise, and a '
            'batch started here would queue behind it',
      );

      await tester.runAsync(() async {
        hold.complete();
      });
      await sending;
      await pumpFrames(tester);

      expect(
        find.text('2 条没有发送成功'),
        findsOneWidget,
        reason: 'the two failed messages are still failed, so the bar is back — '
            'a live send must only *postpone* it, never retire it',
      );
    },
  );

  testWidgets(
    '5b: a pick-and-hash in progress (正在准备) hides the bar',
    (WidgetTester tester) async {
      _seed(backend, messageId: 'm-1', status: MessageStatus.failed);
      _seed(
        backend,
        messageId: 'm-2',
        status: MessageStatus.failed,
        path: '/src/two.bin',
      );
      backend.platform.setPickResult(FileKind.any, const <String>['/src/big.mov']);
      backend.platform.setLength('/src/big.mov', 1000);
      backend.platform.setSha256('/src/big.mov', '00');
      await controller.load();
      await mount(tester);

      expect(find.text('2 条没有发送成功'), findsOneWidget);

      final Completer<void> gate = Completer<void>();
      backend.platform.holdNextHash(gate);

      // 0.2.33: the attach button opens a menu; 发送文件 is the pick that parks
      // the hash below.
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pumpAndSettle();
      await tester.tap(find.text('发送文件'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('正在准备'), findsWidgets,
          reason: 'the hash is held, so the thread is in 正在准备');
      expect(
        find.text('全部重试'),
        findsNothing,
        reason: '正在准备 must not share the strip above the composer with a '
            'second row — the banner yields',
      );

      await tester.runAsync(() async {
        gate.complete();
      });
      await pumpFrames(tester);
    },
  );

  testWidgets(
    '6: a 320 dp phone renders the bar without overflowing, and the button is '
    'entirely on screen',
    (WidgetTester tester) async {
      // The narrowest phone the layout host resolves to. A double-digit count is
      // the worst case for the label, and the row is icon + flexible label +
      // fixed button, so any mistake here is a horizontal RenderFlex overflow
      // (which fails the test by itself).
      for (int i = 0; i < 12; i++) {
        _seed(
          backend,
          messageId: 'm-$i',
          status: MessageStatus.failed,
          path: '/src/$i.bin',
        );
      }
      await controller.load();
      await mount(tester, size: const Size(320, 640));

      expect(find.text('12 条没有发送成功'), findsOneWidget);
      final Rect button = tester.getRect(find.text('全部重试'));
      expect(button.right, lessThanOrEqualTo(320.0),
          reason: 'the button must be fully inside a 320 dp screen');
      expect(button.left, greaterThanOrEqualTo(0.0));
      expect(
        tester.getRect(find.text('12 条没有发送成功')).width,
        greaterThan(0.0),
        reason: 'the label keeps width for itself instead of being squeezed to '
            'nothing by the button',
      );

      await tester.tap(find.text('全部重试'));
      await pumpFrames(tester);
      expect(backend.repo.history(_conversationId).length, 24,
          reason: '12 old + 12 new');
    },
  );

  // ── 0.2.26: the bar can be dismissed (忽略) ─────────────────────────────

  testWidgets(
    '7: 忽略 closes the bar and does NOT delete anything — the three messages '
    'and their 失败 status are still there',
    (WidgetTester tester) async {
      _seed(backend, messageId: 'm-1', status: MessageStatus.failed);
      _seed(
        backend,
        messageId: 'm-2',
        status: MessageStatus.failed,
        path: '/src/two.bin',
      );
      _seed(
        backend,
        messageId: 'm-3',
        status: MessageStatus.failed,
        path: '/src/three.bin',
      );
      await controller.load();
      await mount(tester);

      expect(find.text('3 条没有发送成功'), findsOneWidget);
      expect(
        find.byTooltip('忽略'),
        findsOneWidget,
        reason: 'the complaint was "只有全部重试没有取消按钮" — this is the 取消',
      );

      await tester.tap(find.byTooltip('忽略'));
      await pumpFrames(tester, count: 6);

      expect(
        find.text('全部重试'),
        findsNothing,
        reason: 'the bar must go away on the frame after the tap',
      );
      expect(find.textContaining('没有发送成功'), findsNothing);
      expect(
        backend.repo.history(_conversationId).length,
        3,
        reason: '忽略 ≠ 删除: not one message was removed',
      );
      expect(
        backend.repo
            .history(_conversationId)
            .every((ChatMessage m) => m.status == MessageStatus.failed),
        isTrue,
        reason: 'and 忽略 ≠ 重试: no status changed either',
      );
      expect(
        find.text('失败（可重新发送）'),
        findsNWidgets(3),
        reason: 'the three bubbles are still on screen, each still offering its '
            'own 重新发送 — dismissing the bar strands nobody',
      );
    },
  );

  testWidgets(
    '8: a dismissal covers that batch only — one later failure stays quiet, two '
    'bring the bar back with the un-dismissed count',
    (WidgetTester tester) async {
      _seed(backend, messageId: 'm-1', status: MessageStatus.failed);
      _seed(
        backend,
        messageId: 'm-2',
        status: MessageStatus.failed,
        path: '/src/two.bin',
      );
      await controller.load();
      await mount(tester);
      expect(find.text('2 条没有发送成功'), findsOneWidget);

      await tester.tap(find.byTooltip('忽略'));
      await pumpFrames(tester, count: 6);
      expect(find.textContaining('没有发送成功'), findsNothing);

      // A genuinely new failure, through the real send path (so the thread
      // learns about it the way it does on a device: MessageAdded, then
      // MessageStatusUpdated).
      await newFailedSend(tester, path: '/src/after-1.bin');
      expect(
        find.textContaining('没有发送成功'),
        findsNothing,
        reason: 'one un-dismissed failure is below the ≥2 threshold — the bar '
            'must not pop back for a single message',
      );

      await newFailedSend(tester, path: '/src/after-2.bin');
      expect(
        find.text('2 条没有发送成功'),
        findsOneWidget,
        reason: 'the count is the UN-dismissed ones (2), not all four failures — '
            'counting everything would make the bar say 4 and re-offer the two '
            'the user already put away',
      );
    },
  );

  testWidgets(
    '9: the ✕ fits a 320 dp phone — 48×48 target, label still has width, '
    'nothing overflows, and a tap 2 px inside its edge still lands',
    (WidgetTester tester) async {
      for (int i = 0; i < 12; i++) {
        _seed(
          backend,
          messageId: 'm-$i',
          status: MessageStatus.failed,
          path: '/src/$i.bin',
        );
      }
      await controller.load();
      await mount(tester, size: const Size(320, 640));

      // `byTooltip` finds the Tooltip, whose box is the 40 dp *ink*; the thing a
      // finger hits is the IconButton, so that is what gets measured (the same
      // distinction `tap_target_probe_test` records for every other control).
      final Finder closeButton = find.byWidgetPredicate(
          (Widget w) => w is IconButton && w.tooltip == '忽略');
      final Rect close = tester.getRect(closeButton);
      expect(close.width, greaterThanOrEqualTo(48.0),
          reason: 'the ✕ hit box is ${close.width} wide');
      expect(close.height, greaterThanOrEqualTo(48.0),
          reason: 'the ✕ hit box is ${close.height} high');
      expect(close.right, lessThanOrEqualTo(320.0),
          reason: 'the ✕ must be fully inside a 320 dp screen');

      final Rect retry = tester.getRect(find.text('全部重试'));
      expect(retry.right, lessThanOrEqualTo(320.0));
      expect(
        tester.getRect(find.text('12 条没有发送成功')).width,
        greaterThan(0.0),
        reason: 'the label must keep real width with a second control in the '
            'row, not be squeezed to nothing',
      );

      // The edge test: 2 px inside the 48 dp box is *outside* the 40 dp ink, so
      // only a real 48 dp tap target answers here.
      await tester.tapAt(Offset(close.left + 2, close.center.dy));
      await pumpFrames(tester, count: 6);
      expect(
        find.textContaining('没有发送成功'),
        findsNothing,
        reason: 'a tap 2 px inside the ✕ edge must dismiss the bar',
      );
    },
  );

  testWidgets(
    '★ 0.2.48 criterion 7: while multi-select is on, 「全部重试」 is NOT on screen — '
    'its scope is the whole conversation, the user\'s is the ticked bubbles',
    (WidgetTester tester) async {
      _seed(backend, messageId: 'm-1', status: MessageStatus.failed);
      _seed(
        backend,
        messageId: 'm-2',
        status: MessageStatus.failed,
        path: '/src/two.bin',
      );
      _seed(
        backend,
        messageId: 'm-3',
        status: MessageStatus.failed,
        path: '/src/three.bin',
      );
      await controller.load();
      await mount(tester);

      // The bar is legitimately there in the normal mode…
      expect(find.text('全部重试'), findsOneWidget);
      expect(find.text('3 条没有发送成功'), findsOneWidget);

      // …and it must go away the moment a batch is being picked: it re-sends
      // **every** unsent message (`resendUnsent`), so leaving it on screen while
      // the user has ticked two of five bubbles means one tap re-sends the other
      // three as well. The bottom strip is the batch toolbar in this mode, so the
      // whole-conversation entries are simply not drawn.
      controller.startSelecting();
      await tester.pumpAndSettle();
      expect(find.text('全部重试'), findsNothing);
      expect(find.textContaining('没有发送成功'), findsNothing);
      // The batch toolbar is what owns the bottom strip now.
      expect(find.text('已选 0 条'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('selection-delete')),
        findsOneWidget,
      );

      // …and it comes back when the mode ends: nothing was destroyed.
      controller.cancelSelecting();
      await tester.pumpAndSettle();
      expect(find.text('全部重试'), findsOneWidget);
      expect(find.text('3 条没有发送成功'), findsOneWidget);
    },
  );

  testWidgets(
    '★ 0.2.48 criterion 7: the 待发送 row is hidden in the same mode — it sends '
    'other files, not the ticked messages',
    (WidgetTester tester) async {
      _seed(backend, messageId: 'm-1', status: MessageStatus.failed);
      _seed(
        backend,
        messageId: 'm-2',
        status: MessageStatus.failed,
        path: '/src/two.bin',
      );
      await controller.load();
      useSurfaceSize(tester, const Size(1200, 900));
      await pumpApp(
        tester,
        Scaffold(
          body: ConversationThread(
            controller: controller,
            peer: _peer(),
            sharedPaths: const <String>['/share/photo.png'],
          ),
        ),
        backend: backend,
        settle: true,
      );

      expect(find.text('发到 Rita · photo.png'), findsOneWidget);

      controller.startSelecting();
      await tester.pumpAndSettle();

      expect(find.text('发到 Rita · photo.png'), findsNothing,
          reason: 'its 发送 would send the staged share, not the picked messages');
      expect(find.text('发送'), findsNothing,
          reason: 'the row and its two buttons are gone together');
      expect(find.text('全部重试'), findsNothing);

      controller.cancelSelecting();
      await tester.pumpAndSettle();
      expect(find.text('发到 Rita · photo.png'), findsOneWidget,
          reason: 'leaving the mode must restore the staged share untouched');
    },
  );
}
