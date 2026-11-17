/// A row of the `devices` table: the long-lived counterparty of a conversation.
library;

import '../db/time_codec.dart';

/// Immutable `devices` row.
class DeviceRecord {
  /// Creates a device row.
  const DeviceRecord({
    required this.fingerprint,
    required this.alias,
    this.deviceType,
    this.model,
    this.lastIp,
    this.lastPort,
    this.lastSeenAt,
    this.trusted = false,
    this.pairedAt,
    this.groupCode,
  });

  /// Normalised (uppercase, separator-free) certificate fingerprint.
  final String fingerprint;

  /// Display name last announced by the peer.
  final String alias;

  /// `DeviceType.wire` verbatim, or `null` when never observed.
  final String? deviceType;

  /// Free-form model string, or `null`.
  final String? model;

  /// Last observed IPv4 address, or `null`.
  final String? lastIp;

  /// Last observed TCP port with a three-state meaning: `null` = never
  /// observed, `0` = observed but the peer runs no inbound server (`send`),
  /// `>0` = dialable.
  final int? lastPort;

  /// Last time the peer was seen (UTC), or `null`.
  final DateTime? lastSeenAt;

  /// Whether the user has marked this device as trusted (M6).
  final bool trusted;

  /// When the device was paired (M6), or `null`.
  final DateTime? pairedAt;

  /// Pairing group code (M6), or `null`.
  final String? groupCode;

  /// Whether the peer has an inbound server this device can dial.
  bool get isDialable => lastPort != null && lastPort! > 0;

  /// Builds a record from a `devices` row map (column name -> value).
  factory DeviceRecord.fromRow(Map<String, Object?> row) => DeviceRecord(
        fingerprint: row['fingerprint'] as String,
        alias: row['alias'] as String,
        deviceType: row['device_type'] as String?,
        model: row['model'] as String?,
        lastIp: row['last_ip'] as String?,
        lastPort: row['last_port'] as int?,
        lastSeenAt: fromEpochMillisOrNull(row['last_seen_at']),
        trusted: (row['trusted'] as int? ?? 0) != 0,
        pairedAt: fromEpochMillisOrNull(row['paired_at']),
        groupCode: row['group_code'] as String?,
      );

  /// Serialises to a `devices` row map.
  Map<String, Object?> toRow() => <String, Object?>{
        'fingerprint': fingerprint,
        'alias': alias,
        'device_type': deviceType,
        'model': model,
        'last_ip': lastIp,
        'last_port': lastPort,
        'last_seen_at': toEpochMillisOrNull(lastSeenAt),
        'trusted': trusted ? 1 : 0,
        'paired_at': toEpochMillisOrNull(pairedAt),
        'group_code': groupCode,
      };

  /// Returns a copy with the given fields replaced.
  DeviceRecord copyWith({
    String? fingerprint,
    String? alias,
    String? deviceType,
    String? model,
    String? lastIp,
    int? lastPort,
    DateTime? lastSeenAt,
    bool? trusted,
    DateTime? pairedAt,
    String? groupCode,
  }) =>
      DeviceRecord(
        fingerprint: fingerprint ?? this.fingerprint,
        alias: alias ?? this.alias,
        deviceType: deviceType ?? this.deviceType,
        model: model ?? this.model,
        lastIp: lastIp ?? this.lastIp,
        lastPort: lastPort ?? this.lastPort,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        trusted: trusted ?? this.trusted,
        pairedAt: pairedAt ?? this.pairedAt,
        groupCode: groupCode ?? this.groupCode,
      );

  @override
  bool operator ==(Object other) =>
      other is DeviceRecord &&
      other.fingerprint == fingerprint &&
      other.alias == alias &&
      other.deviceType == deviceType &&
      other.model == model &&
      other.lastIp == lastIp &&
      other.lastPort == lastPort &&
      other.lastSeenAt == lastSeenAt &&
      other.trusted == trusted &&
      other.pairedAt == pairedAt &&
      other.groupCode == groupCode;

  @override
  int get hashCode => Object.hash(fingerprint, alias, deviceType, model, lastIp,
      lastPort, lastSeenAt, trusted, pairedAt, groupCode);

  @override
  String toString() =>
      'DeviceRecord($fingerprint, $alias, lastPort: $lastPort, '
      'trusted: $trusted)';
}
