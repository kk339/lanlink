import 'package:lanlink_core/lanlink_core.dart';
import 'package:lanlink_store/lanlink_store.dart';
import 'package:test/test.dart';

import 'support/test_db.dart';

void main() {
  late LanlinkDatabase db;
  late DevicesDao dao;

  setUp(() {
    db = openTestDatabase();
    dao = DevicesDao(db);
  });

  tearDown(() => db.close());

  group('upsert', () {
    test('inserts a new device', () {
      final device = dao.upsert(
        const DeviceRecord(
          fingerprint: 'FP1',
          alias: 'Phone',
          deviceType: 'desktop',
        ),
        now: t0,
      );
      expect(device.fingerprint, 'FP1');
      expect(device.alias, 'Phone');
      expect(dao.all(), hasLength(1));
      expect(dao.byFingerprint('FP1'), device);
    });

    test('is idempotent and refreshes the observation columns', () {
      dao.upsert(
        const DeviceRecord(
          fingerprint: 'FP1',
          alias: 'Old',
          deviceType: 'desktop',
          model: 'M1',
          lastIp: '10.0.0.1',
          lastPort: 1,
        ),
        now: t0,
      );

      final second = dao.upsert(
        const DeviceRecord(
          fingerprint: 'FP1',
          alias: 'New',
          deviceType: 'mobile',
          model: 'M2',
          lastIp: '10.0.0.2',
          lastPort: 53317,
        ),
        now: at(60),
      );

      expect(dao.all(), hasLength(1), reason: 'must not create a second row');
      expect(second.alias, 'New');
      expect(second.deviceType, 'mobile');
      expect(second.model, 'M2');
      expect(second.lastIp, '10.0.0.2');
      expect(second.lastPort, 53317);
      expect(second.lastSeenAt, at(60));
    });

    test('preserves trusted / paired_at across a later re-upsert', () {
      dao.upsert(const DeviceRecord(fingerprint: 'FP1', alias: 'A'), now: t0);
      dao.setTrusted('FP1', trusted: true, now: at(5));

      dao.upsert(const DeviceRecord(fingerprint: 'FP1', alias: 'B'),
          now: at(10));

      final device = dao.byFingerprint('FP1')!;
      expect(device.alias, 'B', reason: 'alias is still refreshed');
      expect(device.trusted, isTrue, reason: 'a later send must not un-trust');
      expect(device.pairedAt, at(5));
    });

    test('normalises the fingerprint on write and on lookup', () {
      dao.upsert(const DeviceRecord(fingerprint: 'aa:bb', alias: 'A'), now: t0);
      expect(dao.byFingerprint('AABB'), isNotNull);
      expect(dao.byFingerprint('aa:bb'), isNotNull);
      expect(dao.all().single.fingerprint, 'AABB');
    });
  });

  group('touchFromInfo', () {
    test('ignores an empty fingerprint and returns null', () {
      final result = dao.touchFromInfo(
        const DeviceInfo(alias: 'x', fingerprint: '', port: 1),
        address: '10.0.0.9',
        now: t0,
      );
      expect(result, isNull);
      expect(dao.all(), isEmpty);
    });

    test('maps info fields and stores port 0 as a legal value', () {
      final device = dao.touchFromInfo(
        const DeviceInfo(
          alias: 'Srv',
          fingerprint: 'FP1',
          port: 0,
          deviceType: DeviceType.server,
          deviceModel: 'Win',
        ),
        address: '10.0.0.9',
        now: t0,
      )!;
      expect(device.alias, 'Srv');
      expect(device.deviceType, 'server');
      expect(device.model, 'Win');
      expect(device.lastIp, '10.0.0.9');
      expect(device.lastPort, 0, reason: '0 means "no inbound server"');
      expect(device.isDialable, isFalse);
    });

    test('stores a NULL last_ip for an empty address', () {
      final device = dao.touchFromInfo(
        const DeviceInfo(alias: 'x', fingerprint: 'FP1', port: 9),
        address: '',
        now: t0,
      )!;
      expect(device.lastIp, isNull);
    });

    test('preserves trust established earlier', () {
      dao.upsert(const DeviceRecord(fingerprint: 'FP1', alias: 'A'), now: t0);
      dao.setTrusted('FP1', trusted: true, now: at(1));

      final device = dao.touchFromInfo(
        const DeviceInfo(alias: 'A2', fingerprint: 'FP1', port: 5),
        address: '10.0.0.9',
        now: at(2),
      )!;
      expect(device.alias, 'A2');
      expect(device.trusted, isTrue);
    });
  });

  group('setTrusted', () {
    test('turns trust on (stamping paired_at) and off (clearing it)', () {
      dao.upsert(const DeviceRecord(fingerprint: 'FP1', alias: 'A'), now: t0);

      dao.setTrusted('FP1', trusted: true, now: at(30));
      var device = dao.byFingerprint('FP1')!;
      expect(device.trusted, isTrue);
      expect(device.pairedAt, at(30));

      dao.setTrusted('FP1', trusted: false, now: at(60));
      device = dao.byFingerprint('FP1')!;
      expect(device.trusted, isFalse);
      expect(device.pairedAt, isNull);
    });

    test('is a quiet no-op for an unknown fingerprint', () {
      expect(
        () => dao.setTrusted('NOPE', trusted: true, now: t0),
        returnsNormally,
      );
    });
  });

  group('delete', () {
    test('keeps conversations by nulling their device_fingerprint', () {
      dao.upsert(const DeviceRecord(fingerprint: 'FP1', alias: 'A'), now: t0);
      db.execute(
        'INSERT INTO conversations (id, device_fingerprint, created_at) '
        'VALUES (?, ?, ?)',
        <Object?>['c1', 'FP1', toEpochMillis(t0)],
      );

      dao.delete('FP1');

      expect(dao.byFingerprint('FP1'), isNull);
      final row = db.selectOne(
        'SELECT device_fingerprint FROM conversations WHERE id = ?',
        <Object?>['c1'],
      );
      expect(row, isNotNull, reason: 'history must be preserved');
      expect(row!['device_fingerprint'], isNull);
    });
  });
}
