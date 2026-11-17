/// UDP discovery: announces this device and reacts to peers.
///
/// **Two legs, one frame.** Every announcement goes out on both:
///
///  1. **multicast** to [kMulticastGroup] (`224.0.0.168`), and
///  2. **subnet broadcast** to `255.255.255.255` plus the *directed* broadcast
///     of each private interface (`192.168.1.255`, …).
///
/// Neither leg subsumes the other, which is the whole point (docs/21 §2.1):
/// multicast is forwarded by nothing but reaches peers through a router that
/// happens to relay it, while broadcast is guaranteed not to cross a router
/// (RFC 1812 §4.2.1) but is the datagram an access point is least able to
/// filter. Sending both means one leg being dropped is survivable.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/constants.dart';
import '../protocol/device_info.dart';
import '../security/fingerprint.dart';
import 'announcement.dart';
import 'peer_registry.dart';
import 'subnet_broadcast.dart';

/// Which leg an announcement arrived on.
///
/// Reported per datagram so a caller can record (and, during a firewall test,
/// *prove*) how a peer was found: block multicast and every peer must still
/// appear, but with [broadcast].
enum AnnouncementTransport {
  /// Arrived as a multicast datagram on [kMulticastGroup].
  multicast,

  /// Arrived as a subnet broadcast (`255.255.255.255` or a directed one).
  broadcast,

  /// Could not be attributed — the source port matches neither leg (e.g. a
  /// peer whose announce port is at the 16-bit boundary, where the broadcast
  /// marker port cannot be derived).
  unknown,
}

/// Maps a leg to the [PeerSource] the registry records for it.
///
/// [PeerSource.subnetScan] is deliberately not reachable from here: that leg
/// is a per-address HTTPS probe and has its own caller.
extension AnnouncementTransportSource on AnnouncementTransport {
  /// The registry source that corresponds to this leg.
  PeerSource get peerSource => switch (this) {
        AnnouncementTransport.multicast => PeerSource.multicast,
        AnnouncementTransport.broadcast => PeerSource.broadcast,
        AnnouncementTransport.unknown => PeerSource.multicast,
      };
}

/// Called for every announcement received from another device.
///
/// [sourceAddress] is the IP the datagram came from, which the receiver uses to
/// answer with the HTTP `register` handshake. [transport] names the leg it
/// arrived on (diagnostics + firewall tests).
typedef PeerAnnouncedCallback = void Function(
  DeviceInfo peer,
  String sourceAddress,
  AnnouncementTransport transport,
);

/// Sends one already-encoded announcement to one destination.
///
/// The seam that makes the fan-out testable: injecting a [AnnouncementSender]
/// turns [MulticastDiscovery] into a pure planner that opens **no** sockets, so
/// a test can assert exactly which destinations one announce cycle covers and
/// that every datagram carries the identical frame.
typedef AnnouncementSender = void Function(
  Uint8List bytes,
  InternetAddress target,
  int port,
);

/// Supplies the interfaces the broadcast leg should leave from.
///
/// Defaults to [listBroadcastTargets] (real private IPv4 interfaces). Injected
/// in tests so the fan-out does not depend on the machine's NIC set.
typedef BroadcastTargetsProvider = Future<List<BroadcastTarget>> Function();

/// Multicast + subnet-broadcast sender/receiver for discovery announcements.
///
/// When an announcement arrives the receiver is expected to perform the
/// documented bidirectional handshake by issuing an HTTP `POST /register` back
/// to the announcer (it does **not** simply reply over UDP). Pinning to the
/// announced fingerprint is the caller's job — see [PeerClient].
///
/// ## Interfaces
///
/// Two things are deliberately separated, because on Windows the OS gets both
/// of them wrong by default (verified with `netsh interface ipv4 show joins`
/// and the IPv4 route table):
///
///  * **Receiving** joins [group] on *every* usable IPv4 interface. Calling
///    `joinMulticast(group)` with no interface joins only the OS *default*
///    interface, which on a machine with a VPN adapter is the wrong one.
///  * **Sending** uses a dedicated socket bound to [multicastInterface]. Left
///    to the routing table, multicast egress is stolen by the adapter with the
///    lowest metric (a VPN), so announcements never reach the physical LAN.
///
/// The **broadcast** leg needs its own sockets for the same reason: a datagram
/// to `255.255.255.255` leaves through the interface implied by the socket's
/// bound source address, so one socket per private interface is what makes a
/// multi-homed host (Wi-Fi + Ethernet + VPN) covered on all of them.
class MulticastDiscovery {
  MulticastDiscovery({
    required this.deviceInfo,
    this.group = kMulticastGroup,
    this.port = kDefaultPort,
    this.onPeer,
    this.onLog,
    this.onSocketFailure,
    this.announceInterval = const Duration(seconds: 5),
    this.multicastInterface,
    this.multicastEnabled = true,
    this.broadcastEnabled = true,
    this.listen = true,
    this.sender,
    this.broadcastTargetsProvider,
  });

  /// This device's self description; it must carry the certificate fingerprint.
  final DeviceInfo deviceInfo;

  /// Multicast group to join (default [kMulticastGroup]).
  final String group;

  /// UDP port to bind and to send announcements to (default [kDefaultPort]).
  final int port;

  /// Called for **every** announcement received, including repeats.
  ///
  /// Repeats are intentionally surfaced: the caller refreshes the peer's
  /// `lastSeen` on each one, which is what keeps the online/offline state in
  /// [PeerRegistry] accurate.
  final PeerAnnouncedCallback? onPeer;

  /// Optional diagnostic sink. When `null` the layer stays silent.
  final void Function(String message)? onLog;

  /// Called **once** when the receive socket dies on its own — a read error, or
  /// the OS closing it.
  ///
  /// Neither is reported through [onPeer]: without this hook a socket that
  /// errors out stops delivering datagrams **silently and permanently**, which
  /// is the "we keep announcing but hear nobody" state that reads to every peer
  /// as us being offline. The caller is expected to rebuild discovery (a fresh
  /// socket + a fresh group join); a deliberate [stop] never fires this.
  final void Function(Object error)? onSocketFailure;

  /// How often to re-announce (LocalSend announces periodically).
  ///
  /// One cycle covers **both** legs; the broadcast does not get a cadence of
  /// its own, so turning it on does not increase how often we are on the wire.
  final Duration announceInterval;

  /// Address of the interface used to **send** multicast announcements
  /// (auto-selected by `chooseDefaultMulticastInterface`, or supplied via
  /// `--interface`).
  ///
  /// `null` keeps the legacy "let the OS choose" behaviour, which is only
  /// correct on a single-NIC host.
  final InternetAddress? multicastInterface;

  /// Whether to send the multicast leg and join [group].
  ///
  /// `false` is what an "announcement over broadcast only" probe needs — and
  /// what a test uses to prove the broadcast leg works **on its own**, with no
  /// multicast anywhere in the picture.
  final bool multicastEnabled;

  /// Whether to send the subnet-broadcast leg (default `true`, docs/21 §2.1).
  final bool broadcastEnabled;

  /// Whether to bind the receive socket at all.
  ///
  /// `false` makes this instance a **pure announcer** (no `anyIPv4:port`
  /// socket). Besides being honest about intent, it is what lets two instances
  /// live in one process on one port without fighting over the receive socket.
  final bool listen;

  /// Injected datagram sink. When set, **no sockets are opened at all**: the
  /// instance becomes a planner that reports where each announcement would go.
  final AnnouncementSender? sender;

  /// Injected interface list for the broadcast leg (defaults to the real NICs).
  final BroadcastTargetsProvider? broadcastTargetsProvider;

  RawDatagramSocket? _receiveSocket;
  RawDatagramSocket? _sendSocket;
  Timer? _timer;
  final List<String> _joinedInterfaces = <String>[];

  /// One sending socket per private interface, keyed by its local address.
  ///
  /// Keyed by address (not by `NetworkInterface`) because that is what decides
  /// the egress, and because [prepareBroadcast] can then diff the set after a
  /// network change and close exactly the sockets whose interface went away.
  final Map<String, RawDatagramSocket> _broadcastSockets =
      <String, RawDatagramSocket>{};

  /// Interfaces the broadcast leg currently targets.
  List<BroadcastTarget> _targets = const <BroadcastTarget>[];

  /// Source port the broadcast leg sends from (see [kBroadcastSourcePortOffset]).
  int _broadcastSourcePort = 0;

  /// Interfaces the OS has told us cannot carry multicast, so the message is
  /// said **once** per interface instead of on every re-join.
  final Set<String> _unsupportedInterfaces = <String>{};

  /// Set once [onSocketFailure] has fired for the current receive socket, so a
  /// single death (which may surface as both an error *and* a done event) is
  /// reported exactly once.
  bool _receiveFailureReported = false;

  /// Whether [start] has run and [stop] has not.
  bool _started = false;

  /// Whether the instance is currently announcing.
  bool get isRunning => _started;

  /// Names of the interfaces the group was joined on, in join order.
  ///
  /// Exposed so the CLI can print an accurate startup banner.
  List<String> get joinedInterfaces =>
      List<String>.unmodifiable(_joinedInterfaces);

  /// The interfaces the broadcast leg is currently targeting, in OS order.
  ///
  /// Exposed for the startup banner and for tests.
  List<BroadcastTarget> get broadcastTargets =>
      List<BroadcastTarget>.unmodifiable(_targets);

  /// The UDP source port the broadcast leg sends from, or `0` before [start].
  int get broadcastSourcePort => _broadcastSourcePort;

  /// Binds the socket(s), resolves the broadcast targets and starts announcing.
  Future<void> start() async {
    if (_started) {
      return;
    }
    _receiveFailureReported = false;
    _broadcastSourcePort = _resolveBroadcastSourcePort();
    try {
      await _startSockets();
    } on Object {
      // A half-started instance must be retryable, not a silent no-op.
      _started = false;
      rethrow;
    }
    _started = true;
    _timer = Timer.periodic(announceInterval, (_) => announce());
    announce();
  }

  /// Binds everything [start] needs, leaving `_started` to its caller.
  Future<void> _startSockets() async {
    if (sender != null) {
      // Planning mode: no sockets at all — [announce] reports the destinations
      // one cycle covers instead of putting bytes on the wire.
      await prepareBroadcast();
      return;
    }

    if (listen) {
      final InternetAddress groupAddress = InternetAddress(group);
      final RawDatagramSocket receiveSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
      );
      _receiveSocket = receiveSocket;
      receiveSocket.multicastLoopback = true;
      // Kept: without it some platforms refuse to deliver a datagram sent to a
      // broadcast address to this socket. The receive socket is bound to
      // `anyIPv4`, which is also why a broadcast datagram lands in the *same*
      // handler as a multicast one — same parse, same fingerprint de-dup.
      receiveSocket.broadcastEnabled = true;
      receiveSocket.readEventsEnabled = true;
      // A read error or an OS-initiated close both kill receiving permanently,
      // so both are surfaced (docs/13 §4). `cancelOnError` drops the dead
      // subscription; the caller rebuilds the socket in response.
      receiveSocket.listen(
        (event) => _onEvent(receiveSocket, event),
        onError: (Object error) {
          _log('receive socket error: $error');
          _reportSocketFailure(error);
        },
        onDone: () {
          _log('receive socket closed');
          _reportSocketFailure(
            StateError('the multicast receive socket was closed'),
          );
        },
        cancelOnError: true,
      );

      if (multicastEnabled) {
        await _joinOnEveryInterface(receiveSocket, groupAddress);
      }
    }
    if (multicastEnabled) {
      await _bindSendSocket();
    }
    await prepareBroadcast();
  }

  /// Resolves the interfaces the broadcast leg should cover and opens one
  /// sending socket per interface.
  ///
  /// Idempotent and cheap to call again: the sockets of interfaces that
  /// disappeared are closed and the ones that remain are left untouched, so a
  /// network change ([rejoin]) fixes the broadcast leg without churn. A
  /// failure never throws — the multicast leg must keep working on its own.
  Future<void> prepareBroadcast() async {
    if (!broadcastEnabled) {
      _targets = const <BroadcastTarget>[];
      _closeBroadcastSockets();
      return;
    }
    final BroadcastTargetsProvider provider =
        broadcastTargetsProvider ?? listBroadcastTargets;
    final List<BroadcastTarget> targets;
    try {
      targets = await provider();
    } on Object catch (error) {
      // Keep whatever we had: an enumeration failure is not a reason to stop
      // broadcasting on interfaces we already know about.
      _log('broadcast target enumeration failed: $error');
      return;
    }
    _targets = List<BroadcastTarget>.unmodifiable(targets);
    if (sender != null) {
      return;
    }
    await _bindBroadcastSockets(_targets);
  }

  /// Opens a sending socket for every target that does not have one yet and
  /// drops the sockets of targets that are gone.
  Future<void> _bindBroadcastSockets(List<BroadcastTarget> targets) async {
    final Set<String> wanted = <String>{
      for (final BroadcastTarget target in targets) target.addressText,
    };
    for (final String key in _broadcastSockets.keys.toList(growable: false)) {
      if (wanted.contains(key)) {
        continue;
      }
      _broadcastSockets.remove(key)?.close();
      _log('broadcast egress $key closed (interface is gone)');
    }
    for (final BroadcastTarget target in targets) {
      if (_broadcastSockets.containsKey(target.addressText)) {
        continue;
      }
      try {
        final RawDatagramSocket socket = await RawDatagramSocket.bind(
          target.address,
          _broadcastSourcePort,
          // `true` so the app and a `lanlink discover` probe can coexist on one
          // host, exactly like the receive socket does. We never read from
          // these sockets, so nothing about the sharing is ambiguous.
          reuseAddress: true,
        );
        socket.broadcastEnabled = true;
        _broadcastSockets[target.addressText] = socket;
        _log('broadcast egress ${target.addressText} (${target.interfaceName}) '
            'src port $_broadcastSourcePort -> '
            '$kBroadcastAddress:$port'
            '${target.directedBroadcasts.isEmpty ? '' : ' + '
                '${target.directedBroadcasts.join(', ')}'}');
      } on OSError catch (error) {
        // One unusable NIC must not stop the others (docs/21 §2.1).
        _log('broadcast egress ${target.addressText} unavailable: $error');
      }
    }
  }

  /// Closes every broadcast sending socket.
  void _closeBroadcastSockets() {
    for (final RawDatagramSocket socket in _broadcastSockets.values) {
      socket.close();
    }
    _broadcastSockets.clear();
  }

  /// Derives the broadcast source port, falling back to the announce port when
  /// `port + 1` is not a valid port (the only case where the leg cannot be
  /// attributed on the receive side).
  int _resolveBroadcastSourcePort() {
    final int candidate = port + kBroadcastSourcePortOffset;
    if (candidate < 1 || candidate > 0xFFFF) {
      _log('cannot derive a broadcast source port from $port; the broadcast '
          'leg will share the announce port and cannot be told apart');
      return port;
    }
    return candidate;
  }

  /// Joins [group] on every usable IPv4 interface.
  ///
  /// `joinMulticast(group, interface)` is called once per NIC so a peer's
  /// announcement arrives no matter which physical adapter it reached us on.
  /// When no interface can be joined we fall back to the OS default so the
  /// socket still works on a minimal host.
  Future<void> _joinOnEveryInterface(
    RawDatagramSocket socket,
    InternetAddress group,
  ) async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    _joinedInterfaces.clear();
    var joined = 0;
    var alreadyMember = 0;
    var unsupported = 0;
    for (final interface in interfaces) {
      final hasIpv4 =
          interface.addresses.any((a) => a.type == InternetAddressType.IPv4);
      if (!hasIpv4) {
        continue;
      }
      try {
        socket.joinMulticast(group, interface);
        _joinedInterfaces.add(interface.name);
        joined++;
      } on OSError catch (error) {
        switch (classifyJoinError(error)) {
          case MulticastJoinOutcome.alreadyMember:
            // We are (still) a member, so the OS refuses the duplicate. This is
            // the normal outcome of a re-join — and the join must still be
            // attempted, because a membership the OS dropped silently is only
            // recoverable by re-issuing it. Counted as a member, so the
            // fallback below does not fire on a healthy re-join.
            _joinedInterfaces.add(interface.name);
            alreadyMember++;
          case MulticastJoinOutcome.unsupported:
            unsupported++;
            if (_unsupportedInterfaces.add(interface.name)) {
              _log('interface ${interface.name} does not support multicast '
                  '(will be skipped): $error');
            }
          case MulticastJoinOutcome.failed:
            _log('joinMulticast ${group.address} on ${interface.name} '
                'failed: $error');
        }
      }
    }
    // One line per join instead of one per interface: the interfaces that could
    // not be joined are still visible, and a real failure is no longer buried.
    if (joined > 0 || alreadyMember > 0 || unsupported > 0) {
      _log('multicast join on ${group.address}: $joined joined, '
          '$alreadyMember already a member, $unsupported unsupported');
    }
    if (_joinedInterfaces.isEmpty) {
      try {
        socket.joinMulticast(group);
        _log('joined ${group.address} on the OS default interface');
      } on OSError catch (error) {
        // The last resort failed for real: never silenced.
        _log('joinMulticast ${group.address} failed: $error');
      }
    }
  }

  /// Binds a dedicated socket to [multicastInterface] for sending and pins the
  /// outgoing multicast interface to it.
  ///
  /// Two mechanisms are applied together, because either alone is not
  /// guaranteed on Windows:
  ///
  ///  1. **bind the source address** — constrains the source IP;
  ///  2. **`IP_MULTICAST_IF`** via `setRawOption` — the unambiguous egress
  ///     control (Windows otherwise routes `224.0.0.0/4` by metric and a
  ///     low-metric VPN adapter steals it).
  ///
  /// `RawDatagramSocket.multicastInterface` looks like the right knob but is
  /// `@Deprecated("This property is not implemented …")` in the SDK, so it is
  /// deliberately **not** used (see the note in the body).
  Future<void> _bindSendSocket() async {
    final egress = multicastInterface;
    if (egress == null) {
      if (_receiveSocket != null) {
        _sendSocket = _receiveSocket;
        return;
      }
      // Pure announcer (`listen: false`): there is no receive socket to borrow,
      // and sending on any other interface would silently send nothing.
      try {
        final RawDatagramSocket socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          0,
          reuseAddress: true,
        );
        socket.multicastLoopback = true;
        _sendSocket = socket;
      } on OSError catch (error) {
        _log('bind multicast send socket failed: $error');
      }
      return;
    }

    RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(
        egress.address,
        0,
        reuseAddress: true,
      );
    } on OSError catch (error) {
      _log('bind egress ${egress.address} failed: $error; '
          'falling back to the OS default');
      _sendSocket = _receiveSocket;
      return;
    }
    socket.multicastLoopback = true;

    // Do NOT use `socket.multicastInterface = …`: the SDK marks it
    //   @Deprecated("This property is not implemented. Use getRawOption and
    //   setRawOption instead.")   (dart:io, socket.dart, Dart 3.12.2)
    // and its type is `NetworkInterface?`, so it is both a no-op and a type
    // mismatch. `IP_MULTICAST_IF` is the documented way to pin the egress.
    final optionNumber = _ipMulticastIfOption();
    try {
      socket.setRawOption(RawSocketOption(
        _ipProtoIp,
        optionNumber,
        _ipv4InAddr(egress.address),
      ));
      _log('set IP_MULTICAST_IF to ${egress.address} '
          '(level $_ipProtoIp, optname $optionNumber)');
    } on OSError catch (error) {
      _log('setRawOption IP_MULTICAST_IF failed: $error; egress is only '
          'pinned by the bound source address');
    }

    // Read the option back so the log self-certifies what the kernel holds.
    try {
      final value = socket.getRawOption(RawSocketOption(
        _ipProtoIp,
        optionNumber,
        Uint8List(4),
      ));
      _log('egress multicastInterface = ${_formatInAddr(value)}');
    } on OSError catch (error) {
      _log('getRawOption IP_MULTICAST_IF read-back failed: $error');
    }

    _sendSocket = socket;
  }

  /// Sends **one** announcement cycle: the same frame on every enabled leg.
  ///
  /// The bytes are encoded once and reused, so the multicast and broadcast
  /// datagrams are byte-identical — a receiver cannot tell them apart except by
  /// the source port, and a duplicate arrives as a duplicate announcement,
  /// which the registry de-duplicates by fingerprint.
  void announce() {
    if (!multicastEnabled && !broadcastEnabled) {
      return;
    }
    if (sender == null && !_started) {
      // Not started: no sockets, nothing to send on.
      return;
    }
    final Uint8List bytes = Announcement.of(deviceInfo).encode();
    if (multicastEnabled) {
      _sendMulticast(bytes);
    }
    if (broadcastEnabled) {
      _sendBroadcast(bytes);
    }
  }

  /// Sends [bytes] to the multicast group.
  void _sendMulticast(Uint8List bytes) {
    final InternetAddress target = InternetAddress(group);
    final AnnouncementSender? injected = sender;
    if (injected != null) {
      injected(bytes, target, port);
      return;
    }
    final RawDatagramSocket? socket = _sendSocket;
    if (socket == null) {
      return;
    }
    try {
      socket.send(bytes, target, port);
      _log('announce sent as ${deviceInfo.alias} fp=${deviceInfo.fingerprint}');
    } on OSError catch (error) {
      _log('send failed: $error');
    }
  }

  /// Sends [bytes] to the limited broadcast address **and** the directed
  /// broadcast of every private interface.
  ///
  /// A directed broadcast is sent because `255.255.255.255` is dropped by some
  /// drivers/VMs; `255.255.255.255` is sent because the directed address is a
  /// **guess** whenever `dart:io` cannot report the netmask. Two failures that
  /// do not overlap, for one extra datagram per interface per cycle.
  void _sendBroadcast(Uint8List bytes) {
    final List<BroadcastTarget> targets = _targets;
    if (targets.isEmpty) {
      return;
    }
    final AnnouncementSender? injected = sender;
    if (injected != null) {
      for (final BroadcastTarget target in targets) {
        injected(bytes, InternetAddress(kBroadcastAddress), port);
        for (final String directed in target.directedBroadcasts) {
          injected(bytes, InternetAddress(directed), port);
        }
      }
      return;
    }
    var sent = 0;
    for (final BroadcastTarget target in targets) {
      final RawDatagramSocket? socket = _broadcastSockets[target.addressText];
      if (socket == null) {
        continue;
      }
      try {
        socket.send(bytes, InternetAddress(kBroadcastAddress), port);
        for (final String directed in target.directedBroadcasts) {
          socket.send(bytes, InternetAddress(directed), port);
        }
        sent++;
      } on OSError catch (error) {
        // A broadcast that cannot leave one NIC is not fatal: the other NICs and
        // the multicast leg are still in play.
        _log('broadcast send via ${target.addressText} failed: $error');
      }
    }
    if (sent > 0) {
      _log('announce broadcast as ${deviceInfo.alias} on $sent interface(s): '
          '${targets.map((t) => '${t.interfaceName}=${t.addressText}').join(', ')}'
          ' -> $kBroadcastAddress:$port');
    }
  }

  void _onEvent(RawDatagramSocket socket, RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }
    final datagram = socket.receive();
    if (datagram == null) {
      return;
    }
    final announcement = Announcement.tryDecode(datagram.data);
    if (announcement == null) {
      return;
    }
    final info = announcement.info;
    // Skip our own announcement, which comes back through multicast loopback
    // (and, for the broadcast leg, through the local broadcast delivery).
    if (fingerprintsEqual(info.fingerprint, deviceInfo.fingerprint)) {
      return;
    }
    if (normalizeFingerprint(info.fingerprint).isEmpty) {
      return;
    }
    final AnnouncementTransport transport = _classifyTransport(datagram.port);
    _log('announce received from ${info.alias} @ '
        '${datagram.address.address} via ${transport.name} '
        'fp=${info.fingerprint}');
    onPeer?.call(info, datagram.address.address, transport);
  }

  /// Attributes a received datagram to a leg by its **source port**.
  ///
  /// Both legs carry identical bytes and Dart cannot report a datagram's
  /// destination address, so the port the sender bound to
  /// ([kBroadcastSourcePortOffset]) is the only marker available — see that
  /// constant for why this matters (it is what the firewall test reads).
  AnnouncementTransport _classifyTransport(int sourcePort) {
    if (_broadcastSourcePort == 0) {
      return AnnouncementTransport.unknown;
    }
    if (sourcePort == _broadcastSourcePort) {
      // When the marker port could not be derived it equals the announce port,
      // and the two legs are indistinguishable.
      return _broadcastSourcePort == port
          ? AnnouncementTransport.unknown
          : AnnouncementTransport.broadcast;
    }
    return AnnouncementTransport.multicast;
  }

  /// Reports a spontaneous receive-socket death through [onSocketFailure]
  /// exactly once.
  ///
  /// Ignored when the socket is already gone (`_receiveSocket == null`, which
  /// [stop] sets before closing) so a deliberate shutdown never looks like a
  /// failure, and de-duplicated so onError + onDone for one socket fire once.
  void _reportSocketFailure(Object error) {
    if (_receiveSocket == null || _receiveFailureReported) {
      return;
    }
    _receiveFailureReported = true;
    onSocketFailure?.call(error);
  }

  /// Re-joins [group] on every current interface, re-resolves the broadcast
  /// targets and re-announces **both** legs, without tearing anything down.
  ///
  /// Cures two silent failures that raise **no** socket error: the OS dropping
  /// our IGMP membership, and the interface set changing under us (a network
  /// switch, a Wi-Fi roam, a sleep/wake) so the old joins no longer carry
  /// traffic. Because [_joinOnEveryInterface] and [prepareBroadcast] re-list the
  /// interfaces, a NIC that just appeared is joined and one that vanished is
  /// simply not. Returns `false` when discovery is not running.
  Future<bool> rejoin() async {
    final socket = _receiveSocket;
    if (!_started && socket == null) {
      return false;
    }
    if (socket != null && multicastEnabled) {
      await _joinOnEveryInterface(socket, InternetAddress(group));
    }
    if (_broadcastSourcePort == 0) {
      _broadcastSourcePort = _resolveBroadcastSourcePort();
    }
    await prepareBroadcast();
    announce();
    return true;
  }

  /// Stops announcing and closes the socket(s).
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _started = false;
    final receive = _receiveSocket;
    final send = _sendSocket;
    _receiveSocket = null;
    _sendSocket = null;
    _closeBroadcastSockets();
    _targets = const <BroadcastTarget>[];
    if (send != null && !identical(send, receive)) {
      send.close();
    }
    receive?.close();
  }

  void _log(String message) {
    onLog?.call(message);
  }
}

/// How a failed `joinMulticast` attempt should be read.
enum MulticastJoinOutcome {
  /// We are (still) a member of the group on that interface, so the OS refuses
  /// the duplicate — `EADDRINUSE` (Linux/Android, 98) or `WSAEADDRINUSE`
  /// (Windows, 10048). The normal outcome of a re-join, **not** a failure.
  alreadyMember,

  /// The interface cannot carry multicast at all — `WSAEINVAL` (Windows, 10022)
  /// on a virtual/VPN adapter. Worth saying once per interface, then never
  /// again: retrying cannot ever succeed.
  unsupported,

  /// Anything else — the only outcome that must stay visible as a failure.
  failed,
}

/// Classifies the [error] thrown by `RawDatagramSocket.joinMulticast`.
///
/// Pure so the rule can be pinned by a test: the two benign cases used to share
/// the word `failed` with the one case that matters, and were logged on every
/// re-join — which is how a real failure gets buried.
MulticastJoinOutcome classifyJoinError(Object error) {
  final int? code = error is OSError ? error.errorCode : null;
  final String message = error is OSError ? error.message : '$error';
  final String lower = message.toLowerCase();
  if (code == 98 ||
      code == 10048 ||
      lower.contains('already in use') ||
      lower.contains('address in use')) {
    return MulticastJoinOutcome.alreadyMember;
  }
  if (code == 10022 ||
      lower.contains('invalid argument') ||
      lower.contains('无效的参数')) {
    return MulticastJoinOutcome.unsupported;
  }
  return MulticastJoinOutcome.failed;
}

/// `IPPROTO_IP`, i.e. the `level` argument for `IP_MULTICAST_IF`.
const int _ipProtoIp = 0;

/// The `IP_MULTICAST_IF` optname, which differs per platform.
///
/// Windows and the BSD family (incl. macOS) use `9`; the Linux kernel family
/// (incl. Android) uses `32`. (Winsock `ws2tcpip.h` / BSD `netinet/in.h` = 9;
/// Linux `linux/in.h` = 32.)
int _ipMulticastIfOption() {
  if (Platform.isWindows || Platform.isMacOS) {
    return 9;
  }
  return 32;
}

/// Encodes a dotted-quad IPv4 address as a 4-byte `struct in_addr`.
///
/// The bytes are kept in octet order (network byte order), which is what
/// `setsockopt(IP_MULTICAST_IF)` expects — this is why the convenience
/// `RawSocketOption.fromInt` (host byte order) must **not** be used here.
Uint8List _ipv4InAddr(String address) {
  final parts = address.split('.');
  final bytes = Uint8List(4);
  for (var i = 0; i < 4; i++) {
    bytes[i] = i < parts.length ? (int.tryParse(parts[i]) ?? 0) & 0xff : 0;
  }
  return bytes;
}

/// Formats the 4 bytes of a `struct in_addr` (octet order) as `a.b.c.d`.
String _formatInAddr(Uint8List value) {
  if (value.length < 4) {
    return value.toString();
  }
  return '${value[0]}.${value[1]}.${value[2]}.${value[3]}';
}
