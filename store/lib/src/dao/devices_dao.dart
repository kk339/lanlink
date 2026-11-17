/// The `devices` table access object: the long-lived counterparty of a
/// conversation.
///
/// Signatures are frozen by spec §5.3. Every write takes a UTC [DateTime] `now`
/// and never reads the clock itself (spec §5.10); timestamps are stored as UTC
/// epoch milliseconds through the model's `toRow`/`fromRow`.
library;

import 'package:lanlink_core/lanlink_core.dart';

import '../db/lanlink_database.dart';
import '../db/time_codec.dart';
import '../models/device_record.dart';

/// Reads and writes rows of the `devices` table.
class DevicesDao {
  /// Wraps an open [LanlinkDatabase].
  DevicesDao(this._db);

  final LanlinkDatabase _db;

  /// Inserts [device], or updates the existing row with the same fingerprint.
  ///
  /// Idempotent in the fingerprint: upserting the same device twice leaves a
  /// single row. On every call `last_ip` / `last_port` / `last_seen_at` are
  /// **refreshed** and `alias` / `model` / `device_type` are **updated** from
  /// [device]; `last_seen_at` is stamped with [now] (the observation instant).
  ///
  /// `trusted`, `paired_at` and `group_code` are written only when the row is
  /// first inserted and are **left untouched on conflict** (spec §5.3 lists
  /// exactly the six refreshed columns). That is deliberate: a repeated `send`
  /// never silently un-trusts a device — [setTrusted] is the sole mutator of
  /// the trust flag.
  ///
  /// The fingerprint is [normalizeFingerprint]d first (spec §9.1); an empty
  /// fingerprint trips the `length(fingerprint) > 0` check constraint.
  DeviceRecord upsert(DeviceRecord device, {required DateTime now}) {
    final record = device.copyWith(
      fingerprint: normalizeFingerprint(device.fingerprint),
      lastSeenAt: now,
    );
    final row = record.toRow();
    _db.execute(
      'INSERT INTO devices '
      '(fingerprint, alias, device_type, model, last_ip, last_port, '
      'last_seen_at, trusted, paired_at, group_code) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(fingerprint) DO UPDATE SET '
      'alias = excluded.alias, '
      'device_type = excluded.device_type, '
      'model = excluded.model, '
      'last_ip = excluded.last_ip, '
      'last_port = excluded.last_port, '
      'last_seen_at = excluded.last_seen_at',
      <Object?>[
        row['fingerprint'],
        row['alias'],
        row['device_type'],
        row['model'],
        row['last_ip'],
        row['last_port'],
        row['last_seen_at'],
        row['trusted'],
        row['paired_at'],
        row['group_code'],
      ],
    );
    return byFingerprint(record.fingerprint)!;
  }

  /// Bridge from the discovery layer: records [info] as observed at [address].
  ///
  /// * An **empty fingerprint** after normalisation means "no identity", so the
  ///   info is ignored and `null` is returned (spec §5.3).
  /// * An **empty [address]** stores `last_ip = NULL`.
  /// * `last_port` is taken verbatim from `info.port`: `0` is a real value
  ///   meaning "the peer runs no inbound server" (spec §5.7), never a missing
  ///   value.
  ///
  /// Trust/pairing columns are handled by [upsert] (preserved on conflict).
  DeviceRecord? touchFromInfo(
    DeviceInfo info, {
    required String address,
    required DateTime now,
  }) {
    final fingerprint = normalizeFingerprint(info.fingerprint);
    if (fingerprint.isEmpty) {
      return null;
    }
    return upsert(
      DeviceRecord(
        fingerprint: fingerprint,
        alias: info.alias,
        deviceType: info.deviceType.wire,
        model: info.deviceModel,
        lastIp: address.isEmpty ? null : address,
        lastPort: info.port,
        lastSeenAt: now,
      ),
      now: now,
    );
  }

  /// Returns the device with [fingerprint], or `null` when absent.
  ///
  /// The lookup normalises its argument, so a lowercase or colon-separated
  /// fingerprint still finds the row.
  DeviceRecord? byFingerprint(String fingerprint) {
    final row = _db.selectOne(
      'SELECT * FROM devices WHERE fingerprint = ?',
      <Object?>[normalizeFingerprint(fingerprint)],
    );
    return row == null ? null : DeviceRecord.fromRow(row);
  }

  /// Returns every device, most recently seen first (never-seen rows last,
  /// fingerprint breaking ties).
  List<DeviceRecord> all() => _db
      .selectAll(
        'SELECT * FROM devices ORDER BY last_seen_at DESC, fingerprint ASC',
      )
      .map(DeviceRecord.fromRow)
      .toList();

  /// Sets the [trusted] flag, stamping `paired_at` with [now] when turning
  /// trust **on** (an earlier timestamp is preserved) and clearing it when
  /// turning trust **off**. A no-op when the fingerprint is unknown.
  void setTrusted(
    String fingerprint, {
    required bool trusted,
    required DateTime now,
  }) {
    final normalized = normalizeFingerprint(fingerprint);
    if (trusted) {
      _db.execute(
        'UPDATE devices SET trusted = 1, paired_at = COALESCE(paired_at, ?) '
        'WHERE fingerprint = ?',
        <Object?>[toEpochMillis(now), normalized],
      );
    } else {
      _db.execute(
        'UPDATE devices SET trusted = 0, paired_at = NULL '
        'WHERE fingerprint = ?',
        <Object?>[normalized],
      );
    }
  }

  /// Deletes the device with [fingerprint].
  ///
  /// Its conversations are **kept**: the `conversations.device_fingerprint`
  /// foreign key is `ON DELETE SET NULL`, so history survives with a `NULL`
  /// device (spec §5.8). A no-op when the fingerprint is unknown.
  void delete(String fingerprint) {
    _db.execute(
      'DELETE FROM devices WHERE fingerprint = ?',
      <Object?>[normalizeFingerprint(fingerprint)],
    );
  }
}
