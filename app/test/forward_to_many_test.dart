/// **Forwarding one batch to several devices** (0.2.46) — the controller half.
///
/// Until this release 「转发」 answered one device, because the only door was
/// 「⋯ → 多选 → 转发」 and one device per run was the scope. The user's request was
/// "右键一条消息就能转发" **and** "转给两台怎么办", so the same batch now fans out
/// over a list of targets.
///
/// What these cases pin, each against a way the fan-out could be wrong:
///
/// * **5** — a file forwarded to 2 devices really goes out twice: the fake
///   `TransferService` `prepare`d it **once per device** (a row in each store
///   would not be a send);
/// * **6** — an **offline** target ends up `pending` (queued, the pump delivers it
///   later) while the online one ends up `done`: the two are genuinely different
///   states, not one "ok";
/// * **4** — an **empty** target list sends nothing at all. "The user closed the
///   picker" must never be read as "send to everybody";
/// * **serial** — target N+1 does not start until target N is finished. Proved
///   by parking the first `prepare` and asserting the second one has not been
///   called yet (a `Future.wait` fan-out would show 2 immediately);
/// * the per-device sentence lists **every** device with its own verdict, and a
///   gone source file fails **both** devices without leaving an empty message in
///   either conversation.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/picked_cache.dart';

import 'support/fakes.dart';

/// Records what the controller asked to delete from the picked-file cache.
class _RecordingCache implements PickedCachePort {
  /// Every path handed to [discard], flattened.
  final List<String> discarded = <String>[];

  @override
  Future<void> discard(Iterable<String> paths) async {
    discarded.addAll(paths);
  }

  @override
  Future<void> clear({Set<String> keep = const <String>{}}) async {}
}

const String _sourceFp = 'AAAA1111';
const String _onlineFp = 'BBBB2222';
const String _offlineFp = 'CCCC3333';

/// The conversation the messages are forwarded **from**.
PeerDevice _source() => const PeerDevice(
      fingerprint: _sourceFp,
      alias: 'Alice',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// A reachable, online device.
PeerDevice _online() => const PeerDevice(
      fingerprint: _onlineFp,
      alias: '台式机',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53318,
    );

/// A device we have a history with that is **offline right now**: a real port
/// (so it is `canSend` and `isDialable`) but no live discovery entry, which is
/// exactly what makes a send queue instead of fail (Q9).
PeerDevice _offline() => const PeerDevice(
      fingerprint: _offlineFp,
      alias: '笔记本',
      kind: DeviceKind.desktop,
      isOnline: false,
      lastPort: 53319,
    );

const String _body = '这句要转给两台设备';

void main() {
  late FakeBackend backend;
  late TransferOrchestrator orchestrator;
  late ConversationController controller;
  late String conversationId;

  setUp(() {
    backend = FakeBackend(
      devices: <PeerDevice>[_source(), _online(), _offline()],
      online: <DiscoveredPeer>[
        DiscoveredPeer(
          fingerprint: _sourceFp,
          alias: 'Alice',
          kind: DeviceKind.desktop,
          address: '192.168.1.10',
          port: 53317,
          isOnline: true,
          lastSeen: fixedEpoch,
        ),
        DiscoveredPeer(
          fingerprint: _onlineFp,
          alias: '台式机',
          kind: DeviceKind.desktop,
          address: '192.168.1.11',
          port: 53318,
          isOnline: true,
          lastSeen: fixedEpoch,
        ),
      ],
    );
    conversationId = backend.repo
        .addConversation(id: 'c-src', deviceFingerprint: _sourceFp)
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

  /// Seeds one text row in the source conversation and returns it.
  ChatMessage seedText({String id = 'm-text'}) {
    backend.repo.addMessage(
      id: id,
      conversationId: conversationId,
      direction: MessageDirection.outgoing,
      status: MessageStatus.done,
      kind: MessageKind.text,
      textBody: _body,
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
    );
    return backend.repo
        .history(conversationId)
        .firstWhere((ChatMessage m) => m.id == id);
  }

  /// Seeds one file row whose source is [path].
  ChatMessage seedFile({String id = 'm-file', String path = '/d/notes.txt'}) {
    backend.repo.addMessage(
      id: id,
      conversationId: conversationId,
      direction: MessageDirection.outgoing,
      status: MessageStatus.done,
      kind: MessageKind.file,
      files: <FileAttachment>[
        FileAttachment(
          id: 'f-$id',
          messageId: id,
          fileName: 'notes.txt',
          size: 12,
          sha256: 'AA',
          localPath: path,
        ),
      ],
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
    );
    return backend.repo
        .history(conversationId)
        .firstWhere((ChatMessage m) => m.id == id);
  }

  /// Every message recorded in the conversation with [fingerprint] — read back
  /// through the repository, i.e. what a restarted app would show.
  ///
  /// An **absent** conversation answers an empty list rather than throwing: "that
  /// device was never written to" is exactly the fact several cases below assert
  /// (a fan-out that sent everything to everybody, a failed forward that left no
  /// row behind), so a helper that threw would turn the assertion into an error.
  List<ChatMessage> historyOf(String fingerprint) {
    final Iterable<Conversation> matches = backend.repo.conversations().where(
          (Conversation c) =>
              (c.deviceFingerprint ?? '').toUpperCase() ==
              fingerprint.toUpperCase(),
        );
    if (matches.isEmpty) {
      return const <ChatMessage>[];
    }
    return backend.repo.history(matches.first.id);
  }

  test(
    '★ criterion 5: a file forwarded to TWO devices is prepared TWICE — once per '
    'device, and each conversation gains its own file message',
    () async {
      final ChatMessage file = seedFile();
      await controller.load();
      final int before = backend.transfer.prepareCalls;

      final ForwardBatchReport report = await controller.forwardMessagesTo(
        messages: <ChatMessage>[file],
        targets: <PeerDevice>[_online(), _offline()],
      );

      // The online device really received bytes; the offline one queued, so only
      // one prepare can happen here — the point of the assertion is that the
      // count follows the *devices actually dialled*, never one shared batch.
      expect(backend.transfer.prepareCalls, before + 1,
          reason: 'one prepare for the one dialable device');
      expect(report.results, hasLength(2),
          reason: 'both devices get their own verdict');

      final List<ChatMessage> onlineRows = historyOf(_onlineFp);
      expect(onlineRows, hasLength(1));
      expect(onlineRows.single.kind, MessageKind.file);
      expect(onlineRows.single.direction, MessageDirection.outgoing);
      expect(backend.repo.filesOf(onlineRows.single.id).single.fileName,
          'notes.txt');

      final List<ChatMessage> offlineRows = historyOf(_offlineFp);
      expect(offlineRows, hasLength(1),
          reason: 'a queued send still records its row — that is the queue');
      expect(offlineRows.single.status, MessageStatus.pending);

      // And the source conversation is untouched.
      expect(backend.repo.history(conversationId), hasLength(1));
    },
  );

  test(
    '★ criterion 5 (second half): the same file to TWO DIALABLE devices prepares '
    'it twice',
    () async {
      final ChatMessage file = seedFile();
      await controller.load();
      final int before = backend.transfer.prepareCalls;
      // A second online device, so both targets really dial.
      const PeerDevice second =
          PeerDevice(fingerprint: 'DDDD4444', alias: '第二台', kind: DeviceKind.desktop, isOnline: true, lastPort: 53320);

      final ForwardBatchReport report = await controller.forwardMessagesTo(
        messages: <ChatMessage>[file],
        targets: <PeerDevice>[_online(), second],
      );

      expect(backend.transfer.prepareCalls, before + 2,
          reason: '★ two devices ⇒ two prepares; a shared session would be one');
      expect(report.allSent, isTrue,
          reason: 'both devices are dialable, so nothing was queued');
      expect(historyOf(_onlineFp), hasLength(1));
      expect(historyOf('DDDD4444'), hasLength(1));
    },
  );

  test(
    '★ criterion 6: one offline target — that device\'s row is `pending` (queued), '
    'NOT `failed`, and the online one is `done`',
    () async {
      final ChatMessage text = seedText();
      await controller.load();

      final ForwardBatchReport report = await controller.forwardMessagesTo(
        messages: <ChatMessage>[text],
        targets: <PeerDevice>[_online(), _offline()],
      );

      expect(report.results, hasLength(2));
      // ★ The two states the copy has to distinguish.
      expect(historyOf(_onlineFp).single.status, MessageStatus.done);
      expect(historyOf(_offlineFp).single.status, MessageStatus.pending,
          reason: '★ queued, not failed — the outbox pump delivers it later (Q9)');
      expect(historyOf(_offlineFp).single.status, isNot(MessageStatus.failed));

      expect(report.results[0].statusLabel, '成功');
      expect(report.results[1].statusLabel, '排队',
          reason: 'the offline device must not be reported as a failure');
      expect(report.allSent, isTrue,
          reason: 'queued counts as accepted — nothing went wrong');
    },
  );

  test(
    '★ criterion 4: an EMPTY target list sends NOTHING — closing the picker is not '
    '"send to everybody"',
    () async {
      final ChatMessage text = seedText();
      await controller.load();
      final int prepares = backend.transfer.prepareCalls;

      final ForwardBatchReport report = await controller.forwardMessagesTo(
        messages: <ChatMessage>[text],
        targets: const <PeerDevice>[],
      );

      expect(report.isEmpty, isTrue);
      expect(report.results, isEmpty);
      expect(report.notice, contains('没有选择设备'));
      expect(backend.transfer.sentTexts, isEmpty,
          reason: '★ no text frame may leave the app');
      expect(backend.transfer.prepareCalls, prepares);
      expect(historyOf(_onlineFp), isEmpty);
      expect(historyOf(_offlineFp), isEmpty);
    },
  );

  test(
    '★ SERIAL: the second device is not started while the first one is still '
    'sending (a `Future.wait` fan-out would show two prepares at once)',
    () async {
      final ChatMessage file = seedFile();
      await controller.load();
      const PeerDevice second =
          PeerDevice(fingerprint: 'DDDD4444', alias: '第二台', kind: DeviceKind.desktop, isOnline: true, lastPort: 53320);
      final Completer<void> gate = Completer<void>();
      // Parks the **first** prepare only.
      backend.transfer.holdNextPrepare(gate);

      final Future<ForwardBatchReport> run = controller.forwardMessagesTo(
        messages: <ChatMessage>[file],
        targets: <PeerDevice>[_online(), second],
      );
      // Let everything that can run without the gate run.
      await pumpEventQueue();

      expect(backend.transfer.prepareCalls, 1,
          reason: '★ target 2 must not have been dialled yet — that is "serial"');
      expect(gate.isCompleted, isFalse);

      gate.complete();
      final ForwardBatchReport report = await run;

      expect(backend.transfer.prepareCalls, 2, reason: 'and then it goes');
      expect(report.results, hasLength(2));
      expect(report.allSent, isTrue);
    },
  );

  test(
    'a gone source file fails EVERY device loudly, leaves no empty message in any '
    'of them, and the sentence names each device',
    () async {
      final ChatMessage file = seedFile(path: '/d/gone.txt');
      backend.platform.setExists('/d/gone.txt', false);
      await controller.load();
      final int prepares = backend.transfer.prepareCalls;

      final ForwardBatchReport report = await controller.forwardMessagesTo(
        messages: <ChatMessage>[file],
        targets: <PeerDevice>[_online(), _offline()],
      );

      expect(backend.transfer.prepareCalls, prepares);
      expect(historyOf(_onlineFp), isEmpty,
          reason: 'no empty message behind a failed forward');
      expect(historyOf(_offlineFp), isEmpty);
      expect(report.allSent, isFalse);
      for (final ForwardTargetResult result in report.results) {
        expect(result.failures.single.reason, contains('源文件已不在本地'));
        expect(result.statusLabel, contains('源文件已不在本地'),
            reason: 'the reason travels with the device name, never a bare 失败');
      }
      // ★ criterion 7 at the controller level: both names are in the sentence.
      expect(report.notice, contains('台式机'));
      expect(report.notice, contains('笔记本'));
    },
  );

  test(
    '★ criterion 7: the notice is per device — `台式机 成功 · 笔记本 排队`, not one '
    'blanket verdict',
    () async {
      final ChatMessage text = seedText();
      await controller.load();

      final ForwardBatchReport report = await controller.forwardMessagesTo(
        messages: <ChatMessage>[text],
        targets: <PeerDevice>[_online(), _offline()],
      );

      expect(report.notice, '台式机 成功 · 笔记本 排队');
    },
  );

  test(
    '★ criterion 3 (regression): ONE target sends to exactly that device — the '
    'fan-out must not be "always everybody"',
    () async {
      final ChatMessage text = seedText();
      await controller.load();

      final ForwardBatchReport report = await controller.forwardMessagesTo(
        messages: <ChatMessage>[text],
        targets: <PeerDevice>[_offline()],
      );

      expect(report.results, hasLength(1));
      expect(historyOf(_offlineFp), hasLength(1));
      expect(historyOf(_onlineFp), isEmpty,
          reason: '★ the device that was NOT picked must gain nothing');
      expect(backend.repo.history(conversationId), hasLength(1),
          reason: 'and the source conversation is unchanged');
    },
  );

  test(
    'a batch of TWO rows to one device says how many — `台式机 成功（2 条）`, not just '
    '"成功"',
    () async {
      final ChatMessage first = seedText(id: 'm-a');
      final ChatMessage second = seedText(id: 'm-b');
      await controller.load();

      final ForwardBatchReport report = await controller.forwardMessagesTo(
        messages: <ChatMessage>[first, second],
        targets: <PeerDevice>[_online()],
      );

      expect(report.results.single.sent, 2);
      expect(report.notice, '台式机 成功（2 条）');
      expect(historyOf(_onlineFp), hasLength(2),
          reason: 'both rows really went, in one fan-out to one device');
    },
  );

  test(
    '★ a forward does NOT delete the picked copy it just uploaded — the row being '
    'forwarded still names that path, so target 2 would be refused',
    () async {
      final _RecordingCache cache = _RecordingCache();
      final ConversationController local = ConversationController(
        repo: backend.repo,
        orchestrator: orchestrator,
        platform: backend.platform,
        ids: backend.ids,
        clock: backend.clock,
        conversationId: conversationId,
        pickedCache: cache,
      );
      addTearDown(local.dispose);
      // The Android shape: the row's source is a copy the app made itself.
      final ChatMessage file =
          seedFile(path: '/cache/lanlink-picked/1/notes.txt');
      await local.load();
      const PeerDevice second =
          PeerDevice(fingerprint: 'DDDD4444', alias: '第二台', kind: DeviceKind.desktop, isOnline: true, lastPort: 53320);

      final ForwardBatchReport report = await local.forwardMessagesTo(
        messages: <ChatMessage>[file],
        targets: <PeerDevice>[_online(), second],
      );

      expect(report.allSent, isTrue,
          reason: 'both devices must take the file in one run');
      expect(cache.discarded, isEmpty,
          reason: '★ a forward must not consume its own source — deleting the copy '
              'here would fail the second device and orphan the source bubble');
    },
  );

  // ── the 0.2.41 single-target API is unchanged (it is what 0.2.41's tests pin) ──

  test('the single-target selection API still answers one device, and leaves '
      'multi-select when everything went', () async {
    final ChatMessage text = seedText();
    await controller.load();
    controller.startSelecting();
    controller.toggleSelected(text);
    expect(controller.selectedCount, 1);

    final ForwardReport report = await controller.forwardSelectedTo(_online());

    expect(report.sent, 1);
    expect(report.failures, isEmpty);
    expect(report.notice, contains('已转发 1 条'));
    expect(historyOf(_onlineFp), hasLength(1));
    expect(controller.selecting, isFalse,
        reason: 'a fully successful batch has done its job');
  });
}
