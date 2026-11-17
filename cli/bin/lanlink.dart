import 'dart:io';

import 'package:lanlink_cli/src/commands/announce_command.dart';
import 'package:lanlink_cli/src/commands/discover_command.dart';
import 'package:lanlink_cli/src/commands/history_command.dart';
import 'package:lanlink_cli/src/commands/send_command.dart';

/// lanlink command line entrypoint.
///
/// Subcommands:
///   * `discover` - continuously discover peers and print the device list.
///   * `announce` - only announce on the multicast group (diagnostics).
///   * `send`     - send a single file to a peer.
///   * `history`  - read back the M3 session history (with `--db`).
Future<void> main(List<String> argv) async {
  final code = await _dispatch(argv);
  exit(code);
}

Future<int> _dispatch(List<String> argv) async {
  if (argv.isEmpty) {
    _printUsage();
    return 64;
  }
  if (argv.first == 'help' || argv.first == '--help' || argv.first == '-h') {
    _printUsage();
    return 0;
  }

  final command = argv.first;
  final options = _parseOptions(argv.skip(1).toList(growable: false));
  switch (command) {
    case 'discover':
      return DiscoverCommand(options).run();
    case 'announce':
      return AnnounceCommand(options).run();
    case 'send':
      return SendCommand(options).run();
    case 'history':
      return HistoryCommand(options).run();
    default:
      stderr.writeln('unknown command: $command');
      _printUsage();
      return 64;
  }
}

/// Minimal `--key value` / `--flag` parser. Not a general purpose CLI library -
/// just enough for the discovery commands.
Map<String, String> _parseOptions(List<String> argv) {
  final result = <String, String>{};
  for (var index = 0; index < argv.length; index++) {
    final token = argv[index];
    if (!token.startsWith('--')) {
      continue;
    }
    final key = token.substring(2);
    if (index + 1 < argv.length && !argv[index + 1].startsWith('--')) {
      result[key] = argv[index + 1];
      index++;
    } else {
      result[key] = 'true';
    }
  }
  return result;
}

void _printUsage() {
  stdout.writeln('lanlink - local device discovery and file transfer');
  stdout.writeln('');
  stdout.writeln('Usage:');
  stdout.writeln('  lanlink discover [--alias <name>] [--port <tcp>] '
      '[--udp-port <udp>] [--duration <seconds>] [--interval <seconds>]');
  stdout.writeln('                   [--certs <dir>] [--verbose] '
      '[--scan] [--scan-prefix <a.b.c.>] [--scan-interval <seconds>]');
  stdout.writeln('                   [--interface <ipv4>] [--list-interfaces]');
  stdout.writeln('                   [--broadcast-only] [--accept] '
      '[--receive-dir <dir>] [--max-upload-mb <n>]');
  stdout.writeln('  lanlink announce [--alias <name>] [--port <tcp>] '
      '[--udp-port <udp>] [--duration <seconds>] [--interval <seconds>]');
  stdout.writeln('                   [--certs <dir>] [--interface <ipv4>] '
      '[--list-interfaces]');
  stdout.writeln('  lanlink send --to <ip> --file <path> [--port <tcp>]');
  stdout.writeln('               [--fingerprint <hex>] [--allow-unknown] '
      '[--alias <name>]');
  stdout.writeln('               [--certs <dir>] [--interface <ipv4>] '
      '[--list-interfaces] [--verbose] [--db <path>]');
  stdout.writeln('  lanlink history [--db <path>] [--json] [--archived] '
      '[--limit <n>]');
  stdout.writeln('');
  stdout.writeln('  --list-interfaces prints the usable NICs and which one is');
  stdout.writeln('  auto-selected for multicast. --interface <ipv4> pins the');
  stdout
      .writeln('  outgoing multicast NIC to that address. Without --interface');
  stdout
      .writeln('  the first private (RFC1918) NIC is selected, which keeps a');
  stdout.writeln('  low-metric VPN adapter from hijacking multicast egress.');
  stdout.writeln('');
  stdout.writeln('  --scan also probes the local /24 subnet(s) over unicast '
      'TCP. Use it');
  stdout.writeln('  when the router or firewall does not forward multicast.');
  stdout.writeln('');
  stdout.writeln('  discover --broadcast-only does NOT join the multicast group '
      'and does');
  stdout.writeln('  not send multicast; it discovers over the subnet broadcast '
      'leg only.');
  stdout.writeln('  Use it to prove that broadcast still works when multicast '
      'is blocked');
  stdout.writeln('  (each peer line then shows "via broadcast").');
  stdout.writeln('');
  stdout
      .writeln('  send refuses to connect unless the receiver is pinned. Pass');
  stdout
      .writeln('  --fingerprint <hex> obtained out of band, for example from');
  stdout.writeln('  "lanlink discover" run on the receiver. --allow-unknown');
  stdout.writeln('  trusts the receiver on first use: send probes once to');
  stdout.writeln('  observe its certificate fingerprint, then pins that value');
  stdout.writeln('  for the actual upload.');
  stdout.writeln('');
  stdout.writeln(
      '  send is a pure HTTPS client: --interface only checks that the');
  stdout
      .writeln('  address exists. The OS picks the outbound NIC, so it is NOT');
  stdout.writeln(
      '  pinned; use --list-interfaces to inspect the available NICs.');
  stdout.writeln('');
  stdout.writeln(
      '  discover accepts incoming files only with --accept; received');
  stdout.writeln(
      '  files go to --receive-dir (default .lanlink-received/<alias>).');
  stdout.writeln('  --max-upload-mb caps the accepted size (default 10240).');
  stdout.writeln('');
  stdout
      .writeln('  --db <path> writes the M3 session history (send records an');
  stdout.writeln(
      '  outbound message, discover --accept an inbound one). Without');
  stdout.writeln('  --db, send / discover behave exactly as M2: nothing is');
  stdout.writeln('  written. `history` reads it back (default');
  stdout.writeln(
      '  %LOCALAPPDATA%\\lanlink\\lanlink.db); add --json for scripts,');
  stdout.writeln('  --archived to include archived conversations.');
  stdout.writeln('');
  stdout.writeln('Same-host two-process test: use different --port values but '
      'the same --udp-port.');
}
