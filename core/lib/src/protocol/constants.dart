/// Protocol constants for the lanlink wire format (v1).
///
/// The frame format is **our own** (design `docs/13`): every JSON frame body
/// carries a version (`v`) and a type (`t`). The transport (HTTP/1.1 over TLS
/// with client certificates), the fingerprint (= DER SHA-256), idempotent
/// message ids and the 14-edge state machine are unchanged.
///
/// The multicast group and the ports are exposed here only as *defaults*: every
/// module takes them as parameters (see [ProtocolConfig]).
library;

/// Frame protocol version carried in every JSON frame's `v` field.
///
/// A frame whose `v` differs is rejected outright (never parsed "best effort").
const int kFrameVersion = 1;

/// Default TCP **and** UDP port. A private-range value, **not** LocalSend's
/// `53317`, so official LocalSend instances never mix into our device list.
const int kDefaultPort = 49494;

/// Default IPv4 multicast group — inside the **Local Network Control Block**.
///
/// `224.0.0.168` was picked for one reason that changes behaviour on real
/// hardware, not for taste (docs/13 §6, docs/21 §2.1):
///
///  * **RFC 4541 §2.1.2**: a switch/AP that runs IGMP snooping must forward
///    every datagram addressed to `224.0.0.0/24` **out of all ports** — it may
///    not treat those groups as "unknown multicast" and drop them. A custom
///    group in `239.0.0.0/8` (what this used to be: `239.255.66.77`) has no
///    such exemption, so on a snooping switch with "drop unknown multicast"
///    our announcements were silently discarded — which is exactly why mDNS
///    (`224.0.0.251`) still works on networks where a custom group does not.
///  * `224.0.0.0/24` is **link-local by definition**: routers never forward it
///    regardless of TTL, so widening the fan-out cannot leak off the LAN.
///  * `224.0.0.168` is **Unassigned** in the IANA IPv4 Multicast Address Space
///    Registry (it sits inside the `224.0.0.153-224.0.0.250` Unassigned block;
///    checked 2026-10-23, `multicast-addresses-1.csv`). `224.0.0.167` is
///    deliberately avoided: LocalSend uses it, and two apps on one LAN that
///    share a group would deliver each other's announcements into the other's
///    socket.
///
/// ⚠️ Changing this value is a **wire-incompatible change**: two devices must
/// both run 0.2.34 or newer to see each other (the subnet-broadcast leg below
/// is a second path, but it carries the same frame and the same `v`).
const String kMulticastGroup = '224.0.0.168';

/// The **limited** broadcast address (RFC 919 "broadcast on the local net").
///
/// Used as the second discovery leg, sent **in addition to** [kMulticastGroup]
/// and carrying the byte-identical announcement frame. It cannot cross a
/// router (RFC 1812 §4.2.1: a router must not forward it), so it is useless
/// across subnets — but inside one subnet it is the datagram an access point
/// is least able to filter, which is precisely the case multicast loses.
const String kBroadcastAddress = '255.255.255.255';

/// UDP source port offset of the broadcast leg: broadcast datagrams leave from
/// `announcePort + kBroadcastSourcePortOffset`.
///
/// A receiving socket bound to `anyIPv4` cannot read the **destination**
/// address of a datagram (Dart exposes no `IP_PKTINFO`), and both legs carry
/// the same bytes — so without a marker the receiver could not tell which path
/// an announcement arrived on. Binding the broadcast sender sockets to a
/// distinct source port is that marker: it costs nothing on the wire and lets
/// the receiver log/report `multicast` vs `broadcast`, which is what makes the
/// firewall test ("block multicast, broadcast must still work") readable.
const int kBroadcastSourcePortOffset = 1;

/// Base path of every HTTP endpoint.
const String kApiBase = '/api/lanlink/v1';

/// `POST` — discovery handshake (M1); body is a `hello` frame.
const String kPathHello = '$kApiBase/hello';

/// `GET` — self-description / health (M1); body is a `hello.reply` frame.
const String kPathInfo = '$kApiBase/info';

/// `POST` — native text message; body is a `text` frame.
const String kPathText = '$kApiBase/text';

/// `POST` — declare files and receive per-file upload tokens (M2).
const String kPathPrepare = '$kApiBase/prepare';

/// `POST` — binary body upload of a single file (M2).
const String kPathPut = '$kApiBase/put';

/// `GET` — resume offset (reserved; **V1 answers `501 Not Implemented`**).
const String kPathResume = '$kApiBase/resume';

/// `POST` — cancel an in-progress session (M2).
const String kPathCancel = '$kApiBase/cancel';

// --- Frame type markers (the `t` field of every JSON frame, docs/13 §7.1) ---

/// UDP multicast announcement.
const String kFrameAnnounce = 'announce';

/// Discovery handshake request (`POST /hello`).
const String kFrameHello = 'hello';

/// Handshake reply / self-description (`POST /hello` and `GET /info` replies).
const String kFrameHelloReply = 'hello.reply';

/// Native text message (`POST /text`).
const String kFrameText = 'text';

/// Generic success receipt (`POST /text`, `POST /cancel` replies).
const String kFrameAck = 'ack';

/// Declare files and request tokens (`POST /prepare`).
const String kFramePrepare = 'prepare';

/// Session id + per-file tokens (`POST /prepare` reply).
const String kFramePrepareReply = 'prepare.reply';

/// Single-file write receipt (`POST /put` reply).
const String kFramePutReply = 'put.reply';

/// Resume offset reply (reserved; `GET /resume`).
const String kFrameResumeReply = 'resume.reply';

/// Unified error body for any non-2xx response.
const String kFrameError = 'error';

/// Default cap on an accepted file size: 10 GiB (M2). A larger declared file is
/// answered `413 Payload Too Large`.
const int kDefaultMaxUploadBytes = 10 * 1024 * 1024 * 1024;

/// Default cap on concurrently open upload sessions (M2). Bounds the server's
/// per-session memory; the next `prepare` past it is answered
/// `503 Service Unavailable`.
const int kDefaultMaxSessions = 64;

/// Default cap on a single text message body in UTF-8 bytes; a larger body is
/// answered `413 Payload Too Large` (docs/13 §7.3).
const int kMaxTextBytes = 64 * 1024;

/// How much of an upload may pass before progress is reported again.
///
/// One mebibyte keeps the callback rate low (a 400 MB file reports ~400 times)
/// while still moving a percentage bar smoothly, and the check is a single
/// integer comparison per chunk — so reporting cannot slow the transfer down.
const int kUploadProgressStepBytes = 1 << 20;

/// Immutable bundle of the network knobs that must stay configurable.
///
/// The discovery modules never hard-code the group or the ports at their call
/// sites; instead a caller builds one of these and threads the values through.
class ProtocolConfig {
  const ProtocolConfig({
    this.multicastGroup = kMulticastGroup,
    this.udpPort = kDefaultPort,
    this.tcpPort = kDefaultPort,
  });

  /// IPv4 multicast group joined for announcements.
  final String multicastGroup;

  /// UDP port bound for announcements (must match across peers on one host).
  final int udpPort;

  /// TCP port of the local HTTP(S) server.
  final int tcpPort;

  /// Returns a copy with the given fields replaced.
  ProtocolConfig copyWith({
    String? multicastGroup,
    int? udpPort,
    int? tcpPort,
  }) {
    return ProtocolConfig(
      multicastGroup: multicastGroup ?? this.multicastGroup,
      udpPort: udpPort ?? this.udpPort,
      tcpPort: tcpPort ?? this.tcpPort,
    );
  }

  @override
  String toString() =>
      'ProtocolConfig(group: $multicastGroup, udp: $udpPort, tcp: $tcpPort)';
}
