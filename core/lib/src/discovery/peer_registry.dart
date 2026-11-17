/// The device registry — "which devices are there, who is online, how long
/// since I last saw them".
///
/// This is the foundation of the "device as session" model. It is deliberately
/// **pure in-memory and clock-free**: every method that needs the current time
/// takes it as a parameter, so behaviour is deterministic and unit-testable
/// (spec §4 requirement 8).
library;

import 'dart:async';

import '../protocol/device_info.dart';
import '../security/fingerprint.dart';

/// How a peer became known, for diagnostics ("how did I learn about it?").
enum PeerSource {
  /// Learned from a UDP multicast announcement.
  multicast,

  /// Learned from a **subnet-broadcast** announcement (`255.255.255.255` or a
  /// directed broadcast such as `192.168.1.255`).
  ///
  /// The frame is identical to [multicast]; only the leg differs (see
  /// `AnnouncementTransport`). Recorded separately on purpose: it is the only
  /// way to read "multicast was blocked and the fallback carried us" off the
  /// device list instead of guessing (docs/21 §2.1).
  broadcast,

  /// Learned from a subnet scan reply.
  subnetScan,

  /// Learned from an HTTP `register` request or reply.
  register,
}

/// A discovered device plus its online state and timestamps.
class Peer {
  const Peer({
    required this.fingerprint,
    required this.info,
    required this.address,
    required this.firstSeen,
    required this.lastSeen,
    required this.isOnline,
    required this.lastSource,
  });

  /// Primary key — normalised (uppercase, no whitespace, no separators).
  final String fingerprint;

  /// Last known self-description.
  final DeviceInfo info;

  /// Last IP the device was seen at.
  final String address;

  /// When the device was first seen.
  final DateTime firstSeen;

  /// When the device was last seen.
  final DateTime lastSeen;

  /// Whether the device is currently considered online.
  final bool isOnline;

  /// How the device was most recently learned about.
  final PeerSource lastSource;

  /// Returns a copy with the given fields replaced. The [fingerprint] and
  /// [firstSeen] are immutable.
  Peer copyWith({
    DeviceInfo? info,
    String? address,
    DateTime? lastSeen,
    bool? isOnline,
    PeerSource? lastSource,
  }) {
    return Peer(
      fingerprint: fingerprint,
      info: info ?? this.info,
      address: address ?? this.address,
      firstSeen: firstSeen,
      lastSeen: lastSeen ?? this.lastSeen,
      isOnline: isOnline ?? this.isOnline,
      lastSource: lastSource ?? this.lastSource,
    );
  }

  @override
  String toString() =>
      'Peer(${info.alias} @ $address, fp: $fingerprint, online: $isOnline)';
}

/// Base type for registry change notifications.
sealed class PeerEvent {
  const PeerEvent(this.peer);

  /// The peer the event refers to.
  final Peer peer;
}

/// A previously unknown device was added.
final class PeerAdded extends PeerEvent {
  const PeerAdded(super.peer);
}

/// A known device's **reachability-relevant** attributes changed (0.2.47).
///
/// Which fields, and why exactly these:
///
/// * `info.alias` — the name shown everywhere; a rename must repaint the list
///   (this was the only trigger before 0.2.47);
/// * `info.port` — **the dial target.** A peer that restarts lanlink comes back
///   on a (possibly) different port while staying online and keeping its
///   fingerprint and alias, i.e. with no `PeerAdded` / `PeerCameOnline` /
///   `PeerWentOffline` to announce it. Silently absorbing the port change is how
///   a message queued for that peer could stay `pending` for ever: the one
///   thing that had changed — and the only thing a sender cares about — was
///   never reported. `port == 0 → > 0` (the peer opened its receiver) is the
///   same bug with a louder symptom, and is covered by this same comparison.
///
/// Deliberately **not** triggers:
///
/// * `address` — it is re-derived from the source IP of **every** announcement,
///   and the broadcast leg sends one datagram per interface, so a multi-homed
///   peer alternates between two source addresses on every announce tick.
///   Emitting on that would turn the 5 s announcement interval into a permanent
///   event stream for exactly the peers that are already reachable. Consumers
///   read the address from [Peer.address] at dial time anyway (the app's
///   `mergeDeviceCards` overwrites the card's `lastIp` from the live peer), so a
///   stale-then-fresh address is never dialled — and a consumer that needs to
///   notice an otherwise silent change has its own periodic fallback.
/// * `lastSeen` — refreshed by every announcement, never interesting on its own;
/// * `info.deviceModel` / `info.deviceType` — display-only, and stable for the
///   life of the hardware under normal operation;
/// * `info.protocol` / `info.announce` — vestigial, never serialised;
/// * `lastSource` — diagnostics ("which leg carried this"), not reachability.
final class PeerUpdated extends PeerEvent {
  const PeerUpdated(super.peer, {this.previousAlias, this.previousPort});

  /// The alias the peer used before this update, when it changed.
  final String? previousAlias;

  /// The port the peer advertised before this update, when it changed.
  ///
  /// `0` means the peer was advertising "no inbound server" (`DeviceInfo.port`),
  /// so `previousPort == 0` on an update means the peer just became dialable.
  final int? previousPort;
}

/// A device that was offline is online again.
final class PeerCameOnline extends PeerEvent {
  const PeerCameOnline(super.peer);
}

/// A device stopped being seen and is now offline.
final class PeerWentOffline extends PeerEvent {
  const PeerWentOffline(super.peer);
}

/// A device was removed from the registry.
final class PeerRemoved extends PeerEvent {
  const PeerRemoved(super.peer);
}

/// In-memory registry of discovered devices.
class PeerRegistry {
  /// Creates a registry. A device whose `now - lastSeen` exceeds
  /// [offlineAfter] is considered offline by [sweepOffline].
  PeerRegistry({this.offlineAfter = const Duration(seconds: 30)});

  /// A device whose `now - lastSeen` exceeds this is marked offline.
  final Duration offlineAfter;

  final Map<String, Peer> _peers = <String, Peer>{};
  final StreamController<PeerEvent> _events =
      StreamController<PeerEvent>.broadcast();

  /// Every known device, most recently seen first.
  List<Peer> get all {
    final peers = _peers.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return peers;
  }

  /// Every online device, most recently seen first.
  List<Peer> get online =>
      all.where((peer) => peer.isOnline).toList(growable: false);

  /// The number of known devices.
  int get length => _peers.length;

  /// Broadcast stream of registry changes (spec §4 requirement 7).
  ///
  /// Events are delivered in the order the state changed.
  Stream<PeerEvent> get events => _events.stream;

  /// Returns the peer for [fingerprint] (normalised), or `null` if unknown.
  Peer? byFingerprint(String fingerprint) =>
      _peers[normalizeFingerprint(fingerprint)];

  /// Records or refreshes a device.
  ///
  /// The same normalised [DeviceInfo.fingerprint] always refers to the same
  /// device (spec §4 requirement 1). A device with an empty fingerprint cannot
  /// be identified and is ignored.
  void touch(
    DeviceInfo info, {
    required String address,
    required PeerSource source,
    required DateTime now,
  }) {
    final key = normalizeFingerprint(info.fingerprint);
    if (key.isEmpty) {
      return;
    }

    final existing = _peers[key];
    if (existing == null) {
      final peer = Peer(
        fingerprint: key,
        info: info,
        address: address,
        firstSeen: now,
        lastSeen: now,
        isOnline: true,
        lastSource: source,
      );
      _peers[key] = peer;
      _emit(PeerAdded(peer));
      return;
    }

    final wasOnline = existing.isOnline;
    final updated = existing.copyWith(
      info: info,
      address: address,
      lastSeen: now,
      isOnline: true,
      lastSource: source,
    );
    _peers[key] = updated;

    // A device that reappears after being offline is "back online" first,
    // then any attribute change is reported (stable event order).
    if (!wasOnline) {
      _emit(PeerCameOnline(updated));
    }
    // One datagram, at most one event: the alias and the port are compared
    // together so a peer that restarted *and* was renamed costs a consumer one
    // wake-up, not two. Both fields are deviations worth reporting — see
    // [PeerUpdated] for the full list and for why `address` is not one of them.
    final bool aliasChanged = existing.info.alias != info.alias;
    final bool portChanged = existing.info.port != info.port;
    if (aliasChanged || portChanged) {
      _emit(
        PeerUpdated(
          updated,
          previousAlias: aliasChanged ? existing.info.alias : null,
          previousPort: portChanged ? existing.info.port : null,
        ),
      );
    }
  }

  /// Marks devices offline whose last sighting is older than [offlineAfter].
  ///
  /// Safe to call repeatedly: an already-offline device is skipped, so each
  /// device emits [PeerWentOffline] exactly once (requirements 4 & 6).
  void sweepOffline(DateTime now) {
    for (final entry in _peers.entries.toList(growable: false)) {
      final peer = entry.value;
      if (!peer.isOnline) {
        continue;
      }
      if (now.difference(peer.lastSeen) > offlineAfter) {
        final offline = peer.copyWith(isOnline: false);
        _peers[entry.key] = offline;
        _emit(PeerWentOffline(offline));
      }
    }
  }

  /// Removes a device, emitting [PeerRemoved] when it existed.
  void remove(String fingerprint) {
    final peer = _peers.remove(normalizeFingerprint(fingerprint));
    if (peer != null) {
      _emit(PeerRemoved(peer));
    }
  }

  /// Removes every device, emitting [PeerRemoved] for each in insertion order.
  void clear() {
    for (final peer in _peers.values.toList(growable: false)) {
      _emit(PeerRemoved(peer));
    }
    _peers.clear();
  }

  /// Closes the event stream. The registry must not be used afterwards.
  Future<void> dispose() => _events.close();

  void _emit(PeerEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }
}
