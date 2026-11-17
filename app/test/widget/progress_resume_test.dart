/// 0.2.15 regression tests for the reported **"退到手机主屏（应用后台）再回来，
/// 进度条不动了"** defect, driven through the real lifecycle mechanism.
///
/// The two facts these tests encode:
///
/// * while the app is `paused` the engine stops scheduling frames
///   (`SchedulerBinding.scheduleFrame` is a no-op when `framesEnabled` is false)
///   and the OS may defer — or freeze — the 1 Hz ticker, so **no repaint is
///   guaranteed to follow a return to the foreground**;
/// * nothing in the thread used to react to `AppLifecycleState.resumed`, so the
///   first frame after the return either showed the pre-background number or,
///   when the ticker had stopped itself, showed it forever.
///
/// So the assertions are deliberately about *behaviour a user can see*: the bar
/// drawn on the first frame after `resumed`, and (in the second test) the bar
/// moving again a second later — which is the only honest way to prove "the
/// ticker is still running" without touching private fields.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/bootstrap/app_deps.dart';
import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';

import '../support/pump_app.dart';

const String _conversationId = 'c-progress';
const String _messageId = 'm-progress';
const String _fileId = 'f-progress';
const int _total = 1000;

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'AAAA1111',
      alias: 'Alice',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// One conversation holding a single outgoing file **mid-upload**: 100 of 1000
/// bytes done, status `transferring`.
FakeBackend _backendWithLiveTransfer() {
  final FakeBackend backend = FakeBackend();
  backend.repo.addConversation(
    id: _conversationId,
    deviceFingerprint: 'AAAA1111',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.repo.addMessage(
    id: _messageId,
    conversationId: _conversationId,
    direction: MessageDirection.outgoing,
    status: MessageStatus.transferring,
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
    files: <FileAttachment>[
      const FileAttachment(
        id: _fileId,
        messageId: _messageId,
        fileName: 'big.mov',
        size: _total,
        sha256: '00',
        localPath: '/src/big.mov',
      ),
    ],
  );
  backend.repo.addTransfer(
    const TransferProgress(fileId: _fileId, bytesDone: 100, bytesTotal: _total),
  );
  return backend;
}

/// Drives the **real** transition into the background.
///
/// `WidgetsBinding.handleAppLifecycleStateChanged` asserts the legal Android
/// order (`resumed → inactive → hidden → paused`), so the test walks it exactly
/// as the platform does — no shortcut states, no invented sequence.
void _goToBackground(WidgetTester tester) {
  for (final AppLifecycleState state in <AppLifecycleState>[
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

/// And back: `paused → hidden → inactive → resumed`.
void _comeToForeground(WidgetTester tester) {
  for (final AppLifecycleState state in <AppLifecycleState>[
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

/// The bar's current fraction — the number the user is looking at.
double? _barValue(WidgetTester tester) => tester
    .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
    .value;

/// A mounted thread plus the handles a test needs to drive and tear it down.
class _Thread {
  _Thread(this.backend, this.controller, this.orchestrator);

  /// Drives the transfer behind the UI's back.
  final FakeBackend backend;

  /// The controller the thread renders from.
  final ConversationController controller;

  final TransferOrchestrator orchestrator;

  bool _disposed = false;

  /// Releases everything **inside** the test body as well as in `addTearDown`:
  /// the framework verifies "no timer is still pending" *before* tear-downs run,
  /// and a live transfer legitimately keeps the 1 Hz poll armed.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    controller.dispose();
    orchestrator.dispose();
    backend.dispose();
  }
}

/// Mounts the thread over a live transfer.
Future<_Thread> _mountThread(WidgetTester tester) async {
  useSurfaceSize(tester, const Size(600, 900));
  final FakeBackend backend = _backendWithLiveTransfer();
  final AppDeps deps = testDeps(backend);
  final TransferOrchestrator orchestrator = TransferOrchestrator(
    repo: deps.repo,
    transfer: deps.transfer,
  );
  final ConversationController controller = ConversationController(
    repo: deps.repo,
    orchestrator: orchestrator,
    platform: deps.platform,
    ids: deps.ids,
    clock: deps.clock,
    conversationId: _conversationId,
  );
  final _Thread thread = _Thread(backend, controller, orchestrator);
  addTearDown(thread.dispose);
  // Exactly what opening a conversation does (`DetailPane._reconcileConversation`):
  // build the controller, load, then hand it to the thread.
  await controller.load();
  await pumpApp(
    tester,
    Scaffold(
      body: ConversationThread(controller: controller, peer: _peer()),
    ),
    backend: backend,
  );
  return thread;
}

void main() {
  testWidgets(
    '回前台后的**第一帧**就画出后台期间新增的进度（不依赖下一次 tick）',
    (WidgetTester tester) async {
      final _Thread thread = await _mountThread(tester);
      final FakeBackend backend = thread.backend;
      expect(
        _barValue(tester),
        closeTo(0.1, 1e-9),
        reason: 'the seeded 100/1000 must be on screen before we background',
      );

      // ── to the home screen ───────────────────────────────────────────────
      _goToBackground(tester);

      // Bytes keep moving while backgrounded. This is the **transfer**, not the
      // UI: a progress write emits no repository event (that is why the ticker
      // exists), so nothing repaints on its own.
      backend.repo.markTransferProgress(fileId: _fileId, bytesDone: 400);
      // No frames are drawn while paused — and the 1 Hz tick may be deferred or
      // frozen by the OS, so time deliberately does not advance here.
      await tester.pump();
      expect(
        _barValue(tester),
        closeTo(0.1, 1e-9),
        reason: 'a paused app must not paint — the last frame stays on screen',
      );

      // ── back to the app ──────────────────────────────────────────────────
      _comeToForeground(tester);
      await tester.pump();

      expect(
        _barValue(tester),
        closeTo(0.4, 1e-9),
        reason: 'the first frame after `resumed` must show the current '
            'bytes_done (400/1000), not the pre-background 100/1000 — waiting '
            'for the next tick can take a second, and can be forever when no '
            'ticker is running',
      );

      // Released inside the body on purpose: the test framework checks "no timer
      // is still pending" *before* tear-downs run, and a live transfer keeps the
      // 1 Hz poll legitimately armed.
      thread.dispose();
    },
  );

  testWidgets(
    'resumed 之后 ticker 仍在跑：再过 1 秒，新进度继续落到 UI 上',
    (WidgetTester tester) async {
      final _Thread thread = await _mountThread(tester);
      final FakeBackend backend = thread.backend;

      _goToBackground(tester);
      backend.repo.markTransferProgress(fileId: _fileId, bytesDone: 400);
      _comeToForeground(tester);
      await tester.pump();
      expect(_barValue(tester), closeTo(0.4, 1e-9));

      // One full tick interval with a bigger value written behind the UI's back:
      // only a *running* ticker can turn that write into a repaint.
      backend.repo.markTransferProgress(fileId: _fileId, bytesDone: 700);
      await tester.pump(kProgressTickInterval);
      expect(
        _barValue(tester),
        closeTo(0.7, 1e-9),
        reason: 'the ticker must still be polling after the app came back',
      );

      // And once more, to prove it is periodic rather than a single resumed
      // repaint that happened to coincide with the write.
      backend.repo.markTransferProgress(fileId: _fileId, bytesDone: 900);
      await tester.pump(kProgressTickInterval);
      expect(
        _barValue(tester),
        closeTo(0.9, 1e-9),
        reason: 'the poll must keep ticking, not fire once on resume',
      );

      thread.dispose();
    },
  );
}
