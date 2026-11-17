/// HTTPS client for the lanlink endpoints, with certificate pinning.
///
/// The Dart method names (`register`, `prepareUpload`, `upload`, `cancel`) are
/// kept from the LocalSend-shaped era so `cli/` and `app/` need no change; only
/// the paths and the JSON frames differ (design `docs/13`).
library;

import 'dart:convert';
import 'dart:io';

import '../identity/device_certificate.dart';
import '../protocol/constants.dart';
import '../protocol/device_info.dart';
import '../protocol/transfer.dart';
import '../security/fingerprint.dart';

/// Thrown when a peer responds with an unexpected status code, or when a frame
/// is rejected (e.g. an identity mismatch, R-SEC-1).
class PeerHttpException implements Exception {
  PeerHttpException(this.statusCode, this.message, [this.body = '']);

  /// HTTP status returned by the peer (or the response's status when the body
  /// was rejected after a `200`).
  final int statusCode;

  /// Human readable description.
  final String message;

  /// Raw response body, when any.
  final String body;

  @override
  String toString() =>
      'PeerHttpException($statusCode): $message${body.isEmpty ? '' : ' - $body'}';
}

/// HTTPS client for the lanlink endpoints.
///
/// Certificate pinning is enforced in HTTPS mode: the client only accepts a
/// peer whose certificate DER SHA-256 equals [expectedFingerprint] (compared
/// case-insensitively). When no fingerprint is known the client fails closed
/// unless [allowUnknownCertificate] is explicitly enabled for a discovery
/// probe (trust-on-first-use).
class PeerClient {
  PeerClient({
    required this.host,
    required this.port,
    this.expectedFingerprint,
    this.scheme = ProtocolScheme.https,
    this.allowUnknownCertificate = false,
    this.certificate,
    this.onCertificateSeen,
    this.onLog,
  }) {
    // Present our own identity as the TLS **client** certificate.
    //
    // LocalSend HTTPS is mutual TLS: the receiver asks for a client certificate
    // and, against a strict peer, a bare `HttpClient()` makes the handshake
    // abort with `TLSV1_ALERT_CERTIFICATE_REQUIRED` because we never sent one.
    // Passing a context that carries our certificate chain + private key makes
    // the handshake complete. When [certificate] is null the context is null
    // too, which keeps the old behaviour (plain HTTP, or a discovery probe that
    // deliberately dials without an identity).
    _client = HttpClient(context: certificate?.toSecurityContext())
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = 'lanlink/0.1'
      ..findProxy = _directProxy;
    if (scheme == ProtocolScheme.https) {
      _client.badCertificateCallback = _verifyPeer;
    }
  }

  /// LAN traffic must never be routed through a proxy.
  ///
  /// dart:io's [HttpClient] default honours `http_proxy` / `https_proxy` from
  /// the environment. For a LAN transfer that is wrong twice over: the file
  /// would be silently relayed through a third party (this project's hard
  /// constraint is no third-party relay), and when the proxy cannot reach a
  /// private address the failure surfaces as a misleading
  /// "Proxy failed to establish tunnel (502 Bad Gateway)" instead of a plain
  /// connection error.
  static String _directProxy(Uri uri) => 'DIRECT';

  /// Peer host (IP or name).
  final String host;

  /// Peer TCP port.
  final int port;

  /// Expected certificate fingerprint (compared case-insensitively).
  final String? expectedFingerprint;

  /// Transport scheme.
  final ProtocolScheme scheme;

  /// When true, an unknown certificate is accepted and its fingerprint is
  /// reported via [onCertificateSeen] (trust-on-first-use). Only meant for the
  /// subnet-scan bootstrap, never for a real transfer.
  final bool allowUnknownCertificate;

  /// Our own TLS identity, presented to the peer as the **client** certificate.
  ///
  /// Real transfers and the post-discovery `register` back-dial must pass the
  /// local identity here; only the subnet-scan probe leaves it `null` on purpose
  /// (it dials strangers it has not authenticated yet).
  final DeviceCertificate? certificate;

  /// Invoked with the observed fingerprint before the accept/reject decision.
  final void Function(String actualFingerprint)? onCertificateSeen;

  /// Optional diagnostic sink. When `null` the client stays silent.
  final void Function(String message)? onLog;

  late final HttpClient _client;

  /// Whether the last TLS handshake was pinned (as opposed to TOFU-accepted).
  bool pinnedAccept = false;

  String? _observedFingerprint;

  /// SHA-256 of the certificate DER **actually presented during the last TLS
  /// handshake**, uppercase hex, or `null` when no handshake has happened yet
  /// (or the scheme is plain HTTP).
  ///
  /// This is the trustworthy value: it is computed from the peer's real
  /// certificate, so it cannot be spoofed the way a self-reported JSON
  /// fingerprint field can. It is recorded even when [allowUnknownCertificate]
  /// is `true` (trust-on-first-use), which is exactly the subnet-scan bootstrap
  /// case.
  String? get observedFingerprint => _observedFingerprint;

  bool _verifyPeer(X509Certificate certificate, String peerHost, int peerPort) {
    final actual = sha256HexOfBytes(certificate.der);
    _observedFingerprint = actual;
    onCertificateSeen?.call(actual);

    final expected = expectedFingerprint;
    if (expected == null || normalizeFingerprint(expected).isEmpty) {
      if (allowUnknownCertificate) {
        _log('TOFU accept (no expected fingerprint): $actual');
        return true;
      }
      _log('REJECT $host:$port - no expected fingerprint (failing closed); '
          'peer presented $actual');
      return false;
    }

    if (!fingerprintsEqual(expected, actual)) {
      _log('REJECT $host:$port - fingerprint mismatch\n'
          '      expected = ${normalizeFingerprint(expected)}\n'
          '      actual   = $actual');
      return false;
    }

    pinnedAccept = true;
    _log('PIN OK $host:$port -> $actual');
    return true;
  }

  /// R-SEC-1 (docs/13 §5.2): the identity a peer *claims* inside a frame must
  /// equal the identity of the certificate it actually presented in the TLS
  /// handshake.
  ///
  /// The frame's `peer.fp` is only a claim; [observedFingerprint] is measured
  /// from the real certificate. When the two disagree the peer is lying about
  /// who it is, so the response is rejected.
  void _enforceFrameIdentity(DeviceInfo peer) {
    final observed = _observedFingerprint;
    if (observed == null || peer.fingerprint.isEmpty) {
      return;
    }
    if (!fingerprintsEqual(peer.fingerprint, observed)) {
      throw PeerHttpException(
        HttpStatus.ok,
        'peer identity mismatch (R-SEC-1): frame fp=${peer.fingerprint} != '
        'TLS-observed $observed',
      );
    }
  }

  Uri _uri(String path, [Map<String, String>? query]) => Uri(
        scheme: scheme.wire,
        host: host,
        port: port,
        path: path,
        queryParameters: query,
      );

  /// `POST /api/lanlink/v1/hello` — announces [self] and returns the peer.
  ///
  /// Enforces R-SEC-1: the reply's `peer.fp` must equal the fingerprint observed
  /// during the TLS handshake.
  Future<DeviceInfo> register({required DeviceInfo self}) async {
    final request = await _client.postUrl(_uri(kPathHello));
    _writeJson(
      request,
      encodeFrame(kFrameHello, <String, dynamic>{'peer': self.toJson()}),
    );
    final response = await request.close();
    final body = await _readAll(response);
    if (response.statusCode != HttpStatus.ok) {
      throw PeerHttpException(response.statusCode, 'hello failed', body);
    }
    final map = _decodeObject(body, response.statusCode, 'hello');
    requireFrameTypeIs(map, kFrameHelloReply);
    final peer = peerOf(map);
    _enforceFrameIdentity(peer);
    return peer;
  }

  /// `POST /api/lanlink/v1/prepare` — declares [files] and returns the
  /// receiver's per-file upload tokens.
  ///
  /// [folder] groups the declared files into one folder message
  /// (`docs/22` §1.1); each file's own position inside it travels in
  /// [FileMetadata.relativePath]. Both are **optional wire keys**, so leaving
  /// them out sends exactly the pre-0.2.38 frame and a 0.2.37 receiver ignores
  /// them when they are present.
  ///
  /// A `204 No Content` reply means the receiver has nothing to accept and is
  /// surfaced as a [PrepareUploadResponse.isEmpty] response. Any other non-`200`
  /// status throws a [PeerHttpException] carrying the code, e.g. `403` when the
  /// receiver has uploads disabled, `413` when a file exceeds the receiver's
  /// size limit, `503` when its session cap is reached, or `400` when a declared
  /// relative path is not one the receiver is willing to write to.
  Future<PrepareUploadResponse> prepareUpload({
    required DeviceInfo self,
    required List<FileMetadata> files,
    String? pin,
    FolderDescriptor? folder,
  }) async {
    final payload = PrepareUploadRequest(
      info: self,
      files: <String, FileMetadata>{for (final file in files) file.id: file},
      pin: pin,
      folder: folder,
    );
    final request = await _client.postUrl(_uri(kPathPrepare));
    _writeJson(request, payload.toJson());
    final response = await request.close();
    final body = await _readAll(response);
    if (response.statusCode == HttpStatus.noContent) {
      return const PrepareUploadResponse(
          sessionId: '', files: <String, String>{});
    }
    if (response.statusCode != HttpStatus.ok) {
      throw PeerHttpException(response.statusCode, 'prepare failed', body);
    }
    final map = _decodeObject(body, response.statusCode, 'prepare');
    requireFrameTypeIs(map, kFramePrepareReply);
    return PrepareUploadResponse.fromJson(map);
  }

  /// `POST /api/lanlink/v1/put?session=&file=&token=[&offset=]` — streams [file]
  /// as a raw binary body without buffering it in memory.
  ///
  /// Returns the number of bytes sent. Throws [PeerHttpException] on any
  /// non-`200` status, e.g. `403` for an unknown session/token, `409` when the
  /// file was already uploaded, or `413` when it exceeds the receiver's limit.
  ///
  /// [onProgress] is called with the bytes sent so far **while the body
  /// streams**, throttled to one call per [kUploadProgressStepBytes] (plus a
  /// final call at the size) — enough for a live percentage, cheap enough not to
  /// slow the transfer. Callbacks are synchronous; keep them cheap.
  Future<int> upload({
    required String sessionId,
    required String fileId,
    required String token,
    required File file,
    int offset = 0,
    void Function(int bytesSent)? onProgress,
  }) async {
    final length = await file.length();
    final request = await _client.postUrl(_uri(kPathPut, <String, String>{
      'session': sessionId,
      'file': fileId,
      'token': token,
      if (offset > 0) 'offset': '$offset',
    }));
    request.headers.contentType = ContentType.binary;
    request.contentLength = length;
    // `openRead` yields the file in chunks, so a large file never lands in
    // memory as one buffer. Counting on the way through costs a comparison per
    // chunk, so progress reporting cannot slow the link down.
    var sent = 0;
    var reportedAt = 0;
    await request.addStream(file.openRead().map((List<int> chunk) {
      sent += chunk.length;
      final report = onProgress;
      if (report != null && sent - reportedAt >= kUploadProgressStepBytes) {
        reportedAt = sent;
        report(sent);
      }
      return chunk;
    }));
    final response = await request.close();
    final body = await _readAll(response);
    if (response.statusCode != HttpStatus.ok) {
      throw PeerHttpException(response.statusCode, 'put failed', body);
    }
    // The final call always lands, so a finished upload reads 100% even when the
    // size is below one step.
    onProgress?.call(length);
    return length;
  }

  /// `POST /api/lanlink/v1/text` — sends a native text message.
  ///
  /// [id] is a sender-generated nonce the receiver uses for idempotent
  /// de-duplication. Throws [PeerHttpException] on any non-`200` status, e.g.
  /// `403` when the receiver has receiving disabled, or `413` when the body
  /// exceeds the receiver's text limit.
  Future<void> sendText({
    required DeviceInfo self,
    required String id,
    required String text,
  }) async {
    final frame = TextMessage(peer: self, id: id, text: text);
    final request = await _client.postUrl(_uri(kPathText));
    _writeJson(request, frame.toJson());
    final response = await request.close();
    final body = await _readAll(response);
    if (response.statusCode != HttpStatus.ok) {
      throw PeerHttpException(response.statusCode, 'text failed', body);
    }
  }

  /// `POST /api/lanlink/v1/cancel?session=` — abandons an in-flight session.
  ///
  /// The server always answers `200`; matching that keeps the call idempotent
  /// and never throws.
  Future<void> cancel({required String sessionId}) async {
    final request = await _client
        .postUrl(_uri(kPathCancel, <String, String>{'session': sessionId}));
    request.contentLength = 0;
    final response = await request.close();
    await _readAll(response);
  }

  /// `GET /api/lanlink/v1/resume?session=&file=` — returns the bytes the
  /// receiver already holds for [fileId].
  ///
  /// **Reserved (docs/13 §3):** the V1 server answers `501 Not Implemented`, so
  /// this throws a [PeerHttpException] today and is not called by the product
  /// yet.
  Future<int> resume({
    required String sessionId,
    required String fileId,
  }) async {
    final request = await _client.getUrl(_uri(kPathResume, <String, String>{
      'session': sessionId,
      'file': fileId,
    }));
    final response = await request.close();
    final body = await _readAll(response);
    if (response.statusCode != HttpStatus.ok) {
      throw PeerHttpException(response.statusCode, 'resume failed', body);
    }
    final map = _decodeObject(body, response.statusCode, 'resume');
    requireFrameTypeIs(map, kFrameResumeReply);
    final raw = map['offset'];
    return raw is num ? raw.toInt() : 0;
  }

  /// Closes the underlying client and its connections.
  void close() {
    _client.close(force: true);
  }

  Map<String, dynamic> _decodeObject(String body, int status, String label) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw PeerHttpException(status, '$label returned invalid JSON', body);
    }
    if (decoded is! Map) {
      throw PeerHttpException(
          status, '$label returned a non-object body', body);
    }
    return Map<String, dynamic>.from(decoded);
  }

  void _writeJson(HttpClientRequest request, Object body) {
    final bytes = utf8.encode(jsonEncode(body));
    request.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.contentLength = bytes.length;
    request.add(bytes);
  }

  Future<String> _readAll(HttpClientResponse response) =>
      utf8.decoder.bind(response).join();

  void _log(String message) {
    onLog?.call(message);
  }
}
