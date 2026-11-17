import 'dart:async';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// Tests for the eight behavioural requirements in spec §4.
void main() {
  late PeerRegistry registry;
  late List<PeerEvent> events;
  late StreamSubscription<PeerEvent> subscription;

  final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);

  DeviceInfo info({
    String alias = 'NodeB',
    String fingerprint = 'AABB',
    int port = 53318,
  }) =>
      DeviceInfo(alias: alias, fingerprint: fingerprint, port: port);

  /// Lets the broadcast stream deliver everything that is queued.
  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    registry = PeerRegistry(offlineAfter: const Duration(seconds: 30));
    events = <PeerEvent>[];
    subscription = registry.events.listen(events.add);
  });

  tearDown(() async {
    await subscription.cancel();
    await registry.dispose();
  });

  test('req 1: the normalised fingerprint is the primary key', () async {
    registry.touch(
      info(fingerprint: 'AA:BB'),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0,
    );
    registry.touch(
      info(fingerprint: 'aabb'),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0,
    );
    registry.touch(
      info(fingerprint: 'aabb '),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0,
    );
    await settle();

    // One device, not three.
    expect(registry.all.length, 1);
    expect(registry.byFingerprint('aabb')?.fingerprint, 'AABB');
    expect(registry.byFingerprint('AA:BB')?.fingerprint, 'AABB');
    // Only the first touch added a device.
    expect(events.whereType<PeerAdded>().length, 1);
  });

  test('req 2: a new fingerprint is added and emits PeerAdded', () async {
    registry.touch(
      info(),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0,
    );
    await settle();

    expect(registry.all.length, 1);
    expect(events.single, isA<PeerAdded>());
    final peer = registry.all.single;
    expect(peer.isOnline, isTrue);
    expect(peer.firstSeen, t0);
    expect(peer.lastSeen, t0);
    expect(peer.address, '10.0.0.1');
    expect(peer.lastSource, PeerSource.multicast);
  });

  test('req 3: a known fingerprint updates address/info/lastSeen', () async {
    registry.touch(
      info(port: 53318),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0,
    );
    final t1 = t0.add(const Duration(seconds: 5));
    registry.touch(
      // Same alias, **same port**: only the observational metadata moved, so
      // nothing that decides reachability changed and no event may be emitted
      // (see req 3c/3d for the fields that do).
      info(port: 53318),
      address: '10.0.0.9',
      source: PeerSource.register,
      now: t1,
    );
    await settle();

    final peer = registry.all.single;
    expect(peer.address, '10.0.0.9');
    expect(peer.info.port, 53318);
    expect(peer.lastSeen, t1);
    expect(peer.firstSeen, t0);
    expect(peer.lastSource, PeerSource.register);
    // The alias did not change, so no update event is emitted.
    expect(events.whereType<PeerUpdated>(), isEmpty);
  });

  test('req 3b: an alias change emits PeerUpdated', () async {
    registry.touch(
      info(alias: 'Old'),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0,
    );
    registry.touch(
      info(alias: 'New'),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0.add(const Duration(seconds: 5)),
    );
    await settle();

    final updates = events.whereType<PeerUpdated>();
    expect(updates.length, 1);
    expect(updates.single.previousAlias, 'Old');
    expect(updates.single.peer.info.alias, 'New');
  });

  // ── reachability-changing fields must not be swallowed (0.2.47) ──────────
  //
  // Why these exist: `touch()` used to emit `PeerUpdated` **only** when the
  // alias changed. A peer that restarts lanlink keeps the same fingerprint and
  // the same alias and keeps announcing every 5 s — it never goes offline — so
  // the one field that actually moved (the port its HTTP server now listens on)
  // was written into the registry in **complete silence**. Every consumer that
  // is woken by events (the app's `OutboxPump`, the device list) therefore never
  // learned that a previously unreachable peer had become reachable, and a
  // queued message could stay `pending` for ever.

  test('req 3c: a port change emits PeerUpdated (the silent restart)', () async {
    registry.touch(
      info(port: 53317),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0,
    );
    await settle();
    events.clear();

    // 对端重启 lanlink：同一个指纹、同一个别名、同一个地址，只有端口变了，
    // 而且它**一直在公告**，所以既没有 PeerAdded 也没有 PeerCameOnline。
    registry.touch(
      info(port: 53318),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0.add(const Duration(seconds: 5)),
    );
    await settle();

    final updates = events.whereType<PeerUpdated>().toList(growable: false);
    expect(updates, hasLength(1),
        reason: 'the port is the dial target — a change to it must be '
            'observable, otherwise nothing can wake the offline queue');
    expect(updates.single.previousPort, 53317);
    expect(updates.single.peer.info.port, 53318);
    expect(updates.single.previousAlias, isNull,
        reason: 'only the fields that actually changed are reported');
    expect(events.whereType<PeerCameOnline>(), isEmpty,
        reason: 'the peer never went offline — that is the whole problem');
    expect(events.whereType<PeerWentOffline>(), isEmpty);
    expect(events.whereType<PeerAdded>(), isEmpty);
  });

  test('req 3d: a peer that starts advertising a port is announced', () async {
    // `port == 0` means "no inbound server" — the app refuses to dial it
    // (`PeerDevice.canSend`). When the peer opens its receiver the port becomes
    // real, i.e. the peer goes from "cannot be dialled" to "can be dialled",
    // which is exactly the transition that must produce an event.
    registry.touch(
      info(port: 0),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0,
    );
    await settle();
    events.clear();

    registry.touch(
      info(port: 53317),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0.add(const Duration(seconds: 5)),
    );
    await settle();

    final updates = events.whereType<PeerUpdated>().toList(growable: false);
    expect(updates, hasLength(1),
        reason: 'not dialable → dialable is the single most important event '
            'the registry can emit for a queue');
    expect(updates.single.previousPort, 0);
    expect(updates.single.peer.info.port, 53317);
  });

  test('req 3e: a repeated announcement with unchanged fields is silent',
      () async {
    // The other half of the rule, and the reason it cannot simply be "emit on
    // every touch": a peer announces every 5 s. Turning each of those into an
    // event would repaint the device list and re-walk every outbox a dozen
    // times a minute for no reason at all.
    for (int i = 0; i < 6; i++) {
      registry.touch(
        info(),
        address: '10.0.0.1',
        source: PeerSource.multicast,
        now: t0.add(Duration(seconds: 5 * i)),
      );
    }
    await settle();

    expect(events, hasLength(1),
        reason: 'six identical announcements are one PeerAdded and nothing '
            'else — not one event per tick');
    expect(events.single, isA<PeerAdded>());
    expect(events.whereType<PeerUpdated>(), isEmpty);
  });

  test('req 3f: alias and port changing together is one event', () async {
    // One announcement, one event: a consumer that reacts by doing work must
    // not be asked to do it twice for the same datagram.
    registry.touch(
      info(alias: 'Old', port: 53317),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0,
    );
    await settle();
    events.clear();

    registry.touch(
      info(alias: 'New', port: 53320),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0.add(const Duration(seconds: 5)),
    );
    await settle();

    final updates = events.whereType<PeerUpdated>().toList(growable: false);
    expect(updates, hasLength(1));
    expect(updates.single.previousAlias, 'Old');
    expect(updates.single.previousPort, 53317);
    expect(updates.single.peer.info.alias, 'New');
    expect(updates.single.peer.info.port, 53320);
  });

  test('req 4: sweepOffline marks a stale peer offline exactly once', () async {    registry.touch(
      info(),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0,
    );

    // Exactly at the threshold => still online (`>` is strict).
    registry.sweepOffline(t0.add(const Duration(seconds: 30)));
    await settle();
    expect(registry.all.single.isOnline, isTrue);
    expect(events.whereType<PeerWentOffline>(), isEmpty);

    // Just past the threshold => offline, exactly one event.
    registry.sweepOffline(t0.add(const Duration(seconds: 31)));
    await settle();
    expect(registry.all.single.isOnline, isFalse);
    expect(registry.online, isEmpty);
    expect(events.whereType<PeerWentOffline>().length, 1);
  });

  test('req 5: touching an offline peer brings it back online', () async {
    registry.touch(
      info(),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0,
    );
    registry.sweepOffline(t0.add(const Duration(seconds: 40)));
    await settle();
    expect(registry.all.single.isOnline, isFalse);

    final t2 = t0.add(const Duration(seconds: 41));
    registry.touch(
      info(),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t2,
    );
    await settle();

    expect(registry.all.single.isOnline, isTrue);
    expect(registry.all.single.lastSeen, t2);
    expect(events.whereType<PeerCameOnline>().length, 1);
  });

  test('req 6: sweepOffline is idempotent', () async {
    registry.touch(
      info(),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0,
    );
    final stale = t0.add(const Duration(seconds: 40));
    registry.sweepOffline(stale);
    registry.sweepOffline(stale);
    registry.sweepOffline(stale);
    await settle();

    expect(events.whereType<PeerWentOffline>().length, 1);
  });

  test('req 7: events are ordered and the stream is broadcast', () async {
    // A second concurrent listener proves broadcast semantics.
    var secondaryCount = 0;
    final secondary = registry.events.listen((_) => secondaryCount++);
    addTearDown(secondary.cancel);

    registry.touch(
      info(fingerprint: 'AA', alias: 'A'),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0,
    );
    registry.touch(
      info(fingerprint: 'BB', alias: 'B'),
      address: '10.0.0.2',
      source: PeerSource.multicast,
      now: t0,
    );
    await settle();

    expect(events, hasLength(2));
    expect((events[0] as PeerAdded).peer.info.alias, 'A');
    expect((events[1] as PeerAdded).peer.info.alias, 'B');
    // Both listeners received both events.
    expect(secondaryCount, 2);
  });

  test('req 8: time is injected, never read from the clock', () async {
    final a = PeerRegistry();
    final b = PeerRegistry();
    addTearDown(() async {
      await a.dispose();
      await b.dispose();
    });

    a.touch(
      info(),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0,
    );
    b.touch(
      info(),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0,
    );

    // Identical inputs + identical injected clocks => identical state.
    expect(a.all.single.lastSeen, t0);
    expect(a.all.single.lastSeen, b.all.single.lastSeen);
  });

  test('all is sorted by lastSeen descending', () async {
    registry.touch(
      info(fingerprint: 'AA'),
      address: '1',
      source: PeerSource.multicast,
      now: t0,
    );
    registry.touch(
      info(fingerprint: 'BB'),
      address: '2',
      source: PeerSource.multicast,
      now: t0.add(const Duration(seconds: 5)),
    );
    await settle();

    expect(registry.all.first.fingerprint, 'BB');
    expect(registry.all.last.fingerprint, 'AA');
  });

  test('online returns only the online devices', () async {
    registry.touch(
      info(fingerprint: 'AA'),
      address: '1',
      source: PeerSource.multicast,
      now: t0,
    );
    registry.touch(
      info(fingerprint: 'BB'),
      address: '2',
      source: PeerSource.multicast,
      now: t0.add(const Duration(seconds: 20)),
    );
    registry.sweepOffline(t0.add(const Duration(seconds: 40)));
    await settle();

    expect(registry.all.length, 2);
    expect(registry.online.length, 1);
    expect(registry.online.single.fingerprint, 'BB');
  });

  test('remove forgets a device and emits PeerRemoved', () async {
    registry.touch(
      info(),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0,
    );
    registry.remove('aabb');
    await settle();

    expect(registry.all, isEmpty);
    expect(events.whereType<PeerRemoved>().length, 1);

    // Removing an unknown device is a no-op.
    registry.remove('does-not-exist');
    await settle();
    expect(events.whereType<PeerRemoved>().length, 1);
  });

  test('a device without a fingerprint is ignored', () async {
    registry.touch(
      info(fingerprint: ''),
      address: '10.0.0.1',
      source: PeerSource.multicast,
      now: t0,
    );
    await settle();

    expect(registry.all, isEmpty);
    expect(events, isEmpty);
  });
}
