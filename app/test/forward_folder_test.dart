/// 0.2.42 — forwarding a folder declares the folder descriptor with the **same**
/// rule a re-send uses (`ConversationController._positionOf`).
///
/// The two send paths used to disagree about one fact. `_forwardOne` said "keep
/// the hierarchy only when **every** file has one, otherwise send a flat batch",
/// while `resend` (fixed earlier in 0.2.42) says "a missing position falls back
/// to the file's own name". So the same folder, forwarded, could reach the peer
/// as N loose bubbles — and whether it did depended on one null in one row, which
/// is not something a user can report ("有时候是文件夹，有时候不是").
///
/// The tests below pin the unified rule from both sides: a null position no
/// longer demotes the message, and a complete folder behaves exactly as before.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/domain/models.dart';

import 'support/fakes.dart';

PeerDevice _source() => const PeerDevice(
      fingerprint: 'AAAA1111',
      alias: 'Alice',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// The device a message is forwarded **to** — 「会话 = 设备」, so forwarding
/// always writes into another device's conversation.
PeerDevice _target() => const PeerDevice(
      fingerprint: 'BBBB2222',
      alias: 'Bob',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53318,
    );

FileAttachment _row(
  String messageId, {
  required String id,
  required String fileName,
  required String path,
  String? relative,
}) =>
    FileAttachment(
      id: id,
      messageId: messageId,
      fileName: fileName,
      size: 5,
      sha256: 'aa',
      localPath: path,
      relativePath: relative,
    );

void main() {
  late FakeBackend backend;
  late TransferOrchestrator orchestrator;
  late ConversationController controller;
  late String conversationId;

  setUp(() {
    backend = FakeBackend(
      devices: <PeerDevice>[_source(), _target()],
      online: <DiscoveredPeer>[
        DiscoveredPeer(
          fingerprint: 'AAAA1111',
          alias: 'Alice',
          kind: DeviceKind.desktop,
          address: '192.168.1.10',
          port: 53317,
          isOnline: true,
          lastSeen: fixedEpoch,
        ),
        DiscoveredPeer(
          fingerprint: 'BBBB2222',
          alias: 'Bob',
          kind: DeviceKind.desktop,
          address: '192.168.1.11',
          port: 53318,
          isOnline: true,
          lastSeen: fixedEpoch,
        ),
      ],
    );
    conversationId = backend.repo
        .addConversation(id: 'c-1', deviceFingerprint: 'AAAA1111')
        .id;
    orchestrator = TransferOrchestrator(
      repo: backend.repo,
      transfer: backend.transfer,
    );
    controller = ConversationController(
      repo: backend.repo,
      orchestrator: orchestrator,
      platform: backend.platform,
      ids: backend.ids,
      clock: backend.clock,
      conversationId: conversationId,
    );
  });

  tearDown(() {
    controller.dispose();
    orchestrator.dispose();
    backend.dispose();
  });

  /// Seeds one folder message and returns it, ready to be picked.
  ///
  /// `folderName: null` seeds a plain multi-file message; `''` seeds the
  /// degenerate "named, but not nameable" row (see the blank-name test).
  ChatMessage seedMessage({
    required String id,
    required List<FileAttachment> files,
    String? folderName = '素材',
    MessageStatus status = MessageStatus.done,
  }) {
    final bool namedFolder = folderName != null && folderName.isNotEmpty;
    backend.repo.addMessage(
      id: id,
      conversationId: conversationId,
      direction: MessageDirection.outgoing,
      status: status,
      folderName: folderName,
      folderFiles: namedFolder ? files.length : 0,
      files: files,
    );
    return backend.repo
        .history(conversationId)
        .firstWhere((ChatMessage m) => m.id == id);
  }

  /// Picks [message] and forwards the selection to [_target].
  ///
  /// `load()` first, because multi-select answers from the **loaded** timeline
  /// (`selectedMessages` filters `messages`, not a lookup by id) — exactly the
  /// state the app is in when the user opens a thread and uses the ⋯ menu.
  Future<ForwardReport> forward(ChatMessage message) async {
    await controller.load();
    controller.startSelecting();
    controller.toggleSelected(message);
    expect(controller.selectedCount, 1, reason: 'the row must be pickable');
    return controller.forwardSelectedTo(_target());
  }

  test(
    'criterion 1: one null position no longer demotes a forwarded folder — the '
    'descriptor still goes out and that file travels at the root under its own '
    'name',
    () async {
      final ChatMessage folder = seedMessage(
        id: 'm-folder',
        files: <FileAttachment>[
          _row('m-folder',
              id: 'f-1',
              fileName: 'a.txt',
              path: '/素材/a.txt',
              relative: 'sub/a.txt'),
          // ★ The row that used to flip the whole message to flat.
          _row('m-folder', id: 'f-2', fileName: 'b.txt', path: '/素材/b.txt'),
        ],
      );

      final ForwardReport report = await forward(folder);
      expect(report.sent, 1);
      expect(report.failures, isEmpty);

      final FolderRef? preparedFolder = backend.transfer.lastPreparedFolder;
      expect(preparedFolder, isNotNull,
          reason: '★ a null position must not turn one folder into N bubbles');
      expect(preparedFolder!.name, '素材');
      expect(preparedFolder.count, 2);

      final List<OutgoingFile> prepared = backend.transfer.lastPreparedFiles;
      expect(prepared, hasLength(2), reason: 'both files still go');
      expect(prepared[0].relativePath, 'sub/a.txt',
          reason: 'a stored position is passed through untouched');
      // `fileName`, not `null`: `null` would make the frame contradict itself
      // (folder declared, one file positionless) and the peer answers 400.
      expect(prepared[1].relativePath, 'b.txt',
          reason: '★ the fallback is the file\'s own name, not a dropped folder');
      for (final OutgoingFile file in prepared) {
        expect(file.relativePath, isNotNull);
        expect(file.relativePath!.isNotEmpty, isTrue);
      }
      expect(preparedFolder.count, prepared.length);
    },
  );

  test(
    'criterion 2 (regression): a complete folder is forwarded exactly as before '
    '— descriptor plus every stored position',
    () async {
      final ChatMessage folder = seedMessage(
        id: 'm-whole',
        files: <FileAttachment>[
          _row('m-whole',
              id: 'f-1', fileName: 'a.txt', path: '/素材/a.txt', relative: 'a.txt'),
          _row('m-whole',
              id: 'f-2',
              fileName: 'b.txt',
              path: '/素材/sub/b.txt',
              relative: 'sub/b.txt'),
        ],
      );

      final ForwardReport report = await forward(folder);
      expect(report.sent, 1,
          reason: 'forward failures: '
              '${report.failures.map((ForwardFailure f) => f.reason).toList()}');

      expect(backend.transfer.lastPreparedFolder!.name, '素材');
      expect(backend.transfer.lastPreparedFolder!.count, 2);
      expect(
        backend.transfer.lastPreparedFiles
            .map((OutgoingFile f) => f.relativePath)
            .toList(),
        const <String>['a.txt', 'sub/b.txt'],
      );
    },
  );

  test(
    'a flat message is still forwarded flat — no descriptor, no positions',
    () async {
      final ChatMessage flat = seedMessage(
        id: 'm-flat',
        folderName: null,
        files: <FileAttachment>[
          _row('m-flat', id: 'f-1', fileName: 'a.txt', path: '/src/a.txt'),
          _row('m-flat', id: 'f-2', fileName: 'b.txt', path: '/src/b.txt'),
        ],
      );

      final ForwardReport report = await forward(flat);
      expect(report.sent, 1);

      expect(backend.transfer.lastPreparedFolder, isNull,
          reason: '★ a flat send must not grow a folder (that frame is a 400)');
      for (final OutgoingFile file in backend.transfer.lastPreparedFiles) {
        expect(file.relativePath, isNull);
      }
    },
  );

  test(
    'a blank folder name is forwarded as a FLAT send, never as a frame that '
    'says "folder" with no name while its files carry positions',
    () async {
      // `sendPaths` builds its `FolderRef` from a null check alone, so a blank
      // name would reach `folderDescriptorFromRef` as `null` — a folder-less
      // frame whose files all carry `path`, i.e. a 400. The forward path therefore
      // tests the name, not just the null.
      final ChatMessage blank = seedMessage(
        id: 'm-blank',
        folderName: '',
        files: <FileAttachment>[
          _row('m-blank',
              id: 'f-1', fileName: 'a.txt', path: '/src/a.txt', relative: 'x/a.txt'),
          _row('m-blank', id: 'f-2', fileName: 'b.txt', path: '/src/b.txt'),
        ],
      );

      final ForwardReport report = await forward(blank);
      expect(report.sent, 1);

      expect(backend.transfer.lastPreparedFolder, isNull);
      for (final OutgoingFile file in backend.transfer.lastPreparedFiles) {
        expect(file.relativePath, isNull,
            reason: 'no descriptor → no positions, or the frame contradicts itself');
      }
    },
  );
}
