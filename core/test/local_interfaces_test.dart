import 'dart:io';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// Tests for the multicast-egress choice (`local_interfaces.dart`).
///
/// The reported regression ("两台完全互相发现不了") had a specific shape: a
/// phone's cellular link and a machine's virtual adapters are **private-looking**
/// (CGNAT `10.x`, Hyper-V `172.x`, VMware `192.168.x`), so they won the old
/// "first private interface" race and our announcements left through a NIC no
/// LAN peer could hear. The decision is now a pure function, so the rule can be
/// pinned without a real NIC.
LocalInterface _nic(String name, String address, {int index = 1}) =>
    LocalInterface(
      name: name,
      address: InternetAddress(address),
      index: index,
      isPrivate: isPrivateIpv4(address),
    );

void main() {
  group('isLikelyVirtualOrCellularInterface', () {
    test('flags the cellular and virtual adapter names we must skip', () {
      // Every one of these passes `isPrivateIpv4` on a real machine.
      for (final name in <String>[
        'rmnet_data0', // Android cellular (CGNAT 10/8)
        'v4-rmnet_data0', // some Android builds prefix it
        'vEthernet (WSL)', // WSL / Hyper-V (172.x)
        'vEthernet (Default Switch)',
        'VMnet8', // VMware NAT (192.168.x)
        'vmnet1',
        'tun0', // VPN
        'tap-windows',
        'ppp0',
      ]) {
        expect(
          isLikelyVirtualOrCellularInterface(name),
          isTrue,
          reason: '$name must be skipped',
        );
      }
    });

    test('leaves the real LAN adapters alone', () {
      for (final name in <String>[
        'WLAN',
        'Wi-Fi',
        'wlan0',
        'eth0',
        'Ethernet',
        'en0',
        'enp3s0',
      ]) {
        expect(
          isLikelyVirtualOrCellularInterface(name),
          isFalse,
          reason: '$name must stay eligible',
        );
      }
    });
  });

  group('selectPreferredMulticastInterface', () {
    test('skips a cellular link that comes first and wins the race (the bug)',
        () {
      // RED before this change: the old rule took the first *private* entry,
      // which is `rmnet_data0` (10.5.6.7) — announcements then left over the
      // cellular link and no LAN peer ever heard us.
      final selected = selectPreferredMulticastInterface(<LocalInterface>[
        _nic('rmnet_data0', '10.5.6.7'),
        _nic('WLAN', '192.168.5.2'),
      ]);
      expect(selected?.name, 'WLAN');
    });

    test('skips Hyper-V / WSL virtual adapters that come first', () {
      final selected = selectPreferredMulticastInterface(<LocalInterface>[
        _nic('vEthernet (WSL)', '172.20.0.1'),
        _nic('Ethernet', '192.168.1.10'),
      ]);
      expect(selected?.name, 'Ethernet');
    });

    test('skips a VMware NAT adapter that comes first', () {
      final selected = selectPreferredMulticastInterface(<LocalInterface>[
        _nic('VMnet8', '192.168.78.1'),
        _nic('Wi-Fi', '192.168.1.20'),
      ]);
      expect(selected?.name, 'Wi-Fi');
    });

    test('keeps the first eligible private NIC when several qualify', () {
      final selected = selectPreferredMulticastInterface(<LocalInterface>[
        _nic('WLAN', '10.0.0.5'),
        _nic('Ethernet', '192.168.1.2'),
      ]);
      expect(selected?.name, 'WLAN');
    });

    test('falls back to the old rule when every NIC looks virtual', () {
      // The explicit backstop: skipping is a preference, never a way to end up
      // with *no* interface (a wrong egress still beats no egress at all).
      final selected = selectPreferredMulticastInterface(<LocalInterface>[
        _nic('rmnet_data0', '10.5.6.7'),
      ]);
      expect(selected?.name, 'rmnet_data0');
    });

    test(
        'falls back to the first private NIC when the eligible one is not private',
        () {
      final selected = selectPreferredMulticastInterface(<LocalInterface>[
        _nic('rmnet_data0', '10.1.1.1'),
        _nic('eth0', '203.0.113.9'),
      ]);
      // Rule 1 finds nothing (the only private NIC is skipped, `eth0` is
      // public); rule 2 — the pre-existing rule — then wins.
      expect(selected?.name, 'rmnet_data0');
    });

    test('uses the first usable interface when none is private', () {
      final selected = selectPreferredMulticastInterface(<LocalInterface>[
        _nic('eth0', '203.0.113.9'),
        _nic('eth1', '198.51.100.4'),
      ]);
      expect(selected?.name, 'eth0');
    });

    test('returns null when there is no interface at all', () {
      expect(
        selectPreferredMulticastInterface(const <LocalInterface>[]),
        isNull,
      );
    });
  });

  group('chooseEgressAfterChange', () {
    test('adopts the freshly picked interface', () {
      expect(
        chooseEgressAfterChange(
          InternetAddress('192.168.1.2'),
          InternetAddress('192.168.1.9'),
        )?.address,
        '192.168.1.9',
      );
    });

    test('keeps the current interface when the re-pick found nothing', () {
      // A network change must not be able to leave discovery with no egress —
      // returning `null` here would silently stop the announcements.
      expect(
        chooseEgressAfterChange(InternetAddress('192.168.1.2'), null)?.address,
        '192.168.1.2',
      );
    });

    test('stays null when there never was an interface', () {
      expect(chooseEgressAfterChange(null, null), isNull);
    });
  });
}
