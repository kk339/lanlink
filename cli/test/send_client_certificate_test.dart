import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lanlink_cli/src/commands/send_command.dart';
import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// Regression test for the CLI half of the **client-certificate** interop bug.
///
/// `lanlink send` used to build its `PeerClient` without an identity, so it
/// never presented a client certificate. A receiver that requires one (the
/// official LocalSend app does) aborts the mutual-TLS handshake with
/// `TLSV1_ALERT_CERTIFICATE_REQUIRED` and the send fails. This drives the real
/// `SendCommand.run()` against such a receiver:
///
///   * with the fix (certificate passed) the pinned `prepare-upload` + `upload`
///     exchange completes and `run()` returns `0`;
///   * without it the handshake is rejected and `run()` returns `1`.
///
/// ## Why a raw `SecureServerSocket` and not `HttpServer.bindSecure`
///
/// `HttpServer.bindSecure` exposes only `requestClientCertificate`, which this
/// SDK treats as a *hint*: it accepts requests from a client that sends no
/// certificate, so it cannot express "this peer requires a client certificate"
/// and the test would pass even on the broken code. The only Dart API that
/// *requires* the client to authenticate is
/// `SecureServerSocket.bind(..., requireClientCertificate: true)` — it aborts
/// with `PEER_DID_NOT_RETURN_A_CERTIFICATE`, the same failure class the official
/// app produces. We therefore stand up that socket and answer the two endpoints
/// `send` needs by hand.
///
/// The explicit `--fingerprint` path is used on purpose: it skips the TOFU
/// probe (`_probePeer`, which deliberately dials with no certificate) and goes
/// straight to the pinned `prepare-upload` the fix concerns.
void main() {
  String p(Directory dir, String name) =>
      '${dir.path}${Platform.pathSeparator}$name';

  late Directory root;
  late DeviceCertificate serverCert;
  late DeviceCertificate clientCert;
  late _RequiringReceiver receiver;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lanlink_cli_cert_');
    serverCert = await DeviceCertificate.loadOrCreate(
      directory: Directory(p(root, 'server')),
      commonName: 'receiver',
    );
    // The CLI loads *this* pair when given `--certs <dir>`; the receiver trusts
    // it, so presenting it is what the handshake requires.
    clientCert = await DeviceCertificate.loadOrCreate(
      directory: Directory(p(root, 'cli-certs')),
      commonName: 'cli',
    );
    receiver = await _RequiringReceiver.start(
      serverCert: serverCert,
      trustedClientCert: clientCert,
    );
  });

  tearDown(() async {
    await receiver.stop();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test(
    'lanlink send completes against a receiver that requires a client cert, '
    'presenting the certificate loaded from --certs',
    () async {
      final file = File(p(root, 'payload.txt'));
      await file.writeAsString('hello lanlink');

      final code = await SendCommand(<String, String>{
        'to': '127.0.0.1',
        'port': '${receiver.port}',
        'file': file.path,
        'certs': p(root, 'cli-certs'),
        'fingerprint': serverCert.fingerprint,
      }).run();

      expect(code, 0); // the pinned prepare-upload + upload exchange completed
      // The receiver observed *our* certificate — the exact one loaded from the
      // `--certs` directory — not merely "some" certificate.
      expect(
        receiver.observedClientCertificateFingerprint,
        clientCert.fingerprint,
      );
      expect(receiver.preparedFileIds, hasLength(1));
      expect(receiver.uploadedBytes, greaterThan(0));
    },
  );
}

/// A TLS receiver that **requires** a client certificate, answering just the
/// two endpoints `send` calls: `prepare-upload` and `upload`.
class _RequiringReceiver {
  _RequiringReceiver._(this._server, this._subscription);

  final SecureServerSocket _server;
  final StreamSubscription<SecureSocket> _subscription;

  /// Uppercase-hex SHA-256 of the certificate the peer presented in the
  /// handshake, or `null` when a handshake completed without one.
  String? observedClientCertificateFingerprint;

  /// File ids seen in the last `prepare-upload` body.
  final List<String> preparedFileIds = <String>[];

  /// Total bytes received across `upload` bodies.
  int uploadedBytes = 0;

  int get port => _server.port;

  static Future<_RequiringReceiver> start({
    required DeviceCertificate serverCert,
    required DeviceCertificate trustedClientCert,
  }) async {
    final context = serverCert.toSecurityContext();
    context.setTrustedCertificatesBytes(
        utf8.encode(trustedClientCert.certificatePem));

    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
      requestClientCertificate: true,
      requireClientCertificate: true,
    );
    late final _RequiringReceiver handle;
    final subscription = server.listen(
      (SecureSocket socket) => handle._serve(socket),
      onError: (Object _) {
        // The expected "no certificate" abort arrives here; ignore it.
      },
    );
    handle = _RequiringReceiver._(server, subscription);
    return handle;
  }

  Future<void> _serve(SecureSocket socket) async {
    final peer = socket.peerCertificate;
    if (peer != null) {
      observedClientCertificateFingerprint = sha256HexOfBytes(peer.der);
    }
    final request = await _readRequest(socket);
    final path = request?.path ?? '';
    const contentType = 'application/json';
    String body;
    if (path == kPathPrepare) {
      final decoded = jsonDecode(request!.body) as Map<String, dynamic>;
      final files = (decoded['files'] as Map).cast<String, dynamic>();
      preparedFileIds.addAll(files.keys.cast<String>());
      body = jsonEncode(encodeFrame(kFramePrepareReply, <String, Object?>{
        'session': 'sess-1',
        'tokens': <String, String>{
          for (final id in files.keys) id.toString(): 'tok-$id',
        },
        'received': <String, int>{
          for (final id in files.keys) id.toString(): 0,
        },
      }));
    } else if (path == kPathPut) {
      uploadedBytes += request!.bodyBytes;
      body = jsonEncode(encodeFrame(kFramePutReply, <String, Object?>{
        'received': request.bodyBytes,
      }));
    } else {
      body = jsonEncode(encodeFrame(kFrameError, <String, Object?>{
        'code': 404,
        'message': 'not found',
      }));
    }
    final bytes = utf8.encode(body);
    socket.write('HTTP/1.1 200 OK\r\n'
        'Content-Type: $contentType\r\n'
        'Content-Length: ${bytes.length}\r\n'
        'Connection: close\r\n'
        '\r\n');
    socket.add(bytes);
    await socket.flush();
    await socket.close();
  }

  Future<void> stop() async {
    await _subscription.cancel();
    await _server.close();
  }
}

class _Request {
  _Request(this.path, this.body, this.bodyBytes);

  final String path;
  final String body;
  final int bodyBytes;
}

/// Reads one HTTP/1.1 request (headers + `Content-Length`-sized body) off a raw
/// secure socket. Returns `null` when the stream ends before a full request.
Future<_Request?> _readRequest(SecureSocket socket) async {
  final buffer = <int>[];
  var headerEnd = -1;
  var contentLength = 0;
  await for (final chunk in socket) {
    buffer.addAll(chunk);
    if (headerEnd < 0) {
      final text = String.fromCharCodes(buffer);
      final boundary = text.indexOf('\r\n\r\n');
      if (boundary >= 0) {
        headerEnd = boundary + 4;
        for (final line in text.substring(0, boundary).split('\r\n')) {
          if (line.toLowerCase().startsWith('content-length:')) {
            contentLength = int.tryParse(line.substring(15).trim()) ?? 0;
          }
        }
      }
    }
    if (headerEnd >= 0 && buffer.length >= headerEnd + contentLength) {
      final headerText = String.fromCharCodes(buffer.sublist(0, headerEnd));
      final requestLine = headerText.split('\r\n').first;
      final parts = requestLine.split(' ');
      // Drop any query string: the upload URL is `/upload?sessionId=...`.
      final path = (parts.length >= 2 ? parts[1] : '/').split('?').first;
      final bodyBytes = buffer.sublist(headerEnd, headerEnd + contentLength);
      return _Request(path, utf8.decode(bodyBytes), contentLength);
    }
  }
  return null;
}
