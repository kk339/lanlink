import 'dart:async';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// **The core proof of 0.2.34**: the subnet-broadcast leg works on its own.
///
/// The sender instance is built with `multicastEnabled: false`, so it never
/// joins the group and never emits a multicast datagram — the only way its
/// announcement can reach the listener is the broadcast leg. That is exactly
/// the situation on a network where a snooping switch or a firewall rule drops
/// our multicast, which is why this test exists (docs/21 §2.1, criterion 2).
///
/// Both instances live in one process on one UDP port. They cannot both bind
/// `anyIPv4:port` meaningfully, so the sender is a **pure announcer**
/// (`listen: false`) and opens no receive socket at all — which is a stronger
/// isolation than "two different ports" would be, because it removes the shared
/// socket instead of hiding it behind `SO_REUSEADDR`.
void main() {
  const int port = 49513;

  DeviceInfo info(String alias, String fingerprint) => DeviceInfo(
        alias: alias,
        fingerprint: fingerprint,
        port: port,
        deviceType: DeviceType.desktop,
      );

  test('a broadcast-only announcer is discovered by a listener that has '
      'multicast enabled but receives no multicast', () async {
    final List<BroadcastTarget> targets = await listBroadcastTargets();
    if (targets.isEmpty) {
      markTestSkipped('no private IPv4 interface on this host');
      return;
    }

    final Completer<Received> received = Completer<Received>();
    final List<String> listenerLog = <String>[];
    final List<String> senderLog = <String>[];

    final MulticastDiscovery listener = MulticastDiscovery(
      deviceInfo: info('listener', 'B' * 64),
      port: port,
      // It joins the group so a stray multicast *would* be seen; the sender is
      // configured never to send one, so anything that arrives came over
      // broadcast — and the transport below says so explicitly.
      multicastEnabled: true,
      // The listener must not announce: its own broadcast would be a second
      // variable in a test about the sender's leg.
      broadcastEnabled: false,
      announceInterval: const Duration(seconds: 30),
      onLog: listenerLog.add,
      onPeer: (DeviceInfo peer, String sourceAddress,
          AnnouncementTransport transport) {
        if (!received.isCompleted) {
          received.complete(Received(peer, sourceAddress, transport));
        }
      },
    );

    final MulticastDiscovery sender = MulticastDiscovery(
      deviceInfo: info('sender', 'C' * 64),
      port: port,
      // The leg under test: broadcast only.
      multicastEnabled: false,
      broadcastEnabled: true,
      // No receive socket: this instance only speaks.
      listen: false,
      // Re-announce often so a single lost datagram cannot fail the test; the
      // first cycle is already sent from `start()`.
      announceInterval: const Duration(milliseconds: 300),
      onLog: senderLog.add,
    );

    await listener.start();
    await sender.start();
    addTearDown(() async {
      await sender.stop();
      await listener.stop();
    });

    final Received result;
    try {
      result = await received.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      fail('no broadcast announcement arrived within 10s.\n'
          'sender log:\n  ${senderLog.join('\n  ')}\n'
          'listener log:\n  ${listenerLog.join('\n  ')}');
    }

    expect(result.peer.alias, 'sender');
    expect(result.peer.fingerprint, 'C' * 64);
    // The source address is the sender's own interface address, i.e. it really
    // travelled over the wire rather than being faked locally.
    expect(targets.map((BroadcastTarget t) => t.addressText),
        contains(result.sourceAddress));
    // The marker port: the sender's broadcast socket is bound to
    // `port + kBroadcastSourcePortOffset`, which is how a receiver that cannot
    // read a datagram's destination address still names the leg.
    expect(result.transport, AnnouncementTransport.broadcast,
        reason: 'the leg must be attributable, otherwise the firewall test '
            'cannot tell whether multicast or broadcast carried the peer');
  }, timeout: const Timeout(Duration(seconds: 30)));

  // Symmetry check: a **multicast-only** announcer is attributed to the
  // multicast leg. Without it, "everything is broadcast" would pass the test
  // above — and the leg name would be worthless in the firewall test.
  test('a multicast-only announcer is attributed to the multicast leg',
      () async {
    const int multicastPort = 49530;
    final Completer<Received> received = Completer<Received>();

    final MulticastDiscovery listener = MulticastDiscovery(
      deviceInfo: info('listener', 'F' * 64).copyWith(port: multicastPort),
      port: multicastPort,
      multicastEnabled: true,
      broadcastEnabled: false,
      announceInterval: const Duration(seconds: 30),
      onPeer: (DeviceInfo peer, String sourceAddress,
          AnnouncementTransport transport) {
        if (!received.isCompleted) {
          received.complete(Received(peer, sourceAddress, transport));
        }
      },
    );
    final MulticastDiscovery multicastOnly = MulticastDiscovery(
      deviceInfo: info('multicaster', 'G' * 64).copyWith(port: multicastPort),
      port: multicastPort,
      multicastEnabled: true,
      broadcastEnabled: false,
      listen: false,
      announceInterval: const Duration(milliseconds: 300),
    );

    await listener.start();
    await multicastOnly.start();
    addTearDown(() async {
      await multicastOnly.stop();
      await listener.stop();
    });

    final Received result;
    try {
      result = await received.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      fail('no multicast announcement arrived within 10s — on a host with no '
          'multicast route this check cannot run');
    }

    expect(result.peer.alias, 'multicaster');
    expect(result.transport, AnnouncementTransport.multicast);
  }, timeout: const Timeout(Duration(seconds: 30)));

  // Negative control: without the broadcast leg the very same pair finds
  // nothing. Without this, a green run above could be explained by anything
  // else on the host (a multicast datagram from another instance, a leftover
  // socket) and would stop being evidence for the broadcast path.
  test('with both legs disabled nothing arrives (control)', () async {
    const int controlPort = 49520;
    final List<String> listenerLog = <String>[];
    final List<PeerSeen> seen = <PeerSeen>[];

    final MulticastDiscovery listener = MulticastDiscovery(
      deviceInfo: info('listener', 'D' * 64).copyWith(port: controlPort),
      port: controlPort,
      multicastEnabled: true,
      broadcastEnabled: false,
      announceInterval: const Duration(seconds: 30),
      onLog: listenerLog.add,
      onPeer: (DeviceInfo peer, String sourceAddress,
              AnnouncementTransport transport) =>
          seen.add(PeerSeen(peer, transport)),
    );
    final MulticastDiscovery silentSender = MulticastDiscovery(
      deviceInfo: info('silent', 'E' * 64).copyWith(port: controlPort),
      port: controlPort,
      multicastEnabled: false,
      broadcastEnabled: false,
      listen: false,
      announceInterval: const Duration(milliseconds: 300),
    );

    await listener.start();
    await silentSender.start();
    addTearDown(() async {
      await silentSender.stop();
      await listener.stop();
    });

    // Several announce cycles' worth of silence.
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(seen, isEmpty, reason: 'nothing was announced on any leg\n'
        'listener log:\n  ${listenerLog.join('\n  ')}');
  }, timeout: const Timeout(Duration(seconds: 30)));
}

/// What the listener observed.
class Received {
  const Received(this.peer, this.sourceAddress, this.transport);

  final DeviceInfo peer;
  final String sourceAddress;
  final AnnouncementTransport transport;
}

/// What the control test's listener observed (it must stay empty).
class PeerSeen {
  const PeerSeen(this.peer, this.transport);

  final DeviceInfo peer;
  final AnnouncementTransport transport;
}
