/// Unit tests for [TransferOrchestrator] (spec §5.2 / §5.3, M4 T02 / T03).
///
/// All fakes — no real transfer. Asserts the M2 send sequence
/// (`pending → awaiting_confirm → transferring → done`), the rejected / failed /
/// queued branches and the inbound record path.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/session_repository.dart';
import 'package:lanlink_app/domain/transfer_service.dart';

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

OutgoingFile _file(String id, [int size = 100]) => OutgoingFile(
      id: id,
      fileName: '$id.bin',
      size: size,
      sha256: '00',
      localPath: '/src/$id.bin',
    );

void main() {
  late FakeBackend backend;
  late TransferOrchestrator orchestrator;

  setUp(() {
    backend = FakeBackend();
    orchestrator = TransferOrchestrator(
      repo: backend.repo,
      transfer: backend.transfer,
    );
  });

  tearDown(() {
    orchestrator.dispose();
    backend.dispose();
  });

  test('a peer with lastPort == 0 is refused and nothing is recorded (E6)',
      () async {
    final outcome = await orchestrator.send(
      peer: _peer(port: 0),
      files: <OutgoingFile>[_file('a')],
    );
    expect(outcome.ok, isFalse);
    expect(outcome.error, '对方当前不可接收');
    expect(backend.repo.conversations(), isEmpty);
  });

  test('a reachable-but-offline peer queues: stays pending, no session (Q9)',
      () async {
    final outcome = await orchestrator.send(
      peer: _peer(online: false),
      files: <OutgoingFile>[_file('a')],
    );
    expect(outcome.queued, isTrue);
    expect(outcome.rejected, isFalse);
    expect(outcome.error, isNull);

    final Conversation conversation = backend.repo.conversations().single;
    final ChatMessage message = backend.repo.history(conversation.id).single;
    expect(message.status, MessageStatus.pending);
    expect(backend.repo.sessionOf('a'), isNull);
  });

  test(
      'an online, dialable peer runs pending → awaiting_confirm → transferring '
      '→ done', () async {
    final List<MessageStatus> transitions = <MessageStatus>[];
    final StreamSubscription<RepoEvent> sub =
        backend.repo.events.listen((RepoEvent event) {
      if (event is MessageStatusUpdated) {
        transitions.add(event.to);
      }
    });
    addTearDown(sub.cancel);

    final outcome = await orchestrator.send(
      peer: _peer(),
      files: <OutgoingFile>[_file('a', 4096)],
    );
    await pumpEventQueue();

    expect(outcome.ok, isTrue);
    expect(outcome.queued, isFalse);
    expect(outcome.rejected, isFalse);
    expect(transitions, const <MessageStatus>[
      MessageStatus.awaitingConfirm,
      MessageStatus.transferring,
      MessageStatus.done,
    ]);

    final Conversation conversation = backend.repo.conversations().single;
    expect(
      backend.repo.history(conversation.id).single.status,
      MessageStatus.done,
    );
    expect(backend.repo.transferOf('a')!.bytesDone, 4096);
    expect(backend.repo.sessionOf('a'), isNotNull);
  });

  test('a prepare rejection (403) moves the message to rejected (§1.4)',
      () async {
    backend.transfer.rejectNextPrepare(403, 'disabled');
    final outcome = await orchestrator.send(
      peer: _peer(),
      files: <OutgoingFile>[_file('a')],
    );
    expect(outcome.rejected, isTrue);
    expect(outcome.error, 'HTTP 403');

    final Conversation conversation = backend.repo.conversations().single;
    expect(
      backend.repo.history(conversation.id).single.status,
      MessageStatus.rejected,
    );
  });

  test('a prepare network error marks the message failed', () async {
    backend.transfer.failNextPrepare(StateError('network down'));
    final outcome = await orchestrator.send(
      peer: _peer(),
      files: <OutgoingFile>[_file('a')],
    );
    expect(outcome.ok, isFalse);
    expect(outcome.rejected, isFalse);

    final Conversation conversation = backend.repo.conversations().single;
    expect(
      backend.repo.history(conversation.id).single.status,
      MessageStatus.failed,
    );
  });

  test('an upload error marks the message failed', () async {
    backend.transfer.failNextUpload(StateError('io'));
    final outcome = await orchestrator.send(
      peer: _peer(),
      files: <OutgoingFile>[_file('a')],
    );
    expect(outcome.ok, isFalse);

    final Conversation conversation = backend.repo.conversations().single;
    expect(
      backend.repo.history(conversation.id).single.status,
      MessageStatus.failed,
    );
  });

  test('a text send records one pending→done kind=text message (§7.3)',
      () async {
    final outcome = await orchestrator.sendText(
      peer: _peer(),
      text: 'hello',
      nonce: 'n-send-1',
    );
    await pumpEventQueue();

    expect(outcome.ok, isTrue);
    expect(outcome.queued, isFalse);
    expect(backend.transfer.sentTexts.single.id, 'n-send-1');
    expect(backend.transfer.sentTexts.single.text, 'hello');

    final Conversation conversation = backend.repo.conversations().single;
    final ChatMessage message = backend.repo.history(conversation.id).single;
    expect(message.kind, MessageKind.text);
    expect(message.direction, MessageDirection.outgoing);
    expect(message.textBody, 'hello');
    expect(message.status, MessageStatus.done);
  });

  test('a text refusal (403) lands the message rejected, not failed (§7.3)',
      () async {
    backend.transfer.rejectNextText(403, 'disabled');
    final outcome = await orchestrator.sendText(
      peer: _peer(),
      text: 'nope',
      nonce: 'n-send-2',
    );
    await pumpEventQueue();

    expect(outcome.rejected, isTrue);
    final Conversation conversation = backend.repo.conversations().single;
    expect(
      backend.repo.history(conversation.id).single.status,
      MessageStatus.rejected,
    );
  });

  test('an inbound transfer is recorded as one incoming done message (§5.3)',
      () async {
    backend.transfer.emitReceived(
      ReceivedTransfer(
        file: const IncomingFile(
          fileId: 'r-1',
          fileName: 'landed.bin',
          size: 7,
          sha256: '00',
          savedPath: '/received/landed.bin',
        ),
        sender: DiscoveredPeer(
          fingerprint: 'CAFE0003',
          alias: 'Zoe',
          kind: DeviceKind.mobile,
          address: '192.168.1.9',
          port: 53317,
          isOnline: true,
          lastSeen: fixedEpoch,
        ),
      ),
    );
    await pumpEventQueue();

    final Conversation conversation = backend.repo.conversations().single;
    final ChatMessage message = backend.repo.history(conversation.id).single;
    expect(message.direction, MessageDirection.incoming);
    expect(message.status, MessageStatus.done);
    expect(backend.repo.filesOf(message.id).single.fileName, 'landed.bin');
  });

  // ---------------------------------------------------------------------
  // One `prepare` session is ONE message (docs/22 §4.2 for folders, and
  // 0.2.51 for flat multi-selects).
  //
  // The branch order is the contract and each test pins one half of it:
  // folder first (its descriptor must survive), then a flat arrival **with a
  // session** (aggregated — a multi-select), and last the old one-file-one-
  // message path for a single file / a pre-0.2.38 peer that carries no session
  // id. The last two would look identical if the branch were keyed on "flat",
  // which is exactly why both are asserted.
  // ---------------------------------------------------------------------
  group('folder aggregation', () {
    DiscoveredPeer sender() => DiscoveredPeer(
          fingerprint: 'CAFE0005',
          alias: 'Zoe',
          kind: DeviceKind.mobile,
          address: '192.168.1.9',
          port: 53317,
          isOnline: true,
          lastSeen: fixedEpoch,
        );

    ReceivedTransfer folderArrival({
      required String fileId,
      required String relativePath,
      String sessionId = 'sess-abc',
      String folderName = '素材',
      int folderFiles = 3,
    }) =>
        ReceivedTransfer(
          file: IncomingFile(
            fileId: fileId,
            fileName: relativePath.contains('/')
                ? relativePath.split('/').last
                : relativePath,
            size: 5,
            sha256: '00',
            savedPath: '/received/素材/$relativePath',
            relativePath: relativePath,
          ),
          sender: sender(),
          sessionId: sessionId,
          folderName: folderName,
          folderFiles: folderFiles,
        );

    test('(a) ★ three files of one session become ONE message with THREE rows',
        () async {
      for (final String id in <String>['f1', 'f2', 'f3']) {
        backend.transfer.emitReceived(
          folderArrival(fileId: id, relativePath: '$id.bin'),
        );
      }
      await pumpEventQueue();

      final Conversation conversation = backend.repo.conversations().single;
      final List<ChatMessage> messages = backend.repo.history(conversation.id);

      // ★ The whole point: N arrivals, 1 message. Asserting the count first
      // means "3 files in 3 messages" cannot pass by looking at the files.
      expect(messages, hasLength(1));
      final ChatMessage message = messages.single;
      expect(message.direction, MessageDirection.incoming);
      expect(message.status, MessageStatus.done);

      // …and all three attachments are on it.
      final List<FileAttachment> files = backend.repo.filesOf(message.id);
      expect(files, hasLength(3));
      expect(
        files.map((FileAttachment f) => f.id).toSet(),
        <String>{'f1', 'f2', 'f3'},
      );

      // The declared descriptor is stored, and it matches what arrived here
      // (the honest count is `files.length`; this case happens to agree).
      final ({String name, int declared})? folder =
          backend.repo.inboundFolderOf(message.id);
      expect(folder, isNotNull);
      expect(folder!.name, '素材');
      expect(folder.declared, 3);
      expect(files, hasLength(folder.declared));
    });

    test('(a) the attachments keep their own relative paths', () async {
      backend.transfer.emitReceived(
        folderArrival(fileId: 'f1', relativePath: 'a.bin'),
      );
      backend.transfer.emitReceived(
        folderArrival(fileId: 'f2', relativePath: 'data/b.bin'),
      );
      await pumpEventQueue();

      final Conversation conversation = backend.repo.conversations().single;
      final ChatMessage message = backend.repo.history(conversation.id).single;
      expect(
        backend.repo
            .filesOf(message.id)
            .map((FileAttachment f) => f.relativePath)
            .toList(),
        <String>['a.bin', 'data/b.bin'],
      );
    });

    test('(a) declared count ≠ arrived count is not a lie in the store',
        () async {
      // The sender may declare 3 and lose a link; the stored number stays the
      // **declared** one, and the UI is expected to count `files` rows for the
      // "arrived" half. If this ever started writing the arrived count here, the
      // two numbers would become indistinguishable.
      backend.transfer.emitReceived(
        folderArrival(fileId: 'f1', relativePath: 'a.bin'),
      );
      await pumpEventQueue();

      final Conversation conversation = backend.repo.conversations().single;
      final ChatMessage message = backend.repo.history(conversation.id).single;
      expect(backend.repo.inboundFolderOf(message.id)!.declared, 3);
      expect(backend.repo.filesOf(message.id), hasLength(1));
    });

    test(
        '★ 0.2.51 (b): three FLAT arrivals of one session are ONE message with '
        'THREE rows — a multi-select is one batch, not three messages', () async {
      // The same shape a real multi-select send produces on the wire: one
      // `prepare` carrying N files, N `put`s, one session id on every arrival.
      // Until 0.2.51 the store anchored each file on its own `fileId`, so this
      // arrived as three bubbles and the computer showed three messages for one
      // 多选.
      for (final String id in <String>['g1', 'g2', 'g3']) {
        backend.transfer.emitReceived(
          ReceivedTransfer(
            file: IncomingFile(
              fileId: id,
              fileName: '$id.bin',
              size: 5,
              sha256: '00',
              savedPath: '/received/$id.bin',
            ),
            sender: sender(),
            sessionId: 'sess-shared',
          ),
        );
      }
      await pumpEventQueue();

      final Conversation conversation = backend.repo.conversations().single;
      final List<ChatMessage> messages = backend.repo.history(conversation.id);

      // ★ The whole point: N arrivals, 1 message. Asserting the count first means
      // "3 files in 3 messages" cannot pass by counting attachments only.
      expect(messages, hasLength(1),
          reason: '★ one `prepare` session is one message — for a multi-select '
              'exactly as for a folder');
      final ChatMessage message = messages.single;
      expect(
        backend.repo
            .filesOf(message.id)
            .map((FileAttachment f) => f.id)
            .toSet(),
        <String>{'g1', 'g2', 'g3'},
      );

      // …and it is **not** a folder: a batch keeps its own bubble with one row
      // per file — no folder card, no browse page, no declared count.
      expect(message.folderName, isNull);
      expect(message.isFolder, isFalse);
      expect(backend.repo.inboundFolderOf(message.id), isNull,
          reason: 'a batch must never write a folder descriptor');
    });

    test('★ 0.2.51 (b): …but two DIFFERENT sessions are still two messages',
        () async {
      // The other half of the same contract, and the one that catches an
      // over-eager fix: aggregation is **per session**, never "all flat files
      // look like one send". Two separate sends of one file each stay two
      // messages, even in the same conversation and from the same peer.
      for (final String id in <String>['g1', 'g2']) {
        backend.transfer.emitReceived(
          ReceivedTransfer(
            file: IncomingFile(
              fileId: id,
              fileName: '$id.bin',
              size: 5,
              sha256: '00',
              savedPath: '/received/$id.bin',
            ),
            sender: sender(),
            sessionId: 'sess-$id',
          ),
        );
      }
      await pumpEventQueue();

      final Conversation conversation = backend.repo.conversations().single;
      final List<ChatMessage> messages = backend.repo.history(conversation.id);
      expect(messages, hasLength(2),
          reason: 'two sessions = two sends = two messages');
      for (final ChatMessage message in messages) {
        expect(backend.repo.filesOf(message.id), hasLength(1));
      }
    });

    test(
        '★ 0.2.51 (b): a single file with NO session id is untouched — 1 file = '
        '1 message, one `MessageAdded`, nothing else', () async {
      // Every pre-0.2.38 peer, and every genuinely single-file send. This is the
      // regression line for "the batch path did not swallow the old path": an
      // arrival without a session id must still reach `recordIncoming`.
      final List<String> events = <String>[];
      final StreamSubscription<RepoEvent> sub =
          backend.repo.events.listen((RepoEvent event) {
        events.add(event.runtimeType.toString());
      });
      addTearDown(sub.cancel);

      backend.transfer.emitReceived(
        ReceivedTransfer(
          file: const IncomingFile(
            fileId: 'g1',
            fileName: 'solo.bin',
            size: 5,
            sha256: '00',
            savedPath: '/received/solo.bin',
          ),
          sender: sender(),
        ),
      );
      await pumpEventQueue();

      final Conversation conversation = backend.repo.conversations().single;
      final ChatMessage message = backend.repo.history(conversation.id).single;
      expect(message.isFolder, isFalse);
      expect(message.status, MessageStatus.done);
      expect(backend.repo.filesOf(message.id).single.fileName, 'solo.bin');
      expect(backend.repo.inboundFolderOf(message.id), isNull);
      expect(events, <String>['MessageAdded'],
          reason: 'one arrival, one event — no append event for the file that '
              'created the message');
    });
  });

  test('an inbound text is recorded as one incoming done message (§7.3)',
      () async {
    backend.transfer.emitReceivedText(
      ReceivedText(
        sender: DiscoveredPeer(
          fingerprint: 'CAFE0004',
          alias: 'Zoe',
          kind: DeviceKind.mobile,
          address: '192.168.1.9',
          port: 53317,
          isOnline: true,
          lastSeen: fixedEpoch,
        ),
        id: 'nonce-1',
        text: 'hi back',
      ),
    );
    await pumpEventQueue();

    final Conversation conversation = backend.repo.conversations().single;
    final ChatMessage message = backend.repo.history(conversation.id).single;
    expect(message.direction, MessageDirection.incoming);
    expect(message.kind, MessageKind.text);
    expect(message.textBody, 'hi back');
    expect(message.status, MessageStatus.done);
  });

  test('a re-delivered text frame (same nonce) is de-duplicated (§7.3)',
      () async {
    DiscoveredPeer sender() => DiscoveredPeer(
          fingerprint: 'CAFE0005',
          alias: 'Zoe',
          kind: DeviceKind.mobile,
          address: '192.168.1.9',
          port: 53317,
          isOnline: true,
          lastSeen: fixedEpoch,
        );
    backend.transfer.emitReceivedText(
        ReceivedText(sender: sender(), id: 'n-dup', text: 'x'));
    backend.transfer.emitReceivedText(
        ReceivedText(sender: sender(), id: 'n-dup', text: 'x'));
    await pumpEventQueue();

    final Conversation conversation = backend.repo.conversations().single;
    expect(backend.repo.history(conversation.id), hasLength(1));
  });

  // ── progress persistence throttle (0.2.12) ────────────────────────────────
  //
  // The upload callback fires once per MiB (that is what the rate probe reads),
  // but persisting a row on every one of those made a 1 GiB file do 1024
  // fsync-backed commits. The row value ends up identical either way, so only
  // the **count** can tell the two behaviours apart — hence these two tests:
  // one pins the throttle, the other proves the counter can see every write.

  test('progress persistence is throttled to one write per interval', () async {
    final FakeBackend b = FakeBackend();
    final TransferOrchestrator o = TransferOrchestrator(
      repo: b.repo,
      transfer: b.transfer,
      clock: b.clock,
    );
    try {
      // 200 callbacks, 5 ms apart = 1 s of transfer wall time.
      b.transfer.reportProgressInBurst(
        count: 200,
        onStep: () => b.clock.advance(const Duration(milliseconds: 5)),
      );

      final SendOutcome outcome =
          await o.send(peer: _peer(), files: <OutgoingFile>[_file('a', 200)]);
      expect(outcome.ok, isTrue);

      // 1 s / 500 ms => ~3 writes (first callback + two more), plus the terminal
      // write. Anything near 200 means the throttle is gone.
      expect(
        b.repo.progressWrites,
        lessThanOrEqualTo(5),
        reason: 'persisting every MiB would write ~200 times for 200 callbacks',
      );
      // The value the UI ends on must still be exact — throttling may skip
      // intermediate rows, never the final one.
      expect(b.repo.transferOf('a')!.bytesDone, 200);
    } finally {
      o.dispose();
      b.dispose();
    }
  });

  test('with a zero interval every callback persists (throttle is the cause)',
      () async {
    final FakeBackend b = FakeBackend();
    final TransferOrchestrator o = TransferOrchestrator(
      repo: b.repo,
      transfer: b.transfer,
      clock: b.clock,
      progressPersistInterval: Duration.zero,
    );
    try {
      b.transfer.reportProgressInBurst(
        count: 200,
        onStep: () => b.clock.advance(const Duration(milliseconds: 5)),
      );

      await o.send(peer: _peer(), files: <OutgoingFile>[_file('a', 200)]);

      // 200 burst callbacks + the fake's own final "whole size" callback + the
      // orchestrator's terminal write = 202. The exact number is the point: it
      // proves the count above measures the throttle, not an artifact of the
      // fake.
      expect(b.repo.progressWrites, 202);
      expect(b.repo.transferOf('a')!.bytesDone, 200);
    } finally {
      o.dispose();
      b.dispose();
    }
  });
}
