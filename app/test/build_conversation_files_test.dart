/// Pure unit tests for `buildConversationFiles` (PRD §3.4-⑤ / design §4):
/// ordering determinism, the tie-break shared with `buildRecentFiles`,
/// classification through `classifyFile`, and orphan-attachment dropping.
///
/// No Flutter widgets, no repository, no disk — pure functions over domain
/// models only.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/selectors.dart';

ChatMessage _message(
  String id, {
  required DateTime at,
  MessageDirection direction = MessageDirection.incoming,
}) =>
    ChatMessage(
      id: id,
      conversationId: 'c',
      direction: direction,
      kind: MessageKind.file,
      createdAt: at,
      updatedAt: at,
      status: MessageStatus.done,
    );

FileAttachment _file(
  String id,
  String messageId, {
  required String name,
  String? mime,
  int size = 10,
}) =>
    FileAttachment(
      id: id,
      messageId: messageId,
      fileName: name,
      size: size,
      mime: mime,
    );

List<String> _ids(List<ConversationFileItem> items) =>
    items.map((ConversationFileItem item) => item.file.id).toList();

void main() {
  group('buildConversationFiles: flattening', () {
    test('flattens messages × files into one row per attachment', () {
      final ChatMessage m1 = _message('m1', at: DateTime(2026, 1, 2));
      final ChatMessage m2 = _message(
        'm2',
        at: DateTime(2026, 1, 1),
        direction: MessageDirection.outgoing,
      );

      final List<ConversationFileItem> items = buildConversationFiles(
        messages: <ChatMessage>[m1, m2],
        filesByMessage: <String, List<FileAttachment>>{
          'm1': <FileAttachment>[_file('f1', 'm1', name: 'a.jpg')],
          'm2': <FileAttachment>[
            _file('f2', 'm2', name: 'b.mp4'),
            _file('f3', 'm2', name: 'c.pdf'),
          ],
        },
      );

      expect(items.length, 3);
      expect(_ids(items), containsAll(<String>['f1', 'f2', 'f3']));
    });

    test("carries each row's owning message id, time and direction", () {
      final ChatMessage m = _message(
        'm1',
        at: DateTime(2026, 3, 4, 5, 6),
        direction: MessageDirection.outgoing,
      );

      final List<ConversationFileItem> items = buildConversationFiles(
        messages: <ChatMessage>[m],
        filesByMessage: <String, List<FileAttachment>>{
          'm1': <FileAttachment>[_file('f1', 'm1', name: 'a.jpg')],
        },
      );

      expect(items.single.messageId, 'm1');
      expect(items.single.messageCreatedAt, DateTime(2026, 3, 4, 5, 6));
      expect(items.single.direction, MessageDirection.outgoing);
    });

    test('drops orphan attachments whose messageId is not in messages', () {
      final ChatMessage m1 = _message('m1', at: DateTime(2026, 1, 1));

      final List<ConversationFileItem> items = buildConversationFiles(
        messages: <ChatMessage>[m1],
        filesByMessage: <String, List<FileAttachment>>{
          'm1': <FileAttachment>[_file('f1', 'm1', name: 'keep.jpg')],
          'ghost': <FileAttachment>[_file('f2', 'ghost', name: 'drop.jpg')],
        },
      );

      expect(items.length, 1);
      expect(items.single.file.id, 'f1');
    });

    test('empty inputs yield an empty list', () {
      expect(
        buildConversationFiles(
          messages: const <ChatMessage>[],
          filesByMessage: const <String, List<FileAttachment>>{},
        ),
        isEmpty,
      );
    });

    test('is order-independent on messages and does not mutate its inputs', () {
      final ChatMessage m1 = _message('m1', at: DateTime(2026, 1, 2));
      final ChatMessage m2 = _message('m2', at: DateTime(2026, 1, 1));
      final Map<String, List<FileAttachment>> files =
          <String, List<FileAttachment>>{
        'm1': <FileAttachment>[_file('f1', 'm1', name: 'a.jpg')],
        'm2': <FileAttachment>[_file('f2', 'm2', name: 'b.jpg')],
      };
      final List<ChatMessage> ascending = <ChatMessage>[m1, m2];
      final List<ChatMessage> shuffled = <ChatMessage>[m2, m1];

      final List<ConversationFileItem> first = buildConversationFiles(
        messages: ascending,
        filesByMessage: files,
      );
      final List<ConversationFileItem> second = buildConversationFiles(
        messages: shuffled,
        filesByMessage: files,
      );

      expect(first, equals(second));
      expect(ascending, equals(<ChatMessage>[m1, m2]));
    });
  });

  group('buildConversationFiles: ordering (shared with buildRecentFiles)', () {
    test('sorts by messageCreatedAt descending', () {
      final List<ConversationFileItem> items = buildConversationFiles(
        messages: <ChatMessage>[
          _message('m1', at: DateTime(2026, 1, 1)),
          _message('m2', at: DateTime(2026, 1, 3)),
          _message('m3', at: DateTime(2026, 1, 2)),
        ],
        filesByMessage: <String, List<FileAttachment>>{
          'm1': <FileAttachment>[_file('f1', 'm1', name: 'a.jpg')],
          'm2': <FileAttachment>[_file('f2', 'm2', name: 'b.jpg')],
          'm3': <FileAttachment>[_file('f3', 'm3', name: 'c.jpg')],
        },
      );

      expect(_ids(items), <String>['f2', 'f3', 'f1']);
    });

    test('breaks same-instant ties by fileName then by file id', () {
      final DateTime at = DateTime(2026, 1, 1);

      final List<ConversationFileItem> items = buildConversationFiles(
        messages: <ChatMessage>[
          _message('m1', at: at),
          _message('m2', at: at),
        ],
        filesByMessage: <String, List<FileAttachment>>{
          'm1': <FileAttachment>[
            _file('f-b', 'm1', name: 'b.txt'),
            _file('f-a2', 'm1', name: 'a.txt'),
            _file('f-a1', 'm1', name: 'a.txt'),
          ],
          'm2': <FileAttachment>[_file('f-c', 'm2', name: 'c.txt')],
        },
      );

      // Same name 'a.txt' → id ascending (f-a1 before f-a2); then b.txt, c.txt.
      expect(_ids(items), <String>['f-a1', 'f-a2', 'f-b', 'f-c']);
    });

    test('orders identical rows the same way buildRecentFiles does', () {
      final DateTime at = DateTime(2026, 5, 5);
      final ChatMessage m = _message('m1', at: at);
      final List<FileAttachment> attachments = <FileAttachment>[
        _file('f-b', 'm1', name: 'b.txt'),
        _file('f-a', 'm1', name: 'a.txt'),
      ];

      final List<RecentFileItem> recent = buildRecentFiles(
        conversations: <Conversation>[
          Conversation(
            id: 'c',
            deviceFingerprint: 'FP',
            createdAt: DateTime(2026, 1, 1),
          ),
        ],
        messages: <ChatMessage>[m],
        files: attachments,
        isOnDisk: (String path) => true,
      );
      final List<ConversationFileItem> conv = buildConversationFiles(
        messages: <ChatMessage>[m],
        filesByMessage: <String, List<FileAttachment>>{'m1': attachments},
      );

      // Same comparator under the hood → identical order on the same rows.
      expect(
        conv.map((ConversationFileItem i) => i.file.id).toList(),
        recent.map((RecentFileItem i) => i.file.id).toList(),
      );
    });
  });

  group('buildConversationFiles: classification via classifyFile', () {
    test('every row is classifiable through classifyFile (no second table)',
        () {
      final ChatMessage m = _message('m1', at: DateTime(2026, 1, 1));

      final List<ConversationFileItem> items = buildConversationFiles(
        messages: <ChatMessage>[m],
        filesByMessage: <String, List<FileAttachment>>{
          'm1': <FileAttachment>[
            _file('f1', 'm1', name: 'photo.jpg', mime: 'image/jpeg'),
            _file('f2', 'm1', name: 'clip.mp4'),
            _file('f3', 'm1', name: 'doc.pdf'),
            _file('f4', 'm1', name: 'song.mp3'),
          ],
        },
      );

      final Map<String, FileClass> classById = <String, FileClass>{
        for (final ConversationFileItem item in items)
          item.file.id: classifyFile(item.file.fileName, mime: item.file.mime),
      };

      expect(classById['f1'], FileClass.image);
      expect(classById['f2'], FileClass.video);
      expect(classById['f3'], FileClass.document);
      expect(classById['f4'], FileClass.audio);
    });
  });
}
