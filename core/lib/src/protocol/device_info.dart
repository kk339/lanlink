/// The peer self-description exchanged on the wire (the `peer` object of a
/// frame, and the body of a UDP announcement).
///
/// The **Dart property names are intentionally kept** (`alias`, `deviceType`,
/// `deviceModel`, `fingerprint`, `download`) so the `cli/` and `app/` sources
/// need no change; only the JSON keys differ (`name / kind / model / fp /
/// accepts`, docs/13 §7.2). The removed wire fields (`version` → frame `v`,
/// `protocol` → fixed HTTPS, `announce` → frame `t`) are no longer serialised.
library;

import 'constants.dart';

/// Device classification sent on the wire (`kind`).
enum DeviceType {
  mobile('mobile'),
  desktop('desktop'),
  web('web'),
  headless('headless'),
  server('server');

  const DeviceType(this.wire);

  /// The exact string used in JSON.
  ///
  /// **Deliberately unchanged** from LocalSend's values: `store`'s
  /// `device_type` column and the app's `deviceKindFromWire` both key off these
  /// strings, so changing them would desync stored history.
  final String wire;

  /// Parses a wire value, defaulting to [DeviceType.desktop] when unknown —
  /// matching the permissive behaviour of the reference implementations.
  static DeviceType parse(Object? value) {
    for (final type in DeviceType.values) {
      if (type.wire == value) {
        return type;
      }
    }
    return DeviceType.desktop;
  }
}

/// Transport scheme announced by a peer.
///
/// Retained for source compatibility: our wire format runs HTTPS only and no
/// longer serialises `protocol`, but `cli/` and `app/` still pass
/// `protocol: ProtocolScheme.https` to the constructor, so the field stays.
enum ProtocolScheme {
  http('http'),
  https('https');

  const ProtocolScheme(this.wire);

  /// The exact string used in JSON.
  final String wire;

  /// Parses a wire value, defaulting to [ProtocolScheme.https].
  static ProtocolScheme parse(Object? value) =>
      value == 'http' ? ProtocolScheme.http : ProtocolScheme.https;
}

/// A peer's self-description (the `peer` object of a frame).
class DeviceInfo {
  const DeviceInfo({
    required this.alias,
    required this.fingerprint,
    required this.port,
    this.deviceModel,
    this.deviceType = DeviceType.desktop,
    this.protocol = ProtocolScheme.https,
    this.download = false,
    this.announce = false,
  });

  /// Human readable device name (e.g. "Alex's laptop"); wire key `name`.
  final String alias;

  /// Optional model string (e.g. "Windows 11"); wire key `model`.
  final String? deviceModel;

  /// Device classification; wire key `kind`.
  final DeviceType deviceType;

  /// SHA-256 hex of the device certificate (authoritative in HTTPS mode);
  /// wire key `fp`.
  final String fingerprint;

  /// TCP port of the peer's HTTP(S) server.
  final int port;

  /// Transport scheme. **Not serialised** in v1 (always HTTPS); kept so callers
  /// that set it still compile.
  final ProtocolScheme protocol;

  /// Whether the peer is willing to receive files; wire key `accepts`.
  final bool download;

  /// Vestigial: the "this is an announcement" flag is now the frame's `t`
  /// (`announce`). Kept so callers that set it still compile; never serialised.
  final bool announce;

  /// Builds a [DeviceInfo] from a decoded frame's `peer` object.
  ///
  /// Every field is optional and falls back to a sane default, so a truncated
  /// or partially-understood payload never throws.
  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    return DeviceInfo(
      alias: (json['name'] as String?) ?? 'Unknown',
      deviceModel: json['model'] as String?,
      deviceType: DeviceType.parse(json['kind']),
      fingerprint: (json['fp'] as String?) ?? '',
      port: (json['port'] as num?)?.toInt() ?? kDefaultPort,
      download: (json['accepts'] as bool?) ?? false,
    );
  }

  /// Serialises this peer to the exact wire JSON shape (no frame header).
  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': alias,
        'kind': deviceType.wire,
        if (deviceModel != null) 'model': deviceModel,
        'fp': fingerprint,
        'port': port,
        'accepts': download,
      };

  /// Returns a copy with the given fields replaced.
  DeviceInfo copyWith({
    String? alias,
    String? deviceModel,
    DeviceType? deviceType,
    String? fingerprint,
    int? port,
    ProtocolScheme? protocol,
    bool? download,
    bool? announce,
  }) {
    return DeviceInfo(
      alias: alias ?? this.alias,
      deviceModel: deviceModel ?? this.deviceModel,
      deviceType: deviceType ?? this.deviceType,
      fingerprint: fingerprint ?? this.fingerprint,
      port: port ?? this.port,
      protocol: protocol ?? this.protocol,
      download: download ?? this.download,
      announce: announce ?? this.announce,
    );
  }

  @override
  String toString() => 'DeviceInfo(alias: $alias, type: ${deviceType.wire}, '
      'port: $port, protocol: ${protocol.wire}, fingerprint: $fingerprint)';
}
