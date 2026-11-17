/// Non-`dart:io` (Web) branch of the platform seam.
///
/// `create_deps.dart` picks this file when `dart.library.io` is **absent**
/// (spec §3.4). It must therefore contain **no** `dart:io` / `dart:ffi` /
/// `lanlink_core` / `lanlink_store` import, or `flutter build web` would fail
/// (§8.1).
///
/// **【丙】(design §10 丙, approved):** this is no longer the T01 placeholder
/// skeleton (whose every method threw `UnsupportedError`, so the Web preview
/// could not boot). It now wires the **real in-memory fakes** (`data/fake/**`)
/// behind one deterministic [FakeBackend], so the Web preview really runs and
/// renders the three-pane shell with seeded demo data — the A3 acceptance item.
/// Every port it reaches is pure Dart, so the Web build still never sees a
/// platform library (design §9.6).
///
/// **Thumbnails on Web:** [FakePlatformPorts.readFileBytes] returns `null` for a
/// `path` with no preset bytes, so an unseeded path falls back to a type icon —
/// the documented behaviour (design §3.4 / §5.4). The one exception is the
/// demo's `photo.png`, which this file seeds with a small **non-square** PNG so
/// the preview can show a bubble thumbnail keeping the source aspect ratio
/// (PRD §5); without a seeded image the Web demo could never show a real
/// thumbnail at all.
library;

import 'dart:typed_data';

import '../controllers/transfer_orchestrator.dart';
import '../data/fake/fake_backend.dart';
import '../domain/models.dart';
import '../domain/peer_discovery.dart';
import 'app_deps.dart';

/// Builds the Web / non-IO [AppDeps] on a seeded [FakeBackend].
///
/// The returned container is identical in shape to the native one (same six
/// ports + the single shared [TransferOrchestrator], O3), so `LanlinkApp` and
/// the whole `ui/` layer run unchanged on Web.
Future<AppDeps> createAppDeps() async {
  final FakeBackend backend = _webDemoBackend();
  return AppDeps(
    repo: backend.repo,
    discovery: backend.discovery,
    transfer: backend.transfer,
    platform: backend.platform,
    clock: backend.clock,
    ids: backend.ids,
    config: _webConfig,
    orchestrator: TransferOrchestrator(
      repo: backend.repo,
      transfer: backend.transfer,
    ),
  );
}

/// A deterministic, richly-seeded backend for the Web preview only.
///
/// It seeds the frozen "three devices" shape (design's home screenshots) — two
/// online (one of them, Carol, not dialable with `lastPort == 0`) and one
/// offline — plus one thread with Alice so the middle pane, the recent-files
/// list and the right pane all have content. All three demo files deliberately
/// exercise a different `[类型]`: PDF → `[文件]`, PNG → `[图片]`, MP4 →
/// `[视频]`.
FakeBackend _webDemoBackend() {
  final DateTime t0 = fixedEpoch;
  final FakeBackend backend = FakeBackend(
    now: t0,
    devices: <PeerDevice>[
      _device(
        'AAAA1111',
        'Alice Laptop',
        DeviceKind.desktop,
        online: true,
        lastPort: 53317,
        lastSeen: t0,
      ),
      _device(
        'BBBB2222',
        'Bob Phone',
        DeviceKind.mobile,
        online: false,
        lastPort: 53317,
        lastSeen: t0.subtract(const Duration(hours: 2)),
      ),
      _device(
        'CCCC3333',
        'Carol Desktop',
        DeviceKind.desktop,
        online: true,
        lastPort: 0,
        lastSeen: t0.subtract(const Duration(minutes: 5)),
      ),
    ],
    // Carol's live entry also carries `port: 0`, so the merge cannot restore a
    // dialable port and hide "对方当前不可接收" (mirrors FakeBackend.threeDevices).
    online: <DiscoveredPeer>[
      _peer('AAAA1111', 'Alice Laptop', DeviceKind.desktop),
      _peer('CCCC3333', 'Carol Desktop', DeviceKind.desktop, port: 0),
    ],
    status: const DiscoveryStatus(
      phase: DiscoveryPhase.running,
      selfAlias: 'My Laptop',
      selfFingerprint: 'A1B2C3D4E5F60718',
      selfPort: 53317,
    ),
    settings: const AppSettings(
      alias: 'My Laptop',
      saveDirectory: '/received',
    ),
  );

  // One file thread with Alice so 最近文件 / 右栏「消息·文件」tab have content.
  // It deliberately mixes **both directions** (2 incoming + 2 outgoing,
  // interleaved in time) so the left/right bubble split is actually visible in
  // the preview, and covers three `[类型]`: `.pdf`/`.txt` → [文件], `.mp4` →
  // [视频], `.png` → [图片]. The **last** message (photo.png, incoming) drives
  // the middle device card's summary through `lastPreview`.
  final Conversation conversation = backend.repo.addConversation(
    id: 'demo-c-alice',
    deviceFingerprint: 'AAAA1111',
    createdAt: t0.subtract(const Duration(minutes: 50)),
    lastMessageAt: t0,
    lastPreview: 'photo.png',
  );
  backend.repo.addMessage(
    id: 'demo-m-agenda',
    conversationId: conversation.id,
    direction: MessageDirection.incoming,
    status: MessageStatus.done,
    createdAt: t0.subtract(const Duration(minutes: 50)),
    updatedAt: t0.subtract(const Duration(minutes: 50)),
    files: <FileAttachment>[
      _attachment(
        'demo-f-agenda',
        'demo-m-agenda',
        'agenda.txt',
        120,
        'text/plain',
      ),
    ],
  );
  backend.repo.addMessage(
    id: 'demo-m-report',
    conversationId: conversation.id,
    direction: MessageDirection.outgoing,
    status: MessageStatus.done,
    createdAt: t0.subtract(const Duration(minutes: 40)),
    updatedAt: t0.subtract(const Duration(minutes: 40)),
    files: <FileAttachment>[
      _attachment(
        'demo-f-report',
        'demo-m-report',
        'report.pdf',
        204800,
        'application/pdf',
      ),
    ],
  );
  backend.repo.addMessage(
    id: 'demo-m-clip',
    conversationId: conversation.id,
    direction: MessageDirection.outgoing,
    status: MessageStatus.done,
    createdAt: t0.subtract(const Duration(minutes: 20)),
    updatedAt: t0.subtract(const Duration(minutes: 20)),
    files: <FileAttachment>[
      _attachment(
        'demo-f-clip',
        'demo-m-clip',
        'trip.mp4',
        8388608,
        'video/mp4',
      ),
    ],
  );
  backend.repo.addMessage(
    id: 'demo-m-photo',
    conversationId: conversation.id,
    direction: MessageDirection.incoming,
    status: MessageStatus.done,
    createdAt: t0,
    updatedAt: t0,
    files: <FileAttachment>[
      _attachment(
        'demo-f-photo',
        'demo-m-photo',
        'photo.png',
        51200,
        'image/png',
      ),
    ],
  );
  // Seed the one image whose bytes the preview can actually decode. The path
  // must equal the attachment's `localPath` exactly (`_attachment` builds
  // `/received/<name>`), or the port returns `null` and the thumbnail falls back
  // to a type icon. The bytes are a wide (16:9) PNG on purpose: a square image
  // could not demonstrate the aspect-ratio fix.
  backend.platform.setBytes('/received/photo.png', _widePngBytes);
  return backend;
}

/// The Web demo's `photo.png`: a **64×36 (16:9) PNG** — two solid halves —
/// deliberately **non-square** so the preview can show that an image thumbnail
/// keeps the source ratio instead of being squashed into a square (PRD §5).
///
/// Kept as an **explicit byte table**, not `base64Decode` (root cause A): that
/// idiom has already yielded a malformed constant twice in this project, and a
/// byte table has no decode step to go wrong. These bytes are a verified-valid
/// PNG (chunk CRCs + zlib stream all check out).
final Uint8List _widePngBytes = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR len=13, "IHDR"
  0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x24, // width=64, height=36
  0x08, 0x06, 0x00, 0x00, 0x00, 0x39, 0x0C, 0x3C, // depth=8, colour=6 (RGBA)…
  0x92, 0x00, 0x00, 0x00, 0x50, 0x49, 0x44, 0x41, // …IHDR CRC; IDAT len=80
  0x54, 0x78, 0xDA, 0xED, 0xD0, 0x41, 0x11, 0x00, // "IDAT" + zlib stream
  0x20, 0x08, 0x00, 0x30, 0xE2, 0x18, 0xC2, 0x24,
  0x26, 0x31, 0x22, 0x21, 0xEC, 0x82, 0x31, 0xB8,
  0xE3, 0xF6, 0x58, 0x81, 0xC5, 0x3E, 0x59, 0x9D,
  0xDE, 0x5D, 0xAD, 0x42, 0x80, 0x00, 0x01, 0x02,
  0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x00, 0x01,
  0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x00,
  0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80,
  0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40,
  0x80, 0x80, 0xD9, 0x01, 0x1F, 0x7B, 0x45, 0xCD,
  0x3C, 0x8D, 0x5F, 0xC0, 0x5C, 0x00, 0x00, 0x00, // …IDAT CRC; IEND len=0
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, // "IEND" + CRC
  0x82, // IEND CRC tail
]);

/// Preview-only location defaults.
///
/// Web has no filesystem, so every path is empty. The native adapter fills these
/// from `%LOCALAPPDATA%` (spec §8.2); this branch only needs the shape. Ports /
/// group mirror the native defaults so the preview matches production copy.
const AppConfig _webConfig = AppConfig(
  tcpPort: 53317,
  udpPort: 53317,
  // 0.2.34: the literal mirrors `core`'s `kMulticastGroup`. It has to stay a
  // literal — this is the Web branch, and `lanlink_core` reaches `dart:io`.
  multicastGroup: '224.0.0.168',
  certDirectory: '',
  databasePath: '',
  defaultSaveDirectory: '',
  settingsPath: '',
);

/// The all-zero hash used by the seeded attachments (never verified on Web).
const String _demoZeroHash =
    '0000000000000000000000000000000000000000000000000000000000000000';

PeerDevice _device(
  String fingerprint,
  String alias,
  DeviceKind kind, {
  bool online = false,
  int? lastPort,
  DateTime? lastSeen,
}) =>
    PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: kind,
      isOnline: online,
      lastPort: lastPort,
      lastIp: online ? '192.168.1.10' : null,
      lastSeenAt: lastSeen,
    );

DiscoveredPeer _peer(
  String fingerprint,
  String alias,
  DeviceKind kind, {
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
      isOnline: true,
      lastSeen: seen ?? fixedEpoch,
    );

FileAttachment _attachment(
  String id,
  String messageId,
  String name,
  int size,
  String? mime,
) =>
    FileAttachment(
      id: id,
      messageId: messageId,
      fileName: name,
      size: size,
      mime: mime,
      sha256: _demoZeroHash,
      localPath: '/received/$name',
    );
