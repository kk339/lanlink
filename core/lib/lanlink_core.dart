/// lanlink core — the discovery layer of the LAN device transfer tool.
///
/// This is a pure Dart library (no Flutter). It is split by concern:
///
/// * `protocol/`  – wire constants (`lanlink/v1`: base path `/api/lanlink/v1`,
///   default port `49494`, frame type markers) and the [DeviceInfo] data model,
///   plus the transfer payloads ([FileMetadata] / `PrepareUploadRequest` /
///   `PrepareUploadResponse` / `ReceivedFile`).
/// * `security/`  – fingerprint normalisation/compare/hashing, the isolate-backed
///   streaming hasher ([IsolateHasher]), untrusted-input handling for the receive
///   path ([sanitizeFileName] and [normalizeRelativePath]).
/// * `identity/`  – the self-signed [DeviceCertificate] and its fingerprint.
/// * `discovery/` – UDP multicast **and** subnet broadcast announcements
///   (`multicast.dart` / `subnet_broadcast.dart`), the /24 scan and the
///   [PeerRegistry].
/// * `net/`       – the HTTPS [PeerClient] (pinned) and [PeerServer]
///   (`/hello` + `/info`, plus the `/text`, `/prepare`, `/put`, `/resume` and
///   `/cancel` endpoints).
/// * `util/`      – the [EventLoopWatchdog], a diagnostics probe that reports
///   when this isolate stopped running (used by the app's on-device logs).
///
/// Importing this barrel gives access to every public symbol of the layer.
library;

export 'src/discovery/announcement.dart';
export 'src/discovery/multicast.dart';
export 'src/discovery/peer_registry.dart';
export 'src/discovery/subnet_broadcast.dart';
export 'src/discovery/subnet_scan.dart';
export 'src/identity/device_certificate.dart';
export 'src/net/local_interfaces.dart';
export 'src/net/peer_client.dart';
export 'src/net/peer_server.dart';
export 'src/net/upload_stats.dart';
export 'src/protocol/constants.dart';
export 'src/protocol/device_info.dart';
export 'src/protocol/transfer.dart';
export 'src/security/file_name.dart';
export 'src/security/fingerprint.dart';
export 'src/security/hash_worker.dart';
export 'src/security/isolate_hasher.dart';
export 'src/security/relative_path.dart';
export 'src/util/event_loop_watchdog.dart';
