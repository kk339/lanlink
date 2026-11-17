/// Shared multicast-egress interface selection for the CLI subcommands.
///
/// Windows sends multicast out of the adapter with the **lowest route metric**,
/// so a VPN adapter can steal the egress from the physical LAN and announcements
/// never reach peers. Both `discover` and `announce` must therefore decide —
/// once, identically — which NIC announcements leave through.
///
/// This file centralises only the *decision*. The `--list-interfaces` *output
/// formatting* stays in each command, which is free to print it or not.
library;

import 'dart:io';

import 'package:lanlink_core/lanlink_core.dart';

/// The outcome of choosing the multicast egress interface.
class InterfaceSelection {
  const InterfaceSelection({this.iface, this.egress, this.explicitError});

  /// The chosen interface, or `null` when nothing was selected (the OS default
  /// is then used).
  ///
  /// This is a [LocalInterface] — the core abstraction that carries the NIC
  /// name and the `/24` prefix — not a raw `dart:io` `NetworkInterface`, because
  /// core's selection API ([selectDefaultMulticastInterface]) returns the
  /// former.
  final LocalInterface? iface;

  /// The address to hand to `MulticastDiscovery(multicastInterface:)` and
  /// `scanSubnet(interfaceAddress:)`; `null` keeps the OS-default behaviour.
  final InternetAddress? egress;

  /// Non-`null` only when the user passed `--interface` and no matching NIC
  /// exists. The caller prints it and exits non-zero; there is **no** silent
  /// fallback to the OS default.
  final String? explicitError;

  /// Whether a usable egress interface was chosen.
  bool get hasEgress => egress != null;

  /// Startup banner, printed unconditionally by every subcommand.
  ///
  /// `diag-multicast.cmd` reads this line to decide whether the egress NIC was
  /// actually pinned, so the wording must stay stable.
  String get banner {
    final address = egress;
    if (address == null) {
      return 'using system default interface for multicast';
    }
    final name = iface?.name;
    if (name == null) {
      return 'using interface ${address.address} for multicast';
    }
    return 'using interface $name (${address.address}) for multicast';
  }
}

/// Decides which IPv4 interface multicast should leave through.
///
/// [explicit] is the raw `--interface` value. The CLI's value parser yields the
/// literal `'true'` when a flag is given without a value, which is reported as
/// a usage error here.
///
/// When [explicit] is absent the selection follows exactly the same rules as
/// core's [selectDefaultMulticastInterface]: prefer the first RFC1918-private
/// interface, else the first usable one, else none (leaving the OS default).
Future<InterfaceSelection> selectMulticastInterface({String? explicit}) async {
  if (explicit != null && explicit.isNotEmpty) {
    if (explicit == 'true') {
      return const InterfaceSelection(
        explicitError: '--interface requires an IPv4 address '
            '(e.g. --interface 192.168.5.6)',
      );
    }
    final usable = await listUsableInterfaces();
    for (final candidate in usable) {
      if (candidate.addressText == explicit) {
        return InterfaceSelection(iface: candidate, egress: candidate.address);
      }
    }
    final available = usable.isEmpty
        ? 'none'
        : usable.map((candidate) => candidate.addressText).join(', ');
    return InterfaceSelection(
      explicitError: 'interface $explicit not found; use --list-interfaces to '
          'see valid addresses (available: $available)',
    );
  }

  final automatic = await selectDefaultMulticastInterface();
  if (automatic == null) {
    return const InterfaceSelection();
  }
  return InterfaceSelection(iface: automatic, egress: automatic.address);
}
