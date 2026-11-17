import 'package:lanlink_cli/src/commands/discover_command.dart';
import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// `discover --broadcast-only` (0.2.34) is the probe for the one question the
/// user can actually answer on his hardware: *with multicast blocked, does the
/// broadcast leg still find the peer?*
///
/// On a network where the group join succeeds a normal run proves nothing about
/// the broadcast leg — so the switch must really remove that leg, not merely
/// mention it in a banner. These tests pin that.
void main() {
  DeviceInfo self() => DeviceInfo(
        alias: 'probe',
        fingerprint: 'A' * 64,
        port: 49494,
        deviceType: DeviceType.desktop,
      );

  group('discoveryLegs', () {
    test('--broadcast-only turns the multicast leg off and keeps the rest', () {
      final DiscoveryLegs legs = discoveryLegs(broadcastOnly: true);

      expect(legs.multicastEnabled, isFalse,
          reason: 'the group must not be joined and multicast must not be sent');
      expect(legs.broadcastEnabled, isTrue,
          reason: 'the broadcast leg is the whole point of the probe');
      expect(legs.listen, isTrue,
          reason: 'a probe that does not bind the receive socket sees nothing');
      expect(legs.broadcastOnly, isTrue);
    });

    test('without the flag both legs stay live (the default is unchanged)', () {
      final DiscoveryLegs legs = discoveryLegs(broadcastOnly: false);

      expect(legs.multicastEnabled, isTrue);
      expect(legs.broadcastEnabled, isTrue);
      expect(legs.listen, isTrue);
      expect(legs.broadcastOnly, isFalse);
    });

    test('the banner names the mode, so a log cannot be misread', () {
      expect(discoveryLegs(broadcastOnly: true).banner,
          contains('broadcast-only'));
      expect(discoveryLegs(broadcastOnly: true).banner,
          contains('NOT joined'));
      expect(discoveryLegs(broadcastOnly: false).banner,
          contains('both legs'));
    });

    test('the legs reach MulticastDiscovery as given', () {
      // The command builds the instance from exactly these three values; if the
      // names ever drifted apart this would fail to compile rather than flip a
      // flag silently.
      final DiscoveryLegs legs = discoveryLegs(broadcastOnly: true);
      final MulticastDiscovery discovery = MulticastDiscovery(
        deviceInfo: self(),
        port: 49621,
        multicastEnabled: legs.multicastEnabled,
        broadcastEnabled: legs.broadcastEnabled,
        listen: legs.listen,
        announceInterval: const Duration(hours: 1),
      );

      expect(discovery.multicastEnabled, isFalse);
      expect(discovery.broadcastEnabled, isTrue);
      expect(discovery.listen, isTrue);
    });
  });

  group('broadcast-only probe (real sockets)', () {
    test('really does not join the group, while a normal run does', () async {
      // The control matters: an empty `joinedInterfaces` on its own could also
      // mean "the join failed on this host", which would make the probe's
      // silence meaningless.
      final DiscoveryLegs probeLegs = discoveryLegs(broadcastOnly: true);
      final MulticastDiscovery probe = MulticastDiscovery(
        deviceInfo: self(),
        port: 49631,
        multicastEnabled: probeLegs.multicastEnabled,
        broadcastEnabled: probeLegs.broadcastEnabled,
        listen: probeLegs.listen,
        announceInterval: const Duration(hours: 1),
      );
      final DiscoveryLegs normalLegs = discoveryLegs(broadcastOnly: false);
      final MulticastDiscovery control = MulticastDiscovery(
        deviceInfo: self(),
        port: 49632,
        multicastEnabled: normalLegs.multicastEnabled,
        broadcastEnabled: normalLegs.broadcastEnabled,
        listen: normalLegs.listen,
        announceInterval: const Duration(hours: 1),
      );

      await probe.start();
      addTearDown(probe.stop);
      await control.start();
      addTearDown(control.stop);

      if (control.joinedInterfaces.isEmpty) {
        markTestSkipped(
            'no interface on this host accepted the group join, so the '
            'comparison cannot distinguish "did not try" from "could not"');
        return;
      }
      expect(control.joinedInterfaces, isNotEmpty);
      expect(probe.joinedInterfaces, isEmpty,
          reason: '--broadcast-only must not join $kMulticastGroup on any '
              'interface');

      // The probe still listens and still has broadcast targets, otherwise it
      // could not discover anything over the remaining leg.
      expect(probe.isRunning, isTrue);
      expect(probe.broadcastTargets, isNotEmpty);
    });
  });
}
