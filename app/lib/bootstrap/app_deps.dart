/// The app's dependency container + startup configuration (spec §3.2 / §3.4).
///
/// [AppDeps] holds the six ports, the single shared [TransferOrchestrator] (O3)
/// and the frozen [AppConfig]; the conditional-import seam `create_deps.dart`
/// builds it per platform. Pure Dart (§8.1): this file references only
/// `domain/` types and the pure-Dart `controllers/transfer_orchestrator.dart`,
/// so it is Web-safe.
library;

import '../controllers/outbox_pump.dart';
import '../controllers/transfer_orchestrator.dart';
import '../domain/clock.dart';
import '../domain/id_factory.dart';
import '../domain/peer_discovery.dart';
import '../domain/picked_cache.dart';
import '../domain/platform_ports.dart';
import '../domain/session_repository.dart';
import '../domain/share_inbox.dart';
import '../domain/transfer_service.dart';

/// Immutable startup configuration, fixed at launch (spec §3.2 / §8.2).
class AppConfig {
  /// Creates the configuration.
  const AppConfig({
    required this.tcpPort,
    required this.udpPort,
    required this.multicastGroup,
    required this.certDirectory,
    required this.databasePath,
    required this.defaultSaveDirectory,
    required this.settingsPath,
  });

  /// TCP port for the transfer server.
  final int tcpPort;

  /// UDP port for multicast discovery.
  final int udpPort;

  /// Multicast group address.
  final String multicastGroup;

  /// Certificate directory.
  ///
  /// **Must be independent of the alias** (spec §8.2) — otherwise renaming this
  /// device would change its fingerprint and every peer would treat it as new.
  /// The native adapter uses `<app-data>/lanlink/certs`: `%LOCALAPPDATA%\lanlink`
  /// on Windows, the app-support directory on Android/iOS.
  final String certDirectory;

  /// Path to the SQLite session database.
  final String databasePath;

  /// Default directory for received files.
  final String defaultSaveDirectory;

  /// Path to the settings JSON file.
  final String settingsPath;
}

/// The wired set of ports the UI depends on (spec §3.2).
class AppDeps {
  /// Creates the container.
  ///
  /// [orchestrator] is the app-wide, single send/receive orchestration point
  /// (O3). Production passes the instance built **once** at boot in
  /// `create_deps*`; when it is omitted a fresh one is derived over [repo] /
  /// [transfer], which keeps the pure test container (`testDeps`) compiling
  /// unchanged.
  ///
  /// [shareInbox] is the inbound-share port (0.2.18). It defaults to
  /// [NoopShareInbox] — a platform that cannot receive shares — so the Web
  /// build and every existing test keep working without wiring anything, while
  /// the native branch passes the real Android adapter.
  ///
  /// [pickedCache] is the "delete our own temporary copies" port (0.2.23). It
  /// defaults to [NoopPickedCache] for the same reason: desktop never makes a
  /// copy, so the no-op is the correct behaviour there rather than a stub.
  AppDeps({
    required this.repo,
    required this.discovery,
    required this.transfer,
    required this.platform,
    required this.clock,
    required this.ids,
    required this.config,
    TransferOrchestrator? orchestrator,
    OutboxPump? outbox,
    ShareInboxPort? shareInbox,
    PickedCachePort? pickedCache,
  })  : orchestrator = orchestrator ??
            TransferOrchestrator(repo: repo, transfer: transfer),
        _outbox = outbox,
        shareInbox = shareInbox ?? const NoopShareInbox(),
        pickedCache = pickedCache ?? const NoopPickedCache();

  /// Session-history access.
  final SessionRepository repo;

  /// Device discovery.
  final PeerDiscovery discovery;

  /// Transfer send/receive.
  final TransferService transfer;

  /// Platform capabilities.
  final PlatformPorts platform;

  /// Time source (injected for determinism, §8.3).
  final Clock clock;

  /// Id source.
  final IdFactory ids;

  /// Startup configuration.
  final AppConfig config;

  /// The single send/receive orchestration point, shared app-wide (O3).
  ///
  /// Built once at boot (`create_deps*`), never per page, so every send and the
  /// inbound-recording subscription live for the whole app lifetime (§5.3).
  final TransferOrchestrator orchestrator;

  /// The offline queue's consumer (0.2.40).
  ///
  /// Production passes a fully wired instance (with the on-device log hook) from
  /// `create_deps_native`; when it is omitted the pump is built lazily on first
  /// read, which needs [orchestrator] — something the initializer list cannot
  /// reference, since it may have just built it from [repo] / [transfer]. The
  /// lazy default is what keeps the pure test container compiling unchanged.
  ///
  /// **Nothing drains until `outbox.start()` runs.** A test that only builds the
  /// container therefore gets a pump that does nothing, which is the right
  /// default: a container that silently began dialling from a unit test would be
  /// a green that means nothing.
  OutboxPump get outbox =>
      _outbox ??= OutboxPump(
        repo: repo,
        discovery: discovery,
        orchestrator: orchestrator,
        // 0.2.52 — the lazy default asks the same port production does, so a
        // container built by a test does not answer "does the source exist?"
        // with a different rule than the app.
        platform: platform,
        clock: clock,
      );

  OutboxPump? _outbox;

  /// Inbound shares from the OS share sheet (0.2.18).
  ///
  /// Android hands us the files another app shared (channel
  /// `lanlink/share_inbox`); every other platform gets [NoopShareInbox], whose
  /// [ShareInboxPort.isSupported] is `false`, so the UI's share intake simply
  /// never fires. Referenced only through the pure-Dart port, so this container
  /// stays importable from the Web build.
  final ShareInboxPort shareInbox;

  /// Removes the app's own temporary copies of picked / shared files (0.2.23).
  ///
  /// Android copies every picked or shared file into `cache/lanlink-picked/…`
  /// and, before 0.2.23, never deleted it; this port is how those copies are
  /// reclaimed (after a successful send, on a discarded draft, and on launch).
  /// [NoopPickedCache] on platforms that pick in place.
  final PickedCachePort pickedCache;
}
