import 'package:lanlink_store/lanlink_store.dart';
import 'package:test/test.dart';

import 'support/test_db.dart';

void main() {
  group('DeviceRecord', () {
    test('survives a toRow / fromRow round trip', () {
      final record = DeviceRecord(
        fingerprint: '580AC9D0',
        alias: 'Pixel',
        deviceType: 'desktop',
        model: 'Pixel 8',
        lastIp: '192.168.5.9',
        lastPort: 53317,
        lastSeenAt: t0,
        trusted: true,
        pairedAt: at(30),
        groupCode: 'grp-1',
      );
      expect(DeviceRecord.fromRow(record.toRow()), record);
    });

    test('survives a round trip with every optional column null', () {
      const record = DeviceRecord(fingerprint: 'F', alias: 'a');
      expect(DeviceRecord.fromRow(record.toRow()), record);
    });

    test('isDialable is null/0 => false and >0 => true', () {
      const base = DeviceRecord(fingerprint: 'F', alias: 'a');
      expect(base.isDialable, isFalse);
      expect(base.copyWith(lastPort: 0).isDialable, isFalse);
      expect(base.copyWith(lastPort: 53317).isDialable, isTrue);
    });
  });

  group('ConversationRecord', () {
    test('survives a toRow / fromRow round trip', () {
      final record = ConversationRecord(
        id: 'conv-1',
        deviceFingerprint: 'F',
        createdAt: t0,
        lastMessageAt: at(10),
        lastPreview: 'hi',
      );
      expect(ConversationRecord.fromRow(record.toRow()), record);
    });

    test('isArchived tracks archivedAt', () {
      final active = ConversationRecord(id: 'c', createdAt: t0);
      expect(active.isArchived, isFalse);
      expect(active.copyWith(archivedAt: at(5)).isArchived, isTrue);
    });

    test('allows a history-only conversation (no device)', () {
      final record = ConversationRecord(id: 'c', createdAt: t0);
      expect(record.deviceFingerprint, isNull);
      expect(ConversationRecord.fromRow(record.toRow()), record);
    });
  });

  group('MessageRecord', () {
    test('survives a toRow / fromRow round trip (file)', () {
      final record = MessageRecord(
        id: 'MSG1',
        conversationId: 'conv-1',
        direction: MessageDirection.outgoing,
        kind: MessageKind.file,
        createdAt: t0,
        updatedAt: at(5),
        status: MessageStatus.awaitingConfirm,
        eventNonce: 'file-id-1',
      );
      expect(MessageRecord.fromRow(record.toRow()), record);
    });

    test('survives a toRow / fromRow round trip (text)', () {
      final record = MessageRecord(
        id: 'MSG2',
        conversationId: 'conv-1',
        direction: MessageDirection.incoming,
        kind: MessageKind.text,
        textBody: 'hello',
        createdAt: t0,
        updatedAt: t0,
        status: MessageStatus.done,
        eventNonce: 'nonce-x',
      );
      expect(MessageRecord.fromRow(record.toRow()), record);
    });

    test('the enums round-trip through their wire strings', () {
      for (final status in MessageStatus.values) {
        expect(MessageStatus.parse(status.wire), status);
      }
      for (final direction in MessageDirection.values) {
        expect(MessageDirection.parse(direction.wire), direction);
      }
      for (final kind in MessageKind.values) {
        expect(MessageKind.parse(kind.wire), kind);
      }
    });

    test('parsing an unknown value throws FormatException', () {
      expect(() => MessageStatus.parse('nope'), throwsFormatException);
      expect(() => MessageDirection.parse('sideways'), throwsFormatException);
      expect(() => MessageKind.parse('movie'), throwsFormatException);
    });
  });

  group('MessageFileRecord', () {
    test('survives a toRow / fromRow round trip', () {
      const record = MessageFileRecord(
        id: 'F1',
        messageId: 'MSG1',
        fileName: 'report.pdf',
        size: 42,
        mime: 'application/pdf',
        sha256: 'ABC',
        localPath: '/tmp/report.pdf',
        thumbnailPath: '/tmp/report.png',
      );
      expect(MessageFileRecord.fromRow(record.toRow()), record);
    });

    test('supports the unknown-size sentinel', () {
      const record = MessageFileRecord(
        id: 'F2',
        messageId: 'MSG1',
        fileName: 'x',
        size: -1,
      );
      expect(MessageFileRecord.fromRow(record.toRow()).size, -1);
    });
  });

  group('TransferRecord', () {
    test('survives a toRow / fromRow round trip', () {
      final record = TransferRecord(
        id: 'T1',
        fileId: 'F1',
        sessionId: 's-1',
        token: 'tok',
        bytesDone: 40,
        bytesTotal: 100,
        chunkSize: 4096,
        retryCount: 2,
        nextAttemptAt: at(60),
        error: 'boom',
        updatedAt: t0,
      );
      expect(TransferRecord.fromRow(record.toRow()), record);
    });

    test('survives a round trip with every optional column null', () {
      final record = TransferRecord(
        id: 'T2',
        fileId: 'F2',
        bytesTotal: -1,
        updatedAt: t0,
      );
      expect(TransferRecord.fromRow(record.toRow()), record);
    });
  });
}
