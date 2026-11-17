/// The launch sweep **and the offline queue** (0.2.52).
///
/// **The defect these pin down.** `cache/lanlink-picked/<uuid>/` holds one full
/// copy of every picked / shared file, and the sweep at boot used to delete the
/// whole tree — safe, the reasoning went, because nothing there is ever the only
/// copy of anything. That has exactly one exception and it is the queue: a
/// `pending` message has **not** been sent yet, so its copy *is* the only bytes
/// this app can still upload, and `pending` is deliberately preserved across a
/// restart (`outbox_pump.dart`'s library doc). The sweep therefore deleted the
/// source of every queued message at the next launch, the resume dialled anyway,
/// and the failure said 「失败」 with no reason attached.
///
/// Two properties must hold **together**, which is why both are here:
///
/// 1. a queued message's copy survives the sweep;
/// 2. everything else still goes — a terminal message's copy and an orphaned
///    directory included. A "fix" that simply stopped sweeping would trade a
///    lost message for a cache that grows forever, which is the defect 0.2.23
///    exists to prevent.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/data/real/picked_cache.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/picked_cache.dart';
import 'package:path/path.dart' as p;

import 'support/fakes.dart';

const String _kConversationId = 'c-launch';
final DateTime _t0 = DateTime.utc(2026, 1, 1, 12);

/// A repository whose queue read fails, i.e. the one case where the sweep must
/// delete **nothing** (see `sweepLaunchCopies`).
class _UnreadableRepo extends FakeSessionRepository {
  _UnreadableRepo()
      : super(clock: FixedClock(_t0), ids: FixedIdFactory('id'));

  @override
  List<ChatMessage> messagesByStatus(Set<MessageStatus> statuses) {
    throw StateError('database is locked');
  }
}

void main() {
  late Directory temporary;
  late String root;
  late List<String> logs;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('lanlink_keep_test_');
    root = p.join(temporary.path, kPickedCacheDirectoryName);
    logs = <String>[];
  });

  tearDown(() async {
    if (await temporary.exists()) {
      await temporary.delete(recursive: true);
    }
  });

  PickedFileCache cleaner() => PickedFileCache(
        temporaryDirectory: () async => temporary,
        onLog: logs.add,
      );

  /// Creates `<root>/<uuid>/<name>` and answers the file's path — the exact
  /// shape the Android host produces (`MainActivity.copyPickedUri`).
  Future<String> seedCopy(String uuid, {String name = 'video.mp4'}) async {
    final Directory directory = Directory(p.join(root, uuid));
    await directory.create(recursive: true);
    final File file = File(p.join(directory.path, name));
    await file.writeAsBytes(<int>[1, 2, 3, 4]);
    return file.path;
  }

  /// One outgoing file message pointing at [localPath], in [status].
  void seedMessage(
    FakeSessionRepository repo, {
    required String messageId,
    required MessageStatus status,
    required String localPath,
  }) {
    repo.addMessage(
      id: messageId,
      conversationId: _kConversationId,
      direction: MessageDirection.outgoing,
      status: status,
      createdAt: _t0,
      files: <FileAttachment>[
        FileAttachment(
          id: 'f-$messageId',
          messageId: messageId,
          fileName: p.basename(localPath),
          size: 4,
          localPath: localPath,
        ),
      ],
    );
  }

  test('1. a queued message\'s source copy SURVIVES the launch sweep', () async {
    final String queued = await seedCopy('uuid-queued');
    final FakeSessionRepository repo = FakeSessionRepository(
      clock: FixedClock(_t0),
      ids: FixedIdFactory('id'),
    );
    seedMessage(
      repo,
      messageId: 'm-queued',
      status: MessageStatus.pending,
      localPath: queued,
    );

    await sweepLaunchCopies(cache: cleaner(), repo: repo, onLog: logs.add);

    expect(await File(queued).exists(), isTrue,
        reason: 'a `pending` message has not been sent yet — its copy is the '
            'only bytes we can still upload, and `pending` is kept across a '
            'restart on purpose, so the sweep must keep the file too');
    expect(logs, contains(contains('启动清理保留')),
        reason: 'the retention has to be visible in the on-device log: '
            '"why did my cache not shrink" is answerable only from there');
  });

  test('2. the sweep still deletes a TERMINAL message\'s copy', () async {
    final String done = await seedCopy('uuid-done');
    final FakeSessionRepository repo = FakeSessionRepository(
      clock: FixedClock(_t0),
      ids: FixedIdFactory('id'),
    );
    seedMessage(
      repo,
      messageId: 'm-done',
      status: MessageStatus.done,
      localPath: done,
    );

    await sweepLaunchCopies(cache: cleaner(), repo: repo, onLog: logs.add);

    expect(await File(done).exists(), isFalse,
        reason: 'a delivered copy is the leak 0.2.23 removed; keeping it would '
            'trade one lost message for an ever-growing cache');
  });

  test('3. the sweep still deletes an ORPHAN directory nothing references',
      () async {
    final String orphan = await seedCopy('uuid-orphan', name: 'left.behind');
    final FakeSessionRepository repo = FakeSessionRepository(
      clock: FixedClock(_t0),
      ids: FixedIdFactory('id'),
    );

    await sweepLaunchCopies(cache: cleaner(), repo: repo, onLog: logs.add);

    expect(await File(orphan).exists(), isFalse,
        reason: 'a directory no message names is a crash / force-stop leftover '
            '— exactly what the boot sweep is for');
  });

  test('4. one sweep, three kinds of directory: only the queued one lives',
      () async {
    final String queued = await seedCopy('uuid-keep');
    final String delivered = await seedCopy('uuid-delivered', name: 'a.jpg');
    final String orphan = await seedCopy('uuid-orphan', name: 'b.jpg');
    // A second file in the **same** per-send directory as the queued one: the
    // unit of deletion is the directory, so it is retained with its sibling.
    final String sibling = p.join(p.dirname(queued), 'second.mp4');
    await File(sibling).writeAsBytes(<int>[5, 6]);

    final FakeSessionRepository repo = FakeSessionRepository(
      clock: FixedClock(_t0),
      ids: FixedIdFactory('id'),
    );
    seedMessage(
      repo,
      messageId: 'm-keep',
      status: MessageStatus.pending,
      localPath: queued,
    );
    seedMessage(
      repo,
      messageId: 'm-delivered',
      status: MessageStatus.done,
      localPath: delivered,
    );

    await sweepLaunchCopies(cache: cleaner(), repo: repo, onLog: logs.add);

    expect(await File(queued).exists(), isTrue);
    expect(await File(sibling).exists(), isTrue,
        reason: 'the retention set is matched per directory (`<root>/<uuid>/`), '
            'never file by file — a half-deleted per-send directory would be '
            'worse than either answer');
    expect(await File(delivered).exists(), isFalse);
    expect(await File(orphan).exists(), isFalse);
    expect(await Directory(root).exists(), isTrue,
        reason: 'the retained copy still needs its parent');
  });

  test('5. an unreadable queue deletes NOTHING (space is cheaper than a message)',
      () async {
    final String first = await seedCopy('uuid-1');
    final String second = await seedCopy('uuid-2', name: 'b.jpg');

    await sweepLaunchCopies(
      cache: cleaner(),
      repo: _UnreadableRepo(),
      onLog: logs.add,
    );

    expect(await File(first).exists(), isTrue,
        reason: 'a store that cannot answer must not be read as an empty '
            'retention set — that would delete exactly what the unreadable '
            'queue was waiting on');
    expect(await File(second).exists(), isTrue);
    expect(logs, contains(contains('跳过启动清理')));
  });

  test('6. `resumableSourcePaths` is "every non-terminal status", not a list',
      () async {
    final FakeSessionRepository repo = FakeSessionRepository(
      clock: FixedClock(_t0),
      ids: FixedIdFactory('id'),
    );
    for (final MessageStatus status in MessageStatus.values) {
      seedMessage(
        repo,
        messageId: 'm-${status.wire}',
        status: status,
        localPath: '/src/${status.wire}.bin',
      );
    }

    final Set<String> paths = resumableSourcePaths(repo);

    for (final MessageStatus status in MessageStatus.values) {
      final String path = '/src/${status.wire}.bin';
      if (status.isTerminal) {
        expect(paths, isNot(contains(path)),
            reason: '${status.wire} is terminal — nothing will read the file '
                'again');
      } else {
        expect(paths, contains(path),
            reason: '${status.wire} still has an outcome ahead of it '
                '(a resume, or a 重新发送 that re-reads this very path)');
      }
    }
  });
}
