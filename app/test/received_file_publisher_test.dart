/// Unit tests for the "publish a received file" policy (0.2.19).
///
/// **The bug these pin down.** A received file was recorded with the path the
/// core receiver wrote to — the app's PRIVATE directory
/// (`/data/user/0/<pkg>/files/lanlink/received/…`). 复制文件路径 therefore handed
/// the user a path that no file manager, gallery or USB mount can open. The fix
/// publishes the verified bytes into the public `Download/lanlink` collection
/// and records **that** path.
///
/// Three outcomes are covered, because only the first is a success and the other
/// two must not lose the file:
/// * published → public path recorded, private copy deleted;
/// * failed → private path kept, failure logged (the user can still open it from
///   inside the app, and the log says why it is not in 下载);
/// * nothing to do (`null`, desktop/Web) → identical to 0.2.18, private path.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/public_storage.dart';
import 'package:lanlink_app/domain/received_file_publisher.dart';

import 'support/fakes.dart';

/// The path the Android receiver really writes to — the one the user quoted.
const String _privatePath =
    '/data/user/0/io.github.kk339.lanlink/files/lanlink/received/lv_0_(3).mp4';

/// The public path the platform answers after publishing.
const String _publicPath =
    '/storage/emulated/0/Download/lanlink/lv_0_(3).mp4';

const String _fileName = 'lv_0_(3).mp4';

IncomingFile _incomingFile({String savedPath = _privatePath}) => IncomingFile(
      fileId: 'file-1',
      fileName: _fileName,
      size: 5242880,
      sha256: 'AABB',
      savedPath: savedPath,
      mime: 'video/mp4',
    );

ReceivedTransfer _transfer({String savedPath = _privatePath}) => ReceivedTransfer(
      file: _incomingFile(savedPath: savedPath),
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
  late FakePublicStorage storage;
  late List<String> logs;
  late List<String> deleted;

  setUp(() {
    storage = FakePublicStorage();
    logs = <String>[];
    deleted = <String>[];
  });

  ReceivedFilePublisher publisherWith({
    required Future<void> Function(String path) deleteLocalFile,
  }) =>
      ReceivedFilePublisher(
        storage: storage,
        deleteLocalFile: deleteLocalFile,
        onLog: logs.add,
      );

  test('a successful publish records the PUBLIC path and drops the private copy',
      () async {
    storage.setPublishedPath(_publicPath);
    final ReceivedFilePublisher publisher =
        publisherWith(deleteLocalFile: (String path) async => deleted.add(path));

    final PublishedFile result = await publisher.publish(
      srcPath: _privatePath,
      displayName: _fileName,
      mime: 'video/mp4',
    );

    expect(result.error, isNull);
    expect(result.failed, isFalse);
    expect(result.path, _publicPath);
    // The private copy is removed by the DART side, after the export.
    expect(deleted, <String>[_privatePath]);
    // Exactly what was asked of the platform: the file's own name, untouched.
    expect(storage.calls.single.srcPath, _privatePath);
    expect(storage.calls.single.displayName, _fileName);
    expect(storage.calls.single.mime, 'video/mp4');
    expect(logs.single, contains('PUBLISH 已导出'));
    expect(logs.single, contains(_publicPath));
  });

  test('publishTransfer replaces only savedPath (id, size, hash, sender intact)',
      () async {
    storage.setPublishedPath(_publicPath);
    final ReceivedFilePublisher publisher =
        publisherWith(deleteLocalFile: (String path) async => deleted.add(path));

    final ReceivedTransfer recorded =
        await publisher.publishTransfer(_transfer());

    expect(recorded.file.savedPath, _publicPath);
    expect(recorded.file.fileName, _fileName);
    expect(recorded.file.fileId, 'file-1');
    expect(recorded.file.size, 5242880);
    expect(recorded.file.sha256, 'AABB');
    expect(recorded.file.mime, 'video/mp4');
    expect(recorded.sender.fingerprint, 'AAAA1111');
  });

  test('a failed publish keeps the private path, logs it and deletes nothing',
      () async {
    storage.failNextPublish(const PublicStorageException('空间不足'));
    final ReceivedFilePublisher publisher =
        publisherWith(deleteLocalFile: (String path) async => deleted.add(path));

    final PublishedFile result = await publisher.publish(
      srcPath: _privatePath,
      displayName: _fileName,
    );

    expect(result.failed, isTrue);
    expect(result.path, _privatePath, reason: 'the file must stay reachable '
        'from inside the app even when the export failed');
    expect(result.error, '空间不足');
    expect(deleted, isEmpty, reason: 'never delete the only copy');
    // The exact sentence the user will find in lanlink.log.
    expect(
      logs.single,
      'PUBLISH 导出失败：$_fileName（空间不足），文件仍在应用内部',
    );
  });

  test('a publish that throws an ordinary error is still reported, never rethrown',
      () async {
    storage.failNextPublish(StateError('channel closed'));
    final ReceivedFilePublisher publisher =
        publisherWith(deleteLocalFile: (String path) async => deleted.add(path));

    final ReceivedTransfer recorded = await publisher.publishTransfer(_transfer());

    expect(recorded.file.savedPath, _privatePath);
    expect(logs.single, contains('PUBLISH 导出失败：$_fileName'));
    expect(deleted, isEmpty);
  });

  test('a null answer (desktop / Web) changes nothing at all', () async {
    storage.setPublishedPath(null);
    final ReceivedFilePublisher publisher =
        publisherWith(deleteLocalFile: (String path) async => deleted.add(path));

    final ReceivedTransfer recorded = await publisher.publishTransfer(_transfer());

    // Byte-for-byte the 0.2.18 behaviour: same path, no delete, no log noise.
    expect(recorded.file.savedPath, _privatePath);
    expect(deleted, isEmpty);
    expect(logs, isEmpty);
    expect(storage.calls, hasLength(1), reason: 'the port is still asked — it '
        'is the port that decides there is nothing to do');
  });

  test('a failed cleanup does not undo a successful publish', () async {
    storage.setPublishedPath(_publicPath);
    final ReceivedFilePublisher publisher = publisherWith(
      deleteLocalFile: (String path) async =>
          throw const FileSystemException('read-only file system'),
    );

    final PublishedFile result =
        await publisher.publish(srcPath: _privatePath, displayName: _fileName);

    expect(result.failed, isFalse);
    expect(result.path, _publicPath,
        reason: 'the public copy is the record of truth');
    expect(logs, hasLength(2));
    expect(logs.first, contains('内部临时文件删除失败'));
    expect(logs.last, contains('PUBLISH 已导出'));
  });

  test('the private copy is really gone after a successful publish (real file)',
      () async {
    final Directory directory =
        await Directory.systemTemp.createTemp('lanlink_publish_');
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final File source = File('${directory.path}/$_fileName');
    // 128 KiB of real bytes, written in one go — the publish is a copy, so the
    // content must survive it; only the deletion is under test here.
    await source.writeAsBytes(
      List<int>.generate(128 * 1024, (int index) => index % 251),
    );

    storage.setPublishedPath(_publicPath);
    final ReceivedFilePublisher publisher = ReceivedFilePublisher(
      storage: storage,
      deleteLocalFile: (String path) async {
        final File file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      },
    );

    final PublishedFile result =
        await publisher.publish(srcPath: source.path, displayName: _fileName);

    expect(result.failed, isFalse);
    expect(await source.exists(), isFalse,
        reason: 'the private copy must be removed, not merely recorded twice');
    expect(await directory.exists(), isTrue,
        reason: 'only the file is removed — never the directory around it');
  });

  // ── 0.2.23 ────────────────────────────────────────────────────────────────

  test('a failed publish puts the reason ON the transfer, not only in the log',
      () async {
    storage.failNextPublish(const PublicStorageException('空间不足'));
    final ReceivedFilePublisher publisher =
        publisherWith(deleteLocalFile: (String path) async => deleted.add(path));

    final ReceivedTransfer recorded =
        await publisher.publishTransfer(_transfer());

    // The receive still succeeded: same file, same private path, nothing deleted.
    expect(recorded.file.savedPath, _privatePath);
    expect(deleted, isEmpty);
    // …but the failure is now **carried**, which is what the UI turns into
    // 「已收到，但没能导出到「下载」」. Before 0.2.23 this was `null` and the
    // bubble claimed 已完成 while the file was nowhere the user could look.
    expect(recorded.publishError, '空间不足');
    expect(logs.single, contains('PUBLISH 导出失败'));
  });

  test('a successful publish leaves publishError null (the note must not show)',
      () async {
    storage.setPublishedPath(_publicPath);
    final ReceivedFilePublisher publisher =
        publisherWith(deleteLocalFile: (String path) async => deleted.add(path));

    final ReceivedTransfer recorded =
        await publisher.publishTransfer(_transfer());

    expect(recorded.file.savedPath, _publicPath);
    // The reverse direction of the test above: if this were `'空间不足'`-like,
    // every normal receive would carry a warning it does not deserve.
    expect(recorded.publishError, isNull);
  });

  test('a duplicate name: the recorded fileName follows the published basename',
      () async {
    // Android renames a duplicate on publish; the platform's answer is the only
    // authority on the final name. 0.2.22 recorded the *path* but kept the
    // original name, so the second receive of the same file left the disk
    // holding `lv_0_(3) (1).mp4` while the bubble said `lv_0_(3).mp4`.
    const String duplicatePath =
        '/storage/emulated/0/Download/lanlink/lv_0_(3) (1).mp4';
    storage.setPublishedPath(duplicatePath);
    final ReceivedFilePublisher publisher =
        publisherWith(deleteLocalFile: (String path) async => deleted.add(path));

    final ReceivedTransfer recorded =
        await publisher.publishTransfer(_transfer());

    expect(recorded.file.savedPath, duplicatePath);
    expect(recorded.file.fileName, 'lv_0_(3) (1).mp4',
        reason: 'the bubble must name the file that is actually on disk');
    // Everything else about the identity is untouched, so de-duplication and the
    // message id are unaffected by where the file landed.
    expect(recorded.file.fileId, 'file-1');
    expect(recorded.file.sha256, 'AABB');
  });

  // ---------------------------------------------------------------------
  // T04 (c)/(d)/(g) — a folder arrival keeps its shape (0.2.38).
  //
  // ★ (g) guards a trap **only Android can expose**. `publishTransfer` returns
  // early when `published.path == file.savedPath` (desktop / "nothing to
  // publish"), so the field-by-field rebuild below that branch never runs
  // locally. A field forgotten there is invisible to every desktop test and
  // shows up as "the folder arrived flat" on a phone. These cases force the
  // rebuild by answering a DIFFERENT path.
  // ---------------------------------------------------------------------
  group('a folder arrival keeps its shape', () {
    ReceivedTransfer folderTransfer({
      String? relativePath = 'data/a.bin',
      String folderName = '素材',
      int folderFiles = 3,
      String sessionId = 'sess-1',
    }) =>
        ReceivedTransfer(
          file: IncomingFile(
            fileId: 'file-1',
            fileName: 'a.bin',
            size: 10,
            sha256: 'AABB',
            savedPath: _privatePath,
            mime: 'application/octet-stream',
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
          sessionId: sessionId,
          folderName: folderName,
          folderFiles: folderFiles,
        );

    ReceivedFilePublisher quietPublisher() =>
        publisherWith(deleteLocalFile: (String path) async => deleted.add(path));

    test('(c) the published subdirectory nests the folder and the relative dir',
        () async {
      // `null` = nothing to publish (desktop). The request that *would* have been
      // made is what this asserts — the fake records every call.
      storage.setPublishedPath(null);
      await quietPublisher().publishTransfer(folderTransfer());

      expect(storage.calls, hasLength(1));
      expect(storage.calls.single.subdirectory, 'lanlink/素材/data');
    });

    test('(c) a nested relative path contributes every directory level',
        () async {
      storage.setPublishedPath(null);
      await quietPublisher().publishTransfer(
        folderTransfer(relativePath: 'data/deep/x.bin'),
      );
      expect(storage.calls.single.subdirectory, 'lanlink/素材/data/deep');
    });

    test('(d) a plain arrival publishes into the configured folder only',
        () async {
      // Byte-for-byte the pre-0.2.38 behaviour: no folder, no extra segment.
      storage.setPublishedPath(null);
      await quietPublisher().publishTransfer(_transfer());
      expect(storage.calls.single.subdirectory, 'lanlink');
    });

    test('(d) a folder arrival whose file sits at the folder root adds no segment',
        () async {
      storage.setPublishedPath(null);
      await quietPublisher().publishTransfer(
        folderTransfer(relativePath: null),
      );
      expect(storage.calls.single.subdirectory, 'lanlink/素材');
    });

    test('★ (g) a SUCCESSFUL publish keeps relativePath and the folder descriptor',
        () async {
      // A different path is what forces the rebuild branch instead of the early
      // return — without this the assertions below would be about a copy that
      // never happened.
      storage.setPublishedPath(_publicPath);
      final ReceivedTransfer recorded =
          await quietPublisher().publishTransfer(folderTransfer());

      // Proof of which branch ran:
      expect(recorded.file.savedPath, _publicPath);
      expect(recorded.file.savedPath, isNot(_privatePath));

      // The four fields a hand-written rebuild drops silently:
      expect(recorded.file.relativePath, 'data/a.bin',
          reason: '★ otherwise Android shows a flat folder and no local test notices');
      expect(recorded.folderName, '素材');
      expect(recorded.folderFiles, 3);
      expect(recorded.sessionId, 'sess-1');
      expect(recorded.isFolder, isTrue);

      // …and nothing else was lost on the way through.
      expect(recorded.file.fileId, 'file-1');
      // The name follows the **published** basename by design (0.2.23): Android
      // renames a duplicate (`a.bin` → `a (1).bin`) and the platform's answer is
      // the only authority on the final name, so the bubble must show the name
      // that actually exists on disk. Here the fake answered `lv_0_(3).mp4`.
      expect(recorded.file.fileName, 'lv_0_(3).mp4');
      expect(recorded.file.size, 10);
      expect(recorded.file.sha256, 'AABB');
      expect(recorded.sender.fingerprint, 'AAAA1111');
      expect(recorded.publishError, isNull);
    });
  });
}
