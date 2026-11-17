/// UDP multicast announcement payload encapsulation.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../protocol/constants.dart';
import '../protocol/device_info.dart';
import '../protocol/transfer.dart';

/// A discovery announcement: a `{v, t:"announce", peer:{…}}` frame.
///
/// Encapsulating encode/decode in one place keeps the "this is an announcement,
/// not a `hello` body" rule in a single spot. The frame type (`t == "announce"`)
/// replaces the old `announce: true` body flag, and — unlike a `hello` — an
/// announcement does not advertise willingness to receive files.
class Announcement {
  const Announcement(this.info);

  /// The announced device description.
  final DeviceInfo info;

  /// Wraps [info] as an announcement.
  factory Announcement.of(DeviceInfo info) =>
      Announcement(info.copyWith(announce: true, download: false));

  /// Builds an announcement from a decoded frame.
  factory Announcement.fromJson(Map<String, dynamic> json) =>
      Announcement(peerOf(json));

  /// The wire JSON shape (frame header included).
  Map<String, dynamic> toJson() =>
      encodeFrame(kFrameAnnounce, <String, dynamic>{'peer': info.toJson()});

  /// UTF-8 JSON bytes ready to be sent on the wire.
  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  /// Decodes a datagram, returning `null` when it is not a valid announcement.
  ///
  /// A datagram is rejected when it is not valid UTF-8 JSON, is not a JSON
  /// object, does not carry a valid frame header (`v == 1`), or is not an
  /// `announce` frame (e.g. a `hello` body).
  static Announcement? tryDecode(List<int> datagram) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(datagram));
    } on FormatException {
      return null;
    }
    if (decoded is! Map) {
      return null;
    }
    final json = Map<String, dynamic>.from(decoded);
    try {
      if (requireFrameType(json) != kFrameAnnounce) {
        return null;
      }
      return Announcement(peerOf(json));
    } on FormatException {
      return null;
    }
  }
}
