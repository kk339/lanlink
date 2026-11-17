/// The send-side half of the temporary-copy cleanup (0.2.23).
///
/// `picked_cache_test.dart` proves the deleter is safe (it only ever touches
/// `<temp>/lanlink-picked/…`). This file proves the **call site agrees with it**:
/// the copies are freed when — and only when — the send actually delivered.
///
/// The distinction is not cosmetic. A 发送 that fails or is queued still needs its
/// local file: the bubble offers 重新发送, which re-reads that exact path. Deleting
/// on any other outcome would turn a retryable bubble into a permanent
/// 源文件已不在.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/picked_cache.dart';
import 'package:lanlink_app/domain/transfer_service.dart';

import 'support/fakes.dart';

/// A [PickedCachePort] that records the calls it was asked to make.
class _RecordingCache implements PickedCachePort {
  final List<List<String>> discarded = <List<String>>[];
  int clears = 0;

  @override
  Future<void> discard(Iterable<String> paths) async =>
      discarded.add(paths.toList());

  @override
  Future<void> clear({Set<String> keep = const <String>{}}) async => clears++;
}

const PeerDevice _peer = PeerDevice(
  fingerprint: 'AA11',
  alias: 'Alice',
  kind: DeviceKind.desktop,
  isOnline: true,
  lastPort: 53317,
  lastIp: '192.168.1.10',
);

/// The shape Android produces: one per-send directory under the app cache.
const String _pickedPath =
    '/data/user/0/io.github.kk339.lanlink/cache/lanlink-picked/8f2c/clip.mp4';

void main() {
  late FakeBackend backend;
  late _RecordingCache cache;
  late ConversationController controller;

  setUp(() {
    backend = FakeBackend();
    cache = _RecordingCache();
    backend.platform.setExists(_pickedPath, true);
    final Conversation conversation = backend.repo.addConversation(
      id: 'c-cache',
      deviceFingerprint: _peer.fingerprint,
      createdAt: fixedEpoch,
    );
    controller = ConversationController(
      repo: backend.repo,
      orchestrator: TransferOrchestrator(
        repo: backend.repo,
        transfer: backend.transfer,
      ),
      platform: backend.platform,
      ids: backend.ids,
      clock: backend.clock,
      conversationId: conversation.id,
      pickedCache: cache,
    );
  });

  tearDown(() {
    controller.dispose();
    backend.dispose();
  });

  test('a delivered send frees that send temp copy', () async {
    final SendOutcome? outcome = await controller.sendPaths(
      peer: _peer,
      paths: <String>[_pickedPath],
    );

    expect(outcome!.delivered, isTrue);
    expect(cache.discarded, hasLength(1));
    expect(cache.discarded.single, <String>[_pickedPath]);
  });

  test('a FAILED send keeps it — 重新发送 still needs the local file', () async {
    backend.transfer.failNextUpload(StateError('link went away'));

    final SendOutcome? outcome = await controller.sendPaths(
      peer: _peer,
      paths: <String>[_pickedPath],
    );

    expect(outcome!.delivered, isFalse);
    expect(cache.discarded, isEmpty,
        reason: 'deleting here would break the retry the bubble offers');
  });

  test('a QUEUED send keeps it — nothing was attempted, nothing may be freed',
      () async {
    // Offline peer: the send is recorded as `pending` and never dialled (Q9).
    const PeerDevice offline = PeerDevice(
      fingerprint: 'AA11',
      alias: 'Alice',
      kind: DeviceKind.desktop,
      isOnline: false,
      lastPort: 53317,
      lastIp: '192.168.1.10',
    );

    final SendOutcome? outcome = await controller.sendPaths(
      peer: offline,
      paths: <String>[_pickedPath],
    );

    expect(outcome!.queued, isTrue);
    expect(outcome.delivered, isFalse);
    expect(cache.discarded, isEmpty);
  });
}
