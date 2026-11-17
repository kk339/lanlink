/// Pure unit tests for the recent-files selectors (spec §4.3):
/// [buildRecentFiles], [groupByLocalDay], [filterByQuery], [matchesKind],
/// [categorizeFile] and [fileExtension].
///
/// No Flutter widgets, no repository, no disk: these are pure functions, so the
/// tests only build domain models and assert the derivation.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/selectors.dart';

Conversation _conversation(String id,
        {String? fingerprint, bool archived = false}) =>
    Conversation(
      id: id,
      deviceFingerprint: fingerprint,
      createdAt: DateTime(2026, 1, 1),
      isArchived: archived,
    );

ChatMessage _message(
  String id,
  String conversationId, {
  required DateTime at,
  MessageDirection direction = MessageDirection.incoming,
}) =>
    ChatMessage(
      id: id,
      conversationId: conversationId,
      direction: direction,
      kind: MessageKind.file,
      createdAt: at,
      updatedAt: at,
      status: MessageStatus.done,
    );

FileAttachment _attachment(
  String id,
  String messageId, {
  required String name,
  String? mime,
  String? path,
  int size = 10,
}) =>
    FileAttachment(
      id: id,
      messageId: messageId,
      fileName: name,
      size: size,
      mime: mime,
      localPath: path,
    );

RecentFileItem _item(
  String name, {
  String? mime,
  String? path,
  DateTime? at,
  MessageDirection direction = MessageDirection.incoming,
  bool missing = false,
  String id = 'f',
}) =>
    RecentFileItem(
      file: _attachment(id, 'm', name: name, mime: mime, path: path),
      messageId: 'm',
      messageCreatedAt: at ?? DateTime(2026, 1, 1),
      conversationId: 'c',
      deviceFingerprint: 'FP',
      direction: direction,
      sourceMissing: missing,
    );

void main() {
  group('buildRecentFiles', () {
    test('maps fields from the joined message and conversation', () {
      final List<RecentFileItem> items = buildRecentFiles(
        conversations: <Conversation>[_conversation('c1', fingerprint: 'AB12')],
        messages: <ChatMessage>[
          _message('m1', 'c1',
              at: DateTime(2026, 1, 2, 9),
              direction: MessageDirection.outgoing),
        ],
        files: <FileAttachment>[
          _attachment('f1', 'm1', name: 'photo.png', mime: 'image/png'),
        ],
        isOnDisk: (String _) => true,
      );

      expect(items, hasLength(1));
      final RecentFileItem item = items.single;
      expect(item.file.fileName, 'photo.png');
      expect(item.messageId, 'm1');
      expect(item.messageCreatedAt, DateTime(2026, 1, 2, 9));
      expect(item.direction, MessageDirection.outgoing);
      expect(item.conversationId, 'c1');
      expect(item.deviceFingerprint, 'AB12');
      expect(item.sourceMissing, isFalse);
    });

    test('drops an attachment whose message is absent', () {
      final List<RecentFileItem> items = buildRecentFiles(
        conversations: <Conversation>[_conversation('c1', fingerprint: 'AB12')],
        messages: const <ChatMessage>[],
        files: <FileAttachment>[
          _attachment('f1', 'missing-message', name: 'orphan.bin'),
        ],
        isOnDisk: (String _) => true,
      );

      expect(items, isEmpty);
    });

    test('keeps a message whose conversation is absent, with null fingerprint',
        () {
      final List<RecentFileItem> items = buildRecentFiles(
        conversations: const <Conversation>[],
        messages: <ChatMessage>[
          _message('m1', 'ghost-conv', at: DateTime(2026, 1, 1))
        ],
        files: <FileAttachment>[_attachment('f1', 'm1', name: 'a.txt')],
        isOnDisk: (String _) => true,
      );

      expect(items, hasLength(1));
      expect(items.single.conversationId, 'ghost-conv');
      expect(items.single.deviceFingerprint, isNull);
    });

    test('sourceMissing only when a known path is gone', () {
      bool exists(String path) => path == '/present.png';
      final List<RecentFileItem> items = buildRecentFiles(
        conversations: <Conversation>[_conversation('c1', fingerprint: 'AB')],
        messages: <ChatMessage>[
          _message('m1', 'c1', at: DateTime(2026, 1, 3)),
          _message('m2', 'c1', at: DateTime(2026, 1, 2)),
          _message('m3', 'c1', at: DateTime(2026, 1, 1)),
        ],
        files: <FileAttachment>[
          _attachment('f1', 'm1', name: 'present.png', path: '/present.png'),
          _attachment('f2', 'm2', name: 'gone.png', path: '/gone.png'),
          _attachment('f3', 'm3', name: 'unknown.png', path: null),
        ],
        isOnDisk: exists,
      );

      final Map<String, RecentFileItem> byName = <String, RecentFileItem>{
        for (final RecentFileItem i in items) i.file.fileName: i,
      };
      expect(byName['present.png']!.sourceMissing, isFalse);
      expect(byName['gone.png']!.sourceMissing, isTrue);
      expect(byName['unknown.png']!.sourceMissing, isFalse); // path unknown
    });

    test('sorts by messageCreatedAt descending', () {
      final List<RecentFileItem> items = buildRecentFiles(
        conversations: <Conversation>[_conversation('c1', fingerprint: 'AB')],
        messages: <ChatMessage>[
          _message('m1', 'c1', at: DateTime(2026, 1, 1)),
          _message('m2', 'c1', at: DateTime(2026, 1, 3)),
          _message('m3', 'c1', at: DateTime(2026, 1, 2)),
        ],
        files: <FileAttachment>[
          _attachment('f1', 'm1', name: 'old.txt'),
          _attachment('f2', 'm2', name: 'new.txt'),
          _attachment('f3', 'm3', name: 'mid.txt'),
        ],
        isOnDisk: (String _) => true,
      );

      expect(
        items.map((RecentFileItem i) => i.file.fileName).toList(),
        <String>['new.txt', 'mid.txt', 'old.txt'],
      );
    });
  });

  group('groupByLocalDay', () {
    test('keys are yyyy-MM-dd, descending, with descending groups', () {
      final List<RecentFileItem> items = <RecentFileItem>[
        _item('a', at: DateTime(2026, 1, 2, 8)),
        _item('b', at: DateTime(2026, 1, 2, 20)),
        _item('c', at: DateTime(2026, 1, 1, 23)),
      ];

      final Map<String, List<RecentFileItem>> groups = groupByLocalDay(items);

      expect(groups.keys.toList(), <String>['2026-01-02', '2026-01-01']);
      expect(
        groups['2026-01-02']!
            .map((RecentFileItem i) => i.file.fileName)
            .toList(),
        <String>['b', 'a'],
      );
      expect(groups['2026-01-01']!.single.file.fileName, 'c');
      expect(groups.length, 2);
    });

    test('localDateKey zero-pads year, month and day', () {
      expect(localDateKey(DateTime(2026, 3, 7, 5)), '2026-03-07');
    });
  });

  group('filterByQuery', () {
    test('matches file name case-insensitively', () {
      final List<RecentFileItem> items = <RecentFileItem>[
        _item('Report.PDF'),
        _item('holiday.png'),
        _item('notes.txt'),
      ];

      expect(
        filterByQuery(items, 'P')
            .map((RecentFileItem i) => i.file.fileName)
            .toList(),
        <String>['Report.PDF', 'holiday.png'],
      );
      expect(
        filterByQuery(items, 'rep').single.file.fileName,
        'Report.PDF',
      );
    });

    test('a blank query returns a copy with the same contents', () {
      final List<RecentFileItem> items = <RecentFileItem>[
        _item('a'),
        _item('b')
      ];
      final List<RecentFileItem> result = filterByQuery(items, '   ');

      expect(result, items);
      expect(identical(result, items), isFalse);
    });
  });

  group('categorizeFile / matchesKind', () {
    test('categorizeFile: mime wins, extension is the fallback', () {
      expect(categorizeFile('x', mime: 'image/png'), FileCategory.image);
      expect(categorizeFile('x', mime: 'video/mp4'), FileCategory.video);
      expect(categorizeFile('x', mime: 'application/pdf'), FileCategory.file);
      // octet-stream is "unknown" => fall back to the extension
      expect(categorizeFile('photo.JPG', mime: 'application/octet-stream'),
          FileCategory.image);
      expect(categorizeFile('clip.mp4'), FileCategory.video);
      expect(categorizeFile('doc.pdf'), FileCategory.file);
      expect(categorizeFile('mystery.xyz'), FileCategory.other);
      expect(categorizeFile('noextension'), FileCategory.other);
    });

    test('matchesKind: image by mime, and by extension when mime is null', () {
      expect(
        matchesKind(_item('a', mime: 'image/png'), FileKind.image),
        isTrue,
      );
      expect(
        matchesKind(_item('b.png', mime: null), FileKind.image),
        isTrue,
      );
      expect(
        matchesKind(_item('c.mp4', mime: null), FileKind.video),
        isTrue,
      );
      expect(
        matchesKind(_item('d.pdf', mime: null), FileKind.image),
        isFalse,
      );
      expect(
        matchesKind(_item('d.pdf', mime: null), FileKind.any),
        isTrue,
      );
    });

    test('fileExtension: lower-case, no dot, dot-files have none', () {
      expect(fileExtension('Photo.PNG'), 'png');
      expect(fileExtension('archive.tar.gz'), 'gz');
      expect(fileExtension('.gitignore'), '');
      expect(fileExtension('noext'), '');
      expect(fileExtension('trailing.'), '');
    });
  });

  group('classifyFile: the fine classes behind the six tabs', () {
    test('media: mime wins, extension is the fallback', () {
      expect(classifyFile('a', mime: 'image/png'), FileClass.image);
      expect(classifyFile('a', mime: 'video/mp4'), FileClass.video);
      expect(classifyFile('a', mime: 'audio/mpeg'), FileClass.audio);
      expect(classifyFile('clip.mp4'), FileClass.video);
      expect(classifyFile('song.MP3'), FileClass.audio);
    });

    test('installers and archives are split out of the old "file" bucket', () {
      expect(classifyFile('app.apk'), FileClass.installer);
      expect(classifyFile('setup.exe'), FileClass.installer);
      expect(classifyFile('image.iso'), FileClass.installer);
      expect(classifyFile('bundle.zip'), FileClass.archive);
      expect(classifyFile('data.tar.gz'), FileClass.archive);
    });

    test('documents / source / unknown', () {
      expect(classifyFile('doc.pdf'), FileClass.document);
      expect(classifyFile('main.dart'), FileClass.document);
      expect(classifyFile('mystery.xyz'), FileClass.other);
      expect(classifyFile('noextension'), FileClass.other);
      // A specific non-media mime ⇒ document, not the extension.
      expect(
          classifyFile('a.xyz', mime: 'application/pdf'), FileClass.document);
    });

    test('the icon category is derived from the fine class', () {
      // image / video keep their own icons; every "known non-media" class
      // (audio, installer, archive, document) shares the generic file icon, so
      // `format.dart`'s exhaustive four-case switch stays valid.
      expect(categorizeFile('a.png'), FileCategory.image);
      expect(categorizeFile('a.mp4'), FileCategory.video);
      expect(categorizeFile('a.mp3'), FileCategory.file);
      expect(categorizeFile('a.zip'), FileCategory.file);
      expect(categorizeFile('a.apk'), FileCategory.file);
      expect(categorizeFile('a.pdf'), FileCategory.file);
      expect(categorizeFile('a.xyz'), FileCategory.other);
    });
  });

  group('matchesKind: all seven tabs', () {
    test('each category tab matches only its own class', () {
      expect(matchesKind(_item('a.png'), FileKind.image), isTrue);
      expect(matchesKind(_item('a.mp4'), FileKind.video), isTrue);
      expect(matchesKind(_item('a.mp3'), FileKind.audio), isTrue);
      expect(matchesKind(_item('a.apk'), FileKind.installer), isTrue);
      expect(matchesKind(_item('a.zip'), FileKind.archive), isTrue);
      expect(matchesKind(_item('a.pdf'), FileKind.document), isTrue);
      // cross-tab negatives
      expect(matchesKind(_item('a.mp3'), FileKind.image), isFalse);
      expect(matchesKind(_item('a.mp3'), FileKind.video), isFalse);
      expect(matchesKind(_item('a.png'), FileKind.audio), isFalse);
      expect(matchesKind(_item('a.pdf'), FileKind.archive), isFalse);
      expect(matchesKind(_item('a.png'), FileKind.document), isFalse);
    });

    test('any matches every file', () {
      for (final String name in <String>['a.png', 'a.mp3', 'a.zip', 'x']) {
        expect(matchesKind(_item(name), FileKind.any), isTrue, reason: name);
      }
    });

    test('audio by mime; archive / installer / document by mime or extension',
        () {
      expect(
        matchesKind(_item('x', mime: 'audio/flac'), FileKind.audio),
        isTrue,
      );
      expect(matchesKind(_item('x.tar'), FileKind.archive), isTrue);
      expect(matchesKind(_item('x.dmg'), FileKind.installer), isTrue);
      // document: by mime, and by extension
      expect(
        matchesKind(_item('x', mime: 'application/pdf'), FileKind.document),
        isTrue,
      );
      expect(matchesKind(_item('x.pdf'), FileKind.document), isTrue);
    });
  });
}
