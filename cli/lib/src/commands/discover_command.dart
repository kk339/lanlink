import 'dart:async';
import 'dart:io';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:lanlink_store/lanlink_store.dart';

import 'interface_selection.dart';

/// `lanlink discover` — continuously discover peers and print the device list.
///
/// Options:
///   * `--alias <name>`    display name (default: the host name)
///   * `--port <tcp>`      TCP port of the local HTTPS server
///   * `--udp-port <udp>`  UDP multicast port (must match across peers)
///   * `--duration <sec>`  stop after N seconds (default: run until Ctrl-C)
///   * `--interval <sec>`  re-announce interval (default: 5)
///   * `--certs <dir>`     where the device certificate is stored
///   * `--scan`            also probe the local /24 subnet(s) over unicast TCP
///                         (off by default; use it when the router or firewall
///                         does not forward multicast between machines)
///   * `--scan-prefix <a.b.c.>`  restrict the scan to one /24 subnet
///   * `--scan-interval <sec>`   seconds between scans (default: 20)
///   * `--receive-dir <dir>`  where accepted uploads are written
///                         (default: `.lanlink-received/<alias>`)
///   * `--accept`          accept incoming uploads (default: off; when off the
///                         server answers `prepare-upload` with 403)
///   * `--max-upload-mb <n>`  reject uploads larger than n MiB (default: 10240)
///   * `--interface <ipv4>`  pin the outgoing multicast NIC to this address;
///                         without it the first private NIC is auto-selected
///   * `--list-interfaces`   list usable NICs (with auto-selection) and exit
///   * `--broadcast-only`  **do not join the multicast group and do not send
///                         multicast**; listen and announce over the subnet
///                         broadcast leg only. This is the probe for "multicast
///                         is blocked, does broadcast still find the peer?" —
///                         on a network where the group join succeeds, a normal
///                         run proves nothing about the broadcast leg.
///   * `--verbose`         also print transport-level diagnostics
///   * `--db <path>`       also record every received file in the M3 session
///                         history at `<path>` (see `history`). Without `--db`
///                         nothing is written and the output is byte-for-byte
///                         M2.
///
/// It binds the HTTPS server, joins the multicast group, answers each peer's
/// announcement with a pinned `register` handshake and keeps a [PeerRegistry].
/// When `--scan` is given it additionally probes the subnet with `scanSubnet`.
class DiscoverCommand {
  DiscoverCommand(this.options);

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
    final verbose = options['verbose'] == 'true';
    final broadcastOnly = options['broadcast-only'] == 'true';
    // The legs are decided by a pure function so the wiring can be asserted
    // without opening a socket: a wrong boolean here would silently turn the
    // probe into a normal run, which would look like a pass and prove nothing.
    final DiscoveryLegs legs = discoveryLegs(broadcastOnly: broadcastOnly);
    final scan = options['scan'] == 'true';
    final scanIntervalOption = _intOption(options, 'scan-interval', 20);
    final scanPeriod = scanIntervalOption <= 0 ? 20 : scanIntervalOption;
    final rawScanPrefix = options['scan-prefix'];
    final scanPrefix = (rawScanPrefix == null || rawScanPrefix.trim().isEmpty)
        ? null
        : _normalizeScanPrefix(rawScanPrefix);

    final accept = options['accept'] == 'true';
    final receiveDir = options['receive-dir'] ?? '.lanlink-received/$alias';
    final maxUploadMb = _intOption(options, 'max-upload-mb', 10240);
    final maxUploadBytes = maxUploadMb * 1024 * 1024;

    // Decide which NIC multicast leaves through; the same selection is shared
    // with `announce` via [selectMulticastInterface].
    final interfaceSelection =
        await selectMulticastInterface(explicit: options['interface']);
    if (interfaceSelection.explicitError != null) {
      stderr.writeln(interfaceSelection.explicitError);
      return 2;
    }
    final egress = interfaceSelection.egress;
    final multicastBanner = interfaceSelection.banner;

    final certDir = Directory(options['certs'] ?? '.lanlink-certs/$alias');

    final certificate = await DeviceCertificate.loadOrCreate(
      directory: certDir,
      commonName: 'lanlink-$alias',
    );

    final registry = PeerRegistry();
    final registered = <String>{};

    // Assigned once the server has bound and our own identity is known. Read
    // lazily from [isSelf] so the callbacks defined below can reference it.
    late final String selfKey;

    /// Whether [peer] is this very device.
    ///
    /// Our own announcement loops back through multicast, and the subnet scan
    /// can reach our own server, so every *external* peer must be filtered here
    /// before it is written to the registry.
    bool isSelf(DeviceInfo peer) {
      final key = normalizeFingerprint(peer.fingerprint);
      return key.isNotEmpty && key == selfKey;
    }

    void logSelfIgnored() {
      if (verbose) {
        stdout.writeln('[self] ignored own announcement');
      }
    }

    // M3 inbound history is opt-in. The database is opened lazily on the first
    // received file, so `discover` never creates one merely by running; without
    // `--db` not a single store call is made and the output stays byte-for-byte
    // M2.
    final historyDbPath = _resolveDbPath(options);
    final history =
        historyDbPath == null ? null : _InboundHistory(historyDbPath);

    final receiveDirectory = Directory(receiveDir);
    final server = PeerServer(
      alias: alias,
      certificates: certificate,
      port: config.tcpPort,
      saveDirectory: receiveDirectory,
      acceptUploads: accept,
      maxUploadBytes: maxUploadBytes,
      onLog: verbose ? (message) => stdout.writeln('[server] $message') : null,
      onPeerSeen: (peer, remoteAddress) {
        if (isSelf(peer)) {
          logSelfIgnored();
          return;
        }
        registry.touch(
          peer,
          address: remoteAddress.isEmpty ? peer.port.toString() : remoteAddress,
          source: PeerSource.register,
          now: DateTime.now(),
        );
      },
      onUploadFinished: (received) {
        stdout.writeln('[recv] saved ${received.fileName} ${received.size} '
            'bytes sha256=${received.sha256} '
            'match=${received.sha256Matched}');
        stdout.writeln('[recv] path ${received.savedPath}');
        // M3 §6.3: one ReceivedFile == one inbound `done` message. The file is
        // already on disk and its hash verified by the time we are called.
        history?.record(received, DateTime.now().toUtc());
      },
    );
    await server.start();

    final self = server.deviceInfo;
    selfKey = normalizeFingerprint(self.fingerprint);

    final subscription =
        registry.events.listen((event) => _printEvent(event, verbose));
    final sweeper = Timer.periodic(
      const Duration(seconds: 1),
      (_) => registry.sweepOffline(DateTime.now()),
    );

    Future<void> registerTo(DeviceInfo peer, String address) async {
      final client = PeerClient(
        host: address,
        port: peer.port,
        expectedFingerprint: peer.fingerprint,
        // Present our own identity as the TLS **client** certificate (see the
        // matching note in send_command): `badCertificateCallback` only decides
        // whether we trust the peer, not whether the peer can see our
        // certificate. LocalSend HTTPS is mutual TLS, so a peer that requires a
        // client certificate would otherwise reject this `register` handshake
        // with `TLSV1_ALERT_CERTIFICATE_REQUIRED`.
        certificate: certificate,
        onLog:
            verbose ? (message) => stdout.writeln('[client] $message') : null,
      );
      try {
        final reply = await client.register(self: self);
        if (isSelf(reply)) {
          logSelfIgnored();
          return;
        }
        registry.touch(
          reply,
          address: address,
          source: PeerSource.register,
          now: DateTime.now(),
        );
      } on Object catch (error) {
        if (verbose) {
          stderr.writeln('[register] $address:${peer.port} failed: $error');
        }
      } finally {
        client.close();
      }
    }

    var scanning = false;

    Future<void> runScan() async {
      if (scanning) {
        return;
      }
      scanning = true;
      try {
        stdout.writeln('scanning '
            '${_describeScanTarget(scanPrefix, egress?.address)} on '
            'tcp ${config.tcpPort} ...');
        final results = await scanSubnet(
          self: self,
          port: config.tcpPort,
          prefix: scanPrefix,
          interfaceAddress: egress?.address,
          onLog:
              verbose ? (message) => stdout.writeln('[scan] $message') : null,
          onProbe: verbose
              ? (address, result) {
                  if (result != null) {
                    stdout.writeln('[scan] hit $address -> '
                        '${result.info.alias} '
                        'fp=${_shortFingerprint(result.fingerprint)}');
                  }
                }
              : null,
        );
        var added = 0;
        for (final result in results) {
          // Store the fingerprint actually observed on the wire, not the value
          // the peer claimed in its JSON: the scan path accepts unknown certs
          // (TOFU), so the self-reported field is not trustworthy — the same
          // reason the multicast path pins the certificate.
          final peer = result.info.copyWith(fingerprint: result.fingerprint);
          if (isSelf(peer)) {
            logSelfIgnored();
            continue;
          }
          registry.touch(
            peer,
            address: result.address,
            source: PeerSource.subnetScan,
            now: DateTime.now(),
          );
          added++;
        }
        stdout.writeln('scan: $added device(s)');
      } finally {
        scanning = false;
      }
    }

    final discovery = MulticastDiscovery(
      deviceInfo: self,
      group: config.multicastGroup,
      port: config.udpPort,
      multicastInterface: egress,
      // `--broadcast-only` turns the multicast leg off (no join, no multicast
      // datagram) while the receive socket and the broadcast leg stay on.
      multicastEnabled: legs.multicastEnabled,
      broadcastEnabled: legs.broadcastEnabled,
      listen: legs.listen,
      announceInterval: Duration(seconds: interval),
      onLog: verbose ? (message) => stdout.writeln('[udp] $message') : null,
      onPeer: (peer, sourceAddress, transport) {
        if (isSelf(peer)) {
          logSelfIgnored();
          return;
        }
        registry.touch(
          peer,
          address: sourceAddress,
          // `multicast` or `broadcast` — the leg is recorded, not flattened, so
          // the summary can show which path carried each device (0.2.34).
          source: transport.peerSource,
          now: DateTime.now(),
        );
        // Answer every announcement with the register handshake, but only once
        // per peer, to verify the fingerprint and exchange information.
        final key = normalizeFingerprint(peer.fingerprint);
        if (key.isNotEmpty && registered.add(key)) {
          unawaited(registerTo(peer, sourceAddress));
        }
      },
    );
    await discovery.start();

    // The mode line is unconditional: a log that does not say which legs were
    // live invites exactly the misreading this switch exists to prevent.
    stdout.writeln(legs.banner);
    if (legs.broadcastOnly) {
      // The egress banner claims "for multicast". Printing it here would be a
      // lie — and `diag-multicast.cmd` reads that line as "egress was pinned".
      stdout.writeln('multicast egress unused in this mode: broadcasts leave '
          'from every private interface');
    } else {
      stdout.writeln(multicastBanner);
    }
    if (verbose) {
      final targets = discovery.broadcastTargets;
      stdout.writeln('broadcast targets: ${targets.isEmpty ? '(none)' : targets.map((target) => '${target.interfaceName}=${target.addressText} '
          '-> ${target.directedBroadcasts.join('|')}').join(', ')}');
    }
    stdout.writeln('discovering as $alias '
        'tcp=${config.tcpPort} udp=${config.udpPort} '
        'fp=${_shortFingerprint(self.fingerprint)} '
        '(Ctrl-C to stop)');
    stdout.writeln(accept
        ? 'receiving enabled -> ${receiveDirectory.absolute.path}'
        : 'receiving disabled (use --accept to enable)');

    Timer? scanTimer;
    if (scan) {
      unawaited(runScan());
      scanTimer = Timer.periodic(
        Duration(seconds: scanPeriod),
        (_) => unawaited(runScan()),
      );
    }

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

    scanTimer?.cancel();
    sweeper.cancel();
    await subscription.cancel();
    await discovery.stop();
    await server.stop();
    history?.close();

    final all = registry.all;
    stdout.writeln('--- summary: ${all.length} device(s), '
        '${registry.online.length} online ---');
    for (final peer in all) {
      stdout.writeln('${peer.isOnline ? 'online ' : 'offline'} '
          '${peer.info.alias} (${peer.address}:${peer.info.port}) '
          'fp=${_shortFingerprint(peer.fingerprint)} '
          'via ${peer.lastSource.name}');
    }
    await registry.dispose();
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

  void _printEvent(PeerEvent event, bool verbose) {
    final peer = event.peer;
    final symbol = switch (event) {
      PeerAdded() => '+',
      PeerUpdated() => '~',
      PeerCameOnline() => '=',
      PeerWentOffline() => '-',
      PeerRemoved() => 'x',
    };
    final note = switch (event) {
      PeerAdded() => 'new',
      // 0.2.47 — `PeerUpdated` is no longer alias-only: it also fires when the
      // port the peer listens on changes (the "对端重启" shape, which is the
      // one recovery that produces no other event). Naming whichever field
      // actually moved keeps the line honest instead of printing
      // "alias changed (was null)".
      PeerUpdated(:final previousAlias, :final previousPort) => switch ((
        previousAlias,
        previousPort,
      )) {
          (final String alias, _) when alias.isNotEmpty =>
            'alias changed (was $alias)'
                '${previousPort == null ? '' : ', port $previousPort'}',
          (_, final int port) => 'port changed (was $port)',
          _ => 'updated',
        },
      PeerCameOnline() => 'online',
      PeerWentOffline() => 'offline',
      PeerRemoved() => 'removed',
    };
    final fingerprint = verbose
        ? normalizeFingerprint(peer.fingerprint)
        : _shortFingerprint(peer.fingerprint);
    final model = peer.info.deviceModel ?? '';
    // `via` names the leg the last sighting arrived on. With two legs in play
    // (0.2.34) this is what tells "multicast works" apart from "broadcast is
    // carrying us", which is the reading a firewall test needs.
    stdout.writeln('[${_stamp()}] $symbol ${peer.info.alias}  '
        '(${peer.address}:${peer.info.port})  fp=$fingerprint  '
        '${peer.info.deviceType.wire}  $model  via ${peer.lastSource.name}  '
        '- $note');
  }
}

/// The discovery legs one `discover` run uses.
///
/// Extracted from the command so it can be asserted **without opening a
/// socket**: `--broadcast-only` must mean "multicast off, broadcast on, receive
/// socket still open". A wrong boolean here would turn the probe into a normal
/// run — which does find peers on a healthy LAN, so it would look like a
/// success while proving the opposite of what the probe exists for.
class DiscoveryLegs {
  const DiscoveryLegs({
    required this.multicastEnabled,
    required this.broadcastEnabled,
    required this.listen,
    required this.broadcastOnly,
  });

  /// Whether the multicast group is joined and multicast datagrams are sent.
  final bool multicastEnabled;

  /// Whether the subnet-broadcast leg is sent. Always `true` from
  /// [discoveryLegs]: it is the leg under test, and switching it off would
  /// leave nothing at all.
  final bool broadcastEnabled;

  /// Whether the UDP receive socket is bound. Always `true` from
  /// [discoveryLegs]: a probe that does not listen cannot discover anything.
  final bool listen;

  /// Whether the run was started with `--broadcast-only`.
  final bool broadcastOnly;

  /// The startup line that names the mode, so a log can never be ambiguous
  /// about which legs were live.
  String get banner => broadcastOnly
      ? 'mode: broadcast-only (multicast group NOT joined, broadcasts only)'
      : 'mode: multicast + broadcast (both legs live)';
}

/// Maps `discover`'s command line to the legs [MulticastDiscovery] should use.
///
/// `--broadcast-only` disables **only** the multicast leg: no group join and no
/// multicast datagram, while the receive socket and the broadcast leg stay on.
DiscoveryLegs discoveryLegs({required bool broadcastOnly}) => DiscoveryLegs(
      multicastEnabled: !broadcastOnly,
      broadcastEnabled: true,
      listen: true,
      broadcastOnly: broadcastOnly,
    );

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

String _shortFingerprint(String fingerprint) {
  final normalized = normalizeFingerprint(fingerprint);
  if (normalized.length <= 8) {
    return normalized;
  }
  return normalized.substring(0, 8);
}

String _stamp() {
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
}

/// Normalises a user supplied `--scan-prefix` into the `a.b.c.` form that
/// `scanSubnet` expects. Accepts `a.b.c`, `a.b.c.` and `a.b.c.0/24`.
String _normalizeScanPrefix(String value) {
  var text = value.trim();
  final slash = text.indexOf('/');
  if (slash >= 0) {
    text = text.substring(0, slash);
  }
  final parts = text.split('.').where((part) => part.isNotEmpty).toList();
  final octets = parts.length >= 4 ? parts.sublist(0, 3) : parts;
  return '${octets.join('.')}.';
}

/// Human readable scan banner, mirroring `scanSubnet`'s target precedence so it
/// never lies about the scope: an explicit [prefix] wins, else the chosen
/// egress NIC [interfaceAddress] names its `/24`, else `local subnet(s)` (the
/// enumerate-all fallback can span several subnets, so no address is claimed).
///
/// e.g. `192.168.5.6` -> `192.168.5.0/24`.
String _describeScanTarget(String? prefix, String? interfaceAddress) {
  if (prefix != null) {
    final base =
        prefix.endsWith('.') ? prefix.substring(0, prefix.length - 1) : prefix;
    return '$base.0/24';
  }
  if (interfaceAddress != null) {
    final scoped = _prefixOfAddress(interfaceAddress);
    if (scoped != null) {
      final base = scoped.substring(0, scoped.length - 1);
      return '$base.0/24';
    }
  }
  return 'local subnet(s)';
}

/// The `/24` prefix (`a.b.c.`) of [address], or `null` when it is not a
/// well-formed dotted-quad IPv4 string. Mirrors `scanSubnet`'s own prefixing.
String? _prefixOfAddress(String address) {
  final parts = address.split('.');
  if (parts.length != 4) {
    return null;
  }
  return '${parts[0]}.${parts[1]}.${parts[2]}.';
}

/// Resolves `--db`: `null` when the option is absent, the default location when
/// it is given without a value, else the supplied path.
String? _resolveDbPath(Map<String, String> options) {
  final raw = options['db'];
  if (raw == null) {
    return null;
  }
  if (raw == 'true' || raw.isEmpty) {
    return _defaultDbPath();
  }
  return raw;
}

/// The default history database location (`%LOCALAPPDATA%\lanlink\lanlink.db`).
String _defaultDbPath() {
  final base = Platform.environment['LOCALAPPDATA'] ??
      Platform.environment['XDG_DATA_HOME'] ??
      Directory.current.path;
  return <String>[base, 'lanlink', 'lanlink.db'].join(Platform.pathSeparator);
}

/// Lazily-opened M3 inbound history recorder for `discover --accept`.
///
/// The database is opened on the first received file rather than at start-up,
/// so a plain `discover` (even with `--db`) never creates a file until it
/// actually accepts something. A failure to open is reported once and then
/// ignored: recording must never break reception.
class _InboundHistory {
  _InboundHistory(this._dbPath);

  final String _dbPath;

  SessionStore? _store;
  bool _openFailed = false;

  /// Records one received file as an inbound `done` message (spec §6.3).
  void record(ReceivedFile file, DateTime now) {
    final sender = file.sender;
    if (sender == null || normalizeFingerprint(sender.fingerprint).isEmpty) {
      // Without an identifiable sender there is no device (and therefore no
      // conversation) the message could belong to.
      return;
    }
    final store = _ensureStore();
    if (store == null) {
      return;
    }
    try {
      store.recordIncomingFile(
        sender: sender,
        file: IncomingFileSpec.fromReceivedFile(file),
        now: now,
      );
    } on Object catch (error) {
      stderr.writeln('[history] warning: record incoming file failed ($error)');
    }
  }

  void close() {
    try {
      _store?.close();
    } on Object catch (error) {
      stderr.writeln('[history] warning: close failed ($error)');
    }
    _store = null;
  }

  SessionStore? _ensureStore() {
    final existing = _store;
    if (existing != null) {
      return existing;
    }
    if (_openFailed) {
      return null;
    }
    try {
      final directory = File(_dbPath).parent;
      if (!directory.existsSync()) {
        directory.createSync(recursive: true);
      }
      final store = SessionStore(
          db: LanlinkDatabase.openFile(_dbPath), ids: RandomIdGenerator());
      _store = store;
      return store;
    } on Object catch (error) {
      _openFailed = true;
      stderr.writeln('[history] warning: cannot open $_dbPath ($error); '
          'continuing without history');
      return null;
    }
  }
}
