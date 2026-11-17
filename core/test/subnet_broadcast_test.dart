import 'dart:io';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// The subnet-broadcast leg's address arithmetic (docs/21 §2.1, leg 2).
///
/// Every case here is a way the second leg can silently do nothing: a wrong
/// directed address is a datagram the router drops, and a thrown exception in
/// the middle of the fan-out would take discovery down with it.
void main() {
  group('directedBroadcastAddress', () {
    test('192.168.1.37/24 -> 192.168.1.255', () {
      expect(directedBroadcastAddress('192.168.1.37', 24), '192.168.1.255');
    });

    test('10.0.0.5/8 -> 10.255.255.255', () {
      expect(directedBroadcastAddress('10.0.0.5', 8), '10.255.255.255');
    });

    test('172.16.5.9/12 -> 172.31.255.255', () {
      expect(directedBroadcastAddress('172.16.5.9', 12), '172.31.255.255');
    });

    test('/32 is its own broadcast (no host bits to set)', () {
      expect(directedBroadcastAddress('192.168.1.37', 32), '192.168.1.37');
    });

    test('returns null instead of throwing on anything it cannot compute', () {
      // None of these may throw: `BroadcastTarget.directedBroadcasts` runs
      // inside the announce path, and one bad NIC must not stop the others.
      expect(directedBroadcastAddress('not-an-ip', 24), isNull);
      expect(directedBroadcastAddress('192.168.1', 24), isNull);
      expect(directedBroadcastAddress('192.168.1.256', 24), isNull);
      expect(directedBroadcastAddress('192.168..1', 24), isNull);
      expect(directedBroadcastAddress('', 24), isNull);
      expect(directedBroadcastAddress('::1', 24), isNull);
      expect(directedBroadcastAddress('192.168.1.1', 0), isNull,
          reason: '/0 has no directed broadcast distinct from 255.255.255.255');
      expect(directedBroadcastAddress('192.168.1.1', 33), isNull);
      expect(directedBroadcastAddress('192.168.1.1', -1), isNull);
    });
  });

  group('prefixLengthFromNetmask', () {
    test('contiguous masks', () {
      expect(prefixLengthFromNetmask('255.255.255.0'), 24);
      expect(prefixLengthFromNetmask('255.255.0.0'), 16);
      expect(prefixLengthFromNetmask('255.0.0.0'), 8);
      expect(prefixLengthFromNetmask('255.255.255.128'), 25);
      expect(prefixLengthFromNetmask('255.255.255.255'), 32);
      expect(prefixLengthFromNetmask('0.0.0.0'), 0);
    });

    test('a non-contiguous mask is refused rather than guessed at', () {
      expect(prefixLengthFromNetmask('255.0.255.0'), isNull);
      expect(prefixLengthFromNetmask('255.255.0.255'), isNull);
      expect(prefixLengthFromNetmask('nonsense'), isNull);
    });
  });

  group('guessPrefixLength', () {
    test('classful default for the RFC1918 ranges', () {
      expect(guessPrefixLength('10.4.5.6'), 8);
      expect(guessPrefixLength('172.16.0.9'), 12);
      expect(guessPrefixLength('172.31.255.1'), 12);
      expect(guessPrefixLength('192.168.110.91'), 16);
    });

    test('a public address has no guess — we never broadcast out of one', () {
      expect(guessPrefixLength('8.8.8.8'), isNull);
      expect(guessPrefixLength('1.1.1.1'), isNull);
      expect(guessPrefixLength('100.64.0.1'), isNull);
      expect(guessPrefixLength('garbage'), isNull);
    });
  });

  group('BroadcastTarget', () {
    test('a /24 gets exactly one directed address', () {
      final target = BroadcastTarget(
        interfaceName: 'WLAN',
        address: InternetAddress('192.168.1.37'),
        prefixLength: 24,
      );
      expect(target.directedBroadcasts, <String>['192.168.1.255']);
      expect(target.directedBroadcast, '192.168.1.255');
    });

    test('a guess coarser than /24 also tries the /24 it sits in', () {
      // `dart:io` reports no netmask, so 10.x is guessed as /8 — but a home LAN
      // on 10.x is almost always a /24, and the /8 broadcast would be dropped by
      // the gateway. Both are sent; the wrong one costs one datagram.
      final wide = BroadcastTarget(
        interfaceName: 'Ethernet',
        address: InternetAddress('10.0.0.5'),
        prefixLength: 8,
      );
      expect(wide.directedBroadcasts,
          <String>['10.255.255.255', '10.0.0.255']);

      final home = BroadcastTarget(
        interfaceName: 'WLAN',
        address: InternetAddress('192.168.1.37'),
        prefixLength: 16,
      );
      expect(home.directedBroadcasts,
          <String>['192.168.255.255', '192.168.1.255']);
    });

    test('an unknown prefix yields no directed address, and no exception', () {
      final target = BroadcastTarget(
        interfaceName: 'VPN',
        address: InternetAddress('10.8.0.2'),
        prefixLength: null,
      );
      expect(target.directedBroadcasts, isEmpty);
      expect(target.directedBroadcast, isNull);
    });
  });

  group('listBroadcastTargets', () {
    test('only private interfaces are ever targeted', () async {
      final targets = await listBroadcastTargets();
      for (final target in targets) {
        expect(isPrivateIpv4(target.addressText), isTrue,
            reason: 'announcements must never leave a public interface: '
                '${target.addressText}');
      }
      // Addresses are unique: two sockets bound to one address would fight.
      final addresses =
          targets.map((target) => target.addressText).toList(growable: false);
      expect(addresses.toSet().length, addresses.length);
    });
  });
}
