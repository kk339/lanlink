/// Unit tests for [ConversationController] (spec §4.2 / §5.2, M4 T03).
///
/// Driven entirely by [FakeBackend] plus a real [TransferOrchestrator] over the
/// fake [TransferService]. Asserts the in-place event updates (§4.1), the send
/// action (pick → orchestrator), re-send (P1-4 / Q3) and cancel (Q9).
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/real/mappers.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/transfer_service.dart';
import 'package:lanlink_core/lanlink_core.dart' as core;

import 'support/fakes.dart';

PeerDevice _peer({
  String fingerprint = 'AAAA1111',
  bool online = true,
  int? port = 53317,
}) =>
    PeerDevice(
      fingerprint: fingerprint,
      alias: 'Alice',
      kind: DeviceKind.desktop,
      isOnline: online,
      lastPort: port,
    );

DiscoveredPeer _live(String fingerprint) => DiscoveredPeer(
      fingerprint: fingerprint,
      alias: 'Alice',
      kind: DeviceKind.desktop,
      address: '192.168.1.10',
      port: 53317,
      isOnline: true,
      lastSeen: fixedEpoch,
    );

OutgoingFile _outgoing(String id) => OutgoingFile(
      id: id,
      fileName: '$id.bin',
      size: 100,
      sha256: '00',
      localPath: '/src/$id.bin',
    );

FileAttachment _attachment(String id, String messageId, String path) =>
    FileAttachment(
      id: id,
      messageId: messageId,
      fileName: 'old.bin',
      size: 5,
      sha256: '00',
      localPath: path,
    );

void main() {
  late FakeBackend backend;
  late TransferOrchestrator orchestrator;
  late ConversationController controller;
  late String conversationId;

  setUp(() {
    backend = FakeBackend(
      devices: <PeerDevice>[_peer()],
      online: <DiscoveredPeer>[_live('AAAA1111')],
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

  test('load() reads the history ascending by createdAt', () async {
    backend.repo.addMessage(
      id: 'm-late',
      conversationId: conversationId,
      direction: MessageDirection.outgoing,
      status: MessageStatus.done,
      createdAt: fixedEpoch.add(const Duration(minutes: 5)),
    );
    backend.repo.addMessage(
      id: 'm-early',
      conversationId: conversationId,
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
    );

    await controller.load();
    expect(
      controller.messages.valueOrNull!.map((ChatMessage m) => m.id),
      const <String>['m-early', 'm-late'],
    );
    expect(controller.conversationId, 'c-1');
  });

  test(
    'a message for THIS conversation is appended in place; another '
    'conversation is ignored (§4.1)',
    () async {
      await controller.load();
      expect(controller.messages.valueOrNull, isEmpty);

      await orchestrator.send(
        peer: _peer(online: false),
        files: <OutgoingFile>[_outgoing('a')],
      );
      await pumpEventQueue();
      expect(controller.messages.valueOrNull!.length, 1);
      expect(controller.messages.valueOrNull!.single.status,
          MessageStatus.pending);

      await orchestrator.send(
        peer: _peer(fingerprint: 'BBBB2222'),
        files: <OutgoingFile>[_outgoing('b')],
      );
      await pumpEventQueue();
      expect(controller.messages.valueOrNull!.length, 1);
    },
  );

  test(
    'a status change is applied in place (same id, new status, new updatedAt '
    'from the clock — §4.1)',
    () async {
      await controller.load();
      await orchestrator.send(
        peer: _peer(online: false),
        files: <OutgoingFile>[_outgoing('a')],
      );
      await pumpEventQueue();

      final ChatMessage target = controller.messages.valueOrNull!.single;
      expect(target.status, MessageStatus.pending);

      final bool moved = backend.repo.setStatus(
        messageId: target.id,
        from: MessageStatus.pending,
        to: MessageStatus.canceled,
      );
      expect(moved, isTrue);
      await pumpEventQueue();

      final ChatMessage updated = controller.messages.valueOrNull!.single;
      expect(updated.id, target.id);
      expect(updated.status, MessageStatus.canceled);
      expect(updated.updatedAt, backend.clock.nowUtc());
    },
  );

  test(
    'cancel() moves a queued (pending) message to canceled and answers with '
    'copy; a message that cannot be cancelled gets a refusal, not silence '
    '(Q9 / 0.2.22)',
    () async {
      await controller.load();
      await orchestrator.send(
        peer: _peer(online: false),
        files: <OutgoingFile>[_outgoing('a')],
      );
      await pumpEventQueue();

      final ChatMessage pending = controller.messages.valueOrNull!.single;
      final CancelResult canceledResult = await controller.cancel(pending);
      expect(canceledResult.wasCanceled, isTrue);
      expect(canceledResult.notice, '已取消');
      await pumpEventQueue();

      final ChatMessage canceled = controller.messages.valueOrNull!.single;
      expect(canceled.status, MessageStatus.canceled);

      // Before 0.2.22 this returned `false` and the thread dropped it, so the
      // user saw *nothing*. Now the refusal carries a reason.
      final CancelResult again = await controller.cancel(canceled);
      expect(again.wasCanceled, isFalse);
      expect(again.notice, isNotEmpty);
      expect(canceled.status, MessageStatus.canceled);
    },
  );

  test(
    'pickAndSend returns null on a dismissed picker, and delivers on the '
    'online path (§4.4)',
    () async {
      backend.platform.setPickResult(FileKind.image, const <String>[]);
      expect(
        await controller.pickAndSend(peer: _peer(), kind: FileKind.image),
        isNull,
      );

      backend.platform.setPickResult(
        FileKind.image,
        const <String>['/src/a.png', '/src/b.png'],
      );
      backend.platform.setLength('/src/a.png', 10);
      backend.platform.setLength('/src/b.png', 20);
      backend.platform.setSha256('/src/a.png', 'AA');
      backend.platform.setSha256('/src/b.png', 'BB');

      final outcome =
          await controller.pickAndSend(peer: _peer(), kind: FileKind.image);
      expect(outcome, isNotNull);
      expect(outcome!.ok, isTrue);

      final ChatMessage sent = backend.repo.history(conversationId).last;
      expect(sent.direction, MessageDirection.outgoing);
      expect(sent.status, MessageStatus.done);
      expect(
        backend.repo.filesOf(sent.id).map((FileAttachment f) => f.fileName),
        const <String>['a.png', 'b.png'],
      );
    },
  );

  test(
    'canResend requires a failed message whose sources still exist; resend is '
    'a brand-new send (P1-4 / Q3)',
    () async {
      backend.repo.addMessage(
        id: 'm-failed',
        conversationId: conversationId,
        direction: MessageDirection.outgoing,
        status: MessageStatus.failed,
        files: <FileAttachment>[_attachment('f-1', 'm-failed', '/src/old.bin')],
      );
      backend.platform.setExists('/src/old.bin', false);

      final ChatMessage failed = backend.repo.history(conversationId).single;
      expect(await controller.canResend(failed), isFalse);
      expect(await controller.resend(peer: _peer(), message: failed), isNull);

      backend.platform.setExists('/src/old.bin', true);
      expect(await controller.canResend(failed), isTrue);

      final outcome = await controller.resend(peer: _peer(), message: failed);
      expect(outcome, isNotNull);
      expect(outcome!.ok, isTrue);

      final List<ChatMessage> history = backend.repo.history(conversationId);
      expect(history.length, 2);
      expect(history.last.id, isNot('m-failed'));
    },
  );

  test('canResend is false for a message that is not failed', () async {
    backend.repo.addMessage(
      id: 'm-done',
      conversationId: conversationId,
      direction: MessageDirection.outgoing,
      status: MessageStatus.done,
      files: <FileAttachment>[_attachment('f-d', 'm-done', '/src/d.bin')],
    );
    backend.platform.setExists('/src/d.bin', true);

    final ChatMessage done = backend.repo.history(conversationId).single;
    expect(await controller.canResend(done), isFalse);
  });

  // 0.2.12: `resend` used to call the orchestrator **without** bracketing it in
  // the progress ticker, so a re-sent file showed a frozen 0% for the whole
  // upload (the store emits nothing on a progress write; the ticker is what
  // turns those writes into a repaint). This asserts the bracket directly:
  // notifications arrive while the upload is held, and stop once it finishes.
  test('resend starts the progress ticker and stops it when done', () async {
    backend.repo.addMessage(
      id: 'm-failed',
      conversationId: conversationId,
      direction: MessageDirection.outgoing,
      status: MessageStatus.failed,
      files: <FileAttachment>[_attachment('f-1', 'm-failed', '/src/old.bin')],
    );
    backend.platform.setExists('/src/old.bin', true);
    // The failed attempt's own transfer carries the error, exactly as
    // `markSendFailed` leaves it. Without that the old row would still count as
    // "live" (0 of 5 bytes, no error) and the ticker would never stop — which
    // would make both assertions below meaningless.
    backend.repo.addTransfer(
      const TransferProgress(
        fileId: 'f-1',
        bytesDone: 0,
        bytesTotal: 5,
        error: 'network',
      ),
    );
    // The ticker only repaints while the loaded history holds a live transfer,
    // so the thread must be loaded first — exactly what opening a conversation
    // does in the app.
    await controller.load();

    final ChatMessage failed = backend.repo.history(conversationId).single;
    final Completer<void> gate = Completer<void>();
    backend.transfer.holdNextUpload(gate);

    int notifications = 0;
    controller.addListener(() => notifications++);

    final Future<SendOutcome?> pending =
        controller.resend(peer: _peer(), message: failed);

    // Let this send's own repository events land first (MessageAdded + the two
    // status changes), then watch a **quiet** window: while the upload is held
    // nothing else can repaint, so any further notification can only come from
    // the 1 Hz progress ticker. Asserting merely "> 0" would pass on those
    // events alone and would not catch the regression.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final int settled = notifications;
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(
      notifications,
      greaterThan(settled),
      reason: 'the ticker must repaint while the re-sent file is in flight',
    );

    gate.complete();
    await pending;

    // Same quiet-window rule after completion: the trailing
    // `MessageStatusUpdated` is a legitimate one-off, the 1 Hz cadence is not.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final int atCompletion = notifications;
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(
      notifications,
      atCompletion,
      reason: 'the ticker must stop once nothing is in flight',
    );
  });

  // ---------------------------------------------------------------------
  // T03 (c)/(d)/(d2) — the folder goes on the wire and into the database.
  //
  // Every assertion here is paired with a check that the **files** went too:
  // `folder.count == 3` on its own is also true of an implementation that
  // declared three files and sent two, which is exactly the kind of green that
  // proves nothing.
  // ---------------------------------------------------------------------
  group('folder send (docs/22 T03)', () {
    const List<String> paths = <String>[
      '/素材/a.txt',
      '/素材/sub/b.txt',
      '/素材/sub/deep/c.txt',
    ];
    const List<String> relatives = <String>[
      'a.txt',
      'sub/b.txt',
      'sub/deep/c.txt',
    ];
    const String folderName = '素材';

    test('(c) a folder send declares the folder and carries three positions',
        () async {
      final SendOutcome? outcome = await controller.sendPaths(
        peer: _peer(),
        paths: paths,
        relativePaths: relatives,
        folderName: folderName,
      );
      expect(outcome, isNotNull);
      expect(outcome!.delivered, isTrue);

      // 1. The folder object reached `prepare`.
      final FolderRef? folder = backend.transfer.lastPreparedFolder;
      expect(folder, isNotNull);
      expect(folder!.name, folderName);
      expect(folder.count, 3);

      // 2. ★ …and so did all three files. This is the half that stops
      // "count == 3" from being satisfied by a batch that lost a file.
      final List<OutgoingFile> prepared = backend.transfer.lastPreparedFiles;
      expect(prepared, hasLength(3));
      expect(folder.count, prepared.length,
          reason: '★ the declared count must equal the files actually prepared');

      // 3. Each file's position is correct **on the wire value** — asserted
      // through the real mapper, so this covers `FileMetadata.relativePath`
      // and not just the domain field.
      for (int index = 0; index < prepared.length; index++) {
        expect(prepared[index].relativePath, relatives[index]);
        final core.FileMetadata wire = fileMetadataFromOutgoing(prepared[index]);
        expect(wire.relativePath, relatives[index]);
        expect(wire.fileName, prepared[index].fileName);
      }
      // Distinct file ids, so the three are really three files.
      expect(prepared.map((OutgoingFile f) => f.id).toSet(), hasLength(3));
    });

    test('(c) an ordinary multi-select declares NO folder and NO positions',
        () async {
      final SendOutcome? outcome =
          await controller.sendPaths(peer: _peer(), paths: paths);
      expect(outcome!.delivered, isTrue);

      expect(backend.transfer.lastPreparedFolder, isNull);
      expect(backend.transfer.lastPreparedFiles, hasLength(3));
      for (final OutgoingFile file in backend.transfer.lastPreparedFiles) {
        // `null`, never `''`: the receiver tests "is there a value" to decide
        // whether a file has a level, and the wire key is omitted entirely.
        expect(file.relativePath, isNull);
        expect(fileMetadataFromOutgoing(file).relativePath, isNull);
      }
    });

    test('(d) the folder reaches the repository, not only the wire', () async {
      await controller.sendPaths(
        peer: _peer(),
        paths: paths,
        relativePaths: relatives,
        folderName: folderName,
      );

      final List<ChatMessage> outgoing = backend.repo
          .history(conversationId)
          .where((ChatMessage m) => m.direction == MessageDirection.outgoing)
          .toList(growable: false);
      expect(outgoing, hasLength(1), reason: 'one folder = one message');

      final FolderRef? recorded =
          backend.repo.outboundFolderOf(outgoing.single.id);
      expect(recorded, isNotNull);
      expect(recorded!.name, folderName);
      expect(recorded.count, 3);
    });

    test('(d2) ★ a relativePaths list of the wrong length throws before any '
        'byte moves', () async {
      final int messagesBefore = backend.repo.history(conversationId).length;

      await expectLater(
        controller.sendPaths(
          peer: _peer(),
          paths: paths, // 3
          relativePaths: <String>['a.txt'], // 1
          folderName: folderName,
        ),
        throwsArgumentError,
      );

      // ★ "Nothing was sent" has to be asserted on every side effect that could
      // have happened before the throw, not just on the exception:
      expect(backend.transfer.prepareCalls, 0,
          reason: 'no handshake may be attempted');
      expect(backend.transfer.lastPreparedFiles, isEmpty);
      expect(backend.transfer.preparedSessions, isEmpty);
      expect(backend.repo.history(conversationId), hasLength(messagesBefore),
          reason: 'no message row may be recorded');
    });

    test('a flat multi-select with an empty folderName stays flat', () async {
      // `folderName` without `relativePaths` cannot describe a folder, and the
      // receiver refuses a `folder` whose files carry no `path` (`400`). So the
      // pair degrades to a flat send instead of turning a working send into a
      // refused one.
      await controller.sendPaths(
        peer: _peer(),
        paths: paths,
        folderName: folderName,
      );

      expect(backend.transfer.lastPreparedFolder, isNull);
      expect(backend.transfer.lastPreparedFiles, hasLength(3));
      for (final OutgoingFile file in backend.transfer.lastPreparedFiles) {
        expect(file.relativePath, isNull);
      }
    });
  });
}
