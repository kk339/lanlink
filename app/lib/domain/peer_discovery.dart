/// Device-discovery port (spec §3.2): online/offline peers, rescan and the
/// multicast **alias** rebroadcast.
///
/// **Layering (M4 §8.1):** pure Dart — imports only this package's `domain/`.
/// The native adapter (`data/real/lan_peer_discovery.dart`) wraps
/// `MulticastDiscovery` + `PeerRegistry`; the fake is fully programmable.
library;

import 'models.dart';

/// A domain event emitted by a [PeerDiscovery].
sealed class DiscoveryEvent {
  /// Const constructor for subclasses.
  const DiscoveryEvent();
}

/// A peer became visible for the first time.
final class PeerAppeared extends DiscoveryEvent {
  /// Creates the event.
  const PeerAppeared(this.peer);

  /// The peer that appeared.
  final DiscoveredPeer peer;
}

/// A known peer's details changed (e.g. alias or port).
final class PeerUpdated extends DiscoveryEvent {
  /// Creates the event.
  const PeerUpdated(this.peer);

  /// The updated peer.
  final DiscoveredPeer peer;
}

/// A peer that was offline is now online.
final class PeerCameOnline extends DiscoveryEvent {
  /// Creates the event.
  const PeerCameOnline(this.peer);

  /// The peer that came online.
  final DiscoveredPeer peer;
}

/// A peer that was online is now offline.
final class PeerWentOffline extends DiscoveryEvent {
  /// Creates the event.
  const PeerWentOffline(this.peer);

  /// The peer that went offline.
  final DiscoveredPeer peer;
}

/// The discovery layer failed (TCP port in use, NIC failure, no NIC).
final class DiscoveryFailed extends DiscoveryEvent {
  /// Creates the event with a human-readable [message].
  const DiscoveryFailed(this.message);

  /// The failure in plain language (drives the E10 error banner).
  final String message;
}

/// The outcome of one **manual** probe — "I typed this IP in, did anything
/// answer?" (0.2.54).
///
/// ## Why the domain port needs this at all
///
/// "Device = session, file = message": a device only becomes sendable by
/// entering the discovery layer's live peer set, and on a network that filters
/// multicast **and** subnet broadcast there is no frame that can ever put it
/// there. A user who knows the peer's address is then stuck with a device list
/// that shows nothing. This result type is the escape hatch's vocabulary: dial
/// one address, report what happened, and let the ordinary machinery (registry →
/// device card → send) take over.
///
/// It reports **facts, not copy**: the human sentence ("对方没响应" / "对端不是
/// lanlink") belongs to the UI, which is why a failure is a typed [reason] plus an
/// optional diagnostic [ManualProbeError.detail] rather than a message.
sealed class ManualProbeResult {
  /// Const constructor for subclasses.
  const ManualProbeResult();
}

/// A probe that reached a **real lanlink peer** and registered this device with
/// it.
final class ManualProbeOk extends ManualProbeResult {
  /// Creates a successful result.
  const ManualProbeOk({
    required this.fingerprint,
    required this.alias,
    required this.port,
    required this.host,
  });

  /// The peer's fingerprint, **measured from the certificate it presented during
  /// the TLS handshake** — never the value its frame claims.
  ///
  /// Normalised (uppercase, separator-free) so it compares equal to
  /// `DiscoveredPeer.fingerprint` / `PeerDevice.fingerprint` and can be used as
  /// the device-list key directly.
  final String fingerprint;

  /// The name the peer described itself with (possibly empty, e.g. a peer that
  /// never finished setup).
  final String alias;

  /// The TCP port the peer **says** its receiver listens on. `0` means it
  /// advertises no inbound server, exactly like `PeerDevice.lastPort == 0` (it is
  /// then not dialable even though the probe answered).
  final int port;

  /// The address that was actually dialled (the host part of the input, with any
  /// IPv6 brackets removed) — this is the address the device card must show,
  /// because it is the one that provably works from this device.
  final String host;

  @override
  String toString() =>
      'ManualProbeOk($alias @ $host, port: $port, fp: $fingerprint)';
}

/// Why a manual probe failed — the classification the UI turns into one sentence.
enum ManualProbeFailure {
  /// Nothing answered: connection refused, host unreachable, or no reply within
  /// the probe's deadline (a black-holed address looks exactly like this).
  unreachable,

  /// Something answered on TCP but the TLS handshake did not give us a usable
  /// certificate, or the peer's frame identity contradicts the certificate it
  /// presented (R-SEC-1). The UI must not pretend this is the device the user
  /// typed.
  certificateMismatch,

  /// A TLS peer answered, but it is not a lanlink peer (or the port is a
  /// different service on the same box): `/api/lanlink/v1/hello` did not reply
  /// with a `hello.reply` frame.
  notLanlink,

  /// The input was not `IP[:port]` at all — empty, not an IP literal, or a port
  /// outside `1…65535`. Nothing was dialled.
  badInput,
}

/// A probe that did not produce a peer.
final class ManualProbeError extends ManualProbeResult {
  /// Creates a failed result.
  const ManualProbeError(this.reason, {this.detail});

  /// The classification (drives the UI's sentence).
  final ManualProbeFailure reason;

  /// The underlying error text, for the log file only — **never** shown as the
  /// user-facing message, because a raw `SocketException` string is not a
  /// sentence a phone user can act on.
  final String? detail;

  @override
  String toString() =>
      'ManualProbeError(${reason.name}${detail == null ? '' : ': $detail'})';
}

/// Lifecycle phase of the discovery layer.
enum DiscoveryPhase { starting, running, failed }

/// A snapshot of the discovery layer's own status (spec §3.2).
class DiscoveryStatus {
  /// Creates a status snapshot.
  const DiscoveryStatus({
    required this.phase,
    this.errorMessage,
    this.selfAlias,
    this.selfAddress,
    this.selfFingerprint,
    this.selfPort,
  });

  /// The current phase.
  final DiscoveryPhase phase;

  /// Failure text when [phase] is [DiscoveryPhase.failed], else `null`.
  final String? errorMessage;

  /// This device's advertised alias.
  final String? selfAlias;

  /// This device's own LAN address, or `null` before the NIC is chosen.
  ///
  /// **Where it comes from (not invented):** the discovery layer already picks an
  /// egress interface for multicast (`LanPeerDiscovery._multicastInterface`, via
  /// `pickEgressInterface()`), and that `LocalInterface.address` **is** this
  /// device's address on the wire. It is passed straight through — no new
  /// protocol field, no extra probe (docs/18 §3.3 / U4).
  final String? selfAddress;

  /// This device's fingerprint.
  final String? selfFingerprint;

  /// This device's advertised TCP port (`> 0` means peers can dial back).
  final int? selfPort;
}

/// Online/offline peer tracking + rescan + alias rebroadcast (spec §3.2).
abstract interface class PeerDiscovery {
  /// Broadcast domain events (see [DiscoveryEvent]).
  Stream<DiscoveryEvent> get events;

  /// The peers currently online (a snapshot of the registry).
  List<DiscoveredPeer> get online;

  /// The discovery layer's own status.
  DiscoveryStatus get status;

  /// A plain-language warning that discovery is degraded on this platform, or
  /// `null` when all is well.
  ///
  /// Set on **Android** in two cases: the multicast lock could not be taken (the
  /// Wi-Fi stack filters multicast/broadcast frames without it, so peers may be
  /// missed), or the background keep-alive is not fully effective (the
  /// foreground service failed to start, or its notice is invisible because
  /// POST_NOTIFICATIONS was denied — the app may then stop announcing once
  /// backgrounded). The UI surfaces it (never silently ignored).
  String? get multicastWarning;

  /// Starts discovery (multicast announce + listen).
  Future<void> start();

  /// Stops discovery.
  Future<void> stop();

  /// Immediately re-announces (plus one subnet scan, when enabled; P1-5).
  Future<void> rescan();

  /// Re-joins the multicast group on the current interfaces and re-announces.
  ///
  /// Distinct from [rescan], which only re-announces: a resume from sleep or a
  /// network change can invalidate the OS group memberships **without** any
  /// socket error, leaving this device announcing into the void while hearing
  /// nobody — which every peer reads as this device being offline. Re-joining is
  /// the cure. Called on app resume, and by the native adapter itself whenever
  /// it notices the local interface set changed.
  Future<void> rejoin();

  /// Changes this device's name by rebuilding the multicast announcement
  /// (spec §1.5). Applied together with `TransferService.setAlias` by
  /// `SettingsController` (spec §4.6).
  Future<void> setAlias(String alias);

  /// Probes **one address typed by the user** and, when a lanlink peer answers,
  /// makes it a live peer — i.e. it appears in [online] and becomes sendable
  /// (0.2.54).
  ///
  /// [input] is `host` or `host:port`, e.g. `192.168.1.23` or
  /// `192.168.1.23:49494`; a bracketed IPv6 literal carries a port as
  /// `[fe80::1]:49494`. A missing port means the lanlink default, `49494`.
  /// Anything else is [ManualProbeFailure.badInput] and nothing is dialled.
  ///
  /// **Contract every implementation must honour:**
  ///
  /// * it never throws — every failure is a [ManualProbeError];
  /// * it returns within a bounded time (the native adapter caps the attempt at
  ///   a few seconds), because a spinner must never be able to hang on a
  ///   black-holed address;
  /// * a success puts the peer into the live peer set with the **observed**
  ///   certificate fingerprint, which is the only thing that makes the device
  ///   sendable (`selectors.mergeDeviceCards` copies a live peer's address/port
  ///   onto the card, and the transfer service dials from the card);
  /// * it persists **nothing** — no device row, no conversation. Discovery state
  ///   is volatile by design (`devices.last_ip` is not where addresses live).
  Future<ManualProbeResult> probeHost(String input);
}
