/// 0.2.22 — "取消 must actually cancel", and "永远转圈 must have an end".
///
/// Both defects had the same shape: **the capability existed and was never
/// wired**. `TransferService.cancel` had zero callers in the whole app while the
/// bubble drew 取消 on three states; `ConversationController.cancel` returned
/// `false` for two of them and `conversation_thread` threw the answer away. The
/// result the user saw: tap 取消 on a 传输中 bubble → nothing, no message, no
/// change, percentage frozen — because a peer that loses Wi-Fi without a RST
/// leaves `await client.upload()` hanging until the OS keepalive gives up.
///
/// These tests are written to **catch the regression**, not to describe the
/// implementation: each one asserts a state the user could observe (what the row
/// says, whether the abort reached the transport, whether a second status write
/// ever lands).
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/transfer_service.dart';

import 'support/fakes.dart';

PeerDevice _peer({
  String fingerprint = 'AAAA1111',
  bool online = true,
  int? port = 53317,
}) =>
    PeerDevice(
      fingerprint: fingerprint,
      alias: 'Alice',
      kind: DeviceKind.desktop,
      isOnline: online,
      lastPort: port,
    );

OutgoingFile _outgoing(String id, {int size = 100}) => OutgoingFile(
      id: id,
      fileName: '$id.bin',
      size: size,
      sha256: '00',
      localPath: '/src/$id.bin',
    );

/// A [Timer] that never fires on its own.
///
/// The supervisor is driven by an injected [PeriodicTimerFactory] plus the
/// injected [FixedClock], so "30 seconds with no progress" is a `clock.advance`
/// and a [pulse] — no sleeping, and the same code path production runs.
class _ManualTimer implements Timer {
  final int _ticks = 0;
  bool _active = true;

  @override
  int get tick => _ticks;

  @override
  bool get isActive => _active;

  @override
  void cancel() => _active = false;
}

/// Captures every timer the supervisor creates and fires them on demand.
class _ManualClockwork {
  final List<({_ManualTimer timer, void Function(Timer) callback})> _timers =
      <({_ManualTimer timer, void Function(Timer) callback})>[];

  /// The factory to hand to [TransferOrchestrator.periodicTimer].
  Timer factory(Duration interval, void Function(Timer) callback) {
    final _ManualTimer timer = _ManualTimer();
    _timers.add((timer: timer, callback: callback));
    return timer;
  }

  /// How many timers were created and never cancelled (a leak check).
  int get liveTimers => _timers.where((t) => t.timer.isActive).length;

  /// Fires every still-active timer once, in creation order.
  void pulse() {
    for (final ({_ManualTimer timer, void Function(Timer) callback}) entry
        in List<({_ManualTimer timer, void Function(Timer) callback})>.of(
            _timers)) {
      if (entry.timer.isActive) {
        entry.callback(entry.timer);
      }
    }
  }
}

void main() {
  late FakeBackend backend;
  late TransferOrchestrator orchestrator;
  late ConversationController controller;
  late _ManualClockwork clockwork;
  late String conversationId;

  setUp(() {
    backend = FakeBackend(
      devices: <PeerDevice>[_peer()],
      online: <DiscoveredPeer>[
        DiscoveredPeer(
          fingerprint: 'AAAA1111',
          alias: 'Alice',
          kind: DeviceKind.desktop,
          address: '192.168.1.10',
          port: 53317,
          isOnline: true,
          lastSeen: fixedEpoch,
        ),
      ],
    );
    conversationId = backend.repo
        .addConversation(id: 'c-1', deviceFingerprint: 'AAAA1111')
        .id;
    clockwork = _ManualClockwork();
    orchestrator = TransferOrchestrator(
      repo: backend.repo,
      transfer: backend.transfer,
      // The same FixedClock the fake backend shares, so `advance` is the only
      // way time moves.
      clock: backend.clock,
      periodicTimer: clockwork.factory,
    );
    controller = ConversationController(
      repo: backend.repo,
      orchestrator: orchestrator,
      platform: backend.platform,
      ids: backend.ids,
      clock: backend.clock,
      conversationId: conversationId,
    );
  });

  tearDown(() {
    controller.dispose();
    orchestrator.dispose();
    backend.dispose();
  });

  /// The one visible message of this thread.
  ChatMessage onlyMessage() => controller.messages.valueOrNull!.single;

  // ── 判据 1：transferring 取消真的能取消 ──────────────────────────────────

  test(
    'cancel() on a TRANSFERRING message: the abort reaches the transport with '
    'the right peer + sessionId, the row leaves 传输中, and the send does not '
    'come back as done/failed',
    () async {
      await controller.load();
      final Completer<void> hold = Completer<void>();
      backend.transfer.holdNextUpload(hold);

      final Future<SendOutcome> sending = orchestrator.send(
        peer: _peer(),
        files: <OutgoingFile>[_outgoing('a')],
      );
      await pumpEventQueue();

      expect(
        onlyMessage().status,
        MessageStatus.transferring,
        reason: 'the upload is held, so the row must be sitting in 传输中 — this '
            'is the exact frame the user is looking at when they tap 取消',
      );

      final CancelResult result = await controller.cancel(onlyMessage());
      await pumpEventQueue();

      expect(result.wasCanceled, isTrue);
      expect(result.notice, '已取消');
      expect(
        onlyMessage().status,
        MessageStatus.canceled,
        reason: 'the bubble must leave 传输中 — this is the whole report',
      );
      expect(
        backend.transfer.cancelledSessions,
        <String>[backend.transfer.preparedSessions.single],
        reason: 'the peer must be told to drop the session the bytes were '
            'actually going to',
      );
      expect(
        backend.transfer.cancels.single.peer.fingerprint,
        'AAAA1111',
        reason: 'the abort must target the peer being streamed to',
      );

      final SendOutcome outcome = await sending;
      await pumpEventQueue();
      expect(outcome.canceled, isTrue);
      expect(outcome.error, isNull);
      expect(
        onlyMessage().status,
        MessageStatus.canceled,
        reason: 'the tail of the send must not overwrite 已取消 with done/failed',
      );
    },
  );

  // ── 判据 2：awaitingConfirm 取消 ────────────────────────────────────────

  test(
    'cancel() on an AWAITINGCONFIRM message: leaves the state, no session to '
    'announce yet, and the late prepare reply does not resurrect the send',
    () async {
      await controller.load();
      final Completer<void> hold = Completer<void>();
      backend.transfer.holdNextPrepare(hold);

      final Future<SendOutcome> sending = orchestrator.send(
        peer: _peer(),
        files: <OutgoingFile>[_outgoing('a')],
      );
      await pumpEventQueue();
      expect(onlyMessage().status, MessageStatus.awaitingConfirm);

      final CancelResult result = await controller.cancel(onlyMessage());
      await pumpEventQueue();

      expect(result.wasCanceled, isTrue);
      expect(onlyMessage().status, MessageStatus.canceled);
      expect(
        backend.transfer.cancels,
        isEmpty,
        reason: 'no session id exists yet, so there is nothing to announce — the '
            'peer drops it on its own timeout instead',
      );

      // Let the peer finally answer: the send must stop there, not walk on to
      // `transferring` and stream the whole file for a cancelled message.
      hold.complete();
      final SendOutcome outcome = await sending;
      await pumpEventQueue();

      expect(outcome.canceled, isTrue);
      expect(onlyMessage().status, MessageStatus.canceled);
    },
  );

  // ── 判据 4：没有进展的超时 ───────────────────────────────────────────────

  test(
    'no byte progress for 30 s → failed with 连接中断, the transport is aborted, '
    'and the supervisor stops (a further 60 s changes nothing)',
    () async {
      await controller.load();
      final Completer<void> hold = Completer<void>();
      backend.transfer.holdNextUpload(hold);

      final Future<SendOutcome> sending = orchestrator.send(
        peer: _peer(),
        files: <OutgoingFile>[_outgoing('a')],
      );
      await pumpEventQueue();
      expect(onlyMessage().status, MessageStatus.transferring);

      // The socket is half-open: nothing arrives, nothing throws. 29 s is still
      // "alive" — the watchdog must give the link the full window.
      backend.clock.advance(const Duration(seconds: 29));
      clockwork.pulse();
      await pumpEventQueue();
      expect(
        onlyMessage().status,
        MessageStatus.transferring,
        reason: 'a slow-but-alive link must not be killed early (see also the '
            '5 s healthy-transfer test)',
      );

      // 30 s without a single byte → dead.
      backend.clock.advance(const Duration(seconds: 1));
      clockwork.pulse();
      await pumpEventQueue();

      expect(onlyMessage().status, MessageStatus.failed);
      expect(
        backend.repo.transferOf('a'),
        isNotNull,
        reason: 'the transfer row is what the ticker reads to decide it can stop',
      );
      expect(backend.repo.transferOf('a')!.error, kStalledError);
      expect(
        backend.transfer.cancels.single.sessionId,
        backend.transfer.preparedSessions.single,
        reason: 'a stalled send must be aborted, not merely marked dead — the '
            'socket is still open',
      );
      expect(
        clockwork.liveTimers,
        0,
        reason: 'the supervisor must be stopped, not merely ignored',
      );

      final SendOutcome outcome = await sending;
      await pumpEventQueue();
      expect(outcome.ok, isFalse);
      expect(outcome.error, kStalledError);
      expect(outcome.canceled, isFalse);

      // 60 more seconds: the timer is gone, so nothing can fire and no second
      // status write may land (the store rejects `failed → failed`).
      backend.clock.advance(const Duration(seconds: 60));
      clockwork.pulse();
      await pumpEventQueue();
      expect(onlyMessage().status, MessageStatus.failed);
      expect(backend.transfer.cancels.length, 1);
    },
  );

  // ── 判据 5：正常慢速传输不能被误杀 ──────────────────────────────────────

  test(
    'a healthy 5 s transfer (a progress callback every 200 ms) is NOT killed by '
    'the stall supervisor',
    () async {
      await controller.load();
      // 25 callbacks × 200 ms = 5 s of wall time, with the supervisor ticking
      // throughout: this is the slow-but-alive link the watchdog must leave
      // alone.
      backend.transfer.reportProgressInBurst(
        count: 25,
        onStep: () {
          backend.clock.advance(const Duration(milliseconds: 200));
          clockwork.pulse();
        },
      );

      final SendOutcome outcome = await orchestrator.send(
        peer: _peer(),
        files: <OutgoingFile>[_outgoing('a')],
      );
      await pumpEventQueue();

      expect(outcome.ok, isTrue);
      expect(onlyMessage().status, MessageStatus.done);
      expect(backend.transfer.cancels, isEmpty);
      expect(clockwork.liveTimers, 0);
    },
  );

  // ── 判据 6：取消后可以重新发送 ──────────────────────────────────────────

  test(
    'after a cancel the message offers a re-send, and re-sending records a NEW '
    'message (never a retry of the cancelled one)',
    () async {
      await controller.load();
      final Completer<void> hold = Completer<void>();
      backend.transfer.holdNextUpload(hold);

      final Future<SendOutcome> sending = orchestrator.send(
        peer: _peer(),
        files: <OutgoingFile>[_outgoing('a')],
      );
      await pumpEventQueue();
      await controller.cancel(onlyMessage());
      await sending;
      await pumpEventQueue();

      final ChatMessage canceled = onlyMessage();
      expect(canceled.status, MessageStatus.canceled);
      backend.platform.setExists('/src/a.bin', true);
      expect(
        await controller.canResend(canceled),
        isTrue,
        reason: '"I cancelled it, now send it" must be possible; before 0.2.22 '
            'canResend only accepted failed, so the bubble was a dead end',
      );

      await controller.resend(peer: _peer(), message: canceled);
      await pumpEventQueue();

      final List<ChatMessage> history = backend.repo.history(conversationId);
      expect(history.length, 2);
      expect(history.last.id, isNot(canceled.id));
      expect(history.last.status, MessageStatus.done);
    },
  );

  // ── 判据 1/2 的反面：不允许静默 ─────────────────────────────────────────

  test('cancel() on a state that cannot be cancelled says why (never silent)',
      () async {
    backend.repo.addMessage(
      id: 'm-done',
      conversationId: conversationId,
      direction: MessageDirection.outgoing,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
      files: <FileAttachment>[
        const FileAttachment(
          id: 'f-done',
          messageId: 'm-done',
          fileName: 'a.bin',
          size: 5,
          sha256: '00',
          localPath: '/src/a.bin',
        ),
      ],
    );
    await controller.load();

    final CancelResult result = await controller.cancel(onlyMessage());
    expect(result.wasCanceled, isFalse);
    expect(result.notice, isNotEmpty);
    expect(result.notice, isNot('已取消'));
    expect(onlyMessage().status, MessageStatus.done);
  });
}
