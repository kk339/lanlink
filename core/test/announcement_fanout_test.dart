import 'dart:io';
import 'dart:typed_data';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// One announce cycle must cover **both** legs, with the byte-identical frame,
/// and a device seen twice must still be one device (docs/21 §2.1, criteria 1
/// and 3).
///
/// The datagrams are captured through the injected [AnnouncementSender], which
/// is what makes the fan-out assertable: no sockets are opened, so the
/// destinations are pinned exactly instead of being inferred from a real NIC
/// set.
void main() {
  const int announcePort = kDefaultPort;

  DeviceInfo self(String alias, String fingerprint) => DeviceInfo(
        alias: alias,
        fingerprint: fingerprint,
        port: announcePort,
        deviceType: DeviceType.desktop,
      );

  /// One /24 private interface — the shape almost every LAN has.
  List<BroadcastTarget> oneInterface() => <BroadcastTarget>[
        BroadcastTarget(
          interfaceName: 'WLAN',
          address: InternetAddress('192.168.1.37'),
          prefixLength: 24,
        ),
      ];

  group('announce fan-out', () {
    late List<SentDatagram> sent;

    MulticastDiscovery build({
      bool multicastEnabled = true,
      bool broadcastEnabled = true,
      List<BroadcastTarget>? targets,
    }) {
      return MulticastDiscovery(
        deviceInfo: self('announcer', uppercaseFingerprint('announcer')),
        port: announcePort,
        multicastEnabled: multicastEnabled,
        broadcastEnabled: broadcastEnabled,
        sender: (Uint8List bytes, InternetAddress target, int port) =>
            sent.add(SentDatagram(bytes, target, port)),
        broadcastTargetsProvider: () async => targets ?? oneInterface(),
      );
    }

    setUp(() async {
      sent = <SentDatagram>[];
    });

    /// Arms the fan-out and emits one cycle, so a test only has to assert.
    Future<MulticastDiscovery> arm(MulticastDiscovery value) async {
      await value.prepareBroadcast();
      value.announce();
      // Registered per test: a failure before this point cannot leave a timer
      // running into the next test.
      addTearDown(value.stop);
      return value;
    }

    test('one cycle sends at least one 224.0.0.x multicast and at least one '
        '255.255.255.255 broadcast', () async {
      await arm(build());

      final multicasts = sent
          .where((d) => d.target.address == kMulticastGroup)
          .toList(growable: false);
      final limitedBroadcasts = sent
          .where((d) =>
              d.target.address == '255.255.255.255' && d.port == announcePort)
          .toList(growable: false);

      expect(multicasts, hasLength(1),
          reason: 'the multicast leg must still be sent exactly once');
      expect(limitedBroadcasts, isNotEmpty,
          reason: 'the broadcast leg must be sent in the same cycle');

      // The whole point of the address change: only 224.0.0.0/24 carries the
      // RFC 4541 §2.1.2 "forward out of every port" exemption.
      expect(kMulticastGroup, startsWith('224.0.0.'));
      expect(multicasts.single.port, announcePort);

      // The directed broadcast is the more reliable of the two, because
      // `255.255.255.255` is dropped by some drivers.
      expect(sent.map((d) => d.target.address), contains('192.168.1.255'));
    });

    test('every datagram carries the identical frame', () async {
      await arm(build());

      expect(sent.length, greaterThan(1));
      final Uint8List first = sent.first.bytes;
      for (final SentDatagram datagram in sent) {
        expect(datagram.bytes, equals(first),
            reason: 'a receiver must not be able to tell the legs apart by '
                'content — only by the source port');
      }
      final Announcement? decoded = Announcement.tryDecode(first);
      expect(decoded, isNotNull);
      expect(decoded!.info.alias, 'announcer');
    });

    test('a second cycle sends the same destinations again (same cadence)',
        () async {
      final MulticastDiscovery discovery = await arm(build());
      final int afterFirst = sent.length;
      discovery.announce();
      expect(sent.length, afterFirst * 2,
          reason: 'the broadcast leg must not add a cadence of its own — both '
              'legs ride the same announce interval');
    });

    test('the broadcast leg can be switched off', () async {
      await arm(build(broadcastEnabled: false));

      expect(sent.map((d) => d.target.address), isNot(contains('255.255.255.255')));
      expect(sent.map((d) => d.target.address), isNot(contains('192.168.1.255')));
      expect(sent, hasLength(1));
    });

    test('the multicast leg can be switched off — broadcast alone remains',
        () async {
      await arm(build(multicastEnabled: false));

      expect(sent.map((d) => d.target.address), isNot(contains(kMulticastGroup)));
      expect(sent.map((d) => d.target.address), contains('255.255.255.255'));
    });

    test('two interfaces produce two broadcast targets', () async {
      await arm(build(targets: <BroadcastTarget>[
        BroadcastTarget(
          interfaceName: 'WLAN',
          address: InternetAddress('192.168.1.37'),
          prefixLength: 24,
        ),
        BroadcastTarget(
          interfaceName: 'Ethernet',
          address: InternetAddress('10.0.0.5'),
          prefixLength: 8,
        ),
      ]));

      // 255.255.255.255 once per interface: a broadcast to the limited address
      // only leaves the NIC the sending socket is bound to.
      expect(
        sent.where((d) => d.target.address == '255.255.255.255').length,
        2,
      );
      expect(sent.map((d) => d.target.address), contains('192.168.1.255'));
      expect(sent.map((d) => d.target.address), contains('10.255.255.255'));
      expect(sent.map((d) => d.target.address), contains('10.0.0.255'));
    });
  });

  group('de-duplication across legs', () {
    test('a device heard on both legs is one device, and one PeerAdded',
        () async {
      final sent = <SentDatagram>[];
      final discovery = MulticastDiscovery(
        deviceInfo: self('listener', uppercaseFingerprint('listener')),
        port: announcePort,
        sender: (Uint8List bytes, InternetAddress target, int port) =>
            sent.add(SentDatagram(bytes, target, port)),
        broadcastTargetsProvider: () async => oneInterface(),
      );
      await discovery.prepareBroadcast();
      discovery.announce();
      await discovery.stop();

      final registry = PeerRegistry();
      final List<PeerEvent> events = <PeerEvent>[];
      final subscription = registry.events.listen(events.add);
      final DateTime now = DateTime.utc(2026, 10, 23, 12);

      // Feed every datagram through the same path a real receiver would take.
      for (final SentDatagram datagram in sent) {
        final Announcement announcement = Announcement.tryDecode(datagram.bytes)!;
        final PeerSource source = datagram.target.address == kMulticastGroup
            ? PeerSource.multicast
            : PeerSource.broadcast;
        registry.touch(
          announcement.info,
          address: '192.168.1.37',
          source: source,
          now: now,
        );
      }
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(registry.length, 1,
          reason: 'both legs carry the same fingerprint — one device');
      expect(registry.all.single.lastSource, PeerSource.broadcast,
          reason: 'the last leg seen wins, which is how the UI/log shows '
              '"broadcast carried this one"');
      expect(events.whereType<PeerAdded>(), hasLength(1));
      await registry.dispose();
    });

    test('a leg maps to a registry source without losing the distinction', () {
      expect(AnnouncementTransport.multicast.peerSource, PeerSource.multicast);
      expect(AnnouncementTransport.broadcast.peerSource, PeerSource.broadcast);
      // Unknown must stay usable rather than throwing: it is what an
      // unattributable datagram reports.
      expect(AnnouncementTransport.unknown.peerSource, PeerSource.multicast);
    });
  });
}

/// A captured datagram: the bytes, the destination and the port.
class SentDatagram {
  const SentDatagram(this.bytes, this.target, this.port);

  final Uint8List bytes;
  final InternetAddress target;
  final int port;

  @override
  String toString() => 'SentDatagram(${target.address}:$port)';
}

/// A 64-char hex fingerprint derived from [seed], so tests do not hand-copy one.
String uppercaseFingerprint(String seed) {
  final StringBuffer buffer = StringBuffer();
  var value = seed.hashCode & 0x7fffffff;
  while (buffer.length < 64) {
    value = (value * 1103515245 + 12345) & 0x7fffffff;
    buffer.write(value.toRadixString(16).padLeft(8, '0'));
  }
  return buffer.toString().substring(0, 64).toUpperCase();
}
