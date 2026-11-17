/// HTTPS server implementing the lanlink endpoints:
/// `POST /hello`, `GET /info`, `POST /text`, `POST /prepare`, `POST /put`,
/// `GET /resume` (reserved, `501`), `POST /cancel` (design `docs/13`).
///
/// Receiving is **opt-in**: with [PeerServer.acceptUploads] left `false` both
/// `prepare` and `text` are answered `403`, so a device that is only discovering
/// peers never exposes a write path. See [PeerServer] for the size, session-cap
/// and hash-verification rules.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../identity/device_certificate.dart';
import '../protocol/constants.dart';
import '../protocol/device_info.dart';
import '../protocol/transfer.dart';
import '../security/file_name.dart';
import '../security/fingerprint.dart';
import '../security/hash_worker.dart';
import '../security/isolate_hasher.dart';
import '../security/relative_path.dart';
import 'upload_stats.dart';

/// Called for every `hello` request received from a peer.
///
/// [remoteAddress] is the caller's IP as observed on the socket, which the
/// registry uses to remember where the peer lives.
typedef PeerSeenCallback = void Function(DeviceInfo peer, String remoteAddress);

/// Called once a file has been fully received and verified.
typedef UploadFinishedCallback = void Function(ReceivedFile file);

/// Why this receiver refused an inbound request.
///
/// Feeds the receiver's **own** UI trace. A refusal happens before any database
/// write, so the store holds no record of it: the sender sees "对方拒绝了请求"
/// while we would otherwise stay silent.
enum UploadRejectReason {
  /// The receiver is not accepting uploads (the P0-7 default is off).
  acceptingDisabled,

  /// A declared file or text body exceeds the receiver's limit.
  tooLarge,

  /// The concurrent-session cap is reached.
  sessionCapReached,

  /// The request was malformed, or its body could not be parsed.
  badRequest,

  /// No open session for the given id, or a mismatched upload token.
  unauthorized,
}

/// Called when this receiver refuses an inbound request, so the local UI can
/// make the refusal visible.
///
/// [peer] is the sender resolved from the hello table by socket address, or
/// `null` when it cannot be identified. The sender's alias is deliberately
/// **not** read from the refused request body: parsing the body of a request we
/// are about to refuse would widen the untrusted-input surface of a refusal just
/// to display a name — not worth it.
typedef UploadRejectedCallback = void Function(
  DeviceInfo? peer,
  UploadRejectReason reason,
);

/// Called when this receiver has validated and accepted a native text frame
/// (docs/13 §7.3), so the host app can persist it.
///
/// [sender] is the frame's `peer`; [message] is the decoded frame, whose `id`
/// is the sender's nonce — the value the receiver stores as its `event_nonce`
/// for idempotent de-duplication.
typedef TextReceivedCallback = void Function(
  DeviceInfo sender,
  TextMessage message,
);

/// How many bytes of an upload stream pass between two "this peer is alive"
/// reports to [PeerServer.onPeerSeen].
///
/// The registry's only other liveness source is the peer's 5s UDP
/// announcement; a long, purely-TCP transfer would otherwise let a healthy peer
/// time out as offline after `PeerRegistry.offlineAfter` (30s) and flip the UI
/// to 离线 mid-transfer. 8 MiB keeps the refresh far below that even on a slow
/// link, while costing one cheap `touch` per 8 MiB.
const int _kPeerTouchEveryBytes = 8 * 1024 * 1024;

/// How often the receive loop emits a `recv rate:` line (0.2.17), in
/// microseconds.
///
/// 1 Hz is the same cadence as the sender's `upload rate:` line, so the two logs
/// of a single transfer can be laid side by side: 1 s of phone log against 1 s of
/// PC log. Anything slower would miss the *shape* of a decaying curve, which is
/// the whole point of logging a rate rather than only a total.
const int _kRecvRateLogEveryMicros = 1000 * 1000;


/// How long an idle upload session is kept before a later `prepare` reclaims it
/// (0.2.41).
///
/// **Why a sweep at all.** `_sessions` used to only ever grow — `/cancel` was
/// the single deletion point — while `maxSessions` (64) refused everything past
/// it with `503`. `/prepare` needs no pairing and no prior `hello`, so *any* host
/// on the LAN could send 64 one-file prepares, upload nothing, and leave every
/// legitimate sender refused until the receiver was restarted.
///
/// **Why 120 s and not 60.** A folder send is one session held for the whole
/// batch, and a person on the other end may take a moment between files
/// ("received it, now send the next"). 120 s is roomy enough for that, and short
/// enough that 64 abandoned prepares stop mattering within two minutes.
///
/// The sweep also requires `activeUploads == 0`, so this is the *idle* timeout:
/// a single large upload can legitimately run for minutes with no new request
/// starting, and killing its session mid-stream would break the batch.
const Duration kSessionIdleTimeout = Duration(seconds: 120);

/// A minimal but faithful lanlink HTTPS server for discovery and transfer.
class PeerServer {
  PeerServer({
    required this.alias,
    required this.certificates,
    this.saveDirectory,
    this.acceptUploads = false,
    this.maxUploadBytes = kDefaultMaxUploadBytes,
    this.maxSessions = kDefaultMaxSessions,
    this.deviceType = DeviceType.desktop,
    this.deviceModel,
    this.port = kDefaultPort,
    this.onPeerSeen,
    this.onUploadFinished,
    this.onUploadRejected,
    this.onTextReceived,
    this.onLog,
    this.hashWorkerSpawner,
    this.beforeResolveTarget,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The clock every session-timeout decision reads (0.2.41).
  ///
  /// Injectable for the same reason as `EventLoopWatchdog`'s: the idle sweep is
  /// a *time* rule, and a test that has to wait two real minutes for it will not
  /// be run. Production passes nothing and gets [DateTime.now].
  final DateTime Function() _now;

  /// Name shown to peers.
  final String alias;

  /// Certificate + private key; also the source of the fingerprint.
  final DeviceCertificate certificates;

  /// Directory received files are written to. Required only when
  /// [acceptUploads] is `true`; when it is `null` an upload is answered `500`.
  final Directory? saveDirectory;

  /// Whether this device accepts incoming files and text.
  ///
  /// Defaults to `false` (an earlier revision accepted unconditionally) so
  /// merely running discovery never opens a write path. When `false`,
  /// `prepare` and `text` are answered `403 Forbidden`.
  final bool acceptUploads;

  /// Maximum accepted file size in bytes; a larger declared file is answered
  /// `413 Payload Too Large`. Defaults to 10 GiB.
  final int maxUploadBytes;

  /// Maximum number of concurrent upload sessions; once reached, a new
  /// `prepare` is answered `503 Service Unavailable`. Bounds memory use.
  final int maxSessions;

  /// Device classification announced to peers.
  final DeviceType deviceType;

  /// Optional model string announced to peers.
  final String? deviceModel;

  /// Requested TCP port (`0` lets the OS pick one).
  final int port;

  /// Invoked whenever a peer completes the `hello` handshake with this server.
  final PeerSeenCallback? onPeerSeen;

  /// Invoked once an upload completes and its hash has been verified.
  final UploadFinishedCallback? onUploadFinished;

  /// Invoked whenever this receiver refuses an inbound request, so the local UI
  /// can surface a trace (the sender otherwise fails silently on our side).
  ///
  /// Same form as [onPeerSeen] / [onUploadFinished] / [onLog]: this layer speaks
  /// callbacks; the app layer turns it into a stream.
  final UploadRejectedCallback? onUploadRejected;

  /// Invoked once a native text frame has been validated and accepted, so the
  /// host app can write the `messages` row (docs/13 §7.3).
  ///
  /// Same form as [onUploadFinished] / [onUploadRejected]: this layer speaks
  /// callbacks; the app layer turns it into a stream.
  final TextReceivedCallback? onTextReceived;

  /// Optional diagnostic sink. When `null` the server stays silent.
  final void Function(String message)? onLog;

  /// Test/benchmark seam for the receive path's hashing worker (0.2.16).
  ///
  /// `null` — the default and the only value production passes — spawns the real
  /// `lanlink-hash-worker` isolate. Injecting a factory that throws forces
  /// [IsolateHasher]'s inline fallback, which is how the test suite and the
  /// `E:\tmp\perf` harness A/B "hash on a worker" against "hash on the receiving
  /// isolate" through the *real* server, with no production toggle to forget.
  final HashWorkerSpawner? hashWorkerSpawner;

  /// Test seam (CR-2 ④): awaited for an authorised `/put` **after** the session
  /// has been marked busy and **before** its landing directory is resolved.
  ///
  /// Production passes nothing. It exists because the race this pins down needs
  /// [_resolveTarget] — a `create(recursive:)` plus an `exists()` loop — to take
  /// longer than [kSessionIdleTimeout], which on a slow external disk or an SMB
  /// mount is a real thing and in a test is not reachable by waiting.
  ///
  /// Same form and same reasoning as [hashWorkerSpawner]: a seam in the receive
  /// path that the test suite can hold, rather than a production toggle someone
  /// forgets to switch back.
  final Future<void> Function(String sessionId, String fileId)?
      beforeResolveTarget;

  final Random _random = Random.secure();
  HttpServer? _server;

  /// Open upload sessions, keyed by session id.
  final Map<String, _UploadSession> _sessions = <String, _UploadSession>{};

  /// Peers that have completed the `hello` handshake, keyed by normalised
  /// fingerprint. Kept for diagnostics; the authoritative store is the
  /// [PeerRegistry].
  final Map<String, DeviceInfo> knownPeers = <String, DeviceInfo>{};

  /// Recent hello hits keyed by socket address, so a refused request can name
  /// its sender and so the in-session identity (R-SEC-2) can be checked. A
  /// sender hellos just before it prepares, and `/hello` is independent of
  /// [acceptUploads], so this works even while receiving is off. Best-effort: an
  /// address may be absent, in which case the refusal reports a `null` peer.
  final Map<String, DeviceInfo> _peersByAddress = <String, DeviceInfo>{};

  /// The number of sessions currently held open (diagnostics/tests).
  int get openSessionCount => _sessions.length;

  /// Certificate fingerprint (uppercase hex SHA-256 of the DER).
  String get fingerprint => certificates.fingerprint;

  /// Self description advertised over the wire.
  DeviceInfo get deviceInfo => DeviceInfo(
        alias: alias,
        fingerprint: fingerprint,
        port: actualPort,
        deviceType: deviceType,
        deviceModel: deviceModel,
        protocol: ProtocolScheme.https,
        download: acceptUploads,
        announce: false,
      );

  /// The port the server actually bound to (useful when [port] was `0`).
  int get actualPort => _server?.port ?? port;

  /// Binds the TLS server and starts listening.
  Future<void> start() async {
    final context = certificates.toSecurityContext();
    final server = await HttpServer.bindSecure(
      InternetAddress.anyIPv4,
      port,
      context,
    );
    _server = server;
    server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object error) => _log('socket error: $error'),
    );
    _log('listening on ${server.port}');
  }

  /// Stops accepting connections.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    _log('${request.method} $path');
    try {
      if (path == kPathHello && request.method == 'POST') {
        await _handleRegister(request);
      } else if (path == kPathText && request.method == 'POST') {
        await _handleText(request);
      } else if (path == kPathPrepare && request.method == 'POST') {
        await _handlePrepareUpload(request);
      } else if (path == kPathPut && request.method == 'POST') {
        await _handleUpload(request);
      } else if (path == kPathResume && request.method == 'GET') {
        _handleResume(request);
      } else if (path == kPathCancel && request.method == 'POST') {
        await _handleCancel(request);
      } else if (path == kPathInfo) {
        _writeJson(
          request,
          HttpStatus.ok,
          encodeFrame(
            kFrameHelloReply,
            <String, dynamic>{'peer': deviceInfo.toJson()},
          ),
        );
      } else {
        _writeError(request, HttpStatus.notFound, 'unknown path: $path');
      }
    } catch (error, stack) {
      _log('handler error: $error\n$stack');
      _writeError(request, HttpStatus.internalServerError, '$error');
    }
  }

  /// `POST /hello` — the discovery handshake (`hello` frame in, `hello.reply`
  /// out). Not gated by [acceptUploads].
  Future<void> _handleRegister(HttpRequest request) async {
    final body = await _readJsonBody(request);
    if (body == null) {
      _writeError(request, HttpStatus.badRequest, 'missing or invalid body');
      return;
    }
    final DeviceInfo info;
    try {
      requireFrameTypeIs(body, kFrameHello);
      info = peerOf(body);
    } on FormatException catch (error) {
      _log('hello malformed: ${error.message}');
      _writeError(request, HttpStatus.badRequest, 'malformed hello frame');
      return;
    }

    // SECURITY (docs/13 §5.1, R-SEC-4) — the KDE "device id changed between two
    // packets" class: an address must not change the identity it claims. We see
    // only the HTTP side here (the UDP announce is handled elsewhere), so this
    // enforces "stable identity per source address" across successive hellos.
    final remoteAddress = request.connectionInfo?.remoteAddress.address ?? '';
    final previous =
        remoteAddress.isEmpty ? null : _peersByAddress[remoteAddress];
    if (previous != null &&
        previous.fingerprint.isNotEmpty &&
        info.fingerprint.isNotEmpty &&
        !fingerprintsEqual(previous.fingerprint, info.fingerprint)) {
      _log('hello rejected (R-SEC-4): $remoteAddress was '
          '${previous.fingerprint} but now claims ${info.fingerprint}');
      _writeError(request, HttpStatus.forbidden, 'identity changed');
      return;
    }

    if (info.fingerprint.isNotEmpty) {
      knownPeers[normalizeFingerprint(info.fingerprint)] = info;
    }
    if (remoteAddress.isNotEmpty) {
      // Remember who is at this address so a later refusal can name the sender
      // (P0-7 follow-up: `/hello` is not gated by [acceptUploads]).
      _peersByAddress[remoteAddress] = info;
    }
    onPeerSeen?.call(info, remoteAddress);
    _writeJson(
      request,
      HttpStatus.ok,
      encodeFrame(
        kFrameHelloReply,
        <String, dynamic>{'peer': deviceInfo.toJson()},
      ),
    );
  }

  /// `POST /text` — a native text message. `403` when receiving is off, `413`
  /// when the body exceeds [kMaxTextBytes], `400` when malformed.
  Future<void> _handleText(HttpRequest request) async {
    if (!acceptUploads) {
      _log('text refused: acceptUploads is disabled');
      await _reject(
        request,
        HttpStatus.forbidden,
        UploadRejectReason.acceptingDisabled,
      );
      return;
    }
    final body = await _readJsonBody(request);
    if (body == null) {
      await _reject(
          request, HttpStatus.badRequest, UploadRejectReason.badRequest);
      return;
    }
    final TextMessage message;
    try {
      requireFrameTypeIs(body, kFrameText);
      message = TextMessage.fromJson(body);
    } on FormatException catch (error) {
      _log('text malformed: ${error.message}');
      _reportRejected(request, UploadRejectReason.badRequest);
      _writeError(request, HttpStatus.badRequest, 'malformed text frame');
      return;
    }
    if (_identityMismatch(request, message.peer)) {
      _writeError(request, HttpStatus.forbidden, 'identity mismatch');
      return;
    }
    // A frame we could authenticate proves the sender is alive and reachable,
    // even when we go on to refuse it (docs/13 §4 keep-alive): refresh its
    // registry entry before the size check.
    _touchPeer(request, message.peer);
    if (utf8.encode(message.text).length > kMaxTextBytes) {
      _log('text refused: body exceeds kMaxTextBytes=$kMaxTextBytes');
      _reportRejected(request, UploadRejectReason.tooLarge);
      _writeError(request, HttpStatus.requestEntityTooLarge, 'text too large');
      return;
    }

    // Hand the accepted frame to the host app before acknowledging, so its
    // `messages` row is written on the same success path the ack reports.
    _log('TEXT received from ${message.peer.alias} id=${message.id} '
        '${message.text.length} chars');
    onTextReceived?.call(message.peer, message);
    _writeJson(
      request,
      HttpStatus.ok,
      encodeFrame(kFrameAck, <String, dynamic>{}),
    );
  }

  Future<void> _handlePrepareUpload(HttpRequest request) async {
    if (!acceptUploads) {
      _log('prepare refused: acceptUploads is disabled');
      await _reject(
        request,
        HttpStatus.forbidden,
        UploadRejectReason.acceptingDisabled,
      );
      return;
    }
    final body = await _readJsonBody(request);
    if (body == null) {
      await _reject(
          request, HttpStatus.badRequest, UploadRejectReason.badRequest);
      return;
    }
    final PrepareUploadRequest payload;
    try {
      requireFrameTypeIs(body, kFramePrepare);
      payload = PrepareUploadRequest.fromJson(body);
    } on FormatException catch (error) {
      _log('prepare malformed: ${error.message}');
      _reportRejected(request, UploadRejectReason.badRequest);
      _writeError(request, HttpStatus.badRequest, 'malformed prepare frame');
      return;
    }
    if (_identityMismatch(request, payload.info)) {
      _writeError(request, HttpStatus.forbidden, 'identity mismatch');
      return;
    }
    // Keep-alive (docs/13 §4): the sender is demonstrably alive; refresh its
    // registry entry before any accept/refuse decision below.
    _touchPeer(request, payload.info);

    if (payload.files.isEmpty) {
      // 204 = the receiver has nothing to accept.
      _writeEmpty(request, HttpStatus.noContent);
      return;
    }

    // Reject an over-sized file up front, before any token is handed out. The
    // upload handler re-checks the declared content length as defence in depth
    // (a sender may under-declare its size here and lie on the wire).
    for (final file in payload.files.values) {
      if (file.size > maxUploadBytes) {
        _log('prepare refused: ${file.fileName} declares ${file.size} '
            'bytes > maxUploadBytes=$maxUploadBytes');
        _reportRejected(request, UploadRejectReason.tooLarge);
        _writeError(
            request, HttpStatus.requestEntityTooLarge, 'file too large');
        return;
      }
    }

    // Reclaim sessions nobody is using **before** deciding the receiver is full
    // (0.2.41). Order matters twice over: after the cap check this would never
    // help (the request is already refused), and before the size/path checks it
    // would let a malformed frame trigger work for no reason. Lazy, not a timer:
    // the sweep only has to run when it can change an answer, which is exactly
    // when someone is asking "do you have room?".
    _sweepIdleSessions();

    if (_sessions.length >= maxSessions) {
      _log('prepare refused: session cap reached ($maxSessions)');
      _reportRejected(request, UploadRejectReason.sessionCapReached);
      _writeError(
          request, HttpStatus.serviceUnavailable, 'session cap reached');
      return;
    }

    // --- Folder + relative paths (`docs/22` §4.3) --------------------------
    //
    // Decided **here**, before a single token is handed out, and for the whole
    // batch. A `prepare` is an all-or-nothing declaration: refusing one path
    // later, inside `/put`, would leave the sender holding tokens for files we
    // have already refused — it would show "19 of 20" and have no way to know
    // why — and the files it *did* accept would already have created
    // directories by then. So one unusable path refuses the lot.
    //
    // This sits after the size and session-cap checks on purpose: those two
    // answered first in 0.2.37 and the order is part of the observable
    // behaviour a 0.2.37 sender already relies on. A frame with no `folder` and
    // no `path` runs through the loop below without touching anything.
    final FolderDescriptor? folder = _normalizeFolderName(payload.folder);
    final Map<String, String?> relativePaths = <String, String?>{};
    for (final entry in payload.files.entries) {
      final String? declaredPath = entry.value.relativePath;
      // A `path` with no `folder` is a frame that contradicts itself: it says
      // "this file has a position inside a folder" while also saying "there is
      // no folder". Both halves cannot be honoured, and the two ways of
      // pretending otherwise are both wrong:
      //
      //  * honour the path → we create `sub/` for what the record will still
      //    call a flat transfer, leaving a directory on disk that nothing
      //    acknowledges and that the user cannot explain;
      //  * drop the path → the file lands somewhere the sender did not ask for.
      //
      // So the batch is refused, at the same level and with the same answer as
      // an unsafe path. Note this runs on the **normalised** [folder]: a frame
      // whose folder name sanitises to nothing (e.g. `"..."`) has no folder
      // either, and putting its files in a subdirectory is the same
      // contradiction.
      //
      // `path: ""` is caught by this too, on purpose. It is not a *real* case —
      // no sender emits an empty `path` key, and 0.2.37 emits no key at all —
      // but "the key is present" is the claim being made, and the claim is
      // false. If a peer ever legitimately sends `path: ""` for a flat
      // transfer, relax this to `declaredPath.isNotEmpty`.
      if (folder == null && declaredPath != null) {
        _log('prepare refused: fileId=${entry.key} declares path '
            '"$declaredPath" but the frame has no usable folder '
            '(from ${payload.info.alias})');
        _reportRejected(request, UploadRejectReason.badRequest);
        _writeError(request, HttpStatus.badRequest, 'malformed prepare frame');
        return;
      }
      final String? normalized = normalizeRelativePath(declaredPath);
      if (normalized == null) {
        _log('prepare refused: unsafe relative path '
            '"$declaredPath" for fileId=${entry.key} '
            'from ${payload.info.alias}');
        _reportRejected(request, UploadRejectReason.badRequest);
        _writeError(request, HttpStatus.badRequest, 'malformed prepare frame');
        return;
      }
      // `null` (no `path` key) and `''` (an empty one) both mean "flat"; they
      // are recorded as `null` so a pre-0.2.38 frame keeps producing a
      // `ReceivedFile` with every new field at its old default.
      relativePaths[entry.key] = normalized.isEmpty ? null : normalized;
    }

    final session = _UploadSession(
      id: _randomHex(16),
      peer: payload.info,
      lastActivityAt: _now(),
      folder: folder,
    );
    final tokens = <String, String>{};
    final received = <String, int>{};
    for (final file in payload.files.values) {
      final token = _randomHex(16);
      session.files[file.id] = _PendingUpload(
        meta: file,
        token: token,
        relativePath: relativePaths[file.id],
      );
      tokens[file.id] = token;
      // Resume support (docs/13 §3): report how many bytes we already hold. A
      // fresh session always holds zero.
      received[file.id] = 0;
    }
    _sessions[session.id] = session;

    _log('session ${session.id} opened for ${payload.files.length} file(s) '
        'from ${payload.info.alias}'
        '${folder == null ? '' : ' folder="${folder.name}" '
            'declared=${folder.count}'}');
    _writeJson(
      request,
      HttpStatus.ok,
      encodeFrame(kFramePrepareReply, <String, dynamic>{
        'session': session.id,
        'tokens': tokens,
        'received': received,
      }),
    );
  }

  /// Sanitises the declared folder name once, here, so every later step — the
  /// landing directory in [_handleUpload] and `ReceivedFile.folderName` — reads
  /// the same value. Two places applying the same rules independently is how
  /// "one of them got a rule wrong" becomes a security bug.
  ///
  /// A descriptor whose name normalises to nothing is treated as **no folder**:
  /// flattening is honest (the files do arrive), whereas inventing an
  /// `unnamed/` directory would record a name the sender never used.
  FolderDescriptor? _normalizeFolderName(FolderDescriptor? folder) {
    if (folder == null) {
      return null;
    }
    final String name = sanitizeFolderName(folder.name);
    if (name.isEmpty) {
      _log('prepare: folder name "${folder.name}" normalises to nothing - '
          'treating the batch as a flat transfer');
      return null;
    }
    return FolderDescriptor(name: name, count: folder.count);
  }

  /// Drops sessions that have been idle for longer than [kSessionIdleTimeout]
  /// (0.2.41).
  ///
  /// **Only the session record is removed.** Anything already written to disk
  /// belongs to the received file — which the store may already have recorded —
  /// and deleting it here would be "reclaiming a slot" by destroying the user's
  /// data. A reaped session means "a later `/put` for it answers `403`", which is
  /// the same answer an unknown session has always got.
  ///
  /// **`activeUploads > 0` is never swept**, even if the timestamp is ancient: a
  /// single large upload streams for minutes without starting a new request, and
  /// there is no new activity to stamp while it runs.
  ///
  /// One aggregated log line, not one per session: 64 lines per prepare-after-
  /// the-cap would be noise, and the count is the fact worth keeping.
  void _sweepIdleSessions() {
    if (_sessions.isEmpty) {
      return;
    }
    final DateTime now = _now();
    final List<String> idle = <String>[];
    for (final MapEntry<String, _UploadSession> entry in _sessions.entries) {
      final _UploadSession session = entry.value;
      if (session.activeUploads > 0) {
        continue;
      }
      if (now.difference(session.lastActivityAt) <= kSessionIdleTimeout) {
        continue;
      }
      idle.add(entry.key);
    }
    if (idle.isEmpty) {
      return;
    }
    for (final String id in idle) {
      _sessions.remove(id);
    }
    _log('session sweep: dropped ${idle.length} idle session(s), '
        '${_sessions.length} still open (idle > ${kSessionIdleTimeout.inSeconds}s)');
  }

  /// Creates the directories a file lands in and resolves its non-colliding
  /// target path (`docs/22` §4.3).
  ///
  /// [relativePath] has already been normalised at `prepare` time: no `..`, no
  /// absolute form, no empty segments, ≤ 8 segments. [root] is the folder root,
  /// built from a sanitised single-segment name. So neither join can walk
  /// upwards — the containment check in [_handleUpload] is the *second* layer,
  /// never the only one.
  Future<File> _resolveTarget({
    required Directory root,
    required String relativePath,
    required String fileName,
  }) {
    final String directoryPart =
        relativePath.isEmpty ? '' : p.dirname(relativePath);
    if (directoryPart.isEmpty || directoryPart == '.') {
      // `relativePath` is one segment (or absent): the file sits in the root.
      // `p.dirname('a.bin') == '.'`, and `p.join(root, '.')` would be the same
      // directory — this branch exists so the reader does not have to know it.
      return resolveUniqueFile(
        root,
        relativePath.isEmpty ? fileName : relativePath,
      );
    }
    return resolveUniqueFile(
      Directory(p.join(root.path, directoryPart)),
      p.basename(relativePath),
    );
  }

  Future<void> _handleUpload(HttpRequest request) async {
    final query = request.uri.queryParameters;
    final sessionId = query['session'];
    final fileId = query['file'];
    final token = query['token'];
    if (sessionId == null || fileId == null || token == null) {
      await _reject(
          request, HttpStatus.badRequest, UploadRejectReason.badRequest);
      return;
    }
    final session = _sessions[sessionId];
    if (session == null) {
      await _reject(
        request,
        HttpStatus.forbidden,
        UploadRejectReason.unauthorized,
      );
      return;
    }
    final pending = session.files[fileId];
    if (pending == null) {
      await _reject(
          request, HttpStatus.badRequest, UploadRejectReason.badRequest);
      return;
    }
    if (pending.token != token) {
      await _reject(
        request,
        HttpStatus.forbidden,
        UploadRejectReason.unauthorized,
      );
      return;
    }
    if (pending.completed) {
      await _reject(
          request, HttpStatus.conflict, UploadRejectReason.badRequest);
      return;
    }

    // 0.2.41 — this session is being used: it must not be swept as idle. Stamped
    // here, after every authorisation check and before any I/O, so a refused
    // `put` (wrong token, unknown file) cannot keep somebody else's slot alive.
    session.lastActivityAt = _now();

    final meta = pending.meta;
    final declaredLength = request.contentLength;
    if (declaredLength >= 0 && meta.size >= 0 && declaredLength != meta.size) {
      await _reject(
          request, HttpStatus.badRequest, UploadRejectReason.badRequest);
      return;
    }
    if ((meta.size > maxUploadBytes) ||
        (declaredLength >= 0 && declaredLength > maxUploadBytes)) {
      _log('upload refused: exceeds maxUploadBytes=$maxUploadBytes');
      await _reject(
        request,
        HttpStatus.requestEntityTooLarge,
        UploadRejectReason.tooLarge,
      );
      return;
    }

    final directory = saveDirectory;
    if (directory == null) {
      _log('upload refused: acceptUploads is on but saveDirectory is null');
      await _reject(request, HttpStatus.internalServerError);
      return;
    }

    // 0.2.48 / CR-2 ④ — the session is busy from **here**, not from the moment
    // the bytes start flowing.
    //
    // This used to sit immediately before the stream loop, i.e. *after*
    // [_resolveTarget] had already created the landing directory and run its
    // `exists()` loop. Between the [lastActivityAt] stamp above and that
    // increment the only protection against the idle sweep was the timestamp,
    // so a `_resolveTarget` slower than [kSessionIdleTimeout] — a spun-down
    // external disk, an SMB share, a full antivirus scan — let a concurrent
    // `prepare` delete a session that was **in use**, and every remaining `put`
    // of that batch answered `403`.
    //
    // Exactly one release point, and it is a `finally` around everything that
    // follows: the early `return`s for a failed resolution, an escaping target,
    // a failed stream, a size/sha mismatch and an exception out of the sink all
    // pass through it. That is the property worth keeping — a leaked increment
    // means a session that can never be swept, which is the bug 0.2.41 fixed.
    session.activeUploads += 1;
    try {
      await _streamUpload(
        request,
        session: session,
        pending: pending,
        meta: meta,
        directory: directory,
        fileId: fileId,
      );
    } finally {
      session.activeUploads -= 1;
      session.lastActivityAt = _now();
    }
  }

  /// The body of an authorised `/put`: resolve the landing point, stream the
  /// bytes to disk, verify them and answer (`docs/22` §4.3).
  ///
  /// Split out of [_handleUpload] for one reason: the caller's
  /// `session.activeUploads` must be raised **before** [_resolveTarget] runs
  /// (CR-2 ④), and a single `try`/`finally` around the whole of that span is the
  /// only way to keep the increment and its release impossible to separate.
  /// Every local below belongs to one upload; nothing here reads another
  /// request's state.
  Future<void> _streamUpload(
    HttpRequest request, {
    required _UploadSession session,
    required _PendingUpload pending,
    required FileMetadata meta,
    required Directory directory,
    required String fileId,
  }) async {
    // --- Landing point (`docs/22` §4.3) -----------------------------------
    //
    // `<saveDirectory>/<folder>/<relative path>`. Both halves were normalised
    // at `prepare` time, so this replaces the old flat
    // `resolveUniqueFile(directory, meta.fileName)` without weakening it: a
    // frame that declares no folder and no `path` still resolves to exactly the
    // same file name in exactly the same directory.
    final String? sessionFolder = session.folder?.name;
    final Directory root = (sessionFolder == null || sessionFolder.isEmpty)
        ? directory
        : Directory(p.join(directory.path, sessionFolder));
    final String relativePath = pending.relativePath ?? '';
    final File target;
    try {
      await beforeResolveTarget?.call(session.id, fileId);
      target = await _resolveTarget(
        root: root,
        relativePath: relativePath,
        fileName: meta.fileName,
      );
    } on FileSystemException catch (error) {
      // Deliberately caught here rather than left to the handler's catch-all,
      // which answers with `'$error'` — that string carries our local
      // `/data/user/0/...` path, so it would both leak where the receiver keeps
      // its files and tell the sender nothing actionable.
      _log('upload refused: cannot prepare the landing directory for '
          'fileId=$fileId in "${root.path}": $error');
      await _drainQuietly(request);
      _writeError(
        request,
        HttpStatus.internalServerError,
        receiveFailureMessage(error),
      );
      return;
    }

    // Second layer: compare *normalised absolute* paths instead of trusting the
    // joins above to "look right". Nothing has been written yet — the sink is
    // not open — so a rejection here leaves no trace, and we deliberately do not
    // delete anything: removing a path we just proved is outside our root would
    // be the very act we are preventing.
    final String rootPath = p.normalize(root.absolute.path);
    final String targetPath = p.normalize(target.absolute.path);
    if (!p.equals(rootPath, targetPath) &&
        !p.isWithin(rootPath, targetPath)) {
      _log('upload refused: resolved target escapes the save root for '
          'fileId=$fileId (root="$rootPath", target="$targetPath")');
      await _drainQuietly(request);
      _writeError(request, HttpStatus.badRequest, 'malformed prepare frame');
      return;
    }

    final sink = target.openWrite();
    // Hash while writing, through the same accumulator the sender uses: one pass
    // over the bytes, no second read of the file (0.2.12 — this was a
    // `pointycastle` `SHA256Digest`, which capped a transfer at ~21 MiB/s).
    //
    // 0.2.16: the hash runs on a **worker isolate**. It used to run right here,
    // on the isolate that is also reading the socket and writing the file, and
    // that is why the receive direction was the slow one — the user measured
    // 8.2 MiB/s receiving against 12.8 MiB/s sending on the same link, same
    // 962 MB file, and the receive rate decayed to 3–5 MiB/s as TCP pushed back.
    // `add` returns a future only so a slow worker throttles the socket (16
    // chunks in flight) rather than buffering the file in memory.
    final hash = IsolateHasher(spawnWorker: hashWorkerSpawner, log: _log);
    // 0.2.17 — receive-path accounting. **Diagnostics only**: no branch below
    // reads these numbers, so nothing about the transfer changes. The counters
    // cost an `int` add (and three `Stopwatch` reads) per chunk; the one formatted
    // line is built after the body has arrived. What each field is meant to
    // separate is documented in `upload_stats.dart`.
    final stats = UploadStats();
    final loopWatch = Stopwatch()..start();
    var loopTimed = false;
    var rateMarkMicros = 0;
    var rateMarkBytes = 0;
    var received = 0;
    var overflowed = false;
    var streamFailed = false;
    // Kept only so a failed write can answer the peer in its own words instead
    // of `'$error'` (`docs/22` §4.3).
    FileSystemException? streamError;
    var nextTouchAt = _kPeerTouchEveryBytes;
    // Keep-alive (docs/13 §4): a single `/put` can stream for minutes, and the
    // sender's UDP announcement may be lost the whole time; refresh its registry
    // entry up front and again every [_kPeerTouchEveryBytes] so it never times
    // out as offline while its bytes are still arriving.
    _touchPeer(request, session.peer);
    // The busy flag is **not** raised here any more (CR-2 ④): it is raised by
    // [_handleUpload] before [_resolveTarget], so that the landing-directory I/O
    // is covered too. Only the hash worker is torn down on the way out.
    try {
      try {
        // Stream straight to disk: the file is never fully buffered in memory.
        await for (final chunk in request) {
          received += chunk.length;
          stats.addChunk(chunk.length);
          if (received > maxUploadBytes) {
            overflowed = true;
            break;
          }
          // Disk first, worker second. `TransferableTypedData.fromList`
          // consolidates the chunk into its own transferable buffer (it copies;
          // it does not steal the caller's buffer — verified, because a steal
          // would corrupt whatever still holds the list), so handing the chunk
          // to the sink first and the worker afterwards cannot corrupt either.
          //
          // 0.2.17: two clock reads around each phase, accumulated as `int`
          // microseconds. `sink.add` is synchronous (`IOSink` buffers and the
          // `await` on `hash.add` is what yields), so `tAfterSink` measures the
          // hand-off cost and `tAfterHash - tAfterSink` measures the hasher,
          // including any credit-window wait — which is the number that answers
          // "is the worker throttling the socket?".
          final int tStart = loopWatch.elapsedMicroseconds;
          sink.add(chunk);
          final int tAfterSink = loopWatch.elapsedMicroseconds;
          await hash.add(chunk);
          final int tAfterHash = loopWatch.elapsedMicroseconds;
          stats.addSink(tAfterSink - tStart);
          stats.addHash(tAfterHash - tAfterSink);
          if (received >= nextTouchAt) {
            nextTouchAt = received + _kPeerTouchEveryBytes;
            _touchPeer(request, session.peer);
          }
          // 1 Hz receive-side rate line (0.2.17). The sender logs `upload rate:`;
          // the receiver logged nothing, and the receive direction is precisely
          // the one under investigation. The clock is already in hand
          // (`tAfterHash`), so the test costs one integer comparison per chunk
          // and formatting happens at most once a second.
          if (tAfterHash - rateMarkMicros >= _kRecvRateLogEveryMicros) {
            _log(
              formatReceiveRate(
                deltaBytes: received - rateMarkBytes,
                elapsed: Duration(microseconds: tAfterHash - rateMarkMicros),
                receivedBytes: received,
                totalBytes: meta.size,
                chunkCount: stats.chunkCount,
                hashWaitMicros: hash.backpressureWaitMicros,
              ),
            );
            rateMarkMicros = tAfterHash;
            rateMarkBytes = received;
          }
        }
        stats.loopMicros = loopWatch.elapsedMicroseconds;
        loopTimed = true;
        final flushWatch = Stopwatch()..start();
        await sink.flush();
        stats.flushMicros = flushWatch.elapsedMicroseconds;
      } catch (error) {
        if (!loopTimed) {
          // The loop itself threw: record what it managed before unwinding, so
          // the summary of a failed upload is not `loop=0.0ms`.
          stats.loopMicros = loopWatch.elapsedMicroseconds;
        }
        streamFailed = true;
        if (error is FileSystemException) {
          streamError = error;
        }
        _log('upload stream error: $error');
      }
      // Always close before touching the file: on Windows an open handle blocks
      // delete. `IOSink.close` is safe to call exactly once here.
      //
      // Wrapped because a full disk surfaces **at close**, not at `add`: the
      // buffered tail is written then. Letting it escape would hand the peer
      // `'$error'` from the handler's catch-all, complete with our local path.
      final closeWatch = Stopwatch()..start();
      try {
        await sink.close();
      } catch (error) {
        streamFailed = true;
        if (error is FileSystemException) {
          streamError = error;
        }
        _log('upload sink close error: $error');
      }
      stats.closeMicros = closeWatch.elapsedMicroseconds;

      // One line per large upload, logged before the accept/reject decisions so a
      // failed or truncated body is described too. Purely additive: the value of
      // `shouldLog` never feeds a branch. Small bodies stay silent on purpose —
      // thumbnails and text would otherwise drown the log.
      if (stats.shouldLog) {
        _log(
          stats.summary(
            hashBackpressureWaits: hash.backpressureWaits,
            hashBackpressureMicros: hash.backpressureWaitMicros,
            usesIsolateWorker: hash.usesWorker,
          ),
        );
      }

      if (streamFailed) {
        await _deleteQuietly(target);
        // One of the three fixed sentences (`docs/22` §4.3), never the raw OS
        // error: this string is shown to the *sender*, on the failing bubble.
        _writeError(
          request,
          HttpStatus.internalServerError,
          streamError == null
              ? _kReceiveNotWritable
              : receiveFailureMessage(streamError),
        );
        return;
      }
      if (overflowed) {
        await _deleteQuietly(target);
        _log('upload aborted: body exceeded maxUploadBytes=$maxUploadBytes');
        _reportRejected(request, UploadRejectReason.tooLarge);
        _writeError(
            request, HttpStatus.requestEntityTooLarge, 'upload too large');
        return;
      }

      // Only reached with a complete body, so the digest covers exactly the bytes
      // written to disk above. Uppercase hex, identical to the sender's format.
      //
      // A worker that died mid-stream cannot simply be continued inline: the
      // chunks it already folded in were transferred out of this isolate, so an
      // inline continuation would produce a *wrong* digest and get a perfectly
      // good file deleted as a "mismatch". Re-hash the bytes we have already
      // written instead — slow, correct, and only on a path that should not
      // happen.
      String receivedSha;
      try {
        receivedSha = await hash.finish();
      } on HashDigestUnavailable catch (error) {
        _log('${error.reason} - re-hashing ${target.path} from disk');
        receivedSha = await sha256FileHex(target);
      }

      if (meta.size >= 0 && received != meta.size) {
        await _deleteQuietly(target);
        _log('size mismatch: expected ${meta.size}, got $received');
        _reportRejected(request, UploadRejectReason.badRequest);
        _writeError(request, HttpStatus.badRequest, 'size mismatch');
        return;
      }

      // ★ Deliberate design choice (see transfer.dart): a declared SHA-256 that
      // does not match the bytes we received is a hard failure. An earlier
      // revision kept the file and merely flagged `sha256Matched: false`; keeping
      // corrupt bytes would silently deliver data the sender never vouched for, so
      // we delete the file and answer 400 instead.
      final declaredSha = meta.sha256;
      if (declaredSha != null &&
          declaredSha.isNotEmpty &&
          !fingerprintsEqual(declaredSha, receivedSha)) {
        await _deleteQuietly(target);
        _log('sha256 mismatch for fileId=$fileId: declared=$declaredSha '
            'received=$receivedSha - file deleted, replying 400');
        _reportRejected(request, UploadRejectReason.badRequest);
        _writeError(request, HttpStatus.badRequest, 'sha256 mismatch');
        return;
      }

      pending.completed = true;
      // `docs/22` §D8: record the path the file **really** has. `relative` is
      // computed from the resolved target, so a duplicate that landed as
      // `x (1).dll` records `x (1).dll`; recording the requested name instead
      // would make the receiver open a file that does not exist. `/` separated
      // because that is the stored/transmitted/displayed form everywhere.
      final String savedRelative =
          p.relative(target.path, from: root.path).replaceAll(r'\', '/');
      final String? folderName = session.folder?.name;
      // ★ 0.2.52 — **how many files this `prepare` declared**, for a flat batch
      // too.
      //
      // A folder has always had a declared count of its own
      // (`FolderDescriptor.count`), and it is the *descriptor* that owns it, not
      // this session's `files` map: a folder `prepare` may legitimately list
      // fewer files than it declares (`(e)` in `upload_flow_test.dart` sends one
      // file under `count: 2`), and reporting `session.files.length` there would
      // turn "one more may still come" into a wrong number.
      //
      // A **flat** session declares nothing but the `files` map of its own
      // `prepare` — and that map *is* the count, because the sender puts every
      // selected file in one `prepare`. Without it the receiver cannot tell a
      // batch that delivered 3 of 8 from a batch of 3, which is the whole of
      // 0.2.52: folding the batch into one message hid the missing files that
      // used to be visibly missing bubbles.
      //
      // `> 1` on purpose. A **single-file** send opens a session with exactly one
      // entry too, and a declared count of 1 says nothing a single arrival does
      // not already say — worse, it would write a non-NULL `folder_files` on
      // every plain send and change the stored shape (and therefore the UI, the
      // database and the sync story) of a message that has not changed at all.
      // So the rule is: **only a batch declares**, and a one-file session keeps
      // the pre-0.2.52 `0`.
      //
      // No field is added and no frame changes: `ReceivedFile.folderFiles`
      // already exists and is already mapped all the way to
      // `messages.folder_files`.
      final int declaredFiles =
          session.files.length > 1 ? session.files.length : 0;
      final record = ReceivedFile(
        fileId: fileId,
        fileName: p.basename(target.path),
        savedPath: target.path,
        size: received,
        sha256: receivedSha,
        sha256Matched: true,
        sender: session.peer,
        sessionId: session.id,
        folderName: folderName,
        folderFiles:
            folderName == null ? declaredFiles : (session.folder?.count ?? 0),
        // `null` — not `''` — for a flat transfer, so a pre-0.2.38 sender keeps
        // producing a record that is byte-identical to what 0.2.37 produced.
        relativePath:
            (folderName == null || savedRelative.isEmpty) ? null : savedRelative,
      );
      _log('RECEIVED fileId=$fileId name=${record.fileName} bytes=$received '
          'sha256=$receivedSha shaMatch=${record.sha256Matched}'
          '${folderName == null ? '' : ' folder="$folderName" '
              'path="${record.relativePath}"'}');
      onUploadFinished?.call(record);

      _writeJson(
        request,
        HttpStatus.ok,
        encodeFrame(kFramePutReply, <String, dynamic>{'received': received}),
      );
    } finally {
      // Every path above — including the early `return`s for a rejected or
      // mismatched upload, and any exception out of the stream or the sink —
      // tears the worker down here. A leaked hash isolate would live as long as
      // the app does.
      //
      // The session's busy flag and its activity stamp are **not** released
      // here any more (CR-2 ④): [_handleUpload] owns both, around this whole
      // method *and* the landing-directory resolution that precedes it, so the
      // two halves of `activeUploads` live in one place instead of two.
      await hash.dispose();
    }
  }

  /// `GET /resume` — reserved (docs/13 §3): the endpoint exists and its
  /// semantics are fixed, but V1 does not implement resumption, so it answers
  /// `501 Not Implemented`.
  void _handleResume(HttpRequest request) {
    _writeError(request, HttpStatus.notImplemented, 'resume not implemented');
  }

  Future<void> _handleCancel(HttpRequest request) async {
    final sessionId = request.uri.queryParameters['session'];
    if (sessionId != null && _sessions.remove(sessionId) != null) {
      _log('session $sessionId cancelled');
    }
    _writeJson(
      request,
      HttpStatus.ok,
      encodeFrame(kFrameAck, <String, dynamic>{}),
    );
  }

  /// Reports [peer] as freshly seen through [onPeerSeen].
  ///
  /// This is the receiver half of the "a live TCP exchange counts as liveness"
  /// rule (docs/13 §4): the app wires [onPeerSeen] into the same registry the
  /// UDP announcements feed, so an in-flight upload keeps the sender online even
  /// when multicast is momentarily lost. A missing callback or an empty source
  /// address is a quiet no-op (nothing to report).
  void _touchPeer(HttpRequest request, DeviceInfo peer) {
    final callback = onPeerSeen;
    if (callback == null) {
      return;
    }
    final address = request.connectionInfo?.remoteAddress.address ?? '';
    if (address.isEmpty) {
      return;
    }
    callback(peer, address);
  }

  /// R-SEC-2 (docs/13 §5.2): within a session the claimed `peer.fp` must not
  /// change — the identity in a `prepare`/`text` frame must equal the one the
  /// same source address used in its `hello`.
  ///
  /// Returns `false` (allow) when there is no baseline: the receiver cannot
  /// authenticate a caller on its own (R-SEC-3), so a first contact with no
  /// prior hello is permitted and only an *inconsistent* repeat is rejected.
  bool _identityMismatch(HttpRequest request, DeviceInfo peer) {
    final address = request.connectionInfo?.remoteAddress.address ?? '';
    if (address.isEmpty) {
      return false;
    }
    final known = _peersByAddress[address];
    if (known == null ||
        known.fingerprint.isEmpty ||
        peer.fingerprint.isEmpty ||
        fingerprintsEqual(known.fingerprint, peer.fingerprint)) {
      return false;
    }
    _log('R-SEC-2 reject: $address was ${known.fingerprint} but the frame '
        'claims ${peer.fingerprint}');
    return true;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Best effort cleanup; ignore.
    }
  }

  /// Rejects a request with [status], first draining any unread request body.
  ///
  /// Draining matters because a client that has already started streaming its
  /// file would otherwise see the connection reset instead of our response.
  ///
  /// When [reason] is given the refusal is also reported to [onUploadRejected]
  /// so the local UI can show a trace; purely internal failures pass `null`.
  Future<void> _reject(
    HttpRequest request,
    int status, [
    UploadRejectReason? reason,
  ]) async {
    if (reason != null) {
      _reportRejected(request, reason);
    }
    await _drainQuietly(request);
    _writeError(request, status, reason?.name ?? 'request rejected');
  }

  /// Resolves the sender of [request] by socket address and reports [reason] to
  /// [onUploadRejected]. Does nothing when no callback is wired.
  void _reportRejected(HttpRequest request, UploadRejectReason reason) {
    final callback = onUploadRejected;
    if (callback == null) {
      return;
    }
    final address = request.connectionInfo?.remoteAddress.address ?? '';
    callback(address.isEmpty ? null : _peersByAddress[address], reason);
  }

  Future<void> _drainQuietly(HttpRequest request) async {
    try {
      await request.drain<void>();
    } on Exception catch (error) {
      // The request is being rejected anyway; a broken stream changes nothing.
      _log('drain error while rejecting request: $error');
    }
  }

  Future<Map<String, dynamic>?> _readJsonBody(HttpRequest request) async {
    const maxBytes = 8 * 1024 * 1024;
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in request) {
      total += chunk.length;
      if (total > maxBytes) {
        return null;
      }
      builder.add(chunk);
    }
    if (total == 0) {
      return null;
    }
    try {
      final decoded = jsonDecode(utf8.decode(builder.takeBytes()));
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  String _randomHex(int byteCount) {
    final bytes = Uint8List(byteCount);
    for (var index = 0; index < byteCount; index++) {
      bytes[index] = _random.nextInt(256);
    }
    return bytesToHex(bytes).toLowerCase();
  }

  void _writeJson(HttpRequest request, int status, Object body) {
    final bytes = utf8.encode(jsonEncode(body));
    request.response.statusCode = status;
    request.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.response.contentLength = bytes.length;
    request.response.add(bytes);
    request.response.close();
  }

  /// Writes the unified error body (`{v, t:"error", code, message}`) for any
  /// non-2xx response.
  void _writeError(HttpRequest request, int status, String message) {
    _writeJson(
      request,
      status,
      encodeFrame(kFrameError, <String, dynamic>{
        'code': status,
        'message': message,
      }),
    );
  }

  void _writeEmpty(HttpRequest request, int status) {
    request.response.statusCode = status;
    request.response.contentLength = 0;
    request.response.close();
  }

  void _log(String message) {
    onLog?.call(message);
  }
}

/// An in-flight `prepare` session and its per-file pending uploads.
class _UploadSession {
  _UploadSession({
    required this.id,
    required this.peer,
    required this.lastActivityAt,
    this.folder,
  });

  final String id;
  final DeviceInfo peer;

  /// When this session was last demonstrably in use (0.2.41).
  ///
  /// Set at `prepare` time, refreshed when a `/put` is accepted and again when it
  /// finishes. Only [_sweepIdleSessions] reads it, and only when
  /// [activeUploads] is zero.
  DateTime lastActivityAt;

  /// How many `/put` requests are streaming into this session **right now**.
  ///
  /// This, not a timestamp, is the safety key of the idle sweep: one large file
  /// can stream for minutes without any *new* request arriving, so an
  /// activity-time-only rule would delete the session out from under it.
  /// Incremented when a `put` is about to stream, decremented in its `finally`.
  int activeUploads = 0;

  /// The folder this whole session belongs to, with its name **already
  /// sanitised** at `prepare` time; `null` for a plain, flat transfer.
  ///
  /// Kept on the session rather than re-derived per file because one `prepare`
  /// *is* one folder: every file in it shares this root, which is also the
  /// aggregation key the store uses to rebuild a single message (`docs/22` §4.2).
  final FolderDescriptor? folder;

  final Map<String, _PendingUpload> files = <String, _PendingUpload>{};
}

/// One declared file awaiting (or done) upload, with its one-time token.
class _PendingUpload {
  _PendingUpload({required this.meta, required this.token, this.relativePath});

  final FileMetadata meta;
  final String token;

  /// Relative path normalised at `prepare` time — `/` separated, no `..`, no
  /// absolute form, ≤ 8 segments, ≤ 180 characters — or `null` for "write
  /// straight into the session root".
  ///
  /// Held here rather than written back into [meta] because `FileMetadata`
  /// cannot express "clear this optional field" (`copyWith` treats `null` as
  /// "keep"), and a flat file must stay `null` rather than becoming `''`.
  final String? relativePath;

  bool completed = false;
}

/// Fixed wording for a failed inbound write (`docs/22` §4.3).
///
/// These strings travel to the **sender** — `upload` raises, the orchestrator
/// stores it in `transfers.error`, and the failing bubble shows it — so they
/// must be user-facing sentences. Never an OS error and never a local path.
const String _kReceiveNoSpace = '接收入站文件失败：磁盘空间不足';
const String _kReceiveTooLong = '接收入站文件失败：路径过长';
const String _kReceiveNotWritable = '接收入站文件失败：目标位置不可写';

/// Maps a [FileSystemException] onto one of the three fixed sentences above.
///
/// Matching on both the numeric OS code and the message text: the codes are
/// POSIX `ENOSPC`/`ENAMETOOLONG` and the Windows `ERROR_DISK_FULL` /
/// `ERROR_HANDLE_DISK_FULL` / `ERROR_FILENAME_EXCED_RANGE`, and whichever layer
/// reports it (Dart, or the OS through Dart) is not worth depending on.
String receiveFailureMessage(FileSystemException error) {
  final int code = error.osError?.errorCode ?? 0;
  final String detail = (error.osError?.message ?? '').toLowerCase();
  if (code == 28 || // ENOSPC
      code == 112 || // ERROR_DISK_FULL / ERROR_HANDLE_DISK_FULL
      detail.contains('no space') ||
      detail.contains('disk full')) {
    return _kReceiveNoSpace;
  }
  if (code == 36 || // ENAMETOOLONG
      code == 206 || // ERROR_FILENAME_EXCED_RANGE
      detail.contains('too long') ||
      detail.contains('name too long')) {
    return _kReceiveTooLong;
  }
  return _kReceiveNotWritable;
}
