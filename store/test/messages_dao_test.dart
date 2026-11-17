import 'package:lanlink_store/lanlink_store.dart';
import 'package:test/test.dart';

import 'support/test_db.dart';

void main() {
  late LanlinkDatabase db;
  late MessagesDao dao;

  setUp(() {
    db = openTestDatabase();
    dao = MessagesDao(db);
    _seedConversation(db, 'conv-1');
  });

  tearDown(() => db.close());

  MessageRecord outgoing({
    String id = 'MSG1',
    String conversationId = 'conv-1',
    MessageKind kind = MessageKind.file,
    String? textBody,
    DateTime? createdAt,
    DateTime? updatedAt,
    MessageStatus status = MessageStatus.pending,
    String eventNonce = 'file-id-1',
  }) =>
      MessageRecord(
        id: id,
        conversationId: conversationId,
        direction: MessageDirection.outgoing,
        kind: kind,
        textBody: textBody,
        createdAt: createdAt ?? t0,
        updatedAt: updatedAt ?? t0,
        status: status,
        eventNonce: eventNonce,
      );

  int messageCount() =>
      db.selectAll('SELECT COUNT(*) AS n FROM messages').first['n'] as int;

  group('insertIfAbsent', () {
    test('writes a new row the first time and reports created', () {
      final result = dao.insertIfAbsent(outgoing());

      expect(result, (id: 'MSG1', created: true));
      expect(messageCount(), 1);
      expect(dao.byId('MSG1'), outgoing());
    });

    test('is idempotent for the same conversation/direction/event', () {
      final first = dao.insertIfAbsent(outgoing());
      // A replay of the same logical event: even with a *different* id it must
      // not add a second row, and must report the stored row's id.
      final second = dao.insertIfAbsent(outgoing(id: 'MSG-other'));

      expect(first.created, isTrue);
      expect(second.created, isFalse);
      expect(second.id, 'MSG1');
      expect(messageCount(), 1);
    });

    test('keeps two distinct events even when their content is identical', () {
      // Same file content, two separate sends: different event_nonce means two
      // rows. Idempotency must not swallow a legitimate duplicate.
      dao.insertIfAbsent(outgoing(id: 'MSG1', eventNonce: 'event-a'));
      dao.insertIfAbsent(outgoing(id: 'MSG2', eventNonce: 'event-b'));

      expect(messageCount(), 2);
    });

    test('an event in another conversation is not treated as a duplicate', () {
      _seedConversation(db, 'conv-2');
      dao.insertIfAbsent(outgoing());
      dao.insertIfAbsent(outgoing(id: 'MSG2', conversationId: 'conv-2'));

      expect(messageCount(), 2);
    });
  });

  group('byId / byEventNonce', () {
    test('byId returns the row or null', () {
      dao.insertIfAbsent(outgoing());
      expect(dao.byId('MSG1')?.status, MessageStatus.pending);
      expect(dao.byId('nope'), isNull);
    });

    test('byEventNonce matches on the full triple only', () {
      dao.insertIfAbsent(outgoing());

      expect(
        dao
            .byEventNonce(
              conversationId: 'conv-1',
              direction: MessageDirection.outgoing,
              eventNonce: 'file-id-1',
            )
            ?.id,
        'MSG1',
      );
      // Wrong direction and wrong conversation must both miss.
      expect(
        dao.byEventNonce(
          conversationId: 'conv-1',
          direction: MessageDirection.incoming,
          eventNonce: 'file-id-1',
        ),
        isNull,
      );
      expect(
        dao.byEventNonce(
          conversationId: 'conv-9',
          direction: MessageDirection.outgoing,
          eventNonce: 'file-id-1',
        ),
        isNull,
      );
    });
  });

  group('forConversation', () {
    setUp(() {
      dao.insertIfAbsent(outgoing(id: 'M0', eventNonce: 'n0', createdAt: t0));
      dao.insertIfAbsent(
          outgoing(id: 'M1', eventNonce: 'n1', createdAt: at(10)));
      dao.insertIfAbsent(
          outgoing(id: 'M2', eventNonce: 'n2', createdAt: at(20)));
    });

    test('returns newest first', () {
      expect(
        dao.forConversation('conv-1').map((m) => m.id),
        <String>['M2', 'M1', 'M0'],
      );
    });

    test('honours limit', () {
      expect(
        dao.forConversation('conv-1', limit: 2).map((m) => m.id),
        <String>['M2', 'M1'],
      );
    });

    test('before is an exclusive upper bound for paging older messages', () {
      expect(
        dao.forConversation('conv-1', before: at(20)).map((m) => m.id),
        <String>['M1', 'M0'],
      );
    });

    test('an unknown conversation yields an empty list', () {
      expect(dao.forConversation('conv-9'), isEmpty);
    });
  });

  group('byStatus', () {
    test('returns only the requested statuses', () {
      dao.insertIfAbsent(
          outgoing(id: 'M0', eventNonce: 'n0', status: MessageStatus.pending));
      dao.insertIfAbsent(
          outgoing(id: 'M1', eventNonce: 'n1', status: MessageStatus.done));
      dao.insertIfAbsent(
          outgoing(id: 'M2', eventNonce: 'n2', status: MessageStatus.failed));

      expect(
        dao.byStatus({MessageStatus.done}).map((m) => m.id),
        <String>['M1'],
      );
      expect(
        dao.byStatus({MessageStatus.done, MessageStatus.failed}).map(
            (m) => m.id),
        <String>['M1', 'M2'],
      );
    });

    test('an empty set yields an empty list', () {
      expect(dao.byStatus(const <MessageStatus>{}), isEmpty);
    });
  });

  group('updateStatus', () {
    test('applies a legal transition and stamps updated_at', () {
      dao.insertIfAbsent(outgoing());

      final changed = dao.updateStatus(
        id: 'MSG1',
        from: MessageStatus.pending,
        to: MessageStatus.awaitingConfirm,
        now: at(5),
      );

      expect(changed, isTrue);
      final row = dao.byId('MSG1')!;
      expect(row.status, MessageStatus.awaitingConfirm);
      expect(row.updatedAt, at(5));
      expect(row.createdAt, t0);
    });

    test('returns false and leaves the row untouched when status mismatches',
        () {
      dao.insertIfAbsent(outgoing());

      final changed = dao.updateStatus(
        id: 'MSG1',
        from: MessageStatus.awaitingConfirm,
        to: MessageStatus.transferring,
        now: at(5),
      );

      expect(changed, isFalse);
      final row = dao.byId('MSG1')!;
      expect(row.status, MessageStatus.pending);
      expect(row.updatedAt, t0);
    });

    test('throws on an illegal transition and changes nothing', () {
      dao.insertIfAbsent(outgoing());

      expect(
        () => dao.updateStatus(
          id: 'MSG1',
          // `pending -> done` is legal since docs/13 §7.3; `pending ->
          // transferring` remains illegal, so it exercises the error.
          from: MessageStatus.pending,
          to: MessageStatus.transferring,
          now: at(5),
        ),
        throwsA(isA<InvalidStatusTransition>()),
      );
      final row = dao.byId('MSG1')!;
      expect(row.status, MessageStatus.pending);
      expect(row.updatedAt, t0);
    });

    test('a no-op (from == to) is rejected as illegal', () {
      dao.insertIfAbsent(outgoing());
      expect(
        () => dao.updateStatus(
          id: 'MSG1',
          from: MessageStatus.pending,
          to: MessageStatus.pending,
          now: at(5),
        ),
        throwsA(isA<InvalidStatusTransition>()),
      );
    });
  });

  group('foreign keys', () {
    test('deleting a conversation cascades to its messages', () {
      dao.insertIfAbsent(outgoing(id: 'M0', eventNonce: 'n0'));
      dao.insertIfAbsent(outgoing(id: 'M1', eventNonce: 'n1'));
      expect(messageCount(), 2);

      db.execute('DELETE FROM conversations WHERE id = ?', <Object?>['conv-1']);

      expect(messageCount(), 0);
    });
  });
}

/// Inserts a bare `conversations` row (history-only: no device).
void _seedConversation(LanlinkDatabase db, String id) {
  db.execute(
    'INSERT INTO conversations (id, created_at) VALUES (?, ?)',
    <Object?>[id, toEpochMillis(t0)],
  );
}
