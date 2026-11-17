/// Managing the set of **hand-typed peer addresses** (0.2.54) — an optional
/// capability the discovery adapter offers on top of `PeerDiscovery`.
///
/// ## Why this is its own port and not a method on `PeerDiscovery`
///
/// `PeerDiscovery` is the port every implementation must honour — the fake, the
/// Web stub, the native adapter. Keeping a *live set of addresses to re-dial
/// every 25 s* is native-only bookkeeping: the fake has nothing to dial, the Web
/// build has no sockets. Putting it on the port would force two implementations
/// to write three no-op methods, and would widen the port every caller depends
/// on for a feature only one caller uses.
///
/// So it is a **capability**: the adapter `implements` it, and a caller asks
/// `discovery is ManualTargetsControl`. That is a plain domain type, so the
/// check is legal in `controllers/**` and `ui/**` without importing
/// `data/real/**` (the `dart:io` / `lanlink_core` boundary, spec §8.1).
///
/// ## What is *not* here
///
/// No copy: the sentences a failed probe turns into live in `ui/format.dart`,
/// and this file stays pure Dart with no user-facing string of its own.
library;

/// How many hand-typed addresses may be kept at once (0.2.54).
///
/// **A capacity limit is not tidiness here — it is what keeps the feature
/// working.** The manual heartbeat re-dials every target **serially**, and each
/// dial carries a 3 s deadline (a black-holed address produces no error at all).
/// Nine permanently-unreachable targets therefore make one pass take ≥27 s,
/// which is longer than the 25 s period: the next tick is dropped, the effective
/// cycle stretches past 60 s, and the peers that *are* alive start dropping off
/// the list too. Eight keeps the worst case (8 × 3 s = 24 s) inside one period.
///
/// Both halves of the feature use this same number — the adapter refuses to dial
/// a ninth target, and the settings document refuses to remember one — so the
/// list the user sees and the list the heartbeat dials cannot drift apart.
const int kMaxManualPeers = 8;

/// The live set of hand-typed addresses, as the discovery adapter holds it.
///
/// Implemented by `LanPeerDiscovery` (real) and `FakePeerDiscovery` (tests and
/// the Web preview). Every method is **idempotent** and **never throws**: this
/// is bookkeeping around a background dialler, not a transaction a screen waits
/// on.
abstract interface class ManualTargetsControl {
  /// How many addresses are being re-dialled right now.
  ///
  /// A **count**, not the list: the list the user sees is the settings document
  /// (`AppSettings.manualPeers`), which is the source of truth and is what the
  /// 「手动添加的设备」 block renders. This number only answers "how close to
  /// [kMaxManualPeers] is the live set?", which is the one thing the persisted
  /// document cannot answer (a document can name a target the adapter refused).
  int get manualTargetCount;

  /// Whether the set is at [kMaxManualPeers], i.e. another address would be
  /// **silently ignored** by [addManualTarget].
  ///
  /// Exposed so a caller can say "最多 8 个，先删一个" instead of letting the
  /// user type an address that is quietly dropped.
  bool get manualTargetsFull;

  /// Adds one address to the re-dial set.
  ///
  /// [host] is an IP literal (brackets around an IPv6 literal are accepted and
  /// stripped); [port] must be in `1…65535`. Anything else is ignored — the
  /// same rule `PeerDiscovery.probeHost` applies to what the user typed, so a
  /// value that could not be dialled once cannot become a target either.
  ///
  /// Idempotent (the same address twice is one target) and **refused at
  /// capacity** (see [manualTargetsFull]).
  void addManualTarget(String host, int port);

  /// Removes one address from the re-dial set (idempotent).
  ///
  /// **It does not touch the device list.** Removing an address says "stop
  /// re-dialling this"; the peer it reached is an ordinary registry entry that
  /// goes grey on its own when it stops answering (`PeerRegistry.sweepOffline`).
  /// Deleting a device and forgetting a dial target are two different actions
  /// and must not be fused.
  void removeManualTarget(String host, int port);
}
