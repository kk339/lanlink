import 'package:lanlink_store/lanlink_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/test_db.dart';

void main() {
  late LanlinkDatabase db;
  late ConversationsDao dao;
  late DevicesDao devices;

  setUp(() {
    db = openTestDatabase();
    dao = ConversationsDao(db, SequentialIdGenerator(prefix: 'c'));
    devices = DevicesDao(db);
    devices.upsert(const DeviceRecord(fingerprint: 'FP1', alias: 'A'), now: t0);
    devices.upsert(const DeviceRecord(fingerprint: 'FP2', alias: 'B'), now: t0);
  });

  tearDown(() => db.close());

  group('openActive', () {
    test('creates a conversation and is idempotent for a fingerprint', () {
      final first = dao.openActive(deviceFingerprint: 'FP1', now: t0);
      final second = dao.openActive(deviceFingerprint: 'FP1', now: at(10));

      expect(first.id, second.id,
          reason: 'one active conversation per fingerprint');
      expect(dao.all(), hasLength(1));
    });

    test('creates a device-less conversation when the fingerprint is null', () {
      final conversation = dao.openActive(deviceFingerprint: null, now: t0);
      expect(conversation.deviceFingerprint, isNull);
      expect(conversation.createdAt, t0);

      final again = dao.openActive(deviceFingerprint: null, now: at(5));
      expect(again.id, conversation.id);
      expect(dao.all(), hasLength(1));
    });

    test('opens a fresh conversation once the previous one is archived', () {
      final first = dao.openActive(deviceFingerprint: 'FP1', now: t0);
      dao.archive(first.id, now: at(5));

      final second = dao.openActive(deviceFingerprint: 'FP1', now: at(6));
      expect(second.id, isNot(first.id));
      expect(dao.all(), hasLength(1), reason: 'only the active one shows');
      expect(dao.all(includeArchived: true), hasLength(2),
          reason: 'history is kept');
    });

    test('requires the device row to exist (foreign key)', () {
      expect(
        () => dao.openActive(deviceFingerprint: 'GHOST', now: t0),
        throwsA(isA<SqliteException>()),
      );
    });
  });

  group('activeForDevice', () {
    test('is null when none and returns the active one otherwise', () {
      expect(dao.activeForDevice('FP1'), isNull);

      final conversation = dao.openActive(deviceFingerprint: 'FP1', now: t0);
      expect(dao.activeForDevice('FP1')!.id, conversation.id);
      expect(dao.activeForDevice('fp1')!.id, conversation.id,
          reason: 'lookup normalises the fingerprint');
    });
  });

  group('all', () {
    test('orders by last_message_at desc, never-messaged rows last', () {
      final a = dao.openActive(deviceFingerprint: 'FP1', now: t0);
      final b = dao.openActive(deviceFingerprint: 'FP2', now: t0);
      final c = dao.openActive(deviceFingerprint: null, now: t0);

      dao.touchLastMessage(conversationId: a.id, now: at(10), preview: 'hi');
      dao.touchLastMessage(conversationId: b.id, now: at(20), preview: 'yo');

      expect(
        dao.all().map((conversation) => conversation.id).toList(),
        <String>[b.id, a.id, c.id],
      );
    });

    test('excludes archived rows unless asked', () {
      final active = dao.openActive(deviceFingerprint: 'FP1', now: t0);
      final other = dao.openActive(deviceFingerprint: 'FP2', now: t0);
      dao.archive(other.id, now: at(1));

      expect(dao.all().map((c) => c.id).toList(), <String>[active.id]);
      expect(dao.all(includeArchived: true), hasLength(2));
    });
  });

  group('touchLastMessage', () {
    test('updates last_message_at and preview', () {
      final conversation = dao.openActive(deviceFingerprint: 'FP1', now: t0);
      dao.touchLastMessage(
        conversationId: conversation.id,
        now: at(42),
        preview: 'hello',
      );

      final updated = dao.activeForDevice('FP1')!;
      expect(updated.lastMessageAt, at(42));
      expect(updated.lastPreview, 'hello');
    });

    test('throws RowNotFound for a missing conversation', () {
      expect(
        () => dao.touchLastMessage(
          conversationId: 'nope',
          now: t0,
          preview: null,
        ),
        throwsA(isA<RowNotFound>()),
      );
    });
  });

  group('archive / archiveAllForDevice', () {
    test('archive keeps the row and sets archived_at', () {
      final conversation = dao.openActive(deviceFingerprint: 'FP1', now: t0);
      dao.archive(conversation.id, now: at(5));

      expect(dao.activeForDevice('FP1'), isNull);
      expect(dao.all(), isEmpty);

      final archived = dao.all(includeArchived: true).single;
      expect(archived.id, conversation.id);
      expect(archived.isArchived, isTrue);
      expect(archived.archivedAt, at(5));
    });

    test('archive throws RowNotFound for a missing conversation', () {
      expect(
        () => dao.archive('nope', now: t0),
        throwsA(isA<RowNotFound>()),
      );
    });

    test('archiveAllForDevice archives the active row and returns the count',
        () {
      final conversation = dao.openActive(deviceFingerprint: 'FP1', now: t0);

      final count = dao.archiveAllForDevice('FP1', now: at(7));
      expect(count, 1);
      expect(dao.activeForDevice('FP1'), isNull);
      expect(dao.all(includeArchived: true).single.id, conversation.id);

      expect(dao.archiveAllForDevice('FP1', now: at(8)), 0,
          reason: 'nothing active is left to archive');
    });
  });

  group('device deletion', () {
    test('keeps the conversation with a NULL device_fingerprint', () {
      final conversation = dao.openActive(deviceFingerprint: 'FP1', now: t0);

      devices.delete('FP1');

      final kept = dao.all(includeArchived: true).single;
      expect(kept.id, conversation.id);
      expect(kept.deviceFingerprint, isNull);
      expect(kept.isArchived, isFalse, reason: 'still active, just orphaned');
    });
  });
}
