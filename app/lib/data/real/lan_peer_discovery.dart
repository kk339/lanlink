/// The native [PeerDiscovery]: wraps `MulticastDiscovery` + `PeerRegistry`
/// (M4 spec §1.3 port 4 / §2).
///
/// **Layering (M4 §8.1):** `data/real/**` — the only layer allowed to import
/// `package:lanlink_core` / `dart:io`. Referenced only by
/// `bootstrap/create_deps_native.dart`, so the Web build never parses it.
///
/// Ownership split (spec §1.3): this adapter owns the **UDP multicast + the
/// registry**; the resident receiver belongs to `LanTransferService`, whose
/// `/register` hits arrive here through the [registrations] stream and are fed
/// into the same registry.
///
/// `core` is imported with a prefix because both it (the registry's
/// `PeerEvent`s) and the domain (`DiscoveryEvent`s) declare `PeerUpdated` /
/// `PeerCameOnline` / `PeerWentOffline`; the prefix keeps the core event types
/// bound to `core.` and the emitted domain types unprefixed.
library;

import 'dart:async';
import 'dart:io';

import 'package:lanlink_core/lanlink_core.dart' as core;

import '../../domain/clock.dart';
import '../../domain/manual_targets.dart';
import '../../domain/models.dart';
import '../../domain/peer_discovery.dart';
import 'android_foreground_service.dart';
import 'android_multicast_lock.dart';
import 'mappers.dart';

/// Builds one multicast layer (`MulticastDiscovery`).
///
/// **Test seam.** A fake can then record `stop()` (the old sockets being
/// closed) and `start()` (the new ones being bound), which is the only honest
/// way to assert that a resume *rebuilds* discovery instead of re-joining a
/// socket that went stale while the phone was asleep. Production passes `null`
/// and gets the real builder in [_buildMulticast].
typedef MulticastBuilder = core.MulticastDiscovery Function();

/// Dials one known peer and pushes this device's description (`/register`).
///
/// **Test seam**, matching [_registerBack]'s signature; production passes `null`.
typedef RegisterBack = Future<void> Function(
  core.DeviceInfo peer,
  String address,
);

/// Awaits [duration].
///
/// **Test seam** for the resume retry backoff: the app has no fake clock, so the
/// policy is asserted by recording the durations instead of sleeping for them
/// (a real 3s + 6s wait would make the suite slow and flaky).
typedef ResumeDelay = Future<void> Function(Duration duration);

/// Builds the `PeerClient` one **manual probe** uses (`probeHost`).
///
/// **Test seam**, production passes `null` and gets the real client. A test
/// needs it because the peers a manual probe is for are, by definition, not on
/// this machine (a phone, a box behind a firewall), and because the two cases
/// that matter most — "the frame's fingerprint contradicts the certificate" and
/// "it answered but presented no readable certificate" — cannot be produced by a
/// real handshake without a real hostile peer.
typedef ProbeClientBuilder = core.PeerClient Function({
  required String host,
  required int port,
});

/// How often every address the user typed in by hand is re-probed.
///
/// ## Why a manual target needs a heartbeat at all (0.2.54)
///
/// `/hello` is the **only** request that refreshes a peer's own registry
/// (`core/peer_server.dart`'s `onPeerSeen`); `/prepare`, `/put` and `/text` do
/// not. And both sides call a peer offline after 60 s (`bootstrap/
/// create_deps_native.dart` passes `offlineAfter: const Duration(seconds: 60)`).
///
/// So a **single** probe has a 60-second lifetime, and it is one-way: once the
/// peer's card goes grey on our screen we can neither send to it (no dialable
/// address) nor let it reach us (`/prepare` from a peer whose `/hello` we never
/// answer is queued, not delivered). Typing the address again every minute is
/// not a feature; re-probing it is.
///
/// ## Why 25 s
///
/// Two heartbeats per 60 s deadline: absent exactly one tick (the isolate was
/// busy, the phone dozed through it), the peer still stays online; and a target
/// that really did go away is noticed in ≤25 s rather than up to a minute. It is
/// also 5× the announce interval (`announceInterval`, 5 s), so the two legs
/// never interleave into a burst.
///
/// The cost is bounded and deliberate: one `/hello` round trip per target per
/// 25 s, only while the user has targets, and reduced to **serial** dialling so
/// three targets can never become three simultaneous handshakes.
const Duration _kManualHeartbeat = Duration(seconds: 25);

/// One parsed `IP[:port]` target (see [_parseHostPort]).
class _HostPort {
  const _HostPort(this.host, this.port);

  /// The address to dial, with IPv6 brackets removed.
  final String host;

  /// The TCP port to dial, always in `1…65535`.
  final int port;

  @override
  String toString() => '$host:$port';
}

/// Parses what a user typed into `IP[:port]`.
///
/// Accepts `1.2.3.4`, `1.2.3.4:5000`, `[fe80::1]`, `[fe80::1]:5000` and a bare
/// `fe80::1` (a port cannot be attached to an unbracketed IPv6 literal, so the
/// whole string is the host). A missing port means `core.kDefaultPort`.
///
/// Returns `null` — i.e. [ManualProbeFailure.badInput], **nothing dialled** —
/// for anything else: no IP literal (`abc`, `192.168.1.300`), an empty host or
/// port, a port outside `1…65535`, or a stray suffix after `]`.
///
/// Strict on purpose. A hostname (`mypc.local`) is deliberately *not* accepted:
/// resolving one would put a DNS query — and a whole class of "which machine did
/// that resolve to?" failures — between the user and the sentence they need,
/// while the feature exists precisely for the case where name-based discovery
/// has already failed.
_HostPort? _parseHostPort(String input) {
  final String text = input.trim();
  if (text.isEmpty) {
    return null;
  }
  String host;
  String? portText;
  if (text.startsWith('[')) {
    final int close = text.indexOf(']');
    if (close < 0) {
      return null;
    }
    host = text.substring(1, close);
    final String rest = text.substring(close + 1);
    if (rest.isNotEmpty) {
      if (!rest.startsWith(':')) {
        return null;
      }
      portText = rest.substring(1);
    }
  } else {
    final int colons = ':'.allMatches(text).length;
    if (colons == 0) {
      host = text;
    } else if (colons == 1) {
      final int split = text.indexOf(':');
      host = text.substring(0, split);
      portText = text.substring(split + 1);
    } else {
      // Two or more colons and no bracket: an IPv6 literal, no port possible.
      host = text;
    }
  }
  if (host.isEmpty || InternetAddress.tryParse(host) == null) {
    return null;
  }
  if (portText == null) {
    return _HostPort(host, core.kDefaultPort);
  }
  final int? port = int.tryParse(portText);
  if (port == null || port < 1 || port > 65535) {
    return null;
  }
  return _HostPort(host, port);
}

/// [PeerDiscovery] backed by UDP multicast and an in-memory [core.PeerRegistry].
///
/// Also implements [ManualTargetsControl] — the **optional** half of the
/// contract (0.2.54): the live set of hand-typed addresses the 25 s heartbeat
/// re-dials. It is a separate interface on purpose (see that file), so the
/// `PeerDiscovery` port keeps the shape every implementation can honour.
class LanPeerDiscovery implements PeerDiscovery, ManualTargetsControl {
  /// Creates the adapter.
  ///
  /// [registrations] is `LanTransferService.registrations`: every live TCP
  /// contact with a peer (an inbound `/register`/`/prepare`/`/put`/`/text`, or
  /// an outbound exchange we initiated) is written into the registry, so a peer
  /// that reaches our server — or that we are actively transferring with —
  /// stays online even while multicast is unavailable (spec §1.3 / §5.1,
  /// docs/13 §4). This is the registry's **second** liveness source besides the
  /// peer's UDP announcement.
  ///
  /// [keepAlive] (Android only) is the foreground service that stops Android
  /// freezing this app's single Dart isolate while it is in the background; it
  /// is started with [start] and stopped in [dispose], and its own warning is
  /// folded into [multicastWarning] so the existing rail indicator surfaces it.
  ///
  /// [multicastBuilder], [registerBack], [delay] and [probeClient] are **test
  /// seams** only (production passes nothing): they let a test prove that a
  /// resume rebuilds the sockets, that the retry policy is 3s/6s, and that the
  /// resume-time `/register` fan-out happens without opening a real connection.
  /// See the typedefs at the top of this file.
  ///
  /// [manualHeartbeatInterval] is the period of the **manual-target heartbeat**
  /// ([heartbeatOnce]); production keeps [_kManualHeartbeat] (25 s), and a test
  /// shortens it so it can observe ticks, and their absence, in milliseconds
  /// instead of minutes. Same shape as [announceInterval]: a real period with a
  /// default, not a fake clock.
  LanPeerDiscovery({
    required core.DeviceCertificate certificate,
    required core.PeerRegistry registry,
    required Clock clock,
    required int selfPort,
    required String alias,
    required Stream<DiscoveredPeer> registrations,
    String group = core.kMulticastGroup,
    int udpPort = core.kDefaultPort,
    InternetAddress? multicastInterface,
    this.egressSelector,
    Duration announceInterval = const Duration(seconds: 5),
    void Function(String message)? onLog,
    bool scanOnRescan = false,
    String? scanPrefix,
    AndroidForegroundService? keepAlive,
    MulticastBuilder? multicastBuilder,
    RegisterBack? registerBack,
    ResumeDelay? delay,
    ProbeClientBuilder? probeClient,
    Duration manualHeartbeatInterval = _kManualHeartbeat,
  })  : _certificate = certificate,
        _registry = registry,
        _clock = clock,
        _selfPort = selfPort,
        _alias = alias,
        _registrations = registrations,
        _group = group,
        _udpPort = udpPort,
        _multicastInterface = multicastInterface,
        _announceInterval = announceInterval,
        _onLog = onLog,
        _scanOnRescan = scanOnRescan,
        _scanPrefix = scanPrefix,
        _keepAlive = keepAlive,
        _multicastBuilder = multicastBuilder,
        _register = registerBack,
        _delay = delay ?? Future<void>.delayed,
        _probeClient = probeClient,
        _manualHeartbeatInterval = manualHeartbeatInterval,
        _status = DiscoveryStatus(
          phase: DiscoveryPhase.starting,
          selfAlias: alias,
          selfFingerprint: certificate.fingerprint,
          selfPort: selfPort,
        );

  final core.DeviceCertificate _certificate;
  final core.PeerRegistry _registry;
  final Clock _clock;
  final int _selfPort;
  final Stream<DiscoveredPeer> _registrations;
  final String _group;
  final int _udpPort;

  /// The interface currently used as multicast egress.
  ///
  /// Mutable: a network change re-picks it (see [_rePickEgress]), because the
  /// boot-time choice can go stale when adapters appear or disappear.
  InternetAddress? _multicastInterface;

  /// Re-picks the multicast egress on demand. `null` keeps [multicastInterface]
  /// pinned for the whole session (tests, or a caller forcing `--interface`).
  final Future<InternetAddress?> Function()? egressSelector;

  /// Set when a re-pick after a network change found nothing usable; merged into
  /// [multicastWarning] so the degradation is visible, never silent.
  String? _egressWarning;
  final Duration _announceInterval;
  final void Function(String message)? _onLog;
  final bool _scanOnRescan;
  final String? _scanPrefix;

  /// The Android background keep-alive, or `null` (non-Android / Web). Its life
  /// is the app's: started with discovery, re-asserted on every resume (see
  /// [rejoin]), stopped in [dispose].
  final AndroidForegroundService? _keepAlive;

  /// Test seam: builds the multicast layer (see [MulticastBuilder]).
  final MulticastBuilder? _multicastBuilder;

  /// Test seam: the per-peer `/register` handshake (see [RegisterBack]).
  final RegisterBack? _register;

  /// Awaitable backoff used by [rejoin]'s retry loop (see [ResumeDelay]).
  final ResumeDelay _delay;

  /// Test seam: the client [probeHost] dials with (see [ProbeClientBuilder]).
  final ProbeClientBuilder? _probeClient;

  /// The period of [heartbeatOnce] (production: [_kManualHeartbeat]).
  final Duration _manualHeartbeatInterval;

  /// Every address the user typed in by hand, keyed by `host:port` (see
  /// [probeHost]).
  ///
  /// A `Map` rather than a `Set` so the last parsed [_HostPort] is kept — the
  /// heartbeat re-dials exactly what the probe dialled, not a re-parse of what
  /// the user typed (a bare `fe80::1` and `[fe80::1]` must not become two
  /// targets). Insertion order is the dial order, which makes the serial
  /// heartbeat's log readable.
  ///
  /// **A target is kept after a failed probe on purpose.** "The peer is not up
  /// right now" (a phone whose receiver was off, a box mid-reboot) is precisely
  /// the state the heartbeat exists to recover from: the user typed the address
  /// once, so the app keeps trying it and the device appears by itself when it
  /// comes back. Removing a target is a **user action**
  /// ([removeManualTarget], from 设置 →「手动添加的设备」), never a probe outcome —
  /// with one exception, which is not a failure at all: an address that turns out
  /// to be *this* device is dropped again in [probeHost], because dialling
  /// ourselves every 25 s helps nobody.
  final Map<String, _HostPort> _manualTargets = <String, _HostPort>{};

  /// Drives [heartbeatOnce]. Exists **iff** [_manualTargets] is non-empty and
  /// this adapter is not disposed — the same "existence is the invariant"
  /// shape as `OutboxPump._syncScanTimer`, maintained by
  /// [_syncManualHeartbeat] alone.
  Timer? _manualHeartbeat;

  /// True while one [heartbeatOnce] pass is running.
  ///
  /// A pass is serial and each dial carries a 3 s deadline
  /// ([_kManualProbeTimeout]), so a pass over many targets can outlast the 25 s
  /// period. Without this guard the next tick would start a second pass and the
  /// two would interleave — i.e. the concurrency this design deliberately
  /// avoids. A skipped tick is one lost attempt, not a leak: the following tick
  /// picks the work up.
  bool _manualHeartbeatRunning = false;

  /// Last **reported** health per target key, so the log says something only
  /// when the answer changed (25 s × N targets of "still reachable" is noise,
  /// and noise is what makes a real failure invisible).
  final Map<String, bool> _manualTargetHealthy = <String, bool>{};

  final StreamController<DiscoveryEvent> _events =
      StreamController<DiscoveryEvent>.broadcast();

  final Set<String> _registered = <String>{};

  String _alias;
  core.MulticastDiscovery? _multicast;
  Timer? _sweeper;
  Timer? _netWatcher;
  StreamSubscription<core.PeerEvent>? _registrySubscription;
  StreamSubscription<DiscoveredPeer>? _registrationSubscription;
  DiscoveryStatus _status;

  /// The last observed `name:addresses|…` signature of the local IPv4
  /// interfaces, used to notice a network change (see [_pollInterfaces]).
  String? _interfaceSignature;

  /// Set by [dispose]; blocks any in-flight or scheduled recovery.
  bool _disposed = false;

  /// True while a socket-failure recovery is running, so overlapping failures
  /// (onError + onDone, or two errors) cannot start two rebuilds at once.
  bool _recovering = false;

  /// How many times [onSocketFailure] rebuilds before giving up and surfacing
  /// `failed` (a bounded, honest give-up — never an infinite rebuild loop).
  static const int _kMaxRecoveries = 3;

  /// Base delay between recovery attempts; multiplied by the attempt number.
  static const Duration _kRecoveryDelay = Duration(seconds: 2);

  /// How many times a **resume** rebuilds before declaring discovery failed.
  ///
  /// The first attempt is immediate; the remaining two are spaced by
  /// [_kResumeRetryDelay] × attempt (3s, then 6s). Two retries is deliberate:
  /// `AppLifecycleState.resumed` reaches Dart **before** Android has finished
  /// re-associating Wi-Fi, so attempt #1 may legitimately fail on a network that
  /// is still coming up — but a phone that needs longer than 15s has a real
  /// problem, and the E10 banner ("点击重试") is the honest answer then.
  static const int _kResumeAttempts = 3;

  /// Backoff unit for [rejoin] (3s, then 6s — see [_kResumeAttempts]).
  static const Duration _kResumeRetryDelay = Duration(seconds: 3);

  /// How many peers the resume-time `/register` fan-out dials concurrently.
  ///
  /// A phone that has been asleep for an hour may know ten peers; dialling all
  /// of them at once would put ten TLS handshakes on a link that has just come
  /// up. Three is enough to be fast and few enough to stay polite.
  static const int _kRegisterFanOut = 3;

  /// How often the local interface set is polled for a network change.
  ///
  /// A network switch / Wi-Fi roam / sleep-wake can invalidate the OS group
  /// memberships **without** raising a receive-socket error, so no callback
  /// would fire; polling is the plugin-free way to notice it and re-join.
  static const Duration _kNetworkPollInterval = Duration(seconds: 10);

  @override
  Stream<DiscoveryEvent> get events => _events.stream;

  @override
  List<DiscoveredPeer> get online =>
      _registry.online.map(discoveredPeerFromPeer).toList(growable: false);

  @override
  DiscoveryStatus get status => _status;

  @override
  String? get multicastWarning => _multicastWarning ??
      _egressWarning ??
      _keepAliveWarning ??
      _keepAlive?.warning;

  /// Set when an **out-of-band** re-assertion of the keep-alive failed (0.2.54,
  /// see [ensureKeepAlive]). Folded into [multicastWarning] so the existing rail
  /// indicator reports it — a degradation nobody can see is the failure mode this
  /// chain exists to prevent.
  String? _keepAliveWarning;

  /// The `host:port` targets the manual heartbeat is keeping alive, in dial
  /// order.
  ///
  /// Read-only view for tests and for the log; empty means "the user has not
  /// typed an address on this device". Not on the [PeerDiscovery] port: no
  /// screen reads it (the device list is built from the registry, which is
  /// where a manual target actually lands, and the 「手动添加的设备」 block reads
  /// the persisted `AppSettings.manualPeers`). The user-facing list of addresses
  /// is managed through [ManualTargetsControl] ([manualTargets] /
  /// [addManualTarget] / [removeManualTarget]); this `Set` stays as the
  /// `host:port`-shaped view the 0.2.54 heartbeat tests were written against.
  ///
  /// **Test/diagnostic seam** — no production caller. Annotating it
  /// `@visibleForTesting` would mean importing `package:meta`, which this app
  /// does not declare (the UI gets the annotation free through
  /// `package:flutter/material.dart`; `data/real/**` deliberately imports no
  /// Flutter). Same choice as `OutboxPump.onAppResumed`.
  Set<String> get manualProbeTargets =>
      Set<String>.unmodifiable(_manualTargets.keys);

  /// Whether the manual heartbeat timer is currently armed.
  ///
  /// The invariant this exists to let a test judge: armed **iff** there is at
  /// least one manual target. A `Timer` is invisible from the outside, and
  /// asserting "nothing dialled for 60 ms" would pass just as well on a timer
  /// that is armed with a wrong period, so the existence itself is exposed.
  ///
  /// **Test/diagnostic seam** — no production caller (see
  /// [manualProbeTargets] for why there is no annotation).
  bool get hasManualHeartbeat => _manualHeartbeat != null;

  /// The period the heartbeat was built with (production:
  /// [_kManualHeartbeat], 25 s).
  ///
  /// Exposed so the **number** can be judged without waiting for it: "the
  /// deadline is 60 s and the heartbeat is 25 s" is a ratio, and a test that
  /// proves the ratio by sleeping would be a slow test rather than a strict
  /// one. Same test/diagnostic seam as [hasManualHeartbeat].
  Duration get manualHeartbeatPeriod => _manualHeartbeatInterval;

  // ── manual targets: the user's own list of addresses to re-dial (0.2.54) ──
  //
  // [probeHost] is how an address *arrives* (the user typed it and a peer
  // answered); [addManualTarget] is how one arrives without a dial (the
  // addresses a previous session remembered, replayed at boot — see
  // `bootstrap/create_deps_native.dart`); [removeManualTarget] is the way out.
  // All three share one parser ([_normalizeTarget]) and one set
  // ([_manualTargets]), so "what the user typed", "what is dialled every 25 s"
  // and "what is remembered" can never be three different things.

  /// The addresses the heartbeat re-dials, in insertion order.
  ///
  /// A read-only **snapshot**: the heartbeat mutates the live map while it
  /// iterates a copy of it, and a caller holding this list must never be able to
  /// change what is dialled.
  List<({String host, int port})> get manualTargets =>
      List<({String host, int port})>.unmodifiable(
        <({String host, int port})>[
          for (final _HostPort target in _manualTargets.values)
            (host: target.host, port: target.port),
        ],
      );

  @override
  int get manualTargetCount => _manualTargets.length;

  @override
  bool get manualTargetsFull => _manualTargets.length >= kMaxManualPeers;

  /// Adds [host]:[port] to the re-dial set — the boot-time replay path.
  ///
  /// Validated with **exactly** [probeHost]'s rule ([_normalizeTarget] is the
  /// same predicate), so a value that could not be dialled once can never become
  /// a target: a malformed address is logged and ignored rather than throwing
  /// out of a startup path.
  ///
  /// Idempotent, and **refused at capacity** ([manualTargetsFull]): the ninth
  /// address is not added, because nine permanently-unreachable targets would
  /// make one heartbeat pass (8 × 3 s serial worst case = 24 s) longer than the
  /// 25 s period and starve the ones that do answer. The refusal is recorded —
  /// a silently dropped address is exactly the "it just does not work" bug this
  /// feature exists to remove.
  @override
  void addManualTarget(String host, int port) {
    final _HostPort? target = _normalizeTarget(host, port);
    if (target == null) {
      _onLog?.call('manual target: ignored "$host:$port" '
          '(not an IP literal, or the port is outside 1…65535)');
      return;
    }
    _rememberTarget(target, reason: 'added by the caller');
  }

  /// Stops re-dialling [host]:[port] (idempotent).
  ///
  /// **The registry is deliberately untouched.** Forgetting a dial target and
  /// deleting a device are two different user intentions: the peer that address
  /// reached is an ordinary live peer and must go grey on its own when it stops
  /// answering (`PeerRegistry.sweepOffline`), exactly like a peer found by
  /// multicast. Anything else would make “我删了一个地址，设备也跟着消失了”
  /// look like data loss.
  @override
  void removeManualTarget(String host, int port) {
    final _HostPort? target = _normalizeTarget(host, port);
    if (target == null) {
      _onLog?.call('manual target: cannot remove "$host:$port" (not an address)');
      return;
    }
    _forgetTarget(target.toString(), reason: 'removed by the user');
  }

  /// Seeds the addresses an **earlier session** remembered, without dialling.
  ///
  /// Called once at boot (`bootstrap/create_deps_native.dart`) with
  /// `AppSettings.manualPeers`, which is why it takes the persisted type: the
  /// document and the live set then describe the same addresses by
  /// construction. Dialling is *not* this method's job — the caller runs one
  /// [heartbeatOnce] pass in the background, so a dead address costs a 3 s
  /// timeout somewhere off the startup path instead of blocking it.
  void seedManualTargets(Iterable<ManualPeerTarget> targets) {
    for (final ManualPeerTarget target in targets) {
      addManualTarget(target.host, target.port);
    }
  }

  /// Re-asserts the platform keep-alive from **outside** a resume (0.2.54).
  ///
  /// ## Why this exists
  ///
  /// The keep-alive's whole life used to be "started by [start], re-asserted by
  /// [rejoin]". A hand-typed address breaks that assumption: the escape hatch
  /// exists for the case where discovery never came up (a network that eats both
  /// multicast and broadcast), and [probeHost] is deliberately usable then. With
  /// no [start] there is no foreground service and no wake lock, so on Android
  /// the isolate is cached the moment the user switches apps and the 25 s
  /// heartbeat simply stops — silently, which is the worst way for a rescue path
  /// to fail.
  ///
  /// ## Best effort, always
  ///
  /// `ensureRunning` itself never throws, and this wraps it anyway: a boot path
  /// must not be able to fail because a platform channel misbehaved. A genuine
  /// failure is folded into [multicastWarning] (via [_keepAliveWarning]) so the
  /// 本机信息 rail indicator can say "后台保活未确认" instead of the app pretending
  /// everything is fine. No permission is added and the manifest is untouched —
  /// the service is the one the app already ships.
  Future<void> ensureKeepAlive() async {
    final AndroidForegroundService? keepAlive = _keepAlive;
    if (keepAlive == null) {
      return;
    }
    try {
      await keepAlive.ensureRunning();
      _keepAliveWarning = null;
    } on Object catch (error) {
      _keepAliveWarning = '后台保活没能确认（$error）：锁屏或切到后台后可能收不到设备';
      _onLog?.call(_keepAliveWarning!);
    }
  }

  /// Adds [target] to the live set unless it is already there or the set is
  /// full, arming the heartbeat when it actually grew.
  ///
  /// Returns whether the set now contains it — i.e. whether the caller may
  /// expect it to be re-dialled. Used by both [probeHost] and [addManualTarget]
  /// so the capacity rule lives in exactly one place.
  bool _rememberTarget(_HostPort target, {required String reason}) {
    final String key = target.toString();
    if (_manualTargets.containsKey(key)) {
      // Idempotent: re-typing an address the app already knows is free.
      return true;
    }
    if (manualTargetsFull) {
      _onLog?.call('manual target: refusing $key — ${_manualTargets.length} of '
          '$kMaxManualPeers already kept; remove one to add another');
      return false;
    }
    _manualTargets[key] = target;
    _onLog?.call('manual target: $key $reason; '
        '${_manualTargets.length}/$kMaxManualPeers targets');
    _syncManualHeartbeat();
    return true;
  }

  /// Drops [key] from the live set and from the health memo; cancels the timer
  /// when that empties the set.
  void _forgetTarget(String key, {required String reason}) {
    if (_manualTargets.remove(key) == null) {
      return;
    }
    _manualTargetHealthy.remove(key);
    _onLog?.call('manual target: $key $reason; '
        '${_manualTargets.length}/$kMaxManualPeers targets left');
    // `_syncManualHeartbeat` (not `_cancelManualHeartbeat`) so the invariant
    // "armed iff non-empty" keeps exactly one owner.
    _syncManualHeartbeat();
  }

  /// Parses a `(host, port)` pair with [probeHost]'s rules.
  ///
  /// The same predicate as [_parseHostPort], split from it because a seeded
  /// target arrives as two fields rather than one string. Brackets around an
  /// IPv6 literal are stripped, so `[fe80::1]` and `fe80::1` are one target (and
  /// therefore one dial) rather than two.
  _HostPort? _normalizeTarget(String host, int port) {
    String text = host.trim();
    if (text.startsWith('[') && text.endsWith(']') && text.length > 2) {
      text = text.substring(1, text.length - 1);
    }
    if (text.isEmpty || InternetAddress.tryParse(text) == null) {
      return null;
    }
    if (port < 1 || port > 65535) {
      return null;
    }
    return _HostPort(text, port);
  }

  /// The Android multicast lock, held for as long as discovery runs (see
  /// `android_multicast_lock.dart`): the Wi-Fi stack filters multicast frames
  /// without it, so inbound announcements would be missed. The lock's lifetime
  /// is bound to discovery's — one resource, one owner — and `MainActivity`'s
  /// `onDestroy` is the last-resort release.
  static const AndroidMulticastLock _multicastLock = AndroidMulticastLock();

  /// Set when the lock could not be taken; surfaced by the UI (`null` otherwise).
  ///
  /// [multicastWarning] falls back to the keep-alive's own warning when this is
  /// `null`, so the single rail indicator reports either degradation.
  String? _multicastWarning;

  @override
  Future<void> start() async {
    if (_multicast != null) {
      return;
    }
    // Scope 1: the keep-alive's life is the app's. Started here because the app
    // is in the foreground at this point — Android 12+ refuses to start a
    // foreground service from the background, and the whole point is to still be
    // announcing once we *are* backgrounded.
    final AndroidForegroundService? keepAlive = _keepAlive;
    if (keepAlive != null) {
      unawaited(keepAlive.start());
    }
    // Take the lock *first*: without it the Wi-Fi stack drops the very
    // announcements we are about to listen for.
    await _acquireMulticastLock();
    // `??=` so a second — or post-recovery — `start()` never installs duplicate
    // subscriptions. A rebuild that only restarts the *multicast socket* leaves
    // these alive, and a second listener would emit every registry event twice.
    _registrySubscription ??= _registry.events.listen(_onRegistryEvent);
    _registrationSubscription ??= _registrations.listen(_onRegistration);
    _sweeper ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _registry.sweepOffline(_clock.nowUtc()),
    );
    _netWatcher ??= Timer.periodic(
      _kNetworkPollInterval,
      (_) => unawaited(_pollInterfaces()),
    );
    try {
      final multicast = _buildMulticast();
      await multicast.start();
      _multicast = multicast;
      _setStatus(DiscoveryPhase.running);
    } on Object catch (error) {
      _multicast = null;
      // Discovery is not running, so nothing needs the lock.
      await _releaseMulticastLock();
      final message = _humanError(error);
      _setStatus(DiscoveryPhase.failed, message: message);
      _emit(DiscoveryFailed(message));
      // Never silent (M4 §8.5): the controller turns this into the E10 banner.
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    _sweeper?.cancel();
    _sweeper = null;
    _netWatcher?.cancel();
    _netWatcher = null;
    // The heartbeat is a **dialler**, so it must not outlive a stop: a stopped
    // discovery that keeps opening TLS connections to a user-typed address is
    // exactly the "a resource nobody owns" bug this class has been bitten by
    // before. The targets themselves are kept (they are the user's input, not
    // discovery state), so a later [probeHost] — or [addManualTarget], which the
    // controller calls after a successful manual add — still knows them.
    _cancelManualHeartbeat();
    _interfaceSignature = null;
    await _registrySubscription?.cancel();
    _registrySubscription = null;
    await _registrationSubscription?.cancel();
    _registrationSubscription = null;
    final multicast = _multicast;
    _multicast = null;
    await multicast?.stop();
    _registered.clear();
    await _releaseMulticastLock();
    if (_status.phase != DiscoveryPhase.failed) {
      _setStatus(DiscoveryPhase.starting);
    }
  }

  @override
  Future<void> rescan() async {
    // One call, **both** legs: `announce()` sends the multicast frame and the
    // subnet broadcast immediately rather than waiting for the next tick, so
    // pull-to-refresh reaches a peer whose multicast is blocked right away.
    _multicast?.announce();
    if (_scanOnRescan) {
      await _scanSubnet();
    }
  }

  /// Rebuilds discovery after its receive socket died on its own.
  ///
  /// A `RawDatagramSocket` that errors or is closed by the OS stops delivering
  /// datagrams **forever** with no other signal — the "we keep announcing but
  /// hear nobody" state that every peer reads as us being offline. The only cure
  /// is a fresh socket and a fresh group join, which is exactly what
  /// [setAlias] happens to do (and why "保存名称" appears to fix it).
  ///
  /// Guarded so overlapping reports start one rebuild, and bounded
  /// ([_kMaxRecoveries]) so a persistently broken network cannot spin forever —
  /// on final failure the status turns `failed`, which the E10 banner surfaces
  /// and whose retry (`HomeController.retryDiscovery` → [start]) now succeeds
  /// because the dead instance has been cleared.
  Future<void> _onMulticastSocketFailure(Object error) async {
    _onLog?.call('discovery receive socket failed: $error');
    if (_recovering) {
      // A resume rebuild is in flight and owns the layer right now: it will
      // either come up (and the next failure report is a fresh, actionable one)
      // or fall through its own retries to `failed`. Recorded, not silent — this
      // is the one window where a report is deliberately dropped.
      _onLog?.call('socket failure ignored: a rebuild is already in progress');
      return;
    }
    if (_disposed || _multicast == null) {
      return;
    }
    _recovering = true;
    try {
      for (var attempt = 1; attempt <= _kMaxRecoveries; attempt++) {
        await Future<void>.delayed(_kRecoveryDelay * attempt);
        if (_disposed) {
          return;
        }
        if (await _restartMulticast()) {
          _onLog?.call('discovery rebuilt after the receive socket died '
              '(attempt $attempt)');
          return;
        }
      }
      _onLog?.call('discovery rebuild failed after $_kMaxRecoveries attempts');
      _setStatus(
        DiscoveryPhase.failed,
        message: '设备发现已中断，请点击重试或重启 lanlink',
      );
    } finally {
      _recovering = false;
    }
  }

  /// Stops the current multicast layer and starts a fresh one, returning whether
  /// it came up. Leaves `_multicast` `null` when it did not — so a later
  /// [start] (the banner retry) can build from scratch rather than no-op.
  /// Stops the current multicast layer (if any) and starts a fresh one,
  /// returning whether it came up.
  ///
  /// Deliberately tolerates `_multicast == null` — it also **starts** discovery
  /// from nothing, which is what lets [setAlias] revive a device that never got
  /// discovery up. On failure it leaves `_multicast` `null`, so a later [start]
  /// (the E10 banner retry) can build from scratch rather than no-op.
  Future<bool> _restartMulticast() async {
    final previous = _multicast;
    await previous?.stop();
    _multicast = null;
    try {
      final multicast = _buildMulticast();
      await multicast.start();
      _multicast = multicast;
      _setStatus(DiscoveryPhase.running);
      return true;
    } on Object catch (error) {
      _onLog?.call('discovery rebuild failed: $error');
      _multicast = null;
      return false;
    }
  }

  /// Brings discovery **back from a resume** (the port's
  /// [PeerDiscovery.rejoin]): rebuilds the sockets, re-asserts the platform
  /// keep-alives, and tells every known peer we are here over TCP.
  ///
  /// ## Why this rebuilds instead of re-joining (0.2.40)
  ///
  /// It used to call `MulticastDiscovery.rejoin()`, which re-joins the group and
  /// re-announces **on the sockets opened before the phone was asleep**. That
  /// assumes those sockets are still usable, and on Android they are not: a
  /// screen lock tears the Wi-Fi link down, and the sockets opened on the old
  /// `Network` keep "succeeding" while the datagrams go nowhere. `send()` on UDP
  /// reports no error for that, [MulticastDiscovery] can only log what it sees,
  /// and `prepareBroadcast()` keys its sockets by **address** — reconnecting to
  /// the same SSID with the same IP therefore looks like "nothing changed", so
  /// every leg kept reusing a dead socket. Nothing rebuilt them short of a full
  /// `start()`, i.e. restarting the app, which is exactly what the user
  /// reported ("手机只能重新打开软件才会变成在线").
  ///
  /// So the resume path is now the same rebuild the socket-failure path uses
  /// ([_restartMulticast] → `stop()` closes every socket, `start()` binds fresh
  /// ones and re-sets `IP_MULTICAST_IF`). Cost: one extra bind + join per
  /// resume, and a few milliseconds where an announcement cannot be received —
  /// paid once, at a moment the user is looking at the screen.
  ///
  /// Two legs, because either alone is not enough:
  ///
  /// * **Plan A — rebuild** ([_restartMulticast], with [_kResumeAttempts]
  ///   attempts and a 3s/6s backoff, because `resumed` arrives before the Wi-Fi
  ///   link is back);
  /// * **Plan B — TCP** ([_registerWithKnownPeers]): an HTTPS `/register` per
  ///   known peer, which feeds the registry's *second* liveness source on the
  ///   other side ([_onRegistration]). It runs first and independently, so it
  ///   still works when multicast is dead — a lost multicast lock, an AP that
  ///   filters multicast, or a wrongly picked egress.
  @override
  Future<void> rejoin() async {
    if (_disposed) {
      return;
    }

    // Plan B first, and deliberately not awaited: it needs no multicast and must
    // not be skipped when the rebuild below fails (that is the whole point).
    unawaited(_registerWithKnownPeers());

    // Overlapping recoveries would each stop()/start() the layer, and the loser
    // would leave a socket nobody owns. The socket-failure path holds this flag
    // too (see [_onMulticastSocketFailure]).
    if (_recovering) {
      _onLog?.call('rejoin: a recovery is already running; not rebuilding');
      return;
    }
    _recovering = true;
    try {
      // Both are per-platform resources that can be gone without us being told:
      // the OS drops the Wi-Fi multicast filter, and Android kills a cached
      // app's foreground service. `start()` alone cannot fix either on resume —
      // it took the lock once and its `_started` latch never clears.
      await _acquireMulticastLock();
      await _keepAlive?.ensureRunning();

      for (var attempt = 1; attempt <= _kResumeAttempts; attempt++) {
        if (_disposed) {
          return;
        }
        if (await _restartMulticast()) {
          _onLog?.call('rejoin: discovery rebuilt with fresh sockets'
              '${attempt > 1 ? ' (attempt $attempt)' : ''}');
          return;
        }
        if (attempt == _kResumeAttempts) {
          break;
        }
        final Duration backoff = _kResumeRetryDelay * attempt;
        _onLog?.call('rejoin: rebuild failed; retrying in '
            '${backoff.inSeconds}s');
        await _delay(backoff);
      }

      // Giving up is **visible**: the E10 banner reads this status, and its
      // retry (`HomeController.retryDiscovery` → [start]) now really rebuilds,
      // because a failed [_restartMulticast] leaves `_multicast` null.
      const String message = '设备发现已中断，请点击重试或重启 lanlink';
      _onLog?.call('rejoin: discovery rebuild failed after '
          '$_kResumeAttempts attempts');
      _setStatus(DiscoveryPhase.failed, message: message);
      _emit(const DiscoveryFailed(message));
    } finally {
      _recovering = false;
    }
  }

  /// Dials every known peer once with `/register`, ≤[_kRegisterFanOut] at a time.
  ///
  /// This is the resume-time half of liveness that does not depend on a UDP
  /// datagram arriving. The receiving side turns the `/register` into a registry
  /// `touch` (`lan_transfer_service._onPeerSeen` → `registrations` →
  /// [_onRegistration]), so the peer shows us online again even if every
  /// multicast leg on this phone is broken.
  ///
  /// Offline-known peers are included on purpose — they are exactly the devices
  /// that timed us out while we were asleep. Never throws and never reaches the
  /// UI: a peer that is not there is one ignored timeout, not an error.
  Future<void> _registerWithKnownPeers() async {
    final String self = core.normalizeFingerprint(_certificate.fingerprint);
    final List<core.Peer> peers = _registry.all
        .where((core.Peer peer) =>
            peer.info.port > 0 &&
            peer.address.isNotEmpty &&
            peer.fingerprint != self)
        .toList(growable: false);
    if (peers.isEmpty) {
      return;
    }
    _onLog?.call('rejoin: registering with ${peers.length} known peer(s) '
        'over TCP (multicast-independent)');
    for (var start = 0; start < peers.length; start += _kRegisterFanOut) {
      final int end = start + _kRegisterFanOut < peers.length
          ? start + _kRegisterFanOut
          : peers.length;
      await Future.wait(<Future<void>>[
        for (final core.Peer peer in peers.sublist(start, end))
          _registerOne(peer),
      ]);
    }
  }

  /// One peer's `/register`, with every failure reduced to a log line.
  Future<void> _registerOne(core.Peer peer) async {
    final RegisterBack? injected = _register;
    try {
      if (injected != null) {
        await injected(peer.info, peer.address);
        return;
      }
      await _registerBack(peer.info, peer.address);
    } on Object catch (error) {
      _onLog?.call('rejoin: register ${peer.address}:${peer.info.port} '
          'failed: $error');
    }
  }

  /// Polls the local IPv4 interface set and re-joins when it changed.
  ///
  /// Cheap (`NetworkInterface.list` only) and silent while the set is stable, so
  /// it costs nothing on a healthy network and costs a re-join exactly when a
  /// switch / roam / sleep-wake made the old memberships meaningless.
  Future<void> _pollInterfaces() async {
    if (_disposed) {
      return;
    }
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      final addresses = interfaces
          .map((interface) => '${interface.name}:'
              '${interface.addresses.map((a) => a.address).join(',')}')
          .toList()
        ..sort();
      final signature = addresses.join('|');
      final previous = _interfaceSignature;
      _interfaceSignature = signature;
      if (previous != null && previous != signature) {
        _onLog?.call('network changed; re-picking the multicast egress\n'
            '  was: $previous\n'
            '  now: $signature');
        await _rePickEgress();
      }
    } on Object catch (error) {
      _onLog?.call('interface poll failed: $error');
    }
  }

  /// Re-picks the multicast egress after a network change and rebuilds discovery
  /// when it actually moved.
  ///
  /// The boot-time pick goes stale when adapters appear or disappear (a VPN
  /// connects, Wi-Fi roams, mobile data comes up) — and nothing else would
  /// notice, because the receive socket keeps looking healthy while our
  /// announcements leave through an interface no LAN peer can hear.
  ///
  /// A re-pick that finds nothing **keeps** the previous interface
  /// ([chooseEgressAfterChange]): a network change must never leave discovery
  /// with no egress at all. That degradation is recorded in [_egressWarning] and
  /// logged, never swallowed.
  Future<void> _rePickEgress() async {
    final selector = egressSelector;
    if (selector == null) {
      // No selector injected (tests, or a caller that pinned one interface):
      // keep the old behaviour — re-join the current interfaces and re-announce.
      await rejoin();
      return;
    }
    final InternetAddress? picked = await selector();
    if (picked == null) {
      _egressWarning = '网络已变化，但没找到可用的网卡，公告可能发不出去';
      _onLog?.call('network changed but no usable interface was found; keeping '
          '${_multicastInterface?.address ?? '(none)'}');
      return;
    }
    _egressWarning = null;
    if (picked.address == _multicastInterface?.address) {
      _onLog?.call('network changed; egress unchanged (${picked.address})');
      await rejoin();
      return;
    }
    _onLog?.call('network changed; egress re-picked '
        '${_multicastInterface?.address ?? '(none)'} → ${picked.address}');
    _multicastInterface = picked;
    if (!await _restartMulticast()) {
      // Rebuilding failed; stay honest about it rather than looking healthy.
      _setStatus(
        DiscoveryPhase.failed,
        message: '设备发现已中断，请点击重试或重启 lanlink',
      );
    }
  }

  @override
  Future<void> setAlias(String alias) async {
    final String previousAlias = _alias;
    _alias = alias;

    // Discovery never started, or a previous start failed. Do **not** silently
    // no-op — that is exactly what made the "保存名称" button look dead. Start
    // it for real, so the button always has an effect.
    if (_multicast == null) {
      _onLog
          ?.call('setAlias("$alias"): discovery was not running; starting it');
      if (!await _restartMulticast()) {
        _setStatus(
          DiscoveryPhase.failed,
          message: '设备发现启动失败，请点击重试或重启 lanlink',
        );
        throw StateError('无法启动设备发现');
      }
      return;
    }

    // Rebuild so the new alias is actually announced (`MulticastDiscovery`'s
    // `deviceInfo` is final). Reusing the socket-recovery helper means a failure
    // can never strand `_multicast` at null — the state that used to require
    // restarting the whole app to escape.
    if (await _restartMulticast()) {
      _onLog?.call('setAlias("$alias"): discovery restarted');
      return;
    }

    // The rebuild failed: put the old name back and rebuild once more, so a
    // failed rename never leaves discovery down.
    _alias = previousAlias;
    _onLog?.call('setAlias("$alias") failed; restoring "$previousAlias"');
    if (!await _restartMulticast()) {
      _setStatus(
        DiscoveryPhase.failed,
        message: '设备发现已中断，请点击重试或重启 lanlink',
      );
    }
    throw StateError('无法以新名称 "$alias" 重新公告（已恢复为 "$previousAlias"）');
  }

  /// How long one **manual probe** may take before it is reported unreachable.
  ///
  /// A black-holed address (a phone on another subnet, a host that dropped off
  /// the Wi-Fi) produces **no** error at all: the TCP connect just sits there
  /// until `HttpClient.connectionTimeout` (10s in `PeerClient`), which is far
  /// longer than a user will watch a spinner. Three seconds is longer than any
  /// handshake on a working LAN (measured: well under 300ms on Wi-Fi, ~1s on a
  /// cold phone) and short enough to feel like an answer.
  static const Duration _kManualProbeTimeout = Duration(seconds: 3);

  /// Probes one address typed by the user and files what it finds into the
  /// registry (see [PeerDiscovery.probeHost]).
  ///
  /// ## The two things this does that nothing else in the app did
  ///
  /// 1. **Trust on first use.** There is no fingerprint to pin yet — that is the
  ///    whole situation — and `PeerClient` fails **closed** when it has no
  ///    expected fingerprint (`_verifyPeer`: `expected == null` and not
  ///    `allowUnknownCertificate` → handshake rejected). So the probe dials with
  ///    `allowUnknownCertificate: true`, exactly like `cli/send_command.dart`'s
  ///    `_probePeer` and [_registerBack]'s subnet-scan bootstrap.
  /// 2. **Registry, not database.** A peer is sendable because it is a **live**
  ///    peer: `selectors.mergeDeviceCards` copies the live peer's
  ///    `address`/`port` onto the card and `LanTransferService` dials from the
  ///    card. `devices.last_ip` is a dead end (nothing in production ever writes
  ///    it), so the probe writes nothing to storage — by design, not by omission.
  ///
  /// `/api/lanlink/v1/hello` is a **two-way** registration: the peer's server
  /// folds our frame into *its* registry (`peer_server`'s `onPeerSeen`), so one
  /// successful probe makes the two devices mutually visible. That is also the
  /// answer to "why `/hello` and not a bare TLS ping" — reachability alone would
  /// not be enough to send anything.
  ///
  /// Never throws and never blocks longer than [_kManualProbeTimeout]: every
  /// outcome is a [ManualProbeResult].
  ///
  /// **Notification caveat (for the UI step that follows):** the domain event a
  /// new peer produces (`PeerAppeared` / `PeerCameOnline`) is forwarded from the
  /// registry subscription that [start] installs — so a listener on [events] is
  /// woken when discovery is running, and is *not* woken when it never started
  /// (nothing is listening then anyway). [online] reads the registry directly and
  /// is correct in both cases, so a caller that re-reads the device list after a
  /// probe is safe.
  @override
  Future<ManualProbeResult> probeHost(String input) async {
    final _HostPort? target = _parseHostPort(input);
    if (target == null) {
      _onLog?.call('manual probe: rejected "$input" (not IP or IP:port)');
      return const ManualProbeError(ManualProbeFailure.badInput);
    }
    // ★ Remembered **before** the dial, and kept even when it fails: "not
    // answering right now" is the state the heartbeat exists to recover from
    // (see [_manualTargets]). Only [ManualProbeFailure.badInput] — a string that
    // is not an address at all — never becomes a target, because there is
    // nothing to keep dialling.
    //
    // At capacity the probe still runs (the user asked to connect *now*, and a
    // device that answers is worth using this once) but the address is **not**
    // kept, and [_rememberTarget] has already logged why. The caller learns about
    // it from `AppSettings.manualPeers` rather than from here: the result type
    // describes the probe, not the bookkeeping around it.
    final String key = target.toString();
    _rememberTarget(target, reason: 'typed by the user');
    final ManualProbeResult result = await _probeTarget(target);
    _noteManualTargetHealth(key, ok: result is ManualProbeOk);
    if (result is ManualProbeOk &&
        core.normalizeFingerprint(result.fingerprint) ==
            core.normalizeFingerprint(_certificate.fingerprint)) {
      // ★ Probing **ourselves** must not leave a target behind (0.2.54).
      //
      // A plausible typo — and the classic "which of these two addresses am I?"
      // mistake — reaches this device, and `_probeTarget` correctly refuses to
      // file it as a device. Remembering it would be just as wrong and worse in
      // its effect: the heartbeat would dial this device every 25 s, forever,
      // from this device. Removed here rather than refused earlier because
      // "is it me?" can only be answered by *dialling* and reading the
      // certificate.
      _forgetTarget(key, reason: 'it is this device itself');
    }
    return result;
  }

  /// One `/hello` round trip to [target] — the single implementation behind
  /// both [probeHost] and [heartbeatOnce].
  ///
  /// Pure with respect to the target set: it dials and files what answers into
  /// the registry, and knows nothing about heartbeats. That is what lets the
  /// heartbeat reuse **exactly** the probe semantics (observed fingerprint,
  /// self-filter, `PeerSource.register`, the 3 s deadline) instead of growing a
  /// second, subtly different dialler.
  ///
  /// [quiet] silences the per-outcome log lines, which is what the heartbeat
  /// passes: a target that stays unreachable for an hour must not write 144 log
  /// rows — [_noteManualTargetHealth] reports the *change* instead.
  Future<ManualProbeResult> _probeTarget(
    _HostPort target, {
    bool quiet = false,
  }) async {
    void note(String message) {
      if (!quiet) {
        _onLog?.call(message);
      }
    }

    final String host = target.host;
    final int port = target.port;
    final core.PeerClient client = _probeClientFor(host, port);
    try {
      final core.DeviceInfo reply = await client
          .register(self: _selfInfo())
          .timeout(_kManualProbeTimeout);
      // ★ The **measured** fingerprint, not `reply.fingerprint`: the frame's `fp`
      // is a claim, the certificate is evidence. Keying a device on the claim
      // would file it under an identity it never proved, and would collide with
      // the same peer discovered by any other leg (which does use the observed
      // value), producing two cards for one phone.
      final String? observed = client.observedFingerprint;
      if (observed == null || core.normalizeFingerprint(observed).isEmpty) {
        note('manual probe: ip=$host:$port answered but no certificate '
            'fingerprint was observable');
        return ManualProbeError(
          ManualProbeFailure.certificateMismatch,
          detail: '$host:$port answered but presented no readable certificate',
        );
      }
      final String fingerprint = core.normalizeFingerprint(observed);
      // The probe reached *this* device (a plausible typo, and the classic
      // "which of these two addresses am I?" mistake). Report it honestly — a
      // lanlink peer did answer — but never file it: a self peer would be a
      // phantom device card, and every other leg (announcement, register-back,
      // subnet scan) filters self out for exactly that reason.
      if (fingerprint == core.normalizeFingerprint(_certificate.fingerprint)) {
        note('manual probe: ip=$host:$port is this device itself; '
            'not filing it as a peer');
        return ManualProbeOk(
          fingerprint: fingerprint,
          alias: reply.alias,
          port: reply.port,
          host: host,
        );
      }
      // Registry, **not** the database: this is the only place a peer has to
      // appear for the device list to show it and for a send to have a dial
      // target (`mergeDeviceCards` → `PeerDevice.lastIp/lastPort`). Nothing is
      // persisted — discovery state is volatile by design.
      //
      // `PeerSource.register` (no new enum value): the leg really is a `/hello`
      // round trip. The log line above is what tells a manual probe apart from an
      // ordinary register-back when reading a log.
      //
      // ★ `copyWith(fingerprint: observed)`: `PeerRegistry` keys on
      // `info.fingerprint`, and the frame's `fp` is only a claim. Filing the
      // claim would (a) create an identity the peer never proved and (b) collide
      // with the same device discovered by any other leg, which does use the
      // observed value — one phone, two cards.
      _registry.touch(
        reply.copyWith(fingerprint: fingerprint),
        address: host,
        source: core.PeerSource.register,
        now: _clock.nowUtc(),
      );
      note('manual probe: ip=$host:$port -> "${reply.alias}" '
          '(fp ${_shortFingerprint(fingerprint)})');
      return ManualProbeOk(
        fingerprint: fingerprint,
        alias: reply.alias,
        // The port the peer *says* it listens on: that, not the port we dialled,
        // is the dial target for every later send (a forwarded/NATed probe port
        // need not be the receiver's own port).
        port: reply.port,
        host: host,
      );
    } on TimeoutException catch (error) {
      note('manual probe: ip=$host:$port timed out after '
          '${_kManualProbeTimeout.inSeconds}s');
      return ManualProbeError(ManualProbeFailure.unreachable, detail: '$error');
    } on HandshakeException catch (error) {
      note('manual probe: ip=$host:$port handshake failed: $error');
      return ManualProbeError(
        ManualProbeFailure.certificateMismatch,
        detail: error.message,
      );
    } on SocketException catch (error) {
      note('manual probe: ip=$host:$port unreachable: $error');
      return ManualProbeError(ManualProbeFailure.unreachable, detail: '$error');
    } on core.PeerHttpException catch (error) {
      // The TCP connection **and** the TLS handshake succeeded, so the box is
      // there and speaks TLS — but it did not answer `/hello` with a
      // `hello.reply`. That is "wrong peer / wrong port", never "unreachable".
      final bool identityLie = error.message.contains('identity mismatch');
      note('manual probe: ip=$host:$port is not a lanlink peer: $error');
      return ManualProbeError(
        identityLie
            ? ManualProbeFailure.certificateMismatch
            : ManualProbeFailure.notLanlink,
        detail: error.toString(),
      );
    } on Object catch (error) {
      // Anything else is a transport-shaped failure (a closed connection, a
      // malformed body, a platform TLS quirk). Reported as unreachable with the
      // real text in `detail`, so the log still says what happened.
      note('manual probe: ip=$host:$port failed: $error');
      return ManualProbeError(ManualProbeFailure.unreachable, detail: '$error');
    } finally {
      client.close();
    }
  }

  /// Re-probes every manual target once — the body of the 25 s heartbeat
  /// ([_kManualHeartbeat]), and the entry point its [Timer] calls.
  ///
  /// ## Why this has to exist
  ///
  /// A `/hello` is the only request that refreshes a peer's registry
  /// (`core/peer_server.dart`'s `onPeerSeen`), and both sides drop a peer after
  /// 60 s. One probe therefore buys **60 seconds** of mutual visibility: after
  /// that the peer's card goes grey here (nothing dialable) and its own card for
  /// us goes grey there (its `/prepare` is queued, never delivered). Re-probing
  /// the same address is what turns "a one-off probe" into "a device that is
  /// there".
  ///
  /// ## Serial, on purpose
  ///
  /// One `for` loop with an `await` inside it: target #2 is not dialled until #1
  /// finished. Parallel dialling (`Future.wait`) would be faster by a few
  /// hundred milliseconds on a healthy LAN and would put N simultaneous TLS
  /// handshakes on a link that is, by definition, one we have reason to
  /// distrust — and it would make the log interleave. [_manualHeartbeatRunning]
  /// keeps a slow pass (3 s deadline each) from overlapping the next tick.
  ///
  /// ## Failures are not events
  ///
  /// A target that does not answer is **kept** (see [_manualTargets]) and
  /// reported **once** ([_noteManualTargetHealth]), never as a UI error: the
  /// peer's card turning grey is the UI, and it is produced by the registry's
  /// own `sweepOffline` rather than by anything here. Nothing about a heartbeat
  /// touches the device list, the outbox, or `DiscoveryStatus`.
  ///
  /// Public rather than private because a test must be able to run one pass
  /// **without waiting 25 s** — the same choice `OutboxPump.onAppResumed` makes
  /// for its own trigger. No production caller; the timer is the caller.
  Future<void> heartbeatOnce() async {
    if (_disposed || _manualTargets.isEmpty) {
      return;
    }
    if (_manualHeartbeatRunning) {
      // Deliberately silent: a pass over N targets, each with a 3 s deadline,
      // can outlast the 25 s period, and then this fires on **every** tick —
      // exactly the repetition that hides the one line that matters. Nothing is
      // lost by dropping the tick (the next one picks the work up), and the
      // condition it describes is already visible in the UI as a peer that
      // stays grey.
      return;
    }
    _manualHeartbeatRunning = true;
    try {
      // A snapshot: [probeHost] may add a target while this pass runs, and it
      // must wait for the next tick rather than be dialled twice in one.
      final List<MapEntry<String, _HostPort>> targets =
          _manualTargets.entries.toList(growable: false);
      for (final MapEntry<String, _HostPort> entry in targets) {
        // Two ways this pass must stop where it is: the adapter was disposed,
        // or a [stop] cancelled the timer mid-pass — a pass that outlived a
        // `stop()` would keep dialling from a state nobody owns. Each target's
        // dial is bounded by [_kManualProbeTimeout], so the window is short.
        if (_disposed || _manualHeartbeat == null) {
          return;
        }
        final ManualProbeResult result = await _probeTarget(
          entry.value,
          quiet: true,
        );
        _noteManualTargetHealth(entry.key, ok: result is ManualProbeOk);
      }
    } finally {
      _manualHeartbeatRunning = false;
    }
  }

  /// Arms or cancels the heartbeat so that "there is a timer" and "there is at
  /// least one manual target" are always the same statement.
  ///
  /// Called from the three places that can change the set — [probeHost],
  /// [addManualTarget] (via [_rememberTarget]) and [removeManualTarget] (via
  /// [_forgetTarget]) — and from [stop] / [dispose] via
  /// [_cancelManualHeartbeat]. Idempotent, so no caller has to know whether a
  /// timer already exists: the invariant is derived from the set, never
  /// remembered separately.
  void _syncManualHeartbeat() {
    if (_disposed || _manualTargets.isEmpty) {
      _cancelManualHeartbeat();
      return;
    }
    _manualHeartbeat ??= Timer.periodic(
      _manualHeartbeatInterval,
      (_) => unawaited(heartbeatOnce()),
    );
  }

  /// Stops the heartbeat (idempotent).
  void _cancelManualHeartbeat() {
    _manualHeartbeat?.cancel();
    _manualHeartbeat = null;
  }

  /// Logs one target's reachability, and only when it **changed**.
  ///
  /// 25 s × N targets of "still there" is not information, it is noise — and
  /// noise is what makes the one line that matters invisible in a log the user
  /// sends in. So the rule is strictly "a transition, and nothing else":
  ///
  /// * the first observation is **silent** — [probeHost] has just logged the
  ///   probe's own result, and repeating it as "answers again" would claim a
  ///   recovery that never happened;
  /// * reachable → unreachable logs once, and says the target is **kept** (that
  ///   is the part a reader needs: the app will try again by itself);
  /// * unreachable → reachable logs once;
  /// * same-as-last logs nothing, however many passes run.
  void _noteManualTargetHealth(String key, {required bool ok}) {
    final bool? previous = _manualTargetHealthy[key];
    _manualTargetHealthy[key] = ok;
    if (previous == null || previous == ok) {
      return;
    }
    if (ok) {
      _onLog?.call('manual heartbeat: ip=$key answers again');
    } else {
      _onLog?.call('manual heartbeat: ip=$key does not answer; '
          'keeping it as a target and retrying every '
          '${_manualHeartbeatInterval.inSeconds}s');
    }
  }

  /// Builds the client one probe dials with.
  ///
  /// `allowUnknownCertificate: true` because a probe by definition has no
  /// fingerprint to pin yet (trust on first use); [certificate] is still passed
  /// so the peer sees a client certificate — without one, a strict lanlink
  /// receiver aborts the handshake with `TLSV1_ALERT_CERTIFICATE_REQUIRED`.
  core.PeerClient _probeClientFor(String host, int port) {
    final ProbeClientBuilder? builder = _probeClient;
    if (builder != null) {
      return builder(host: host, port: port);
    }
    return core.PeerClient(
      host: host,
      port: port,
      allowUnknownCertificate: true,
      certificate: _certificate,
      onLog: _onLog,
    );
  }

  /// A fingerprint shortened for a log line (a full SHA-256 hex is 64 chars and
  /// makes every log row unreadable).
  static String _shortFingerprint(String fingerprint) =>
      fingerprint.length <= 16 ? fingerprint : fingerprint.substring(0, 16);

  /// Stops discovery (if running) and releases the event stream.
  Future<void> dispose() async {
    _disposed = true;
    // The keep-alive shares the app's life, so it goes down with the adapter.
    await _keepAlive?.stop();
    await stop();
    if (!_events.isClosed) {
      await _events.close();
    }
  }

  /// Takes the Android multicast lock — a no-op off Android. A failure is
  /// **recorded, not swallowed**: [multicastWarning] names it so the UI can warn
  /// that discovery may miss peers.
  Future<void> _acquireMulticastLock() async {
    if (!_multicastLock.isSupported) {
      return;
    }
    final bool held = await _multicastLock.acquire();
    if (held) {
      _multicastWarning = null;
      return;
    }
    _multicastWarning = '安卓上设备发现可能不可靠：未能获取组播锁，可能收不到其他设备';
    _onLog?.call(_multicastWarning!);
  }

  /// Releases the Android multicast lock — a no-op off Android.
  Future<void> _releaseMulticastLock() async {
    if (!_multicastLock.isSupported) {
      return;
    }
    await _multicastLock.release();
    _multicastWarning = null;
  }

  // ── internals ─────────────────────────────────────────────────────────────

  // Broadcast is left at its default (`on`) and the target list is left to
  // core's `listBroadcastTargets()`: the second leg must cover every **private**
  // interface, not just the multicast egress, because a locked-down Wi-Fi AP
  // tends to eat multicast on one NIC while broadcast still gets through.
  //
  // Each call builds a **fresh** layer, which is what makes a rebuild a rebuild:
  // `MulticastDiscovery.start()` binds new sockets and `stop()` closes the old
  // ones, so there is no path where a resume can end up re-announcing on a
  // socket from before the phone slept (0.2.40).
  core.MulticastDiscovery _buildMulticast() {
    final MulticastBuilder? builder = _multicastBuilder;
    if (builder != null) {
      return builder();
    }
    return core.MulticastDiscovery(
      deviceInfo: _selfInfo(),
      group: _group,
      port: _udpPort,
      multicastInterface: _multicastInterface,
      announceInterval: _announceInterval,
      onLog: _onLog,
      onPeer: _onPeerSeen,
      // A dead receive socket is reported here; the recovery below rebuilds
      // it. `unawaited` because the core layer speaks a synchronous callback.
      onSocketFailure: (Object error) =>
          unawaited(_onMulticastSocketFailure(error)),
    );
  }

  core.DeviceInfo _selfInfo() => core.DeviceInfo(
        alias: _alias,
        fingerprint: _certificate.fingerprint,
        port: _selfPort,
        deviceType: core.DeviceType.desktop,
        protocol: core.ProtocolScheme.https,
        download: false,
        announce: true,
      );

  void _onPeerSeen(
    core.DeviceInfo peer,
    String sourceAddress,
    core.AnnouncementTransport transport,
  ) {
    final key = core.normalizeFingerprint(peer.fingerprint);
    if (key.isEmpty ||
        key == core.normalizeFingerprint(_certificate.fingerprint)) {
      return;
    }
    // The leg is kept (`multicast` vs `broadcast`): with the broadcast leg added
    // in 0.2.34 a peer can arrive on either, and "which one" is the only
    // evidence that the fallback is what is carrying discovery on a locked-down
    // network. The same fingerprint arriving twice (once per leg) collapses into
    // one peer here, because [core.PeerRegistry] is keyed by fingerprint.
    _registry.touch(
      peer,
      address: sourceAddress,
      source: transport.peerSource,
      now: _clock.nowUtc(),
    );
    // Answer each new peer's announcement once with the pinned register
    // handshake, so the certificate is verified (parity with `discover`).
    if (_registered.add(key)) {
      unawaited(_registerBack(peer, sourceAddress));
    }
  }

  void _onRegistration(DiscoveredPeer peer) {
    final key = core.normalizeFingerprint(peer.fingerprint);
    if (key.isEmpty) {
      return;
    }
    _registry.touch(
      deviceInfoFromDiscoveredPeer(peer),
      address: peer.address,
      source: core.PeerSource.register,
      now: _clock.nowUtc(),
    );
  }

  void _onRegistryEvent(core.PeerEvent event) {
    final peer = discoveredPeerFromPeer(event.peer);
    switch (event) {
      case core.PeerAdded():
        _emit(PeerAppeared(peer));
      case core.PeerUpdated():
        _emit(PeerUpdated(peer));
      case core.PeerCameOnline():
        _emit(PeerCameOnline(peer));
      case core.PeerWentOffline():
        _emit(PeerWentOffline(peer));
      case core.PeerRemoved():
        // The domain has no "removed" event; a removal is reported as offline.
        _emit(PeerWentOffline(peer));
    }
  }

  Future<void> _registerBack(core.DeviceInfo peer, String address) async {
    final client = core.PeerClient(
      host: address,
      port: peer.port,
      expectedFingerprint: peer.fingerprint,
      certificate: _certificate,
      onLog: _onLog,
    );
    try {
      final reply = await client.register(self: _selfInfo());
      if (core.normalizeFingerprint(reply.fingerprint) ==
          core.normalizeFingerprint(_certificate.fingerprint)) {
        return;
      }
      _registry.touch(
        reply,
        address: address,
        source: core.PeerSource.register,
        now: _clock.nowUtc(),
      );
    } on Object catch (error) {
      _onLog?.call('register $address:${peer.port} failed: $error');
    } finally {
      client.close();
    }
  }

  Future<void> _scanSubnet() async {
    try {
      final results = await core.scanSubnet(
        self: _selfInfo(),
        port: _selfPort,
        prefix: _scanPrefix,
        interfaceAddress: _multicastInterface?.address,
        onLog: _onLog,
      );
      for (final result in results) {
        final peer = result.info.copyWith(fingerprint: result.fingerprint);
        if (core.normalizeFingerprint(peer.fingerprint) ==
            core.normalizeFingerprint(_certificate.fingerprint)) {
          continue;
        }
        _registry.touch(
          peer,
          address: result.address,
          source: core.PeerSource.subnetScan,
          now: _clock.nowUtc(),
        );
      }
    } on Object catch (error) {
      _onLog?.call('subnet scan failed: $error');
    }
  }

  void _setStatus(DiscoveryPhase phase, {String? message}) {
    _status = DiscoveryStatus(
      phase: phase,
      errorMessage: message,
      selfAlias: _alias,
      // The address of the very interface this instance picked for multicast —
      // the same `LocalInterface` whose `address` already feeds `interfaceAddress`
      // a few lines up. Reused, not re-probed (docs/18 §3.3 / U4).
      selfAddress: _multicastInterface?.address,
      selfFingerprint: _certificate.fingerprint,
      selfPort: _selfPort,
    );
  }

  void _emit(DiscoveryEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  String _humanError(Object error) {
    if (error is SocketException) {
      return '无法加入组播（${error.message}）：请检查网络连接、防火墙，'
          '或 ${core.kDefaultPort} 端口是否被占用。';
    }
    return '发现层启动失败：$error';
  }
}
