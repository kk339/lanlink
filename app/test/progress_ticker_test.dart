/// 0.2.15 regression tests for the progress ticker's **ownership**
/// (`ConversationController`).
///
/// The reported sequence was: "退到 App 首页再重新进这个会话，会看到进度往前跳了
/// 一大截，然后又像卡住". Both halves are visible here:
///
/// * the jump is `load()` reading fresh `bytes_done` — a *new* controller is
///   built per selection (`DetailPane._reconcileConversation`);
/// * the freeze is that the new controller never started a ticker: until 0.2.15
///   the only starters were the three send brackets, so a thread that merely
///   *read* a transfer in flight never polled at all;
/// * and the stop inside `_tickProgress` was a one-way door — nothing could
///   restart the poll once a tick had found "nothing live", not even the next
///   transfer.
///
/// Like `conversation_controller_test.dart`'s ticker test, these observe
/// **notifications** in a *quiet window*: while nothing else can repaint (no
/// events, no user input), a notification can only come from the 1 Hz poll.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/domain/models.dart';

import 'support/fakes.dart';

const String _conversationId = 'c-ticker';
const String _messageId = 'm-ticker';
const String _fileId = 'f-ticker';
const int _total = 1000;

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'AAAA1111',
      alias: 'Alice',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

OutgoingFile _outgoing(String id, {int size = 100}) => OutgoingFile(
      id: id,
      fileName: '$id.bin',
      size: size,
      sha256: '00',
      localPath: '/src/$id.bin',
    );

void main() {
  late FakeBackend backend;
  late TransferOrchestrator orchestrator;

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
    orchestrator = TransferOrchestrator(
      repo: backend.repo,
      transfer: backend.transfer,
    );
  });

  tearDown(() {
    orchestrator.dispose();
    backend.dispose();
  });

  /// A controller wired exactly as `DetailPane` wires one per selection.
  ConversationController newController() => ConversationController(
        repo: backend.repo,
        orchestrator: orchestrator,
        platform: backend.platform,
        ids: backend.ids,
        clock: backend.clock,
        conversationId: _conversationId,
      );

  test(
    'a controller that merely LOADS a thread with a transfer in flight polls '
    'it (the "重新进会话 → 跳一下 → 又卡住" defect)',
    () async {
      backend.repo.addTransfer(
        const TransferProgress(
          fileId: _fileId,
          bytesDone: 100,
          bytesTotal: _total,
        ),
      );
      final ConversationController controller = newController();
      addTearDown(controller.dispose);

      int notifications = 0;
      controller.addListener(() => notifications++);

      // This is the whole re-entry path: build a controller, load it. Nothing is
      // sent from here, so under the old rules no ticker was ever started.
      await controller.load();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final int settled = notifications;
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(
        notifications,
        greaterThan(settled),
        reason: 'loading a thread with a live transfer must start the 1 Hz poll'
            ' — otherwise the bar shows the load()-time value and never moves',
      );
    },
  );

  test(
    'a poll that stopped (nothing live) is restarted by the NEXT transfer — the '
    'stop is not a one-way door',
    () async {
      // Start with a **finished** transfer: nothing live, so `load()` must leave
      // the poll off (no pointless 1 Hz work).
      backend.repo.addTransfer(
        const TransferProgress(
          fileId: _fileId,
          bytesDone: _total,
          bytesTotal: _total,
        ),
      );
      final ConversationController controller = newController();
      addTearDown(controller.dispose);

      int notifications = 0;
      controller.addListener(() => notifications++);

      await controller.load();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final int idle = notifications;
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(
        notifications,
        idle,
        reason: 'nothing in flight → no poll at all is the correct behaviour',
      );

      // A brand-new outgoing file arrives through the repository (exactly what
      // the orchestrator does at the start of a send): 0 of 100 bytes…
      //
      // **0.2.40 — this stimulus is now two steps, and the second one is the
      // real event.** Recording an outgoing message leaves it `pending` (queued
      // for an offline peer, Q9), and `pending` deliberately no longer counts as
      // "live" (`_hasLiveTransfer`): it starts no byte and paints no bar, so
      // treating it as live is what made the 1 Hz poll tick forever on a bubble
      // that never moves. The transition that *does* mean "the send started" is
      // the one `TransferOrchestrator` (and, since 0.2.40, `OutboxPump`) writes
      // immediately before `prepare`: `pending → awaitingConfirm`. That is what
      // this test must drive, otherwise it would be asserting the very
      // behaviour 0.2.40 removed.
      final SendHandle handle = backend.repo.recordOutgoing(
        peer: _peer(),
        files: <OutgoingFile>[_outgoing('f-new')],
      );
      // `pending` alone: still nothing live, so no **ongoing** poll.
      //
      // The window is measured *after* the `MessageAdded` repaint, not across
      // it: adding a row is one notification (the list changed), and it is the
      // 1 Hz ticker that must not start. Comparing against the count from before
      // the send would be asserting "no repaint at all", which is not the rule.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final int afterQueued = notifications;
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(
        notifications,
        afterQueued,
        reason: 'a queued message is not a moving transfer — it must not start '
            'the 1 Hz poll (0.2.40)',
      );

      expect(
        backend.repo.setStatus(
          messageId: handle.messageId,
          from: MessageStatus.pending,
          to: MessageStatus.awaitingConfirm,
        ),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final int afterStart = notifications;
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(
        notifications,
        greaterThan(afterStart),
        reason: 'the next transfer must re-arm the poll, otherwise a thread that '
            'ever saw "nothing live" stays frozen for its whole life',
      );
    },
  );
}
