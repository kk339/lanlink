/// The subnet-broadcast leg of discovery: where to send it, and how to work
/// out the **directed** broadcast address of an interface.
///
/// This is discovery's second path (docs/21 §2.1). Multicast can be swallowed
/// by an AP's IGMP-snooping filter or by a firewall rule that knows nothing
/// about our port; a broadcast to the local subnet very often survives both.
/// Neither leg is a superset of the other, so both are sent every cycle —
/// which is why this file exists separately from `multicast.dart`: the address
/// arithmetic is pure and testable, and the socket plumbing is not.
///
/// Deliberately **not** related to `SubnetScan` (`subnet_scan.dart`), which
/// probes all 256 addresses of a /24 over HTTPS: that is a high-cost,
/// manually-triggered fallback, whereas everything here is one UDP datagram
/// per interface.
library;

import 'dart:io';

import '../net/local_interfaces.dart';

/// One interface a broadcast announcement should be sent out of.
///
/// A broadcast datagram only leaves the interface implied by the **source**
/// address of the sending socket, so a per-interface socket is required to
/// cover a multi-homed host (Wi-Fi + Ethernet, or a VPN adapter alongside the
/// physical NIC).
class BroadcastTarget {
  const BroadcastTarget({
    required this.interfaceName,
    required this.address,
    required this.prefixLength,
  });

  /// OS interface name, e.g. `WLAN` (diagnostics only).
  final String interfaceName;

  /// The interface's own IPv4 address; the sending socket binds to it.
  final InternetAddress address;

  /// Prefix length of the interface's subnet, or `null` when it could not be
  /// derived — in which case only [kBroadcastAddress] is used for this NIC.
  final int? prefixLength;

  /// The interface's address as a dotted quad.
  String get addressText => address.address;

  /// Directed broadcast addresses worth trying on this interface.
  ///
  /// Empty when [prefixLength] is `null` (nothing can be computed) or when the
  /// address is malformed — this method never throws, because one unusable NIC
  /// must not stop the others from being announced on.
  ///
  /// `dart:io`'s `NetworkInterface` exposes **no netmask**, so [prefixLength]
  /// is a guess (see [guessPrefixLength]). When the guess is coarser than /24
  /// (`10.0.0.0/8`, `172.16.0.0/12`) the /24 the address actually sits in is
  /// added too: a 10.x LAN in a home or small office is almost always /24, so
  /// both guesses are sent and the wrong one simply costs one datagram that
  /// the nearest router drops (RFC 1812 §4.2.1 — directed broadcasts are not
  /// forwarded).
  List<String> get directedBroadcasts {
    final int? prefix = prefixLength;
    if (prefix == null) {
      return const <String>[];
    }
    final String? primary = directedBroadcastAddress(addressText, prefix);
    if (primary == null) {
      return const <String>[];
    }
    if (prefix >= 24) {
      return <String>[primary];
    }
    final String? slash24 = directedBroadcastAddress(addressText, 24);
    if (slash24 == null || slash24 == primary) {
      return <String>[primary];
    }
    return <String>[primary, slash24];
  }

  /// The first (most likely) directed broadcast, or `null` when unknown.
  String? get directedBroadcast {
    final List<String> all = directedBroadcasts;
    return all.isEmpty ? null : all.first;
  }

  @override
  String toString() => 'BroadcastTarget($interfaceName, $addressText'
      '/${prefixLength ?? '?'}, directed: ${directedBroadcasts.join('|')})';
}

/// The **directed** (subnet) broadcast address of [address] in a
/// [prefixLength]-bit subnet: `192.168.1.37/24 -> 192.168.1.255`,
/// `10.0.0.5/8 -> 10.255.255.255`.
///
/// Returns `null` — and **never throws** — when [address] is not a dotted-quad
/// IPv4 address, or [prefixLength] is outside `1..32` (a `/0` has no directed
/// broadcast distinct from `kBroadcastAddress`, and a negative or oversized
/// prefix is meaningless).
String? directedBroadcastAddress(String address, int prefixLength) {
  if (prefixLength < 1 || prefixLength > 32) {
    return null;
  }
  final List<int>? octets = _parseIpv4(address);
  if (octets == null) {
    return null;
  }
  final int value = _toUint32(octets);
  // `<< 0` for /32 gives 0xFFFFFFFF, so no special case is needed.
  final int mask = (0xFFFFFFFF << (32 - prefixLength)) & 0xFFFFFFFF;
  final int broadcast = (value & mask) | (~mask & 0xFFFFFFFF);
  return _fromUint32(broadcast);
}

/// The prefix length a dotted-quad [netmask] encodes (`255.255.255.0 -> 24`).
///
/// Returns `null` for a malformed mask and for a **non-contiguous** one
/// (`255.0.255.0`), which no real interface uses and which would make
/// [directedBroadcastAddress] a guess on top of a guess.
int? prefixLengthFromNetmask(String netmask) {
  final List<int>? octets = _parseIpv4(netmask);
  if (octets == null) {
    return null;
  }
  final int value = _toUint32(octets);
  // A contiguous mask is a run of ones followed by a run of zeroes, i.e.
  // `~value` is 2^k - 1 for some k.
  final int inverted = ~value & 0xFFFFFFFF;
  if ((inverted & (inverted + 1)) != 0) {
    return null;
  }
  var prefix = 0;
  var rest = value;
  while (rest != 0) {
    prefix += rest & 1;
    rest >>= 1;
  }
  return prefix;
}

/// Best-effort prefix length for a **private** [address], used only because
/// `dart:io` does not expose the interface netmask.
///
/// The classful default is assumed: `10/8`, `172.16/12`, `192.168/16`. This is
/// right for `172.16/12` far more often than not and wrong for a `192.168` /16,
/// which is why `BroadcastTarget.directedBroadcasts` also emits the /24 of the
/// address whenever the guess is coarser than /24 — and why the *limited*
/// broadcast (`kBroadcastAddress`) is always sent as well.
///
/// Returns `null` for anything outside RFC1918 (we must never broadcast out of
/// a public interface) and for malformed input.
int? guessPrefixLength(String address) {
  final List<int>? octets = _parseIpv4(address);
  if (octets == null || !isPrivateIpv4(address)) {
    return null;
  }
  final int first = octets[0];
  final int second = octets[1];
  if (first == 10) {
    return 8;
  }
  if (first == 172 && second >= 16 && second <= 31) {
    return 12;
  }
  return 16;
}

/// Enumerates the interfaces a broadcast announcement should leave from.
///
/// **Private IPv4 interfaces only** — announcement frames describe the device
/// and must never be pushed at a public segment (docs/21 §2.1, "坑").
/// Interfaces that share an address are collapsed, and a failure to enumerate
/// the interfaces yields an empty list rather than an exception: the multicast
/// leg must keep working even when this one cannot.
Future<List<BroadcastTarget>> listBroadcastTargets() async {
  final List<LocalInterface> interfaces;
  try {
    interfaces = await listUsableInterfaces();
  } on Object {
    return const <BroadcastTarget>[];
  }
  final List<BroadcastTarget> targets = <BroadcastTarget>[];
  final Set<String> seen = <String>{};
  for (final LocalInterface interface in interfaces) {
    if (!interface.isPrivate) {
      continue;
    }
    if (!seen.add(interface.addressText)) {
      continue;
    }
    targets.add(BroadcastTarget(
      interfaceName: interface.name,
      address: interface.address,
      prefixLength: guessPrefixLength(interface.addressText),
    ));
  }
  return targets;
}

/// Parses `a.b.c.d` into four octets, or `null` when it is not one.
List<int>? _parseIpv4(String address) {
  final List<String> parts = address.split('.');
  if (parts.length != 4) {
    return null;
  }
  final List<int> octets = <int>[];
  for (final String part in parts) {
    if (part.isEmpty) {
      return null;
    }
    final int? value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) {
      return null;
    }
    octets.add(value);
  }
  return octets;
}

/// Packs four octets into an unsigned 32-bit value (network order semantics).
int _toUint32(List<int> octets) =>
    ((octets[0] << 24) |
        (octets[1] << 16) |
        (octets[2] << 8) |
        octets[3]) &
    0xFFFFFFFF;

/// Unpacks an unsigned 32-bit value back into `a.b.c.d`.
String _fromUint32(int value) {
  final int v = value & 0xFFFFFFFF;
  return '${(v >> 24) & 0xff}.${(v >> 16) & 0xff}.${(v >> 8) & 0xff}.${v & 0xff}';
}
