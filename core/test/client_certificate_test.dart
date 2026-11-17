import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// Regression test for the real-device interop bug:
/// **our client never presented a client certificate**.
///
/// LocalSend's HTTPS mode is mutual TLS. A strict peer (the official app)
/// requests a client certificate during the handshake and aborts when it
/// receives none, surfacing as `TLSV1_ALERT_CERTIFICATE_REQUIRED` on the wire.
/// Our `PeerClient` used a bare `HttpClient()` with no `SecurityContext`, so it
/// always failed that handshake. The fix passes the device identity in as the
/// client certificate (`PeerClient(certificate: ...)`).
///
/// ## Why a raw `SecureServerSocket` and not `HttpServer.bindSecure`
///
/// `HttpServer.bindSecure` exposes only `requestClientCertificate`, which the
/// current SDK treats as a *hint*: measured on this Windows SDK it accepts a
/// request from a client that sends **no** certificate (`200 OK`), so it cannot
/// express "this peer requires a client certificate" and therefore cannot fail
/// before the fix. The only Dart API that *requires* the client to authenticate
/// is `SecureServerSocket.bind(..., requireClientCertificate: true)`; it aborts
/// the handshake with `PEER_DID_NOT_RETURN_A_CERTIFICATE` — the exact failure
/// class the official app triggers. We therefore stand up that server and speak
/// the single `hello` exchange by hand.
void main() {
  String p(Directory dir, String name) =>
      '${dir.path}${Platform.pathSeparator}$name';

  late Directory root;
  late DeviceCertificate serverCert;
  late DeviceCertificate clientCert;
  late DeviceInfo self;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('lanlink_clientcert_');
    // One RSA pair per role, generated once (key generation is slow).
    serverCert = await DeviceCertificate.loadOrCreate(
      directory: Directory(p(root, 'server-cert')),
    );
    clientCert = await DeviceCertificate.loadOrCreate(
      directory: Directory(p(root, 'client-cert')),
      commonName: 'dialer',
    );
    self = DeviceInfo(
      alias: 'Dialer',
      fingerprint: clientCert.fingerprint,
      port: 0,
    );
  });

  tearDownAll(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test(
    'the client presents its certificate to a peer that requires one, '
    'and the handshake fails when it does not',
    () async {
      final requiring = await _RequiringPeerServer.start(
        serverCert: serverCert,
        // The server must trust the dialer's self-signed cert to verify it.
        trustedClientCert: clientCert,
        replyAlias: 'Requiring',
      );
      addTearDown(requiring.stop);

      // (1) With an identity supplied the mutual-TLS handshake succeeds and the
      //     `register` exchange completes — this is the fixed path.
      final withCert = PeerClient(
        host: '127.0.0.1',
        port: requiring.port,
        expectedFingerprint: serverCert.fingerprint,
        certificate: clientCert,
      );
      addTearDown(withCert.close);
      final peer = await withCert.register(self: self);
      expect(peer.alias, 'Requiring'); // the reply body was parsed
      expect(requiring.sawClientCertificate, isTrue); // the server saw our cert

      // (2) Without an identity the very same server aborts the handshake
      //     (`PEER_DID_NOT_RETURN_A_CERTIFICATE`), reproducing the pre-fix bug.
      final withoutCert = PeerClient(
        host: '127.0.0.1',
        port: requiring.port,
        expectedFingerprint: serverCert.fingerprint,
      );
      addTearDown(withoutCert.close);
      await expectLater(
        withoutCert.register(self: self),
        throwsA(isA<Exception>()),
      );
    },
  );
}

/// A TLS peer that **requires** a client certificate, speaking just enough
/// HTTP/1.1 to answer one `hello` request with a `hello.reply` frame.
///
/// Implemented on a raw [SecureServerSocket] (not [HttpServer]) because only
/// that API can require the client to authenticate — see the file doc-comment.
class _RequiringPeerServer {
  _RequiringPeerServer._(this._server, this._subscription, this._serverCert);

  final SecureServerSocket _server;
  final StreamSubscription<SecureSocket> _subscription;
  final DeviceCertificate _serverCert;

  /// Whether the last completed handshake carried a client certificate.
  bool sawClientCertificate = false;

  /// The actual TCP port the OS assigned.
  int get port => _server.port;

  static Future<_RequiringPeerServer> start({
    required DeviceCertificate serverCert,
    required DeviceCertificate trustedClientCert,
    required String replyAlias,
  }) async {
    final context = serverCert.toSecurityContext();
    // Trust exactly the dialer's cert so the server can verify it; combined
    // with `requireClientCertificate: true` this rejects everyone else.
    context.setTrustedCertificatesBytes(
        utf8.encode(trustedClientCert.certificatePem));

    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
      requestClientCertificate: true,
      requireClientCertificate: true,
    );
    late final _RequiringPeerServer handle;
    final subscription = server.listen(
      (SecureSocket socket) => handle._serve(socket, replyAlias),
      onError: (Object _) {
        // The expected "no certificate" abort arrives here; ignore it.
      },
    );
    handle = _RequiringPeerServer._(server, subscription, serverCert);
    return handle;
  }

  Future<void> _serve(SecureSocket socket, String replyAlias) async {
    if (socket.peerCertificate != null) {
      sawClientCertificate = true;
    }
    await _drainRequest(socket);
    final body = jsonEncode(encodeFrame(kFrameHelloReply, <String, dynamic>{
      'peer': DeviceInfo(
        alias: replyAlias,
        fingerprint: _serverCert.fingerprint,
        port: port,
      ).toJson(),
    }));
    final bytes = utf8.encode(body);
    socket.write('HTTP/1.1 200 OK\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: ${bytes.length}\r\n'
        'Connection: close\r\n'
        '\r\n');
    socket.add(bytes);
    await socket.flush();
    await socket.close();
  }

  /// Reads from [socket] until the full HTTP request (headers + body, sized by
  /// `Content-Length`) has arrived.
  Future<void> _drainRequest(SecureSocket socket) async {
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
        return;
      }
    }
  }

  Future<void> stop() async {
    await _subscription.cancel();
    await _server.close();
  }
}
