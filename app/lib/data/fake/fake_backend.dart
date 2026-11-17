import '../../domain/clock.dart';
import '../../domain/id_factory.dart';
import '../../domain/models.dart';
import '../../domain/peer_discovery.dart';
import 'fake_peer_discovery.dart';
import 'fake_platform_ports.dart';
import 'fake_session_repository.dart';
import 'fake_transfer_service.dart';

/// The frozen base instant for every fixture: 2026-01-01T12:00:00Z (UTC).
final DateTime _t0 = DateTime.utc(2026, 1, 1, 12);

/// A fully-wired, deterministic fake backend — the **single entry point** a
/// controller / widget test (or the Web preview) uses to stand up the whole
/// data layer in one line.
///
/// It owns one [FixedClock] and one [FixedIdFactory] and shares those exact
/// instances with every fake that needs them, so ids and timestamps are stable
/// and reproducible across the repository, discovery and transfer fakes. Pure
/// Dart: it imports only this app's `domain/` and its sibling fakes — never
/// `dart:io`, `dart:ffi`, `lanlink_core` or `lanlink_store` (M4 §8.1).
///
/// Named constructors cover the frozen scenarios the UI walkthrough and the
/// widget tests need: three devices, two conversations, one message per status,
/// an offline peer, and a peer whose `lastPort == 0` (not dialable).
class FakeBackend {
  FakeBackend._({
    required this.clock,
    required this.ids,
    required this.repo,
    required this.discovery,
    required this.transfer,
    required this.platform,
  });

  /// Builds a backend from scratch. Every argument is optional; the result is
  /// empty unless [devices] / [online] seed it.
  ///
  /// [now] pins the clock (defaults to [fixedEpoch]); [devices] seed the
  /// repository's device rows (offline list / merge base); [online] seed the
  /// discovery layer's currently-online peers; [status] overrides the discovery
  /// status (e.g. a `failed` phase for E10); [settings] override the preset
  /// platform settings; [accepting] overrides the receiver's initial state.
  ///
  /// [mobile] answers `PlatformPorts.isMobile` (0.2.54): the settings page picks
  /// its **layout** from it (the phone's grouped cards vs the desktop's fields),
  /// so a test that wants to judge the phone shape — the 「手动添加的设备」 block
  /// included — has to say so. Window width alone does not decide that: the shell
  /// layout comes from the width, the settings body from the platform.
  factory FakeBackend({
    DateTime? now,
    List<PeerDevice> devices = const <PeerDevice>[],
    List<DiscoveredPeer> online = const <DiscoveredPeer>[],
    DiscoveryStatus? status,
    AppSettings? settings,
    bool? accepting,
    int? localPort = 53317,
    bool mobile = false,
  }) {
    final FixedClock clock = FixedClock(now ?? _t0);
    final FixedIdFactory ids = FixedIdFactory('id');
    // Built first so the receiver can start on the **same** directory the
    // settings name — exactly as `create_deps_native` wires it
    // (`LanTransferService(saveDirectory: settings.saveDirectory)`). Without
    // that, `SettingsController.setSaveDirectory`'s "apply, then persist"
    // contract could be tested against a receiver that started somewhere else.
    final FakePlatformPorts platform =
        FakePlatformPorts(settings: settings, mobile: mobile);
    return FakeBackend._(
      clock: clock,
      ids: ids,
      repo: FakeSessionRepository(clock: clock, ids: ids, devices: devices),
      discovery: FakePeerDiscovery(clock: clock, peers: online, status: status),
      transfer: FakeTransferService(
        ids: ids,
        // A `null` [accepting] means "as production would boot it", i.e. the
        // persisted default — `create_deps_native` passes
        // `acceptUploads: settings.acceptByDefault`. Since 0.2.25 that default
        // is on, so the fake boots receivable too; a test that wants the
        // "user switched receiving off" state says so, either with
        // `accepting: false` or (`Scenarios` aside) via
        // `AppSettings(acceptByDefault: false)`.
        accepting: accepting ?? platform.presetSettings.acceptByDefault,
        localPort: localPort,
        saveDirectory: platform.presetSettings.saveDirectory,
      ),
      platform: platform,
    );
  }

  /// The deterministic clock shared by every fake.
  final FixedClock clock;

  /// The deterministic id source shared by every fake.
  final FixedIdFactory ids;

  /// The in-memory session repository.
  final FakeSessionRepository repo;

  /// The programmable peer discovery.
  final FakePeerDiscovery discovery;

  /// The controllable transfer service.
  final FakeTransferService transfer;

  /// The preset platform capabilities.
  final FakePlatformPorts platform;

  // ── frozen scenarios (one line each) ──────────────────────────────────

  /// Three device cards: two online (one of them not dialable, `lastPort == 0`)
  /// and one offline — the shape of the home screen (M4 §4.2 / PRD P0-2).
  ///
  /// Carol (`CCCC3333`) carries `port: 0` on **both** her stored row and her live
  /// entry: `mergeDeviceCards` step 3 lets the live peer win on the volatile
  /// fields, so a live entry left at the default `port` would overwrite the
  /// stored `0` back to a dialable port and hide "对方当前不可接收" (A2-15).
  factory FakeBackend.threeDevices() => FakeBackend(
        devices: <PeerDevice>[
          _device(
            'AAAA1111',
            'Alice Laptop',
            DeviceKind.desktop,
            online: true,
            lastPort: 53317,
            lastSeen: _t0,
            preview: 'report.pdf',
            activity: _t0,
          ),
          _device(
            'BBBB2222',
            'Bob Phone',
            DeviceKind.mobile,
            online: false,
            lastPort: 53317,
            lastSeen: _t0.subtract(const Duration(hours: 2)),
            preview: 'notes.txt',
            activity: _t0.subtract(const Duration(hours: 2)),
          ),
          _device(
            'CCCC3333',
            'Carol Desktop',
            DeviceKind.desktop,
            online: true,
            lastPort: 0,
            lastSeen: _t0.subtract(const Duration(minutes: 5)),
          ),
        ],
        online: <DiscoveredPeer>[
          _peer('AAAA1111', 'Alice Laptop', DeviceKind.desktop),
          // port: 0 keeps Carol non-dialable *after* the merge (see docstring).
          _peer('CCCC3333', 'Carol Desktop', DeviceKind.desktop, port: 0),
        ],
      );

  /// Two conversations: one file conversation bound to a device, one local text
  /// conversation with no device (exercise both shapes of the list).
  factory FakeBackend.twoConversations() {
    final FakeBackend backend = FakeBackend(
      devices: <PeerDevice>[
        _device(
          'AAAA1111',
          'Alice Laptop',
          DeviceKind.desktop,
          online: true,
          lastPort: 53317,
          lastSeen: _t0,
          preview: 'report.pdf',
          activity: _t0,
        ),
      ],
      online: <DiscoveredPeer>[
        _peer('AAAA1111', 'Alice Laptop', DeviceKind.desktop),
      ],
    );
    final Conversation fileConversation = backend.repo.addConversation(
      id: 'c-file',
      deviceFingerprint: 'AAAA1111',
      createdAt: _t0.subtract(const Duration(minutes: 30)),
      lastMessageAt: _t0,
      lastPreview: 'report.pdf',
    );
    backend.repo.addMessage(
      id: 'm-out-1',
      conversationId: fileConversation.id,
      direction: MessageDirection.outgoing,
      status: MessageStatus.done,
      createdAt: _t0.subtract(const Duration(minutes: 30)),
      updatedAt: _t0,
      files: <FileAttachment>[
        _file('f-out-1', 'm-out-1', 'report.pdf', 204800),
      ],
    );
    final Conversation textConversation = backend.repo.addConversation(
      id: 'c-text',
      createdAt: _t0.subtract(const Duration(minutes: 10)),
      lastMessageAt: _t0.subtract(const Duration(minutes: 10)),
      lastPreview: 'ping?',
    );
    backend.repo.addMessage(
      id: 'm-text-1',
      conversationId: textConversation.id,
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.text,
      textBody: 'ping?',
      createdAt: _t0.subtract(const Duration(minutes: 10)),
      updatedAt: _t0.subtract(const Duration(minutes: 10)),
    );
    return backend;
  }

  /// One conversation holding exactly one message per [MessageStatus] — the
  /// seven-state fixture the status chip / bubble walkthrough needs.
  factory FakeBackend.allStatuses() {
    final FakeBackend backend = FakeBackend(
      devices: <PeerDevice>[
        _device(
          'DDDD4444',
          'Dave Laptop',
          DeviceKind.desktop,
          online: true,
          lastPort: 53317,
          lastSeen: _t0,
        ),
      ],
      online: <DiscoveredPeer>[
        _peer('DDDD4444', 'Dave Laptop', DeviceKind.desktop),
      ],
    );
    final Conversation conversation = backend.repo.addConversation(
      id: 'c-status',
      deviceFingerprint: 'DDDD4444',
      createdAt: _t0,
      lastMessageAt: _t0,
    );
    var minute = 0;
    for (final MessageStatus status in MessageStatus.values) {
      final DateTime at = _t0.add(Duration(minutes: minute));
      final String messageId = 'm-${status.wire}';
      backend.repo.addMessage(
        id: messageId,
        conversationId: conversation.id,
        direction: minute.isEven
            ? MessageDirection.outgoing
            : MessageDirection.incoming,
        status: status,
        createdAt: at,
        updatedAt: at,
        files: <FileAttachment>[
          _file('f-${status.wire}', messageId, 'file-${status.wire}.bin', 1024),
        ],
      );
      minute++;
    }
    return backend;
  }

  /// A single peer known only from history: offline, no live discovery entry.
  factory FakeBackend.peerOffline() => FakeBackend(
        devices: <PeerDevice>[
          _device(
            'EEEE5555',
            'Eve Phone',
            DeviceKind.mobile,
            online: false,
            lastPort: 53317,
            lastSeen: _t0.subtract(const Duration(hours: 5)),
          ),
        ],
      );

  /// A peer whose `lastPort == 0`: seen, online, but runs no inbound server, so
  /// sending must be refused (M4 §3.1 `canSend` / PRD Q9 / A2-15).
  ///
  /// As with Carol in [FakeBackend.threeDevices], the live entry carries
  /// `port: 0` so the merge cannot overwrite the stored `0` back to a dialable
  /// port (see that factory's note).
  factory FakeBackend.lastPortZero() => FakeBackend(
        devices: <PeerDevice>[
          _device(
            'FFFF6666',
            'Frank Old Client',
            DeviceKind.desktop,
            online: true,
            lastPort: 0,
            lastSeen: _t0,
          ),
        ],
        online: <DiscoveredPeer>[
          _peer('FFFF6666', 'Frank Old Client', DeviceKind.desktop, port: 0),
        ],
      );

  /// Closes every fake's stream so a test leaves no live subscription behind.
  void dispose() {
    repo.close();
    discovery.dispose();
    transfer.dispose();
  }
}

/// The base instant every fixture is derived from, exposed so tests can assert
/// exact timestamps without re-declaring it.
DateTime get fixedEpoch => _t0;

PeerDevice _device(
  String fingerprint,
  String alias,
  DeviceKind kind, {
  bool online = false,
  int? lastPort,
  DateTime? lastSeen,
  String? preview,
  DateTime? activity,
}) =>
    PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: kind,
      isOnline: online,
      lastPort: lastPort,
      lastIp: online ? '192.168.1.10' : null,
      lastSeenAt: lastSeen,
      lastPreview: preview,
      lastActivityAt: activity,
    );

DiscoveredPeer _peer(
  String fingerprint,
  String alias,
  DeviceKind kind, {
  bool online = true,
  int port = 53317,
  String address = '192.168.1.10',
  DateTime? seen,
}) =>
    DiscoveredPeer(
      fingerprint: fingerprint,
      alias: alias,
      kind: kind,
      address: address,
      port: port,
      isOnline: online,
      lastSeen: seen ?? _t0,
    );

FileAttachment _file(String id, String messageId, String name, int size) =>
    FileAttachment(
      id: id,
      messageId: messageId,
      fileName: name,
      size: size,
      sha256:
          '0000000000000000000000000000000000000000000000000000000000000000',
      localPath: '/received/$name',
    );
