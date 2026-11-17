/// Unit tests for [HomeController] (spec §4.1 / §4.2 / §5.1, M4 T03).
///
/// Driven entirely by [FakeBackend] — no sockets, no database and no clock
/// reads. Asserts the merge key + conflict rules (A2-3 / A2-4 / A2-5), the
/// discovery error banner (E10), the receiver toggle (P0-7) and that
/// [HomeController.init] is idempotent and runs the E2 zombie cleanup.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/home_controller.dart';
import 'package:lanlink_app/domain/models.dart';

import 'support/fakes.dart';

void main() {
  late FakeBackend backend;
  late HomeController controller;

  setUp(() {
    backend = FakeBackend.threeDevices();
    controller = HomeController(
      repo: backend.repo,
      discovery: backend.discovery,
      transfer: backend.transfer,
    );
  });

  tearDown(() {
    controller.dispose();
    backend.dispose();
  });

  test('cards is Loading before init (A2-2)', () {
    expect(controller.cards.isLoading, isTrue);
    expect(controller.cards.valueOrNull, isNull);
  });

  test(
    'init() merges devices + conversations + live peers, online first '
    '(A2-3 / A2-4)',
    () async {
      await controller.init();
      final List<PeerDevice> cards = controller.cards.valueOrNull!;
      expect(cards.length, 3);
      // The only offline card sorts last; both live peers are online.
      expect(cards.last.fingerprint, 'BBBB2222');
      expect(cards.last.isOnline, isFalse);
      expect(
        cards.take(2).map((PeerDevice d) => d.fingerprint).toSet(),
        const <String>{'AAAA1111', 'CCCC3333'},
      );
      expect(cards.take(2).every((PeerDevice d) => d.isOnline), isTrue);
    },
  );

  test(
    'a fingerprint present in both sources collapses to one card, and the live '
    'peer wins lastPort (A2-3)',
    () async {
      // Explicit, self-contained scenario: the stored row and the live peer
      // disagree on the port, so "which one wins" is observable *without*
      // depending on any shared fixture's incidental value. The stored value
      // must survive only if the merge is broken; the live value must win.
      const int storedPort = 40000;
      const int livePort = 53317;
      final FakeBackend local = FakeBackend(
        devices: <PeerDevice>[
          const PeerDevice(
            fingerprint: 'CCCC3333',
            alias: 'Carol Desktop',
            kind: DeviceKind.desktop,
            lastPort: storedPort,
          ),
        ],
        online: <DiscoveredPeer>[
          DiscoveredPeer(
            fingerprint: 'CCCC3333',
            alias: 'Carol Desktop',
            kind: DeviceKind.desktop,
            address: '192.168.1.10',
            port: livePort,
            isOnline: true,
            lastSeen: DateTime.utc(2026, 1, 1, 12),
          ),
        ],
      );
      addTearDown(local.dispose);
      final HomeController localController = HomeController(
        repo: local.repo,
        discovery: local.discovery,
        transfer: local.transfer,
      );
      addTearDown(localController.dispose);

      await localController.init();

      final List<PeerDevice> cards = localController.cards.valueOrNull!;
      final List<PeerDevice> carol =
          cards.where((PeerDevice d) => d.fingerprint == 'CCCC3333').toList();
      expect(carol.length, 1, reason: 'both sources collapse to one card');
      expect(carol.single.lastPort, livePort, reason: 'the live peer wins');
      expect(carol.single.lastPort, isNot(storedPort));
      expect(carol.single.isDialable, isTrue);
      expect(carol.single.isOnline, isTrue);
    },
  );

  test(
    'archived and device-less conversations never reach the home list (A2-5)',
    () async {
      await controller.init();
      backend.repo.addConversation(
        id: 'c-archived',
        deviceFingerprint: 'DEAD0001',
        createdAt: backend.clock.nowUtc(),
        lastMessageAt: backend.clock.nowUtc(),
        isArchived: true,
      );
      backend.repo.addConversation(
        id: 'c-active',
        deviceFingerprint: 'BEEF0002',
        createdAt: backend.clock.nowUtc(),
        lastMessageAt: backend.clock.nowUtc(),
      );
      backend.repo.addConversation(
        id: 'c-local',
        createdAt: backend.clock.nowUtc(),
        lastMessageAt: backend.clock.nowUtc(),
      );
      await controller.rescan();

      final Set<String> fingerprints = controller.cards.valueOrNull!
          .map((PeerDevice d) => d.fingerprint)
          .toSet();
      expect(fingerprints.contains('DEAD0001'), isFalse);
      expect(fingerprints.contains('BEEF0002'), isTrue);
      expect(controller.cards.valueOrNull!.length, 4);
    },
  );

  test(
    'a discovery failure surfaces the error banner; clearError() dismisses it '
    '(E10)',
    () async {
      await controller.init();
      expect(controller.error, isNull);

      backend.discovery.fail('TCP 端口被占用');
      await pumpEventQueue();
      expect(controller.error, 'TCP 端口被占用');

      controller.clearError();
      expect(controller.error, isNull);
    },
  );

  test(
    'accepting mirrors TransferService.accepting (read-only) (P0-7)',
    () async {
      await controller.init();
      // 0.2.25: the fake boots the receiver the way production does
      // (`acceptUploads: settings.acceptByDefault`, default on), so the mirror
      // starts `true`. Both directions are asserted — a getter that returned a
      // constant would pass a one-way check.
      expect(controller.accepting, isTrue);
      // The single write entry is `SettingsController.setAccepting`; the home
      // controller only *mirrors* the receiver (the legacy non-persisting shim
      // was removed in T05).
      await backend.transfer.setAccepting(false);
      expect(controller.accepting, isFalse);
      await backend.transfer.setAccepting(true);
      expect(controller.accepting, isTrue);
    },
  );

  test(
    'a refused inbound request leaves a notice; clearTransferNotice() clears it '
    '(P0-7 follow-up)',
    () async {
      await controller.init();
      expect(controller.transferNotice, isNull);

      backend.transfer.emitUploadRejected(
        UploadRejected(
          peer: DiscoveredPeer(
            fingerprint: 'AAAA1111',
            alias: 'Alice Laptop',
            kind: DeviceKind.desktop,
            address: '192.168.1.20',
            port: 53317,
            isOnline: true,
            lastSeen: backend.clock.nowUtc(),
          ),
          reason: InboundRejectReason.acceptingDisabled,
        ),
      );
      await pumpEventQueue();

      final UploadRejected? notice = controller.transferNotice;
      expect(notice, isNotNull);
      expect(notice!.reason, InboundRejectReason.acceptingDisabled);
      expect(notice.peer?.alias, 'Alice Laptop');

      controller.clearTransferNotice();
      expect(controller.transferNotice, isNull);
    },
  );

  test('init() is idempotent and runs the E2 zombie cleanup', () async {
    final Conversation conversation =
        backend.repo.addConversation(id: 'c-x', deviceFingerprint: 'AAAA1111');
    backend.repo.addMessage(
      id: 'm-zombie',
      conversationId: conversation.id,
      direction: MessageDirection.outgoing,
      status: MessageStatus.transferring,
    );

    await controller.init();
    final int cardsAfterFirst = controller.cards.valueOrNull!.length;
    await controller.init(); // The second call must be a no-op.
    expect(controller.cards.valueOrNull!.length, cardsAfterFirst);

    expect(
      backend.repo
          .messagesByStatus(const <MessageStatus>{MessageStatus.transferring}),
      isEmpty,
    );
    expect(
      backend.repo
          .messagesByStatus(const <MessageStatus>{MessageStatus.failed}).map(
              (ChatMessage m) => m.id),
      contains('m-zombie'),
    );
  });
}
