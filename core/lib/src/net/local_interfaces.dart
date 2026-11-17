/// Local IPv4 interface enumeration and default multicast egress selection.
///
/// Windows picks the outgoing interface for multicast by route metric: the
/// adapter with the **lowest** metric wins. A VPN adapter (e.g. Radmin VPN with
/// metric 1) therefore steals the multicast egress from the physical Wi-Fi /
/// Ethernet NIC (metric 30), so announcements leave through the tunnel and
/// never reach peers on the physical LAN.
///
/// This module lets callers (a) enumerate the usable NICs, (b) pick a sane
/// default egress, and (c) look up a NIC by address so they can name it in
/// logs. The actual socket pinning lives in [MulticastDiscovery].
library;

import 'dart:io';

/// A usable local network interface carrying a single IPv4 address.
///
/// "Usable" means the interface is up, is not the loopback device and has at
/// least one IPv4 address (link-local addresses are excluded upstream).
class LocalInterface {
  const LocalInterface({
    required this.name,
    required this.address,
    required this.index,
    required this.isPrivate,
  });

  /// OS interface name, e.g. `WLAN` or `Radmin VPN`.
  final String name;

  /// The interface's IPv4 address.
  final InternetAddress address;

  /// OS interface index (`netsh interface ipv4 show interfaces` "Idx").
  final int index;

  /// Whether [address] falls inside an RFC1918 private range.
  final bool isPrivate;

  /// The address as a dotted-quad string, e.g. `192.168.5.6`.
  String get addressText => address.address;

  @override
  String toString() => 'LocalInterface($name, $addressText, '
      'index: $index, private: $isPrivate)';
}

/// Returns every up, non-loopback interface that has at least one IPv4 address.
///
/// Interfaces are returned in the order the OS reports them; when a single NIC
/// carries more than one IPv4 address, one [LocalInterface] is emitted per
/// address.
Future<List<LocalInterface>> listUsableInterfaces() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  final result = <LocalInterface>[];
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (address.type != InternetAddressType.IPv4) {
        continue;
      }
      result.add(LocalInterface(
        name: interface.name,
        address: address,
        index: interface.index,
        isPrivate: isPrivateIpv4(address.address),
      ));
    }
  }
  return result;
}

/// Whether [address] is an RFC1918 private IPv4 address.
///
/// Recognised ranges: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`.
/// Malformed input returns `false` (never throws).
bool isPrivateIpv4(String address) {
  final parts = address.split('.');
  if (parts.length != 4) {
    return false;
  }
  final octets = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) {
      return false;
    }
    octets.add(value);
  }
  final first = octets[0];
  final second = octets[1];
  if (first == 10) {
    return true;
  }
  if (first == 172 && second >= 16 && second <= 31) {
    return true;
  }
  if (first == 192 && second == 168) {
    return true;
  }
  return false;
}

/// Chooses the default interface used to **send** multicast.
///
/// See [selectDefaultMulticastInterface]; this returns just its address, which
/// is what a socket binds to. Prefer [selectDefaultMulticastInterface] when the
/// chosen NIC's **name** needs to be logged.
Future<InternetAddress?> chooseDefaultMulticastInterface({
  void Function(String message)? onLog,
}) async {
  final selected = await selectDefaultMulticastInterface(onLog: onLog);
  return selected?.address;
}

/// Interface-name prefixes that mean "never send multicast from here".
///
/// A phone's cellular link (`rmnet*`, `v4-*`) is CGNAT'd into `10/8`, and a
/// machine's virtual adapters (Hyper-V `vEthernet*`, VMware `VMnet*`, VPN
/// `tun*` / `tap*` / `ppp*`) sit in `172.16/12` or `192.168/16` — so **all of
/// them pass [isPrivateIpv4]** and can win the "first private interface" race,
/// sending our announcements out of a NIC that no peer on the LAN can hear.
const List<String> _excludedInterfacePrefixes = <String>[
  'rmnet',
  'v4-',
  'veth', // Windows `vEthernet (…)` (then `vethernet`), Linux `veth*`
  'vmnet',
  'tun',
  'tap',
  'ppp',
];

/// Whether [name] looks like a cellular / virtual adapter we must not send
/// multicast from.
///
/// Matching is a case-insensitive **prefix** test, because OS names carry a
/// suffix (`rmnet_data0`, `vEthernet (WSL)`, `VMnet8`, `tun0`).
bool isLikelyVirtualOrCellularInterface(String name) {
  final lower = name.toLowerCase();
  for (final prefix in _excludedInterfacePrefixes) {
    if (lower.startsWith(prefix)) {
      return true;
    }
  }
  return false;
}

/// The preferred multicast egress among [interfaces], or `null` when there are
/// none — the **pure** decision behind [selectDefaultMulticastInterface].
///
/// Preference order:
/// 1. the first **private** interface that is not cellular/virtual — the fix for
///    the "两台互相发现不了" report, where such an adapter won the race and our
///    announcements left through a NIC the peer could not hear;
/// 2. the first private interface — the pre-existing rule, kept as the
///    **fallback** so an environment where every NIC looks virtual still yields
///    one interface instead of none (a wrong egress beats having no egress);
/// 3. the first usable interface;
/// 4. `null` when [interfaces] is empty.
LocalInterface? selectPreferredMulticastInterface(
  List<LocalInterface> interfaces,
) {
  if (interfaces.isEmpty) {
    return null;
  }
  for (final interface in interfaces) {
    if (interface.isPrivate &&
        !isLikelyVirtualOrCellularInterface(interface.name)) {
      return interface;
    }
  }
  for (final interface in interfaces) {
    if (interface.isPrivate) {
      return interface;
    }
  }
  return interfaces.first;
}

/// The egress to use after a network change: the freshly [picked] interface, or
/// [current] when the re-pick found nothing.
///
/// A failed re-pick must **never** be able to leave discovery with no egress at
/// all — that would silently stop the announcements this whole mechanism exists
/// to protect. Keeping the previous (possibly stale) interface is the honest
/// degradation; the caller logs it.
InternetAddress? chooseEgressAfterChange(
  InternetAddress? current,
  InternetAddress? picked,
) =>
    picked ?? current;

/// Chooses the default [LocalInterface] used to **send** multicast.
///
/// The decision itself is [selectPreferredMulticastInterface]; this enumerates
/// the NICs and reports what it saw. [onLog] receives one line per candidate
/// (with the reason it was kept or skipped) plus the verdict, so `lanlink.log`
/// can answer "which NIC did we pick, and why" after the fact.
Future<LocalInterface?> selectDefaultMulticastInterface({
  void Function(String message)? onLog,
}) async {
  final interfaces = await listUsableInterfaces();
  for (final interface in interfaces) {
    final bool skipped = isLikelyVirtualOrCellularInterface(interface.name);
    onLog?.call('interface candidate: ${interface.name} '
        'idx=${interface.index} ${interface.addressText} '
        'private=${interface.isPrivate} '
        '${skipped ? 'SKIPPED (cellular/virtual)' : 'eligible'}');
  }
  final selected = selectPreferredMulticastInterface(interfaces);
  if (selected == null) {
    onLog?.call('no usable interface; keeping the OS default multicast egress');
    return null;
  }
  final bool fellBack = isLikelyVirtualOrCellularInterface(selected.name);
  onLog?.call('multicast egress: ${selected.name} idx=${selected.index} '
      '${selected.addressText}'
      '${fellBack ? ' (FALLBACK: nothing better was available)' : ''}');
  return selected;
}
