/// The queued-message note must never become a dead end (0.2.40).
///
/// The bug this guards: the note's condition was
/// `status == pending && !peer.isOnline`, so **the moment the peer came online
/// the explanation disappeared** while the status stayed `pending` — a bubble
/// showing a bare 「排队中」 with no reason and no button (`_actions` draws
/// 重新发送 only for `failed` / `canceled`). That is literally the user's
/// *"就一直排队"*, made worse by the sentence vanishing.
///
/// The queue now drains itself, so a reachable peer means "about to go" — the
/// note has to say that rather than say nothing.
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

const String _kOfflineNote = '对方离线，排队等待上传';
const String _kOnlineNote = '即将发送…';

/// 0.2.48 — the peer is visible but has **no inbound server** (`lastPort == 0`).
///
/// The pump deliberately does not drive that card (`OutboxPump._pass` skips
/// `!isDialable || !canSend`), so the message stays `pending` for good. The old
/// line still promised 「即将发送…」 — a sentence the app could never keep, printed
/// next to a composer saying 「对方当前不可接收」.
const String _kNotReceivableNote = '对方暂时收不了，等它可接收后再发';

PeerDevice _peer({required bool online, int? lastPort = 53317}) => PeerDevice(
      fingerprint: 'CC01',
      alias: '小甲',
      kind: DeviceKind.desktop,
      isOnline: online,
      lastPort: lastPort,
    );

/// The mounted thread plus the controller that owns it.
///
/// The controller is handed back rather than registered for teardown because a
/// `pending` row keeps the 1 Hz progress ticker alive (`_hasLiveTransfer` treats
/// "not terminal" as live — see the note in the report), and a live `Timer` after
/// the body returns fails `flutter_test`'s invariant check. Every test therefore
/// ends with [disposeThread]; `addTearDown` would run too late.
typedef MountedThread = ({FakeBackend backend, ConversationController controller});

/// Mounts one conversation holding a single message with [status].
///
/// The attachment has a `localPath`, so a `pending` row is a *resumable* queue
/// entry — the shape the reported bug is about.
Future<MountedThread> _mount(
  WidgetTester tester, {
  required MessageStatus status,
  required bool peerOnline,
  int? lastPort = 53317,
}) async {
  useSurfaceSize(tester, const Size(600, 1200));
  final FakeBackend backend = FakeBackend();
  backend.repo.addConversation(
    id: 'c-1',
    deviceFingerprint: 'CC01',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.repo.addMessage(
    id: 'm-1',
    conversationId: 'c-1',
    direction: MessageDirection.outgoing,
    status: status,
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
    files: <FileAttachment>[
      FileAttachment(
        id: 'f1',
        messageId: 'm-1',
        fileName: 'notes.txt',
        size: 12,
        sha256: 'AA',
        localPath: '/d/notes.txt',
      ),
    ],
  );
  final ConversationController controller = ConversationController(
    repo: backend.repo,
    orchestrator:
        TransferOrchestrator(repo: backend.repo, transfer: backend.transfer),
    platform: backend.platform,
    ids: backend.ids,
    clock: backend.clock,
    conversationId: 'c-1',
    drafts: ComposerDraftStore(),
  );
  unawaited(controller.load());
  await pumpApp(
    tester,
    Scaffold(
      body: ConversationThread(
        controller: controller,
        peer: _peer(online: peerOnline, lastPort: lastPort),
      ),
    ),
    backend: backend,
    settle: true,
  );
  return (backend: backend, controller: controller);
}

/// Unmounts and disposes, in that order, so no timer outlives the tree.
Future<void> _disposeThread(WidgetTester tester, MountedThread mounted) async {
  await tester.pumpWidget(const SizedBox.shrink());
  mounted.controller.dispose();
  mounted.backend.dispose();
}

void main() {
  testWidgets('an offline peer: the queued message says why it waits',
      (WidgetTester tester) async {
    final MountedThread mounted =
        await _mount(tester, status: MessageStatus.pending, peerOnline: false);

    expect(find.text(_kOfflineNote), findsOneWidget);
    expect(find.text(_kOnlineNote), findsNothing);

    await _disposeThread(tester, mounted);
  });

  testWidgets('the peer is online: the note stays, and explains the wait',
      (WidgetTester tester) async {
    final MountedThread mounted =
        await _mount(tester, status: MessageStatus.pending, peerOnline: true);

    // The old code rendered **nothing** here — a bare 排队中 chip with no reason
    // and no action, which is the reported "就一直排队".
    expect(find.text(_kOnlineNote), findsOneWidget);
    expect(find.text(_kOfflineNote), findsNothing);

    await _disposeThread(tester, mounted);
  });

  testWidgets('a message that is not queued never gets the note',
      (WidgetTester tester) async {
    final MountedThread mounted =
        await _mount(tester, status: MessageStatus.done, peerOnline: false);

    expect(find.text(_kOfflineNote), findsNothing);
    expect(find.text(_kOnlineNote), findsNothing);
    expect(find.text(_kNotReceivableNote), findsNothing);

    await _disposeThread(tester, mounted);
  });

  testWidgets(
      '★ 0.2.48: an online peer with NO inbound server — the note must not promise '
      'a send the pump will never make', (WidgetTester tester) async {
    final MountedThread mounted = await _mount(
      tester,
      status: MessageStatus.pending,
      peerOnline: true,
      lastPort: 0,
    );

    // Before this change the line read 「即将发送…」, and it was a lie: the pump
    // skips a card whose `canSend` / `isDialable` is false (`outbox_pump.dart`,
    // `!card.canSend → continue`), so the message was never going to move.
    expect(find.text(_kOnlineNote), findsNothing);
    expect(find.text(_kNotReceivableNote), findsOneWidget);
    // …and it must not contradict the composer, which says the same thing in its
    // own words for the same peer state.
    expect(find.text('对方当前不可接收'), findsOneWidget);

    await _disposeThread(tester, mounted);
  });

  testWidgets(
      '★ 0.2.48: online but not yet *dialable* (no port seen) is the same third '
      'state — the pump skips it too', (WidgetTester tester) async {
    final MountedThread mounted = await _mount(
      tester,
      status: MessageStatus.pending,
      peerOnline: true,
      lastPort: null,
    );

    expect(find.text(_kOnlineNote), findsNothing);
    expect(find.text(_kNotReceivableNote), findsOneWidget);

    await _disposeThread(tester, mounted);
  });
}
