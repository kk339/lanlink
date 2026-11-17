/// End-to-end recording test for received-file paths (0.2.19).
///
/// **The seam under test** is exactly the one the fix sits on:
/// `ReceivedFilePublisher.publishTransfer` (the real policy) → the event the
/// transfer stream carries → `TransferOrchestrator` → `recordIncoming`. The
/// repository is the fake, so what this asserts is precisely what the database
/// will store — and therefore what the UI's 复制文件路径 hands the user.
///
/// The regression it guards: before 0.2.19 the recorded path was the app's
/// PRIVATE one (`/data/user/0/<pkg>/files/lanlink/received/…`), which is real
/// but unopenable from any file manager, gallery or USB mount on Android.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/public_storage.dart';
import 'package:lanlink_app/domain/received_file_publisher.dart';

import 'support/fakes.dart';

const String _privatePath =
    '/data/user/0/io.github.kk339.lanlink/files/lanlink/received/lv_0_(3).mp4';
const String _publicPath =
    '/storage/emulated/0/Download/lanlink/lv_0_(3).mp4';

ReceivedTransfer _transfer() => ReceivedTransfer(
      file: const IncomingFile(
        fileId: 'file-1',
        fileName: 'lv_0_(3).mp4',
        size: 5242880,
        sha256: 'AABB',
        savedPath: _privatePath,
      ),
      sender: DiscoveredPeer(
        fingerprint: 'AAAA1111',
        alias: 'Alice Phone',
        kind: DeviceKind.mobile,
        address: '192.168.1.7',
        port: 53317,
        isOnline: true,
        lastSeen: fixedEpoch,
      ),
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

  /// The single recorded file's path, after [event] has been pumped through the
  /// orchestrator's receive subscription.
  Future<String> recordedPathFor(ReceivedTransfer event) async {
    backend.transfer.emitReceived(event);
    await pumpEventQueue();
    final Conversation conversation = backend.repo.conversations().single;
    final ChatMessage message = backend.repo.history(conversation.id).single;
    return backend.repo.filesOf(message.id).single.localPath!;
  }

  test('a published file is recorded with the public Download path', () async {
    final FakePublicStorage storage =
        FakePublicStorage(publishedPath: _publicPath);
    final List<String> deleted = <String>[];
    final ReceivedFilePublisher publisher = ReceivedFilePublisher(
      storage: storage,
      deleteLocalFile: (String path) async => deleted.add(path),
    );

    final String recorded = await recordedPathFor(
      await publisher.publishTransfer(_transfer()),
    );

    expect(recorded, _publicPath);
    expect(deleted, <String>[_privatePath]);
  });

  test('a failed publish is recorded with the private path, and says why',
      () async {
    final FakePublicStorage storage = FakePublicStorage()
      ..failNextPublish(const PublicStorageException('空间不足'));
    final List<String> logs = <String>[];
    final List<String> deleted = <String>[];
    final ReceivedFilePublisher publisher = ReceivedFilePublisher(
      storage: storage,
      deleteLocalFile: (String path) async => deleted.add(path),
      onLog: logs.add,
    );

    final String recorded = await recordedPathFor(
      await publisher.publishTransfer(_transfer()),
    );

    // The file is still in the app (the bubble opens it), the history row is
    // still created, and the log explains why 下载 does not contain it.
    expect(recorded, _privatePath);
    expect(deleted, isEmpty);
    expect(logs.single, contains('PUBLISH 导出失败：lv_0_(3).mp4'));
    expect(logs.single, contains('文件仍在应用内部'));
  });

  test('a platform with nothing to publish records the 0.2.18 path unchanged',
      () async {
    // `FakePublicStorage()` answers `null`, which is what the desktop port does.
    final List<String> deleted = <String>[];
    final List<String> logs = <String>[];
    final ReceivedFilePublisher publisher = ReceivedFilePublisher(
      storage: FakePublicStorage(),
      deleteLocalFile: (String path) async => deleted.add(path),
      onLog: logs.add,
    );

    final String recorded = await recordedPathFor(
      await publisher.publishTransfer(_transfer()),
    );

    expect(recorded, _privatePath);
    expect(deleted, isEmpty);
    expect(logs, isEmpty);
  });

  /// 0.2.23: the failure reason must reach the **stored** record, because that is
  /// what the bubble reads back (`transferOf(fileId).error`) — a reason that
  /// lives only in the log is a reason the user never sees.
  Future<TransferProgress> recordedProgressFor(ReceivedTransfer event) async {
    backend.transfer.emitReceived(event);
    await pumpEventQueue();
    final Conversation conversation = backend.repo.conversations().single;
    final ChatMessage message = backend.repo.history(conversation.id).single;
    final FileAttachment file = backend.repo.filesOf(message.id).single;
    // The message itself is still `done`: the file *did* arrive.
    expect(message.status, MessageStatus.done);
    return backend.repo.transferOf(file.id)!;
  }

  test('a failed publish records why, so the bubble can say it', () async {
    final ReceivedFilePublisher publisher = ReceivedFilePublisher(
      storage: FakePublicStorage()
        ..failNextPublish(const PublicStorageException('空间不足')),
      deleteLocalFile: (String path) async {},
    );

    final TransferProgress progress =
        await recordedProgressFor(await publisher.publishTransfer(_transfer()));

    expect(progress.error, '空间不足');
    expect(progress.bytesDone, progress.bytesTotal,
        reason: 'the bytes are all here — this is a note, not a failed transfer');
  });

  test('a successful publish records no publish error', () async {
    final ReceivedFilePublisher publisher = ReceivedFilePublisher(
      storage: FakePublicStorage(publishedPath: _publicPath),
      deleteLocalFile: (String path) async {},
    );

    final TransferProgress progress =
        await recordedProgressFor(await publisher.publishTransfer(_transfer()));

    expect(progress.error, isNull,
        reason: 'a normal receive must not carry a warning it does not deserve');
  });

  // ---------------------------------------------------------------------
  // T04 (e) + the composition the two features only reveal together.
  //
  // A folder where one file could not be exported is the interesting shape: the
  // message must stay **one** `done` message with a `publishError` note, not
  // three messages and not a failure. A failed export is not a failed receive —
  // the bytes are on disk either way.
  // ---------------------------------------------------------------------
  test('(e) a failed publish on a folder arrival: done, one message, reason kept',
      () async {
    final FakePublicStorage storage = FakePublicStorage()
      ..failNextPublish(const PublicStorageException('空间不足'));
    final ReceivedFilePublisher publisher = ReceivedFilePublisher(
      storage: storage,
      deleteLocalFile: (String path) async {},
      onLog: (String message) {},
    );

    ReceivedTransfer arrival(String fileId, String relativePath) =>
        ReceivedTransfer(
          file: IncomingFile(
            fileId: fileId,
            fileName: relativePath.split('/').last,
            size: 5,
            sha256: '00',
            savedPath: '/private/素材/$relativePath',
            relativePath: relativePath,
          ),
          sender: DiscoveredPeer(
            fingerprint: 'AAAA1111',
            alias: 'Alice Phone',
            kind: DeviceKind.mobile,
            address: '192.168.1.7',
            port: 53317,
            isOnline: true,
            lastSeen: fixedEpoch,
          ),
          sessionId: 'sess-pub',
          folderName: '素材',
          folderFiles: 2,
        );

    // The first file's export fails; the second's would succeed (the fake's
    // failure is consumed once, so the second really does publish).
    backend.transfer.emitReceived(
      await publisher.publishTransfer(arrival('e1', 'data/a.bin')),
    );
    backend.transfer.emitReceived(
      await publisher.publishTransfer(arrival('e2', 'b.bin')),
    );
    await pumpEventQueue();

    final Conversation conversation = backend.repo.conversations().single;
    final List<ChatMessage> messages = backend.repo.history(conversation.id);

    // ★ Still ONE message, still `done` — a failed export never becomes a
    // failed receive.
    expect(messages, hasLength(1));
    expect(messages.single.status, MessageStatus.done);

    // Both attachments are there; only one of them carries the reason.
    final List<FileAttachment> files = backend.repo.filesOf(messages.single.id);
    expect(files, hasLength(2));
    expect(
      backend.repo.transferOf('e1')!.error,
      '空间不足',
      reason: 'the reason rides on the transfer row, so it survives a restart',
    );
    expect(backend.repo.transferOf('e2')!.error, isNull);

    // And the file that failed kept its private path — it is still openable from
    // inside the app even though it never reached 下载.
    expect(
      files.firstWhere((FileAttachment f) => f.id == 'e1').localPath,
      '/private/素材/data/a.bin',
    );
  });
}
