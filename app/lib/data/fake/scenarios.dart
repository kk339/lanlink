/// Named builders for the PRD §6 edge cases (E1–E13, plus the M4-rework
/// E15/E16 and the E20–E22 files-tab cases) on top of the fake backend.
///
/// This is the **official entry point** for the in-memory fakes: it re-exports
/// [FakeBackend] (and its sibling fakes) and adds one builder per edge case, so
/// a widget test can stand up the exact state an E-case needs in a single line
/// (`Scenarios.e5PeerReinstalled()`), without hand-seeding the repository.
///
/// Each builder only arranges **state**; it asserts nothing. The matching
/// behavioural assertions live in `test/widget/edge_cases_test.dart`.
///
/// Pure Dart (M4 §8.1): it imports only this app's `domain/` and its sibling
/// fakes — never `dart:io` / `dart:ffi` / `lanlink_core` / `lanlink_store` — so
/// it is Web-safe and also usable from the Web preview.
library;

import '../../domain/models.dart';
import 'fake_backend.dart';

export '../../domain/clock.dart' show FixedClock;
export '../../domain/id_factory.dart' show FixedIdFactory;
export 'fake_backend.dart';
export 'fake_peer_discovery.dart';
export 'fake_platform_ports.dart';
export 'fake_session_repository.dart';
export 'fake_transfer_service.dart';

/// PRD §6 edge-case fixtures — one builder per E1–E13.
///
/// The fixtures share the deterministic [fixedEpoch] and the fixed ids/fingerprints
/// documented on each builder, so the widget tests can assert on stable copy.
abstract final class Scenarios {
  /// E1 — the peer goes offline while a transfer is in flight.
  ///
  /// Seeds `E1000001` ("Eve Laptop") as **online** (live entry) with a two-message
  /// thread: `notes.txt` (received, `done`) and `big.iso` (outgoing,
  /// `transferring`). A test can drive the offline transition with
  /// `backend.discovery.wentOffline(peer)`; the merge lets the live entry win
  /// `isOnline`, so the card flips to offline once the entry is gone (a stored
  /// row never forces `isOnline` — `mergeDeviceCards` ignores it).
  ///
  /// **Boundary (E1 ∩ E2):** mounting the home page runs the startup cleanup
  /// (`SessionRepository.failInterruptedMessages`), so the seeded `transferring`
  /// message is swept to `failed` the moment the app starts — a `transferring`
  /// state never survives an app start. That is exactly PRD §6 E1 ("正在传输的
  /// 消息转为 `failed`"), so the widget test asserts the **transition**, not a
  /// surviving "传输中".
  static FakeBackend e1PeerWentOffline() {
    final FakeBackend backend = FakeBackend(
      devices: <PeerDevice>[
        _device('E1000001', 'Eve Laptop', DeviceKind.desktop,
            lastPort: 53317, preview: 'big.iso', activity: fixedEpoch),
      ],
      online: <DiscoveredPeer>[
        _live('E1000001', 'Eve Laptop', DeviceKind.desktop)
      ],
    );
    final Conversation conversation = backend.repo.addConversation(
      id: 'c-e1',
      deviceFingerprint: 'E1000001',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch.add(const Duration(minutes: 1)),
    );
    backend.repo.addMessage(
      id: 'm-e1-received',
      conversationId: conversation.id,
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      files: <FileAttachment>[
        _file('f-e1-received', 'm-e1-received', 'notes.txt', 120,
            path: '/received/notes.txt'),
      ],
    );
    backend.repo.addMessage(
      id: 'm-e1-inflight',
      conversationId: conversation.id,
      direction: MessageDirection.outgoing,
      status: MessageStatus.transferring,
      createdAt: fixedEpoch.add(const Duration(minutes: 1)),
      files: <FileAttachment>[
        _file('f-e1-inflight', 'm-e1-inflight', 'big.iso', 1048576,
            path: '/src/big.iso'),
      ],
    );
    return backend;
  }

  /// E2 — the app restarted with a transfer left mid-flight.
  ///
  /// Seeds one thread with the three non-terminal shapes: `awaiting_confirm`,
  /// `transferring` and a queued `pending`. A startup (`HomeController.init`)
  /// must sweep only the first two to `failed` and leave `pending` queued
  /// (A2-22). Ids: `m-e2-awaiting` / `m-e2-transferring` / `m-e2-pending`.
  static FakeBackend e2InterruptedTransfer() {
    final FakeBackend backend = FakeBackend(
      devices: <PeerDevice>[
        _device('E2000002', 'Eve Laptop', DeviceKind.desktop, lastPort: 53317),
      ],
      online: <DiscoveredPeer>[
        _live('E2000002', 'Eve Laptop', DeviceKind.desktop)
      ],
    );
    final Conversation conversation = backend.repo.addConversation(
      id: 'c-e2',
      deviceFingerprint: 'E2000002',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch.add(const Duration(minutes: 2)),
    );
    backend.repo.addMessage(
      id: 'm-e2-awaiting',
      conversationId: conversation.id,
      direction: MessageDirection.outgoing,
      status: MessageStatus.awaitingConfirm,
      createdAt: fixedEpoch,
      files: <FileAttachment>[
        _file('f-e2-awaiting', 'm-e2-awaiting', 'a.bin', 10,
            path: '/src/a.bin'),
      ],
    );
    backend.repo.addMessage(
      id: 'm-e2-transferring',
      conversationId: conversation.id,
      direction: MessageDirection.outgoing,
      status: MessageStatus.transferring,
      createdAt: fixedEpoch.add(const Duration(minutes: 1)),
      files: <FileAttachment>[
        _file('f-e2-transferring', 'm-e2-transferring', 'b.bin', 20,
            path: '/src/b.bin'),
      ],
    );
    backend.repo.addMessage(
      id: 'm-e2-pending',
      conversationId: conversation.id,
      direction: MessageDirection.outgoing,
      status: MessageStatus.pending,
      createdAt: fixedEpoch.add(const Duration(minutes: 2)),
      files: <FileAttachment>[
        _file('f-e2-pending', 'm-e2-pending', 'c.bin', 30, path: '/src/c.bin'),
      ],
    );
    return backend;
  }

  /// E3 — the receiver already had a file with the same name.
  ///
  /// The landing side resolves unique names (`photo (1).jpg`); the receiver
  /// stores that **actual on-disk name** in `files.file_name`, so the UI shows
  /// the resolved name and the user can tell it was renamed. Seeds an incoming
  /// `done` message carrying `photo (1).jpg`.
  static FakeBackend e3RenamedOnReceive() {
    final FakeBackend backend = FakeBackend(
      devices: <PeerDevice>[
        _device('E3000003', 'Eve Laptop', DeviceKind.desktop, lastPort: 53317),
      ],
      online: <DiscoveredPeer>[
        _live('E3000003', 'Eve Laptop', DeviceKind.desktop)
      ],
    );
    final Conversation conversation = backend.repo.addConversation(
      id: 'c-e3',
      deviceFingerprint: 'E3000003',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-e3',
      conversationId: conversation.id,
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      files: <FileAttachment>[
        _file('f-e3', 'm-e3', 'photo (1).jpg', 4096,
            mime: 'image/jpeg', path: '/received/photo (1).jpg'),
      ],
    );
    return backend;
  }

  /// E4 — several messages at the same instant.
  ///
  /// Seeds three outgoing `done` messages with the **identical** `createdAt`
  /// (same second). The timeline de-duplicates by message id and shows all of
  /// them — same-instant messages are never collapsed.
  static FakeBackend e4SameInstantMessages() {
    final FakeBackend backend = FakeBackend(
      devices: <PeerDevice>[
        _device('E4000004', 'Eve Laptop', DeviceKind.desktop, lastPort: 53317),
      ],
      online: <DiscoveredPeer>[
        _live('E4000004', 'Eve Laptop', DeviceKind.desktop)
      ],
    );
    final Conversation conversation = backend.repo.addConversation(
      id: 'c-e4',
      deviceFingerprint: 'E4000004',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    for (var index = 0; index < 3; index++) {
      final String id = 'm-e4-$index';
      backend.repo.addMessage(
        id: id,
        conversationId: conversation.id,
        direction: MessageDirection.outgoing,
        status: MessageStatus.done,
        createdAt: fixedEpoch,
        files: <FileAttachment>[
          _file('f-e4-$index', id, 'part-$index.bin', 100 + index,
              path: '/src/part-$index.bin'),
        ],
      );
    }
    return backend;
  }

  /// E5 — the peer reinstalled (its fingerprint changed).
  ///
  /// The old thread (`E5000005`, alias "Eve (old)") is **archived**; a new
  /// device (`E5999999`, "Eve New Phone") appears. The stored old-row carries no
  /// preview/activity, so its home card reads "尚未传输过" — the old history is
  /// hidden from home but preserved in the archived entry (Q8 / U11).
  static FakeBackend e5PeerReinstalled() {
    final FakeBackend backend = FakeBackend(
      devices: <PeerDevice>[
        _device('E5000005', 'Eve (old)', DeviceKind.desktop, lastPort: 53317),
        _device('E5999999', 'Eve New Phone', DeviceKind.mobile,
            lastPort: 53317, preview: 'new.txt', activity: fixedEpoch),
      ],
      online: <DiscoveredPeer>[
        _live('E5999999', 'Eve New Phone', DeviceKind.mobile),
      ],
    );
    backend.repo.addConversation(
      id: 'c-e5-old',
      deviceFingerprint: 'E5000005',
      createdAt: fixedEpoch.subtract(const Duration(days: 1)),
      lastMessageAt: fixedEpoch.subtract(const Duration(days: 1)),
      lastPreview: 'old.pdf',
      isArchived: true,
    );
    final Conversation fresh = backend.repo.addConversation(
      id: 'c-e5-new',
      deviceFingerprint: 'E5999999',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
      lastPreview: 'new.txt',
    );
    backend.repo.addMessage(
      id: 'm-e5-new',
      conversationId: fresh.id,
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      files: <FileAttachment>[
        _file('f-e5-new', 'm-e5-new', 'new.txt', 10, path: '/received/new.txt'),
      ],
    );
    return backend;
  }

  /// E6 — the peer advertises no inbound server (`lastPort == 0`).
  ///
  /// Delegates to [FakeBackend.lastPortZero] (Frank, `FFFF6666`): seen and
  /// online, but not dialable, so sending must be refused and the UI must show
  /// "对方当前不可接收".
  static FakeBackend e6NotReceivable() => FakeBackend.lastPortZero();

  /// E7 — a file whose size is unknown (`size == -1`).
  ///
  /// Seeds an incoming `done` message carrying a `-1`-byte file (`mystery.bin`).
  /// The UI must render "未知大小", never "0 B" or "-1 B".
  static FakeBackend e7UnknownSize() {
    final FakeBackend backend = FakeBackend(
      devices: <PeerDevice>[
        _device('E7000007', 'Eve Laptop', DeviceKind.desktop, lastPort: 53317),
      ],
      online: <DiscoveredPeer>[
        _live('E7000007', 'Eve Laptop', DeviceKind.desktop)
      ],
    );
    final Conversation conversation = backend.repo.addConversation(
      id: 'c-e7',
      deviceFingerprint: 'E7000007',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-e7',
      conversationId: conversation.id,
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      files: <FileAttachment>[
        _file('f-e7', 'm-e7', 'mystery.bin', -1, path: '/received/mystery.bin'),
      ],
    );
    return backend;
  }

  /// E8 — the file has no MIME type (`mime == null`).
  ///
  /// Seeds `photo.png` with `mime: null`. Classification must fall back to the
  /// name's extension, so it still appears in "全部" **and** in the "图片" tab.
  static FakeBackend e8NullMime() {
    final FakeBackend backend = FakeBackend(
      devices: <PeerDevice>[
        _device('E8000008', 'Eve Laptop', DeviceKind.desktop, lastPort: 53317),
      ],
      online: <DiscoveredPeer>[
        _live('E8000008', 'Eve Laptop', DeviceKind.desktop)
      ],
    );
    final Conversation conversation = backend.repo.addConversation(
      id: 'c-e8',
      deviceFingerprint: 'E8000008',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-e8',
      conversationId: conversation.id,
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      files: <FileAttachment>[
        // `mime` deliberately omitted (null): classification falls back to `.png`.
        _file('f-e8', 'm-e8', 'photo.png', 2048, path: '/received/photo.png'),
      ],
    );
    return backend;
  }

  /// E9 — an **image** message (the M4 rework does real thumbnails).
  ///
  /// Seeds an image message (`pic.png`, `image/png`). PRD §6 E9 ("`thumbnail_path`
  /// is always NULL ⇒ always a type icon") is **retired** (design §8.2): an image
  /// now takes the `FileThumbnail` path and reads the port once. With no bytes
  /// preset the read yields `null`, so the slot falls back to the type icon — no
  /// broken image, no error. The widget test asserts the port was consulted and
  /// the fallback rendered.
  static FakeBackend e9ThumbnailNull() {
    final FakeBackend backend = FakeBackend(
      devices: <PeerDevice>[
        _device('E9000009', 'Eve Laptop', DeviceKind.desktop, lastPort: 53317),
      ],
      online: <DiscoveredPeer>[
        _live('E9000009', 'Eve Laptop', DeviceKind.desktop)
      ],
    );
    final Conversation conversation = backend.repo.addConversation(
      id: 'c-e9',
      deviceFingerprint: 'E9000009',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-e9',
      conversationId: conversation.id,
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      files: <FileAttachment>[
        _file('f-e9', 'm-e9', 'pic.png', 3072,
            mime: 'image/png', path: '/received/pic.png'),
      ],
    );
    return backend;
  }

  /// E10 — the discovery layer failed to start (port taken / NIC error).
  ///
  /// An empty backend. The failure cannot be a construction-time fixture: the
  /// home page calls `FakePeerDiscovery.start()` during init, which resets the
  /// phase to `running` — so the test injects the failure **after** start via
  /// `backend.discovery.fail(Scenarios.e10ErrorMessage)`. The banner must then be
  /// persistent and offer a retry.
  static FakeBackend e10DiscoveryFailed() => FakeBackend();

  /// The human-readable reason used by the E10 fixture (port occupied).
  static const String e10ErrorMessage = '端口 53317 被占用';

  /// E11 — one outgoing message with several files.
  ///
  /// Seeds a `done` message with three files and a `transferring` message with
  /// two files, so the bubble must list every file (name + size) and show the
  /// in-flight one's progress.
  static FakeBackend e11MultiFile() {
    final FakeBackend backend = FakeBackend(
      devices: <PeerDevice>[
        _device('E1100011', 'Eve Laptop', DeviceKind.desktop, lastPort: 53317),
      ],
      online: <DiscoveredPeer>[
        _live('E1100011', 'Eve Laptop', DeviceKind.desktop)
      ],
    );
    final Conversation conversation = backend.repo.addConversation(
      id: 'c-e11',
      deviceFingerprint: 'E1100011',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch.add(const Duration(minutes: 1)),
    );
    backend.repo.addMessage(
      id: 'm-e11-done',
      conversationId: conversation.id,
      direction: MessageDirection.outgoing,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      files: <FileAttachment>[
        _file('f-e11-a', 'm-e11-done', 'one.txt', 100, path: '/src/one.txt'),
        _file('f-e11-b', 'm-e11-done', 'two.png', 200,
            mime: 'image/png', path: '/src/two.png'),
        _file('f-e11-c', 'm-e11-done', 'three.zip', 300,
            path: '/src/three.zip'),
      ],
    );
    backend.repo.addMessage(
      id: 'm-e11-inflight',
      conversationId: conversation.id,
      direction: MessageDirection.outgoing,
      status: MessageStatus.transferring,
      createdAt: fixedEpoch.add(const Duration(minutes: 1)),
      files: <FileAttachment>[
        _file('f-e11-d', 'm-e11-inflight', 'four.bin', 400,
            path: '/src/four.bin'),
        _file('f-e11-e', 'm-e11-inflight', 'five.bin', 500,
            path: '/src/five.bin'),
      ],
    );
    return backend;
  }

  /// E12 — a very long CJK / emoji file name.
  ///
  /// Seeds one file whose name mixes Chinese, an emoji and a long tail. The
  /// timeline must truncate it to a single line without overflowing the layout.
  static FakeBackend e12LongName() {
    final FakeBackend backend = FakeBackend(
      devices: <PeerDevice>[
        _device('E1200012', 'Eve Laptop', DeviceKind.desktop, lastPort: 53317),
      ],
      online: <DiscoveredPeer>[
        _live('E1200012', 'Eve Laptop', DeviceKind.desktop)
      ],
    );
    final Conversation conversation = backend.repo.addConversation(
      id: 'c-e12',
      deviceFingerprint: 'E1200012',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-e12',
      conversationId: conversation.id,
      direction: MessageDirection.outgoing,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      files: <FileAttachment>[
        _file('f-e12', 'm-e12', e12LongFileName, 1024,
            path: '/src/$e12LongFileName'),
      ],
    );
    return backend;
  }

  /// The exact long name used by the E12 fixture (CJK + emoji + a long tail).
  static const String e12LongFileName =
      '这是一个非常非常长的中文文件名带表情🎉🚀以及一长串后缀用来测试单行截断.mp4';

  /// E13 — first run / the history database does not exist.
  ///
  /// A completely empty backend (no devices, no conversations): every page must
  /// show its **empty** state, never an error.
  static FakeBackend e13FreshInstall() => FakeBackend();

  /// E14 — a narrow window folds to **two levels** (list ⇄ detail) with a back
  /// affordance (PRD §8-A3 / design §6.1).
  ///
  /// The data is the ordinary three-device list — E14 is a *layout* behaviour, so
  /// the widget test drives the window width (`useSurfaceSize`) rather than the
  /// data. This builder exists so the narrow-window case has a named fixture like
  /// every other E-case.
  static FakeBackend e14NarrowFold() => FakeBackend.threeDevices();

  /// E15 — thumbnail load failed / the source file is gone.
  ///
  /// Seeds an **image** message (`gone.png`) whose source file is reported
  /// missing (`backend.platform.setExists('/received/gone.png', false)`). The
  /// recent-files row is then `sourceMissing`, so it renders a type icon and
  /// **never reads the port** (PRD §8-G30).
  static FakeBackend e15ThumbnailFallback() {
    final FakeBackend backend = FakeBackend(
      devices: <PeerDevice>[
        _device('E1500015', 'Eve Laptop', DeviceKind.desktop, lastPort: 53317),
      ],
      online: <DiscoveredPeer>[
        _live('E1500015', 'Eve Laptop', DeviceKind.desktop),
      ],
    );
    backend.platform.setExists('/received/gone.png', false);
    final Conversation conversation = backend.repo.addConversation(
      id: 'c-e15',
      deviceFingerprint: 'E1500015',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-e15',
      conversationId: conversation.id,
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      files: <FileAttachment>[
        _file('f-e15', 'm-e15', 'gone.png', 2048,
            mime: 'image/png', path: '/received/gone.png'),
      ],
    );
    return backend;
  }

  /// E16 — the middle-pane highlight and the right pane must stay in sync
  /// (PRD §6 E16), and the right pane must never collapse to an empty state.
  ///
  /// Two devices (one online) plus a conversation carrying an image and a video
  /// file, so a test can (a) move the conversation selection between two rows and
  /// (b) select a recent file, switch the middle-pane tab / type a query, and
  /// still see the file detail on the right.
  static FakeBackend e16SelectionSync() {
    final FakeBackend backend = FakeBackend(
      devices: <PeerDevice>[
        _device('AAAA1111', 'Alice Laptop', DeviceKind.desktop,
            lastPort: 53317, preview: 'photo.png', activity: fixedEpoch),
        _device('BBBB2222', 'Bob Phone', DeviceKind.mobile, lastPort: 53317),
      ],
      online: <DiscoveredPeer>[
        _live('AAAA1111', 'Alice Laptop', DeviceKind.desktop),
      ],
    );
    final Conversation conversation = backend.repo.addConversation(
      id: 'c-e16',
      deviceFingerprint: 'AAAA1111',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
      lastPreview: 'photo.png',
    );
    backend.repo.addMessage(
      id: 'm-e16-photo',
      conversationId: conversation.id,
      direction: MessageDirection.outgoing,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      files: <FileAttachment>[
        _file('f-e16-photo', 'm-e16-photo', 'photo.png', 2048,
            mime: 'image/png', path: '/received/photo.png'),
      ],
    );
    backend.repo.addMessage(
      id: 'm-e16-clip',
      conversationId: conversation.id,
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      createdAt: fixedEpoch.add(const Duration(minutes: 1)),
      files: <FileAttachment>[
        _file('f-e16-clip', 'm-e16-clip', 'clip.mp4', 4096,
            mime: 'video/mp4', path: '/received/clip.mp4'),
      ],
    );
    return backend;
  }

  /// E20–E22 — the right pane's **`文件` tab** (the per-conversation attachment
  /// list, PRD §4 / §10 E20–E22; design §8.3).
  ///
  /// Two conversations. The **bound** one (`E2000020` / `c-e20-a`) carries a
  /// two-file message plus a one-file message (3 attachments); a *second*
  /// conversation (`E2000021` / `c-e20-b`) carries one more. So the right pane's
  /// `文件` tab shows **3** rows while the middle-pane 最近文件 list shows **4** —
  /// two deliberately different data sources, which is exactly what E22 pins (the
  /// counts must **not** be equal). `photo.png` is an image (thumbnail slot); the
  /// rest are not (type icon). Every path is `/received/…` so the recent-files
  /// `sourceMissing` probe never hides a row.
  static FakeBackend e20ConversationFiles() {
    final FakeBackend backend = FakeBackend(
      devices: <PeerDevice>[
        _device('E2000020', 'Eve Laptop', DeviceKind.desktop,
            lastPort: 53317, preview: 'clip.mp4', activity: fixedEpoch),
        _device('E2000021', 'Mallory Phone', DeviceKind.mobile,
            lastPort: 53317, preview: 'other.txt', activity: fixedEpoch),
      ],
      online: <DiscoveredPeer>[
        _live('E2000020', 'Eve Laptop', DeviceKind.desktop),
      ],
    );
    final Conversation bound = backend.repo.addConversation(
      id: 'c-e20-a',
      deviceFingerprint: 'E2000020',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch.add(const Duration(minutes: 1)),
      lastPreview: 'clip.mp4',
    );
    backend.repo.addMessage(
      id: 'm-e20-a1',
      conversationId: bound.id,
      direction: MessageDirection.outgoing,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      files: <FileAttachment>[
        _file('f-e20-a1-photo', 'm-e20-a1', 'photo.png', 2048,
            mime: 'image/png', path: '/received/photo.png'),
        _file('f-e20-a1-notes', 'm-e20-a1', 'notes.pdf', 1024,
            mime: 'application/pdf', path: '/received/notes.pdf'),
      ],
    );
    backend.repo.addMessage(
      id: 'm-e20-a2',
      conversationId: bound.id,
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      createdAt: fixedEpoch.add(const Duration(minutes: 1)),
      files: <FileAttachment>[
        _file('f-e20-a2-clip', 'm-e20-a2', 'clip.mp4', 4096,
            mime: 'video/mp4', path: '/received/clip.mp4'),
      ],
    );
    final Conversation other = backend.repo.addConversation(
      id: 'c-e20-b',
      deviceFingerprint: 'E2000021',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
      lastPreview: 'other.txt',
    );
    backend.repo.addMessage(
      id: 'm-e20-b1',
      conversationId: other.id,
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      files: <FileAttachment>[
        _file('f-e20-b1', 'm-e20-b1', 'other.txt', 512,
            path: '/received/other.txt'),
      ],
    );
    return backend;
  }

  /// The bound conversation's attachment count in [e20ConversationFiles] — the
  /// `Σ history(msg).length` the E20 test asserts the `文件` tab renders.
  static const int e20BoundFileCount = 3;

  /// The global 最近文件 row count in [e20ConversationFiles] (E22: 4 ≠ 3).
  static const int e20RecentFileCount = 4;
}

/// The zero hash used by the seeded attachments (not asserted on).
const String _zeroHash =
    '0000000000000000000000000000000000000000000000000000000000000000';

PeerDevice _device(
  String fingerprint,
  String alias,
  DeviceKind kind, {
  int? lastPort,
  String? preview,
  DateTime? activity,
}) =>
    PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: kind,
      lastPort: lastPort,
      lastPreview: preview,
      lastActivityAt: activity,
    );

DiscoveredPeer _live(String fingerprint, String alias, DeviceKind kind) =>
    DiscoveredPeer(
      fingerprint: fingerprint,
      alias: alias,
      kind: kind,
      address: '192.168.1.10',
      port: 53317,
      isOnline: true,
      lastSeen: fixedEpoch,
    );

FileAttachment _file(
  String id,
  String messageId,
  String name,
  int size, {
  String? mime,
  String? path,
}) =>
    FileAttachment(
      id: id,
      messageId: messageId,
      fileName: name,
      size: size,
      mime: mime,
      sha256: _zeroHash,
      localPath: path,
    );
