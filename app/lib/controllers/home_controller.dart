/// The home screen controller (spec §4.1 / §4.2 / §5.1).
///
/// Owns exactly the **home state**: the merged device cards, a read-only mirror
/// of the receiver mode, and the discovery error. It merges the two sources
/// through the pure selector [mergeDeviceCards] (never re-implementing the
/// rules) and re-reads on every repository/discovery event — the data set is
/// tiny (a personal tool), so the debounce in §4.1 is intentionally omitted to
/// keep the controller deterministic and directly testable.
///
/// **The shell's receiver switch does *not* write through here** (P0-7): its
/// single write entry is `SettingsController.setAccepting`, which persists the
/// choice as well as rebuilding the receiver. [accepting] is only a read-only
/// mirror of [TransferService.accepting]. (The legacy non-persisting
/// `setAccepting` shim was removed in T05 alongside the old
/// `ui/pages/home_page.dart` that was its only caller.)
///
/// Layering (spec §8.1): imports only `dart:async`, `package:flutter/foundation`,
/// this package's `domain/**` and `ui/format.dart`. No `lanlink_core` /
/// `lanlink_store` / `dart:io`.
///
/// `ui/format.dart` is the one non-`domain/` import, and it is deliberate: the
/// 0.2.54 rulings put the four failure sentences there (§8.4: one copy source)
/// and this controller is what turns a `ManualProbeFailure` into the sentence a
/// screen shows. The alternative — a raw reason code plus a switch in every
/// caller — would have put the same four Chinese strings in two places. Nothing
/// in `format.dart` imports a controller, so there is no cycle.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/async_value.dart';
import '../domain/manual_targets.dart';
import '../domain/models.dart';
import '../domain/peer_discovery.dart';
import '../domain/platform_ports.dart';
import '../domain/session_repository.dart';
import '../domain/selectors.dart';
import '../domain/transfer_service.dart';
import '../ui/format.dart';

/// Drives the device list, the receiver toggle and the discovery error.
class HomeController extends ChangeNotifier {
  /// Wires the controller to the three ports it reads.
  ///
  /// [platform] is optional and used **only** by the hand-typed-address feature
  /// (0.2.54): remembering an address the user typed, and forgetting one they
  /// removed, are edits of `AppSettings.manualPeers` — and the settings document
  /// has exactly one owner, `PlatformPorts`. Everything else on this screen works
  /// without it, which is what keeps the existing `HomeController(repo:…)`
  /// call sites (tests included) compiling and honest.
  HomeController({
    required SessionRepository repo,
    required PeerDiscovery discovery,
    required TransferService transfer,
    PlatformPorts? platform,
  })  : _repo = repo,
        _discovery = discovery,
        _transfer = transfer,
        _platform = platform {
    // The **optional** half of the discovery contract (0.2.54): only the native
    // adapter keeps a live set of hand-typed addresses to re-dial, so this is a
    // capability check rather than a fourth required port (see
    // `domain/manual_targets.dart` for why it is not on `PeerDiscovery`). The
    // cast is explicit because `ManualTargetsControl` is not a subtype of
    // `PeerDiscovery`, so `is` cannot promote to it.
    final PeerDiscovery port = discovery;
    _manualTargets =
        port is ManualTargetsControl ? port as ManualTargetsControl : null;
  }

  final SessionRepository _repo;
  final PeerDiscovery _discovery;
  final TransferService _transfer;
  final PlatformPorts? _platform;

  /// The live re-dial set, or `null` when the discovery implementation has none
  /// (the fake in a plain controller test, the Web stub).
  ManualTargetsControl? _manualTargets;

  StreamSubscription<RepoEvent>? _repoSub;
  StreamSubscription<DiscoveryEvent>? _discoverySub;
  StreamSubscription<UploadRejected>? _rejectedSub;
  bool _started = false;
  bool _disposed = false;

  AsyncValue<List<PeerDevice>> _cards = const Loading<List<PeerDevice>>();
  String? _error;
  UploadRejected? _transferNotice;

  /// The merged device cards. `Loading` until [init] has run once — a page can
  /// therefore tell "still discovering" apart from "found nothing" (A2-2).
  AsyncValue<List<PeerDevice>> get cards => _cards;

  /// The discovery error to surface in the persistent banner, or `null` (E10).
  String? get error => _error;

  /// The most recent inbound request this device **refused** (P0-7 follow-up),
  /// or `null`. A refusal is not a message — it belongs to no conversation — so
  /// it surfaces as a dismissible app-level notice, never in the message list.
  UploadRejected? get transferNotice => _transferNotice;

  /// Whether the receiver currently accepts inbound uploads (P0-7). The single
  /// source of truth is [TransferService.accepting].
  bool get accepting => _transfer.accepting;

  /// A warning that discovery is degraded on this platform, or `null`.
  ///
  /// Currently the Android multicast lock failing to be taken (discovery may
  /// miss peers). Read live from the discovery port, so the rail's
  /// always-visible indicator surfaces it — never silently dropped.
  String? get warning => _discovery.multicastWarning;

  /// The live discovery status (phase / self alias / self port).
  DiscoveryStatus get discoveryStatus => _discovery.status;

  /// Starts receiving, discovery and the zombie cleanup, then loads the cards.
  ///
  /// Idempotent: a second call is a no-op. E2 zombie cleanup turns any leftover
  /// `awaiting_confirm` / `transferring` into `failed` (never `pending`).
  Future<void> init() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;

    _repo.failInterruptedMessages();
    await _transfer.startReceiver();

    _discoverySub = _discovery.events.listen(_onDiscoveryEvent);
    _repoSub = _repo.events.listen((_) => _reload());
    // The receiver's own "we refused someone" trace (P0-7 follow-up): subscribe
    // for the app's lifetime here, next to the other app-level streams.
    _rejectedSub = _transfer.uploadRejected.listen(_onUploadRejected);
    await _discovery.start();
    _reload();
  }

  void _onDiscoveryEvent(DiscoveryEvent event) => _reload();

  void _onUploadRejected(UploadRejected event) {
    _transferNotice = event;
    _notify();
  }

  /// Recomputes the cards from discovery + stored conversations + device rows.
  void _reload() {
    if (_disposed) {
      return;
    }
    final DiscoveryStatus status = _discovery.status;
    _error = status.phase == DiscoveryPhase.failed
        ? (status.errorMessage ?? '设备发现启动失败')
        : null;
    _cards = Data<List<PeerDevice>>(
      mergeDeviceCards(
        online: _discovery.online,
        conversations: _repo.conversations(),
        devices: _repo.devices(),
      ),
    );
    notifyListeners();
  }

  /// P1-5: announce again immediately (and sweep the subnet if configured).
  Future<void> rescan() async {
    await _discovery.rescan();
    _reload();
  }

  // ── hand-typed addresses (0.2.54) ─────────────────────────────────────────
  //
  // The escape hatch for a network that eats both multicast and broadcast: the
  // user types the peer's address, one `/hello` round trip decides, and a peer
  // that answers becomes an ordinary live peer. Both methods answer `null` on
  // success and **one actionable Chinese sentence** on failure, because the
  // surfaces that call them (the dialog and the settings list) can only show a
  // string — and a `SocketException` is not something a phone user can act on.

  /// Probes [input] (`IP` or `IP:PORT`) and, when a peer answers, keeps it.
  ///
  /// Three things happen on success, in this order, and the order matters:
  ///
  /// 1. [PeerDiscovery.probeHost] dials and files the peer into the discovery
  ///    layer's live set — that is what makes the device appear and become
  ///    sendable (the probe itself writes nothing durable);
  /// 2. the address is added to `AppSettings.manualPeers` so it comes back by
  ///    itself after a restart (deduped on `ManualPeerTarget`'s equality, and
  ///    refused at [kMaxManualPeers] — an unbounded list would starve the
  ///    heartbeat, see that constant);
  /// 3. [_reload] re-reads the cards, because the discovery *event* that a new
  ///    peer emits is only forwarded while discovery is running — and a manual
  ///    probe exists precisely for the case where it never started.
  ///
  /// Success is **silent** (the device simply appears); failure is the one line
  /// the caller shows. Returns `null` when the peer was reached.
  Future<String?> addManualPeer(String input) async {
    final ManualProbeResult result = await _discovery.probeHost(input);
    if (result is! ManualProbeOk) {
      // `probeHost` never throws (its contract), so the only other shape is an
      // error, whose `reason` is the classification the copy switches over.
      final ManualProbeFailure reason = (result as ManualProbeError).reason;
      return manualProbeFailureText(reason);
    }
    final String? problem = await _rememberManualPeer(result);
    _reload();
    return problem;
  }

  /// Stops re-dialling [target] and forgets it in the settings document.
  ///
  /// The **device is deliberately left alone**: forgetting a dial address is not
  /// deleting a device. The peer stays in the registry and goes grey on its own
  /// when it stops answering (`PeerRegistry.sweepOffline`), which is the same
  /// fate as any other peer that went away — so removing an address can never
  /// look like "my chat disappeared".
  ///
  /// Returns `null` on success, or one sentence for the caller to show.
  Future<String?> removeManualPeer(ManualPeerTarget target) async {
    // Stop the heartbeat first: it is the only *behaviour* that must change, and
    // it must change even when the document write below fails.
    _manualTargets?.removeManualTarget(target.host, target.port);
    final PlatformPorts? platform = _platform;
    if (platform == null) {
      _reload();
      return null;
    }
    try {
      final AppSettings current = await platform.loadSettings();
      if (!current.manualPeers.contains(target)) {
        // Already gone (a double tap, or another window). Nothing to write.
        _reload();
        return null;
      }
      await platform.saveSettings(
        current.copyWith(
          manualPeers: <ManualPeerTarget>[
            for (final ManualPeerTarget kept in current.manualPeers)
              if (kept != target) kept,
          ],
        ),
      );
    } on Object {
      // The row will still be there when the caller re-reads the document, which
      // is the honest outcome; saying so is better than a silent no-op.
      _reload();
      return kManualPeerRemoveFailed;
    }
    _reload();
    return null;
  }

  /// Adds a just-probed address to the settings document.
  ///
  /// Returns `null` when nothing needs saying, or the one sentence that does:
  /// the capacity refusal, or "connected, but we could not remember it" (the
  /// device works *now*; only the next launch is affected).
  Future<String?> _rememberManualPeer(ManualProbeOk ok) async {
    final PlatformPorts? platform = _platform;
    if (platform == null) {
      // A container with no settings document (a pure controller test). The
      // probe's own effect is the only one available.
      return null;
    }
    if (ok.port <= 0) {
      // It answered but advertises no receiver: the device is in the list, and
      // there is no dial target to remember (`ManualPeerTarget.isValid` would
      // refuse port 0 anyway).
      return null;
    }
    final ManualPeerTarget target =
        ManualPeerTarget(host: ok.host, port: ok.port);
    final AppSettings current;
    try {
      current = await platform.loadSettings();
    } on Object {
      return kManualPeerNotRemembered;
    }
    if (current.manualPeers.contains(target)) {
      // Re-typing an address the app already knows: nothing to write, and no
      // point re-saving the same document.
      return null;
    }
    if (current.manualPeers.length >= kMaxManualPeers) {
      // The heartbeat refuses the ninth address too (the adapter enforces the
      // same number), so the live set is put back in step with the document:
      // "not remembered" must mean "not re-dialled", or the app would be doing
      // work the user cannot see or stop.
      _manualTargets?.removeManualTarget(target.host, target.port);
      return kManualPeerAtCapacity;
    }
    try {
      await platform.saveSettings(
        current.copyWith(
          manualPeers: <ManualPeerTarget>[...current.manualPeers, target],
        ),
      );
    } on Object {
      return kManualPeerNotRemembered;
    }
    return null;
  }

  /// Retries a failed discovery startup (E10 / A2-14's retry action).
  Future<void> retryDiscovery() async {
    await _discovery.start();
    _reload();
  }

  /// Dismisses the current error banner.
  void clearError() {
    _error = null;
    _notify();
  }

  /// Dismisses the current refusal notice.
  void clearTransferNotice() {
    if (_transferNotice == null) {
      return;
    }
    _transferNotice = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _repoSub?.cancel();
    _discoverySub?.cancel();
    _rejectedSub?.cancel();
    super.dispose();
  }
}
