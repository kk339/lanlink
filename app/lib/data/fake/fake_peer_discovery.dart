import 'dart:async';

import '../../domain/clock.dart';
import '../../domain/manual_targets.dart';
import '../../domain/models.dart';
import '../../domain/peer_discovery.dart';

/// In-memory, fully programmable [PeerDiscovery].
///
/// Pure Dart (M4 §8.1): imports only `dart:async` and this app's `domain/`. It
/// lets a test — or the Web preview — decide exactly what the discovery layer
/// reports: peer appearances, updates, online/offline transitions, and startup
/// failure (E10), without any socket or `dart:io`.
///
/// It also implements [ManualTargetsControl] (0.2.54) — the optional half of the
/// contract the native adapter offers — so the whole hand-typed-address flow
/// (add, capacity, remove) is exercisable in a widget test without `dart:io`.
class FakePeerDiscovery implements PeerDiscovery, ManualTargetsControl {
  /// Creates a discovery source. [peers] are seeded as currently-online peers.
  FakePeerDiscovery({
    required Clock clock,
    List<DiscoveredPeer> peers = const <DiscoveredPeer>[],
    DiscoveryStatus? status,
  })  : _clock = clock,
        _status = status ??
            const DiscoveryStatus(
              phase: DiscoveryPhase.starting,
              selfAlias: 'This device',
              // Non-null on purpose: it is what the entry test reads off the
              // 本机信息 sheet. A permanent null here would make the sheet's
              // address a placeholder in every test, i.e. nothing would guard
              // the plumbing (docs/18 §3.3).
              selfAddress: '192.168.1.23',
              selfPort: 53317,
            ) {
    for (final peer in peers) {
      _online[peer.fingerprint] = peer;
    }
  }

  final Clock _clock;

  final StreamController<DiscoveryEvent> _events =
      StreamController<DiscoveryEvent>.broadcast();

  final Map<String, DiscoveredPeer> _online = <String, DiscoveredPeer>{};

  DiscoveryStatus _status;

  @override
  Stream<DiscoveryEvent> get events => _events.stream;

  @override
  List<DiscoveredPeer> get online {
    final list = _online.values.where((peer) => peer.isOnline).toList();
    list.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return list;
  }

  @override
  DiscoveryStatus get status => _status;

  /// The fake never reports a multicast-lock warning (that is Android-only in
  /// the real adapter).
  @override
  String? get multicastWarning => null;

  @override
  Future<void> start() async {
    _status = DiscoveryStatus(
      phase: DiscoveryPhase.running,
      errorMessage: _status.errorMessage,
      selfAlias: _status.selfAlias,
      // ★ **A new field is only as good as its copy sites.** `DiscoveryStatus` is
      // immutable and gets rebuilt by hand in several places; when `selfAddress`
      // was added, these re-constructions kept only the fields they were written
      // with, so the address was silently dropped on every re-publish. Anyone
      // adding a field here must walk the `DiscoveryStatus(` call sites.
      selfAddress: _status.selfAddress,
      selfFingerprint: _status.selfFingerprint,
      selfPort: _status.selfPort,
    );
  }

  @override
  Future<void> stop() async {
    _status = DiscoveryStatus(
      phase: DiscoveryPhase.starting,
      selfAlias: _status.selfAlias,
      // ★ **A new field is only as good as its copy sites.** `DiscoveryStatus` is
      // immutable and gets rebuilt by hand in several places; when `selfAddress`
      // was added, these re-constructions kept only the fields they were written
      // with, so the address was silently dropped on every re-publish. Anyone
      // adding a field here must walk the `DiscoveryStatus(` call sites.
      selfAddress: _status.selfAddress,
      selfFingerprint: _status.selfFingerprint,
      selfPort: _status.selfPort,
    );
  }

  /// How many times [rescan] has been called.
  ///
  /// A judgement that says "the menu item triggers a rescan" can only be as
  /// strong as its ability to observe the call — "the item is tappable" is not
  /// "the rescan ran". This counter is what closes that gap.
  int rescanCount = 0;

  @override
  Future<void> rescan() async {
    rescanCount++;
    final now = _clock.nowUtc();
    for (final entry in _online.entries.toList()) {
      final peer = entry.value;
      // `DiscoveredPeer` has no `copyWith` in the frozen contract (M4 §3.1), so
      // re-stamp by rebuilding the record explicitly.
      final refreshed = DiscoveredPeer(
        fingerprint: peer.fingerprint,
        alias: peer.alias,
        kind: peer.kind,
        address: peer.address,
        port: peer.port,
        isOnline: peer.isOnline,
        lastSeen: now,
        model: peer.model,
      );
      _online[entry.key] = refreshed;
      _events.add(PeerUpdated(refreshed));
    }
  }

  /// A re-join is invisible in the fake (there is no real group to join); it
  /// behaves exactly like [rescan], so a caller that expects "peers get fresh
  /// `lastSeen`s" sees that.
  @override
  Future<void> rejoin() => rescan();

  @override
  Future<void> setAlias(String alias) async {
    _status = DiscoveryStatus(
      phase: _status.phase,
      errorMessage: _status.errorMessage,
      selfAlias: alias,
      selfAddress: _status.selfAddress, // rename keeps the address
      selfFingerprint: _status.selfFingerprint,
      selfPort: _status.selfPort,
    );
  }

  // ── manual probe (0.2.54) ─────────────────────────────────────────────

  /// Every input [probeHost] was called with, in order, exactly as received.
  ///
  /// The call itself is the observable: a UI test can judge "the entry point
  /// passed on what the user typed" without any socket, and "nothing was dialled"
  /// is assertable too (`probeHostCalls` stays empty).
  final List<String> probeHostCalls = <String>[];

  /// The outcome the next [probeHost] should produce.
  ///
  /// `null` (never scheduled) makes [probeHost] throw a [StateError] instead of
  /// inventing one: a fake that answered "some failure" by default would let a
  /// broken UI test pass by accident, which is exactly the false-green this
  /// project treats as a defect.
  ManualProbeResult? _probeOutcome;

  /// Schedules what [probeHost] answers next.
  ///
  /// A [ManualProbeOk] also **becomes a live peer** — that is the contract the
  /// real adapter implements and the only reason the UI can offer to send — so a
  /// widget test sees the device list grow for real. A [ManualProbeError] changes
  /// nothing.
  void setManualProbeOutcome(ManualProbeResult outcome) {
    _probeOutcome = outcome;
  }

  /// Answers as scheduled, and applies a success to the live peer set exactly
  /// like the native adapter applies it to `core.PeerRegistry`.
  @override
  Future<ManualProbeResult> probeHost(String input) async {
    probeHostCalls.add(input);
    final ManualProbeResult? outcome = _probeOutcome;
    if (outcome == null) {
      throw StateError(
        'FakePeerDiscovery.probeHost("$input") has no scheduled outcome; call '
        'setManualProbeOutcome() first',
      );
    }
    if (outcome is ManualProbeOk) {
      // The adapter remembers the address it dialled (that is what the heartbeat
      // re-dials), so the fake does too — otherwise a controller test would see
      // a device appear while the target list stayed empty, which is a state
      // production can never be in.
      addManualTarget(outcome.host, outcome.port);
      final DateTime now = _clock.nowUtc();
      final bool known = _online.containsKey(outcome.fingerprint);
      final DiscoveredPeer peer = DiscoveredPeer(
        fingerprint: outcome.fingerprint,
        alias: outcome.alias,
        // The input carries an address, not a device class: the real registry
        // learns `kind` from the peer's own frame, which this fake models as
        // "not described" rather than guessing `desktop`.
        kind: DeviceKind.unknown,
        address: outcome.host,
        port: outcome.port,
        isOnline: true,
        lastSeen: now,
      );
      _online[peer.fingerprint] = peer;
      _events.add(known ? PeerUpdated(peer) : PeerAppeared(peer));
    }
    return outcome;
  }

  // ── manual targets (0.2.54) ───────────────────────────────────────────

  /// The addresses this fake is "keeping alive", in insertion order.
  final List<ManualPeerTarget> _manualTargets = <ManualPeerTarget>[];

  /// Every address accepted by [addManualTarget], in order.
  ///
  /// Recorded so a judgement can be about the **call** rather than about a
  /// side effect that could have come from anywhere (the same reason
  /// [probeHostCalls] exists).
  final List<ManualPeerTarget> addedManualTargets = <ManualPeerTarget>[];

  /// Every address actually removed by [removeManualTarget], in order.
  final List<ManualPeerTarget> removedManualTargets = <ManualPeerTarget>[];

  /// The targets as `ManualPeerTarget`s (the adapter exposes a record-shaped
  /// list; this fake keeps the persisted type, which is what a test compares).
  List<ManualPeerTarget> get manualTargets =>
      List<ManualPeerTarget>.unmodifiable(_manualTargets);

  @override
  int get manualTargetCount => _manualTargets.length;

  @override
  bool get manualTargetsFull => _manualTargets.length >= kMaxManualPeers;

  @override
  void addManualTarget(String host, int port) {
    final ManualPeerTarget target = ManualPeerTarget(host: host, port: port);
    if (!target.isValid ||
        manualTargetsFull ||
        _manualTargets.contains(target)) {
      return;
    }
    _manualTargets.add(target);
    addedManualTargets.add(target);
  }

  @override
  void removeManualTarget(String host, int port) {
    final ManualPeerTarget target = ManualPeerTarget(host: host, port: port);
    if (_manualTargets.remove(target)) {
      removedManualTargets.add(target);
    }
  }

  // ── programmable control (test / preview only) ────────────────────────

  /// Reports a brand-new peer.
  void appear(DiscoveredPeer peer) {
    _online[peer.fingerprint] = peer;
    _events.add(PeerAppeared(peer));
  }

  /// Reports a changed peer.
  void update(DiscoveredPeer peer) {
    _online[peer.fingerprint] = peer;
    _events.add(PeerUpdated(peer));
  }

  /// Reports a peer transitioning to online.
  void comeOnline(DiscoveredPeer peer) {
    _online[peer.fingerprint] = peer;
    _events.add(PeerCameOnline(peer));
  }

  /// Reports a peer transitioning to offline.
  void wentOffline(DiscoveredPeer peer) {
    _online.remove(peer.fingerprint);
    _events.add(PeerWentOffline(peer));
  }

  /// Replaces the whole online set (convenience for scenarios).
  void setOnline(Iterable<DiscoveredPeer> peers) {
    _online
      ..clear()
      ..addEntries(
          peers.map((p) => MapEntry<String, DiscoveredPeer>(p.fingerprint, p)));
  }

  /// Drives the discovery layer into its failed phase (E10 / A2-14).
  void fail(String message) {
    _status = DiscoveryStatus(
      phase: DiscoveryPhase.failed,
      errorMessage: message,
      selfAlias: _status.selfAlias,
      // ★ **A new field is only as good as its copy sites.** `DiscoveryStatus` is
      // immutable and gets rebuilt by hand in several places; when `selfAddress`
      // was added, these re-constructions kept only the fields they were written
      // with, so the address was silently dropped on every re-publish. Anyone
      // adding a field here must walk the `DiscoveryStatus(` call sites.
      selfAddress: _status.selfAddress,
      selfFingerprint: _status.selfFingerprint,
      selfPort: _status.selfPort,
    );
    _events.add(DiscoveryFailed(message));
  }

  /// Releases the event stream.
  void dispose() => _events.close();
}
