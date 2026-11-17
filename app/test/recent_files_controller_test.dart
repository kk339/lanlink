/// Unit tests for [RecentFilesController] (spec §4.3 / §5.4, M4 T03).
///
/// Driven entirely by [FakeBackend]. Asserts the aggregation (including
/// archived conversations, E5), the category tab (mime first, extension
/// fallback, E8), the file-name search and the local-day grouping.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/recent_files_controller.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/selectors.dart';

import 'support/fakes.dart';

DateTime _day(int day, [int hour = 0]) => DateTime.utc(2026, 1, day, hour);

FileAttachment _file(
  String id,
  String messageId,
  String name,
  String path, {
  String? mime,
}) =>
    FileAttachment(
      id: id,
      messageId: messageId,
      fileName: name,
      size: 10,
      mime: mime,
      sha256: '00',
      localPath: path,
    );

/// One active + one archived conversation, five files spread across three days.
FakeBackend _fixture() {
  final FakeBackend backend = FakeBackend();
  final Conversation active = backend.repo.addConversation(
    id: 'c-active',
    deviceFingerprint: 'AAAA1111',
    createdAt: _day(1),
  );
  final Conversation archived = backend.repo.addConversation(
    id: 'c-arch',
    deviceFingerprint: 'BBBB2222',
    createdAt: _day(1),
    isArchived: true,
  );

  backend.repo.addMessage(
    id: 'm1',
    conversationId: active.id,
    direction: MessageDirection.outgoing,
    status: MessageStatus.done,
    createdAt: _day(1, 12),
    files: <FileAttachment>[_file('f1', 'm1', 'photo.png', '/src/photo.png')],
  );
  backend.repo.addMessage(
    id: 'm2',
    conversationId: active.id,
    direction: MessageDirection.incoming,
    status: MessageStatus.done,
    createdAt: _day(2, 12),
    files: <FileAttachment>[
      _file('f2', 'm2', 'clip.bin', '/src/clip.bin', mime: 'video/mp4'),
    ],
  );
  backend.repo.addMessage(
    id: 'm3',
    conversationId: active.id,
    direction: MessageDirection.outgoing,
    status: MessageStatus.done,
    createdAt: _day(2, 13),
    files: <FileAttachment>[_file('f3', 'm3', 'notes.txt', '/src/notes.txt')],
  );
  backend.repo.addMessage(
    id: 'm5',
    conversationId: active.id,
    direction: MessageDirection.outgoing,
    status: MessageStatus.done,
    createdAt: _day(2, 14),
    files: <FileAttachment>[_file('f5', 'm5', 'photo.JPG', '/src/photo.JPG')],
  );
  backend.repo.addMessage(
    id: 'm4',
    conversationId: archived.id,
    direction: MessageDirection.incoming,
    status: MessageStatus.done,
    createdAt: _day(3, 12),
    files: <FileAttachment>[_file('f4', 'm4', 'hidden.pdf', '/src/hidden.pdf')],
  );
  return backend;
}

void main() {
  late FakeBackend backend;
  late RecentFilesController controller;

  setUp(() {
    backend = _fixture();
    controller = RecentFilesController(
      repo: backend.repo,
      platform: backend.platform,
    );
  });

  tearDown(() {
    controller.dispose();
    backend.dispose();
  });

  test(
    'all is Loading until load(); it aggregates archived conversations too '
    '(E5), newest first',
    () async {
      expect(controller.all.isLoading, isTrue);
      await controller.load();
      final List<RecentFileItem> items = controller.all.valueOrNull!;
      expect(
        items.map((RecentFileItem i) => i.file.id),
        const <String>['f4', 'f5', 'f3', 'f2', 'f1'],
      );
    },
  );

  test('the category tab classifies by mime first, extension fallback (E8)',
      () async {
    await controller.load();

    controller.setTab(FileKind.image);
    expect(
      controller.visible.map((RecentFileItem i) => i.file.id),
      const <String>['f5', 'f1'],
    );

    controller.setTab(FileKind.video);
    expect(
      controller.visible.map((RecentFileItem i) => i.file.id),
      const <String>['f2'],
    );

    controller.setTab(FileKind.any);
    expect(controller.visible.length, 5);
  });

  test('setQuery filters file names case-insensitively', () async {
    await controller.load();

    controller.setQuery('photo');
    expect(
      controller.visible.map((RecentFileItem i) => i.file.id).toSet(),
      const <String>{'f1', 'f5'},
    );

    controller.setQuery('CLIP');
    expect(
      controller.visible.map((RecentFileItem i) => i.file.id),
      const <String>['f2'],
    );

    controller.setQuery('');
    expect(controller.visible.length, 5);
  });

  test('grouped() buckets by local day, newest group first', () async {
    await controller.load();
    final Map<String, List<RecentFileItem>> groups = controller.grouped;

    expect(
      groups.values.expand((List<RecentFileItem> g) => g).length,
      controller.visible.length,
    );
    final List<String> keys = groups.keys.toList();
    expect(keys,
        List<String>.of(keys)..sort((String a, String b) => b.compareTo(a)));
    for (final MapEntry<String, List<RecentFileItem>> entry in groups.entries) {
      for (final RecentFileItem item in entry.value) {
        expect(localDateKey(item.messageCreatedAt), entry.key);
      }
    }
  });

  test('sourceMissing comes from the platform existence probe (§4.3 / E7)',
      () async {
    backend.platform.setExists('/src/photo.png', false);
    await controller.load();
    final Map<String, RecentFileItem> byId = <String, RecentFileItem>{
      for (final RecentFileItem item in controller.all.valueOrNull!)
        item.file.id: item,
    };
    expect(byId['f1']!.sourceMissing, isTrue);
    expect(byId['f2']!.sourceMissing, isFalse);
  });

  test('setQuery / setTab notify listeners, and a same-value set does not',
      () async {
    var notifications = 0;
    controller.addListener(() {
      notifications++;
    });

    controller.setQuery('x');
    expect(notifications, 1);
    controller.setQuery('x');
    expect(notifications, 1);

    controller.setTab(FileKind.image);
    expect(notifications, 2);
    controller.setTab(FileKind.image);
    expect(notifications, 2);
  });
}
