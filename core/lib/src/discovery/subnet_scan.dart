/// Fallback discovery: probe every host on the local /24 subnet(s).
library;

import 'dart:io';

import '../net/peer_client.dart';
import '../protocol/constants.dart';
import '../protocol/device_info.dart';

/// Result of a single successful subnet probe.
class ScanResult {
  const ScanResult({
    required this.address,
    required this.info,
    required this.fingerprint,
  });

  /// IP the responder answered from.
  final String address;

  /// The peer's self description.
  final DeviceInfo info;

  /// Fingerprint recorded for this peer, uppercase hex.
  ///
  /// Preferred source is the certificate **actually observed during the TLS
  /// handshake** ([PeerClient.observedFingerprint]); the peer's self-reported
  /// `fingerprint` JSON field is only a fallback for the (rare) case where no
  /// handshake fingerprint was captured. The self-reported value alone is not
  /// trustworthy — a peer could put anything there.
  final String fingerprint;
}

/// Called after each individual probe with its (possibly `null`) result.
typedef ScanProbeCallback = void Function(String address, ScanResult? result);

/// Probes every host on the local /24 subnet(s) with a `POST /register`.
///
/// Because the fingerprint is unknown before the first contact, the probe runs
/// with trust-on-first-use and reports the observed fingerprint in the result
/// so the caller can pin it for the real transfer afterwards.
///
/// Target selection, in precedence order:
///   1. [prefix] — an explicit `a.b.c.` prefix (from `--scan-prefix`);
///   2. [interfaceAddress] — only that address's `/24` (from the chosen
///      multicast egress NIC), so a stray VPN subnet is not scanned;
///   3. otherwise, every local IPv4 `/24` (legacy behaviour).
Future<List<ScanResult>> scanSubnet({
  required DeviceInfo self,
  int port = kDefaultPort,
  String? prefix,
  String? interfaceAddress,
  Duration timeout = const Duration(milliseconds: 700),
  ScanProbeCallback? onProbe,
  void Function(String message)? onLog,
}) async {
  final prefixes = <String>{};
  if (prefix != null) {
    prefixes.add(prefix);
  } else if (interfaceAddress != null) {
    final scoped = _prefixOf(interfaceAddress);
    if (scoped != null) {
      prefixes.add(scoped);
    }
  } else {
    for (final address in await localIpv4Addresses()) {
      final scoped = _prefixOf(address);
      if (scoped != null) {
        prefixes.add(scoped);
      }
    }
  }

  final results = <ScanResult>[];
  for (final currentPrefix in prefixes) {
    onLog?.call('probing ${currentPrefix}1-254 :$port');
    final futures = <Future<void>>[];
    for (var host = 1; host < 255; host++) {
      final address = '$currentPrefix$host';
      futures.add(_probe(address, port, self, timeout, onLog).then((result) {
        onProbe?.call(address, result);
        if (result != null) {
          results.add(result);
        }
      }));
    }
    await Future.wait(futures);
  }
  return results;
}

Future<ScanResult?> _probe(
  String address,
  int port,
  DeviceInfo self,
  Duration timeout,
  void Function(String message)? onLog,
) async {
  final client = PeerClient(
    host: address,
    port: port,
    allowUnknownCertificate: true,
  );
  try {
    final reply = await client.register(self: self).timeout(timeout);
    // Prefer the fingerprint of the certificate we actually saw on the wire.
    // Only fall back to the peer's self-reported value when the handshake did
    // not surface one, and say so, because that value is unauthenticated.
    final observed = client.observedFingerprint;
    if (observed == null) {
      onLog?.call('$address: no TLS-observed fingerprint; falling back to the '
          'peer self-reported value (unverified)');
    }
    return ScanResult(
      address: address,
      info: reply,
      fingerprint: observed ?? reply.fingerprint,
    );
  } on Object {
    return null;
  } finally {
    client.close();
  }
}

/// The `/24` prefix (`a.b.c.`) of [address], or `null` when [address] is not a
/// well-formed dotted-quad IPv4 string.
String? _prefixOf(String address) {
  final parts = address.split('.');
  if (parts.length != 4) {
    return null;
  }
  return '${parts[0]}.${parts[1]}.${parts[2]}.';
}

/// Returns the non-loopback IPv4 addresses of this host.
Future<List<String>> localIpv4Addresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  return [
    for (final interface in interfaces)
      for (final address in interface.addresses) address.address,
  ];
}
