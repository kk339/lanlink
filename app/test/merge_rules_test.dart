/// Pure unit tests for [mergeDeviceCards] (spec §4.2, acceptance A2-3/4/5).
///
/// These are plain, no-Flutter tests: the selector is pure Dart, so the test
/// only builds domain models and asserts the merge result. Nothing here touches
/// a repository, a socket or the disk.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/selectors.dart';

PeerDevice _device(
  String fingerprint, {
  String alias = 'stored',
  DeviceKind kind = DeviceKind.desktop,
  int? lastPort,
  String? lastIp,
  DateTime? lastSeen,
  String? model,
}) =>
    PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: kind,
      model: model,
      lastPort: lastPort,
      lastIp: lastIp,
      lastSeenAt: lastSeen,
    );

Conversation _conversation(
  String id,
  String? fingerprint, {
  DateTime? lastMessageAt,
  String? lastPreview,
  bool archived = false,
}) =>
    Conversation(
      id: id,
      deviceFingerprint: fingerprint,
      createdAt: DateTime(2026, 1, 1),
      lastMessageAt: lastMessageAt,
      lastPreview: lastPreview,
      isArchived: archived,
    );

DiscoveredPeer _peer(
  String fingerprint, {
  String alias = 'live',
  DeviceKind kind = DeviceKind.mobile,
  String address = '10.0.0.2',
  int port = 53317,
  DateTime? lastSeen,
}) =>
    DiscoveredPeer(
      fingerprint: fingerprint,
      alias: alias,
      kind: kind,
      address: address,
      port: port,
      isOnline: true,
      lastSeen: lastSeen ?? DateTime(2026, 1, 2, 12),
    );

void main() {
  group('mergeDeviceCards', () {
    test('a fingerprint in both memory and DB yields ONE online card (A2-3)',
        () {
      final List<PeerDevice> cards = mergeDeviceCards(
        online: <DiscoveredPeer>[
          _peer('AABB',
              alias: 'Live Name',
              kind: DeviceKind.mobile,
              address: '10.0.0.9',
              port: 53317),
        ],
        conversations: <Conversation>[
          _conversation('c1', 'AABB',
              lastMessageAt: DateTime(2026, 1, 1, 10), lastPreview: 'hello'),
        ],
        devices: <PeerDevice>[
          _device('AABB',
              alias: 'Old Name',
              kind: DeviceKind.desktop,
              lastPort: 0,
              lastIp: '10.0.0.1',
              lastSeen: DateTime(2026, 1, 1)),
        ],
      );

      expect(cards, hasLength(1));
      final PeerDevice card = cards.single;
      expect(card.isOnline, isTrue);
      expect(card.alias, 'Live Name'); // memory wins when online
      expect(card.kind, DeviceKind.mobile); // memory wins when online
      expect(card.lastPort, 53317); // memory port when online
      expect(card.lastIp, '10.0.0.9'); // memory address
      expect(card.conversationId, 'c1'); // history from DB
      expect(card.lastPreview, 'hello'); // history from DB
      expect(card.lastActivityAt, DateTime(2026, 1, 1, 10));
    });

    test('fingerprints are normalised before merging (separators/case)', () {
      final List<PeerDevice> cards = mergeDeviceCards(
        online: <DiscoveredPeer>[_peer('aa:bb:cc')],
        conversations: const <Conversation>[],
        devices: <PeerDevice>[_device('AABBCC')],
      );

      expect(cards, hasLength(1));
      expect(cards.single.fingerprint, 'AABBCC');
      expect(cards.single.isOnline, isTrue);
    });

    test('a stored device with no active conversation still gets a card', () {
      final List<PeerDevice> cards = mergeDeviceCards(
        online: const <DiscoveredPeer>[],
        conversations: const <Conversation>[],
        devices: <PeerDevice>[
          _device('DDEE',
              alias: 'Ghost',
              kind: DeviceKind.server,
              lastPort: 0,
              lastIp: '10.0.0.5'),
        ],
      );

      expect(cards, hasLength(1));
      final PeerDevice card = cards.single;
      expect(card.isOnline, isFalse);
      expect(card.alias, 'Ghost');
      expect(card.kind, DeviceKind.server);
      expect(card.conversationId, isNull);
      expect(card.hasHistory, isFalse);
      expect(card.canSend, isFalse); // last_port == 0 => sending forbidden (E6)
    });

    test('an online peer never seen in the DB still shows (A2-4)', () {
      final List<PeerDevice> cards = mergeDeviceCards(
        online: <DiscoveredPeer>[_peer('FF11', alias: 'Fresh')],
        conversations: const <Conversation>[],
        devices: const <PeerDevice>[],
      );

      expect(cards, hasLength(1));
      final PeerDevice card = cards.single;
      expect(card.isOnline, isTrue);
      expect(card.alias, 'Fresh');
      expect(card.conversationId, isNull);
      expect(card.lastPreview, isNull);
      expect(card.hasHistory, isFalse);
      expect(card.canSend, isTrue); // port > 0 => allowed
    });

    test('a history-only conversation (no device) never reaches home', () {
      final List<PeerDevice> cards = mergeDeviceCards(
        online: const <DiscoveredPeer>[],
        conversations: <Conversation>[_conversation('c9', null)],
        devices: const <PeerDevice>[],
      );

      expect(cards, isEmpty);
    });

    test('an archived conversation never reaches home (A2-5, Q8)', () {
      final List<PeerDevice> cards = mergeDeviceCards(
        online: const <DiscoveredPeer>[],
        conversations: <Conversation>[
          _conversation('c2', 'AB12',
              lastMessageAt: DateTime(2026, 1, 1), archived: true),
        ],
        devices: const <PeerDevice>[],
      );

      expect(cards, isEmpty);
    });

    test('offline conflict: alias/kind/port/ip all come from the DB', () {
      final List<PeerDevice> cards = mergeDeviceCards(
        online: const <DiscoveredPeer>[],
        conversations: <Conversation>[
          _conversation('c1', 'AB12', lastMessageAt: DateTime(2026, 1, 1, 8)),
        ],
        devices: <PeerDevice>[
          _device('AB12',
              alias: 'Stored Name',
              kind: DeviceKind.headless,
              lastPort: 53317,
              lastIp: '10.0.0.7'),
        ],
      );

      final PeerDevice card = cards.single;
      expect(card.isOnline, isFalse);
      expect(card.alias, 'Stored Name');
      expect(card.kind, DeviceKind.headless);
      expect(card.lastPort, 53317);
      expect(card.lastIp, '10.0.0.7');
    });

    test(
        'online section sorts by lastSeen desc; offline by activity desc, '
        'null last', () {
      final List<PeerDevice> cards = mergeDeviceCards(
        online: <DiscoveredPeer>[
          _peer('A1', alias: 'older', lastSeen: DateTime(2026, 1, 2, 9)),
          _peer('A2', alias: 'newer', lastSeen: DateTime(2026, 1, 2, 18)),
        ],
        conversations: <Conversation>[
          _conversation('c1', 'B1', lastMessageAt: DateTime(2026, 1, 1, 7)),
          _conversation('c2', 'B2', lastMessageAt: DateTime(2026, 1, 1, 19)),
        ],
        devices: <PeerDevice>[
          _device('B1', alias: 'b1'),
          _device('B2', alias: 'b2'),
          _device('B3', alias: 'no-history'), // lastActivityAt stays null
        ],
      );

      expect(
        cards.map((PeerDevice c) => c.alias).toList(),
        <String>['newer', 'older', 'b2', 'b1', 'no-history'],
      );
    });
  });
}
