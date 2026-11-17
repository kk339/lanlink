import 'dart:async';
import 'dart:io';

import 'package:lanlink_core/lanlink_core.dart';

import 'interface_selection.dart';

/// `lanlink announce` — only announce on the multicast group, do not react to
/// peers. Used to debug "why can't the other side see me?".
///
/// Options:
///   * `--alias <name>`    announced name (default: the host name)
///   * `--port <tcp>`      TCP port advertised to peers
///   * `--udp-port <udp>`  UDP multicast port (must match across peers)
///   * `--duration <sec>`  stop after N seconds (default: run until Ctrl-C)
///   * `--interval <sec>`  re-announce interval (default: 5)
///   * `--certs <dir>`     where the device certificate is stored
///   * `--interface <ipv4>`  pin the outgoing multicast NIC to this address;
///                         without it the first private NIC is auto-selected
///   * `--list-interfaces`   list usable NICs (with auto-selection) and exit
class AnnounceCommand {
  AnnounceCommand(this.options);

  /// Raw `--key value` options parsed from the command line.
  final Map<String, String> options;

  Future<int> run() async {
    if (options['list-interfaces'] == 'true') {
      return _listInterfaces();
    }

    final alias = options['alias'] ?? _defaultAlias();
    final config = ProtocolConfig(
      udpPort: _intOption(options, 'udp-port', kDefaultPort),
      tcpPort: _intOption(options, 'port', kDefaultPort),
    );
    final duration = _intOption(options, 'duration', 0);
    final interval = _intOption(options, 'interval', 5);
    final certDir = Directory(options['certs'] ?? '.lanlink-certs/$alias');

    // Pin the multicast egress NIC. On a multi-NIC (or VPN) host the OS would
    // otherwise send announcements out of the wrong adapter, which is exactly
    // what `announce` exists to help diagnose — so it must not lie here.
    final interfaceSelection =
        await selectMulticastInterface(explicit: options['interface']);
    if (interfaceSelection.explicitError != null) {
      stderr.writeln(interfaceSelection.explicitError);
      return 2;
    }

    final certificate = await DeviceCertificate.loadOrCreate(
      directory: certDir,
      commonName: 'lanlink-$alias',
    );

    final info = DeviceInfo(
      alias: alias,
      fingerprint: certificate.fingerprint,
      port: config.tcpPort,
      protocol: ProtocolScheme.https,
      announce: true,
    );

    final discovery = MulticastDiscovery(
      deviceInfo: info,
      group: config.multicastGroup,
      port: config.udpPort,
      multicastInterface: interfaceSelection.egress,
      announceInterval: Duration(seconds: interval),
      onLog: (message) => stdout.writeln('[announce] $message'),
    );
    await discovery.start();

    // Unconditional banner: `diag-multicast.cmd` reads this line to decide
    // whether the egress NIC was pinned, so it must always be printed.
    stdout.writeln(interfaceSelection.banner);
    stdout.writeln('announcing as $alias on '
        '${config.multicastGroup}:${config.udpPort} '
        'tcp=${config.tcpPort} fp=${certificate.fingerprint} '
        '(Ctrl-C to stop)');

    if (duration > 0) {
      await Future<void>.delayed(Duration(seconds: duration));
    } else {
      final done = Completer<void>();
      ProcessSignal.sigint.watch().listen((_) {
        if (!done.isCompleted) {
          done.complete();
        }
      });
      await done.future;
    }

    await discovery.stop();
    stdout.writeln('stopped');
    return 0;
  }

  /// Prints every usable interface and which one would be auto-selected.
  Future<int> _listInterfaces() async {
    final interfaces = await listUsableInterfaces();
    stdout.writeln('usable interfaces:');
    if (interfaces.isEmpty) {
      stdout.writeln('  (none: no up, non-loopback IPv4 interface found)');
      return 0;
    }
    final automatic = await chooseDefaultMulticastInterface();
    final automaticAddress = automatic?.address;
    for (final interface in interfaces) {
      final selected = interface.addressText == automaticAddress;
      final marker = selected ? '*' : '-';
      final kind = interface.isPrivate ? 'private' : 'public';
      final note = selected ? '  (auto-selected)' : '';
      stdout.writeln('  $marker ${interface.name.padRight(14)} '
          '${interface.addressText.padRight(16)} '
          'idx ${interface.index.toString().padLeft(3)}  $kind$note');
    }
    return 0;
  }
}

int _intOption(Map<String, String> options, String key, int fallback) {
  final raw = options[key];
  if (raw == null) {
    return fallback;
  }
  return int.tryParse(raw) ?? fallback;
}

String _defaultAlias() {
  final hostname = Platform.localHostname;
  return hostname.isEmpty ? 'lanlink' : hostname;
}
