/// The device identity: a self-signed RSA certificate plus its private key.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';

import '../security/fingerprint.dart';

/// A self-signed certificate together with its private key, exposing the
/// certificate fingerprint used for TLS pinning.
///
/// In HTTPS mode the LocalSend fingerprint is defined as the **SHA-256 of the
/// certificate DER**, uppercase hex — exactly what [fingerprint] returns.
class DeviceCertificate {
  DeviceCertificate._({
    required this.certificatePem,
    required this.privateKeyPem,
    required this.certificateDer,
  });

  /// PEM encoded certificate.
  final String certificatePem;

  /// PEM encoded PKCS#8 private key.
  final String privateKeyPem;

  /// Raw DER bytes of the certificate.
  final Uint8List certificateDer;

  /// Uppercase hex SHA-256 of [certificateDer] — the LocalSend fingerprint.
  String get fingerprint => sha256HexOfBytes(certificateDer);

  /// Builds a [SecurityContext] for a TLS server using this certificate.
  SecurityContext toSecurityContext() {
    final context = SecurityContext(withTrustedRoots: false);
    context.useCertificateChainBytes(utf8.encode(certificatePem));
    context.usePrivateKeyBytes(utf8.encode(privateKeyPem));
    return context;
  }

  /// Generates a fresh RSA-2048 self-signed certificate.
  static DeviceCertificate generate({
    String commonName = 'lanlink',
    List<String>? subjectAltNames,
    int days = 3650,
  }) {
    final keyPair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final privateKey = keyPair.privateKey as RSAPrivateKey;
    final publicKey = keyPair.publicKey as RSAPublicKey;

    final attributes = <String, String>{
      'CN': commonName,
      'O': 'lanlink',
    };
    final csr = X509Utils.generateRsaCsrPem(
      attributes,
      privateKey,
      publicKey,
      san: subjectAltNames,
    );
    final certificatePem = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      days,
      sans: subjectAltNames,
    );
    final privateKeyPem = CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);
    final der = CryptoUtils.getBytesFromPEMString(certificatePem);

    return DeviceCertificate._(
      certificatePem: certificatePem,
      privateKeyPem: privateKeyPem,
      certificateDer: der,
    );
  }

  /// Rebuilds a certificate from PEM strings, recomputing the fingerprint from
  /// the DER so a persisted identity stays stable across runs.
  static DeviceCertificate fromPem({
    required String certificatePem,
    required String privateKeyPem,
  }) {
    final der = CryptoUtils.getBytesFromPEMString(certificatePem);
    return DeviceCertificate._(
      certificatePem: certificatePem,
      privateKeyPem: privateKeyPem,
      certificateDer: der,
    );
  }

  /// Loads `cert.pem` / `key.pem` from [directory], generating and persisting a
  /// new pair when they are missing.
  static Future<DeviceCertificate> loadOrCreate({
    required Directory directory,
    String commonName = 'lanlink',
    List<String>? subjectAltNames,
    int days = 3650,
  }) async {
    final separator = Platform.pathSeparator;
    final certificateFile = File('${directory.path}${separator}cert.pem');
    final keyFile = File('${directory.path}${separator}key.pem');
    if (await certificateFile.exists() && await keyFile.exists()) {
      return DeviceCertificate.fromPem(
        certificatePem: await certificateFile.readAsString(),
        privateKeyPem: await keyFile.readAsString(),
      );
    }
    final certificate = DeviceCertificate.generate(
      commonName: commonName,
      subjectAltNames: subjectAltNames,
      days: days,
    );
    await directory.create(recursive: true);
    await certificateFile.writeAsString(certificate.certificatePem);
    await keyFile.writeAsString(certificate.privateKeyPem);
    return certificate;
  }
}
