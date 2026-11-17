import 'dart:io';
import 'dart:math';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:lanlink_store/lanlink_store.dart';

import 'interface_selection.dart';

/// `lanlink send` - send a single file to a peer over the pinned HTTPS path.
///
/// Options:
///   * `--to <ip>`           the receiver's IPv4 address (required)
///   * `--file <path>`       the file to send (required; exactly one in M2)
///   * `--port <tcp>`        the receiver's TCP port (default: 53317)
///   * `--fingerprint <hex>` the receiver's certificate fingerprint; pins the
///                         TLS connection (recommended)
///   * `--allow-unknown`     trust the receiver on first use: probe once to
///                         observe its fingerprint, then pin it for the upload
///   * `--alias <name>`      our display name (default: the host name)
///   * `--certs <dir>`       where our device certificate is stored
///   * `--interface <ipv4>`  validate the outgoing NIC address (parity with
///                         `discover`; outbound HTTPS egress is chosen by the
///                         OS, so this only guards against typos)
///   * `--list-interfaces`   list usable NICs (with auto-selection) and exit
///   * `--verbose`           also print transport-level diagnostics
///   * `--db <path>`         also record this send in the M3 session history at
///                         `<path>` (see `history`). Without `--db` nothing is
///                         written and the output is byte-for-byte M2.
///
/// Exit codes: `0` success; `1` receiver rejected / protocol error;
/// `2` configuration or security-policy problem (missing fingerprint);
/// `64` usage error; `66` input file unusable.
class SendCommand {
  SendCommand(this.options);

  /// Raw `--key value` options parsed from the command line.
  final Map<String, String> options;

  Future<int> run() async {
    // `--list-interfaces` is a pure inspection mode; like `discover` it must
    // work without the otherwise-required `--to` / `--file`.
    if (options['list-interfaces'] == 'true') {
      return _listInterfaces();
    }

    // 1. Usage validation.
    final host = options['to'];
    final filePath = options['file'];
    if (host == null || host.isEmpty) {
      stderr.writeln('send: missing required --to <ip>');
      return 64;
    }
    if (filePath == null || filePath.isEmpty) {
      stderr.writeln('send: missing required --file <path>');
      return 64;
    }

    final alias = options['alias'] ?? _defaultAlias();
    final port = _intOption(options, 'port', kDefaultPort);
    final verbose = options['verbose'] == 'true';
    final allowUnknown = options['allow-unknown'] == 'true';
    final onLog = verbose
        ? (String message) => stdout.writeln('[client] $message')
        : null;

    final rawFingerprint = options['fingerprint'];
    final explicitFingerprint =
        (rawFingerprint == null || rawFingerprint.trim().isEmpty)
            ? null
            : normalizeFingerprint(rawFingerprint);

    // Optional outgoing-NIC validation (parity with `discover` / `announce`).
    // A send-only CLI cannot bind the source address through the frozen
    // `PeerClient`, so this only catches a mistyped address early.
    final explicitInterface = options['interface'];
    if (explicitInterface != null && explicitInterface.isNotEmpty) {
      final selection =
          await selectMulticastInterface(explicit: explicitInterface);
      if (selection.explicitError != null) {
        stderr.writeln(selection.explicitError);
        return 2;
      }
    }

    // 3. Read the input file.
    final file = File(filePath);
    try {
      if (!await file.exists()) {
        stderr.writeln('send: input file not found: $filePath');
        return 66;
      }
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        stderr.writeln('send: not a regular file: $filePath');
        return 66;
      }
    } on FileSystemException catch (error) {
      stderr.writeln('send: cannot access input file $filePath '
          '(${error.message})');
      return 66;
    }

    final fileName = _basename(filePath);
    var size = 0;
    try {
      size = await file.length();
    } on FileSystemException catch (error) {
      stderr.writeln('send: cannot read input file $filePath '
          '(${error.message})');
      return 66;
    }
    final fileType = _fileTypeFor(fileName);

    // 6. Fingerprint policy - fail closed by default.
    if (explicitFingerprint == null && !allowUnknown) {
      stderr.writeln('send: refusing to connect to $host:$port without a '
          'pinned fingerprint.');
      stderr.writeln('      Pass --fingerprint <hex> (from the receiver), or');
      stderr.writeln('      pass --allow-unknown to trust the receiver on '
          'first use (TOFU).');
      return 2;
    }

    // 4. Stream the whole file through SHA-256 (uppercase hex); the receiver
    //    re-computes this while writing and rejects a mismatch.
    final sha256 = await sha256FileHex(file);

    // 5. Certificate, kept in the same location as discover / announce.
    final certDir = Directory(options['certs'] ?? '.lanlink-certs/$alias');
    final certificate = await DeviceCertificate.loadOrCreate(
      directory: certDir,
      commonName: 'lanlink-$alias',
    );

    // This CLI runs no inbound server, so it advertises port 0. The receiver
    // records us as a peer with port 0 (`+ alias (ip:0)`) but never connects
    // back in M2. M3 turns `send` into a resident app that *does* run a
    // server, so revisit this then.
    final self = DeviceInfo(
      alias: alias,
      fingerprint: certificate.fingerprint,
      port: 0,
      deviceType: DeviceType.desktop,
      protocol: ProtocolScheme.https,
      download: false,
      announce: false,
    );

    final fileId = _randomHex(8);
    final metadata = FileMetadata(
      id: fileId,
      fileName: fileName,
      size: size,
      fileType: fileType,
      sha256: sha256,
    );

    // 6 (cont). TOFU bootstrap: probe once to *observe* the receiver's
    // certificate fingerprint, then reconnect pinned, so the actual transfer
    // is never unauthenticated.
    final String pinnedFingerprint;
    final DeviceInfo peerInfo;
    if (explicitFingerprint != null) {
      pinnedFingerprint = explicitFingerprint;
      // No probe is performed, so the peer's alias is unknown: label the
      // history device with the dialled address rather than inventing one.
      peerInfo = DeviceInfo(
        alias: host,
        fingerprint: pinnedFingerprint,
        port: port,
        deviceType: DeviceType.desktop,
        protocol: ProtocolScheme.https,
      );
    } else {
      final probed = await _probePeer(
        host: host,
        port: port,
        self: self,
        onLog: onLog,
      );
      if (probed == null) {
        // Reaching the peer failed (or it presented no usable certificate):
        // a connection / protocol error, not a local configuration problem.
        return 1;
      }
      // Pin the fingerprint *observed on the wire* (never the one the peer
      // merely claimed in its JSON); keep the rest of its self-description for
      // the history row.
      pinnedFingerprint = probed.fingerprint;
      peerInfo = probed;
      stdout.writeln('observed fingerprint $pinnedFingerprint '
          '(pinned for the transfer)');
    }

    final client = PeerClient(
      host: host,
      port: port,
      expectedFingerprint: pinnedFingerprint,
      // Present our own identity as the TLS **client** certificate.
      //
      // Setting only `badCertificateCallback` (which `PeerClient` does
      // internally) decides whether we *trust* the receiver; it never shows the
      // receiver *our* certificate. LocalSend's HTTPS mode is mutual TLS, so a
      // peer that requires a client certificate aborts the handshake with
      // `TLSV1_ALERT_CERTIFICATE_REQUIRED` when we send none. `certificate` is
      // already loaded above (same `--certs` location as discover / announce).
      certificate: certificate,
      onLog: onLog,
    );

    // M3 history is opt-in: [_SendHistory.open] returns `null` without `--db`,
    // in which case not a single store call is made and the output below stays
    // byte-for-byte M2.
    final history = _SendHistory.open(_resolveDbPath(options));
    final spec = OutgoingFileSpec(
      id: fileId,
      fileName: fileName,
      size: size,
      sha256: sha256,
      localPath: file.absolute.path,
      mime: fileType,
    );

    String? messageId;
    try {
      messageId = history?.begin(
        peer: peerInfo,
        spec: spec,
        now: DateTime.now().toUtc(),
      );
      history?.awaitingConfirm(messageId, DateTime.now().toUtc());

      // 7. prepare-upload.
      final prepared = await client
          .prepareUpload(self: self, files: <FileMetadata>[metadata]);
      if (prepared.isEmpty) {
        stdout.writeln('send: receiver rejected the transfer or has nothing to '
            'accept (204 No Content).');
        history?.rejected(messageId, DateTime.now().toUtc());
        return 1;
      }
      final token = prepared.files[fileId];
      if (token == null) {
        stdout.writeln('send: receiver did not grant a token for '
            'fileId=$fileId.');
        history?.failed(messageId, 'receiver granted no upload token',
            DateTime.now().toUtc());
        return 1;
      }

      history?.transferring(
        messageId,
        fileId: fileId,
        sessionId: prepared.sessionId,
        token: token,
        now: DateTime.now().toUtc(),
      );

      // 8. upload.
      final int sent;
      try {
        sent = await client.upload(
          sessionId: prepared.sessionId,
          fileId: fileId,
          token: token,
          file: file,
        );
      } on PeerHttpException catch (error) {
        _printHttpError('upload', error);
        history?.failed(
            messageId, 'HTTP ${error.statusCode}', DateTime.now().toUtc());
        await _tryCancel(client, prepared.sessionId);
        return 1;
      }

      history?.succeed(
        messageId,
        fileId: fileId,
        bytes: sent,
        now: DateTime.now().toUtc(),
      );

      // 9. Fixed conclusion line, easy to grep from a script.
      stdout.writeln('SENT name=$fileName bytes=$sent sha256=$sha256 -> '
          '$host:$port fp=${_shortFingerprint(pinnedFingerprint)}');
      return 0;
    } on PeerHttpException catch (error) {
      _printHttpError('prepare-upload', error);
      history?.rejected(messageId, DateTime.now().toUtc());
      return 1;
    } on Object catch (error) {
      stderr.writeln('send: transfer failed: $error');
      history?.failed(messageId, error.toString(), DateTime.now().toUtc());
      return 1;
    } finally {
      history?.close();
      client.close();
    }
  }

  /// Probes [host] with trust-on-first-use and returns the peer's
  /// self-description, with `fingerprint` replaced by the certificate
  /// fingerprint **actually observed on the wire**, or `null` on failure.
  ///
  /// The observed value is authoritative: the peer's JSON `fingerprint` field
  /// is only a claim, so it is never trusted for pinning (parity with M2).
  Future<DeviceInfo?> _probePeer({
    required String host,
    required int port,
    required DeviceInfo self,
    required void Function(String message)? onLog,
  }) async {
    final probe = PeerClient(
      host: host,
      port: port,
      allowUnknownCertificate: true,
      onLog: onLog,
    );
    try {
      final reply = await probe.register(self: self);
      final observed = probe.observedFingerprint;
      if (observed == null || observed.isEmpty) {
        stderr.writeln('send: probe reached $host:$port but no certificate '
            'fingerprint was observed; refusing to continue.');
        return null;
      }
      return reply.copyWith(fingerprint: observed);
    } on Object catch (error) {
      stderr.writeln('send: probe to $host:$port failed: $error');
      return null;
    } finally {
      probe.close();
    }
  }

  Future<void> _tryCancel(PeerClient client, String sessionId) async {
    if (sessionId.isEmpty) {
      return;
    }
    try {
      await client.cancel(sessionId: sessionId);
    } on Object catch (error) {
      stderr.writeln('send: cancel failed (best effort): $error');
    }
  }

  void _printHttpError(String stage, PeerHttpException error) {
    stderr.writeln('send: $stage failed: HTTP ${error.statusCode} '
        '${error.message}');
    if (error.body.isNotEmpty) {
      stderr.writeln('      body: ${error.body}');
    }
  }

  /// Prints every usable interface and which one would be auto-selected.
  ///
  /// Kept byte-for-byte identical to `discover`'s `--list-interfaces` output.
  Future<int> _listInterfaces() async {
    final interfaces = await listUsableInterfaces();
    stdout.writeln('usable interfaces:');
    if (interfaces.isEmpty) {
      stdout.writeln('  (none: no up, non-loopback IPv4 interface found)');
      return 0;
    }
    final automatic = await chooseDefaultMulticastInterface();
    final automaticAddress = automatic?.address;
    for (final interface in interfaces) {
      final selected = interface.addressText == automaticAddress;
      final marker = selected ? '*' : '-';
      final kind = interface.isPrivate ? 'private' : 'public';
      final note = selected ? '  (auto-selected)' : '';
      stdout.writeln('  $marker ${interface.name.padRight(14)} '
          '${interface.addressText.padRight(16)} '
          'idx ${interface.index.toString().padLeft(3)}  $kind$note');
    }
    return 0;
  }
}

final Random _random = Random.secure();

/// Lowercase hex of [byteCount] random bytes, used as a per-transfer file id.
String _randomHex(int byteCount) {
  final bytes = List<int>.generate(byteCount, (_) => _random.nextInt(256));
  return bytesToHex(bytes).toLowerCase();
}

int _intOption(Map<String, String> options, String key, int fallback) {
  final raw = options[key];
  if (raw == null) {
    return fallback;
  }
  return int.tryParse(raw) ?? fallback;
}

String _defaultAlias() {
  final hostname = Platform.localHostname;
  return hostname.isEmpty ? 'lanlink' : hostname;
}

/// The final path segment of [path], handling both `/` and `\` separators.
String _basename(String path) {
  var text = path.replaceAll('\\', '/');
  while (text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  final slash = text.lastIndexOf('/');
  if (slash < 0) {
    return text;
  }
  return text.substring(slash + 1);
}

/// A small extension-to-MIME map; anything unknown is `octet-stream`.
const Map<String, String> _mimeByExtension = <String, String>{
  '.txt': 'text/plain',
  '.json': 'application/json',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.gif': 'image/gif',
  '.pdf': 'application/pdf',
  '.zip': 'application/zip',
  '.bin': 'application/octet-stream',
  '.exe': 'application/x-msdownload',
};

String _fileTypeFor(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0) {
    return 'application/octet-stream';
  }
  final extension = fileName.substring(dot).toLowerCase();
  return _mimeByExtension[extension] ?? 'application/octet-stream';
}

String _shortFingerprint(String fingerprint) {
  final normalized = normalizeFingerprint(fingerprint);
  if (normalized.length <= 8) {
    return normalized;
  }
  return normalized.substring(0, 8);
}

/// Resolves `--db`: `null` when the option is absent, the default location when
/// it is given without a value, else the supplied path.
String? _resolveDbPath(Map<String, String> options) {
  final raw = options['db'];
  if (raw == null) {
    return null;
  }
  if (raw == 'true' || raw.isEmpty) {
    return _defaultDbPath();
  }
  return raw;
}

/// The default history database location (`%LOCALAPPDATA%\lanlink\lanlink.db`).
String _defaultDbPath() {
  final base = Platform.environment['LOCALAPPDATA'] ??
      Platform.environment['XDG_DATA_HOME'] ??
      Directory.current.path;
  return <String>[base, 'lanlink', 'lanlink.db'].join(Platform.pathSeparator);
}

/// Best-effort M3 history recorder for `send`.
///
/// [open] returns `null` when `--db` was not given, so the no-`--db` path never
/// touches SQLite and stays byte-for-byte M2. Every later call is a no-op
/// without a store, and swallows (but reports) store errors so a history
/// problem can never change a transfer's outcome.
class _SendHistory {
  _SendHistory._(this._store);

  final SessionStore _store;

  /// Opens the history database at [dbPath]; `null` when [dbPath] is `null`
  /// (no `--db`) or the database cannot be opened.
  static _SendHistory? open(String? dbPath) {
    if (dbPath == null) {
      return null;
    }
    try {
      final directory = File(dbPath).parent;
      if (!directory.existsSync()) {
        directory.createSync(recursive: true);
      }
      final db = LanlinkDatabase.openFile(dbPath);
      return _SendHistory._(SessionStore(db: db, ids: RandomIdGenerator()));
    } on Object catch (error) {
      stderr.writeln('[history] warning: cannot open $dbPath ($error); '
          'continuing without history');
      return null;
    }
  }

  /// Records the outbound message (`status = pending`) and returns its id, or
  /// `null` when the store rejected/failed the write.
  String? begin({
    required DeviceInfo peer,
    required OutgoingFileSpec spec,
    required DateTime now,
  }) {
    try {
      return _store
          .recordOutgoingFiles(
            peer: peer,
            files: <OutgoingFileSpec>[spec],
            now: now,
          )
          .messageId;
    } on Object catch (error) {
      _warn('record outgoing message', error);
      return null;
    }
  }

  void awaitingConfirm(String? messageId, DateTime now) {
    if (messageId == null) {
      return;
    }
    _guard('mark awaiting_confirm', () {
      _store.setStatus(
        messageId: messageId,
        from: MessageStatus.pending,
        to: MessageStatus.awaitingConfirm,
        now: now,
      );
    });
  }

  void transferring(
    String? messageId, {
    required String fileId,
    required String sessionId,
    required String token,
    required DateTime now,
  }) {
    if (messageId == null) {
      return;
    }
    _guard('attach session', () {
      _store.attachSession(
        fileId: fileId,
        sessionId: sessionId,
        token: token,
        now: now,
      );
    });
    _guard('mark transferring', () {
      _store.setStatus(
        messageId: messageId,
        from: MessageStatus.awaitingConfirm,
        to: MessageStatus.transferring,
        now: now,
      );
    });
  }

  void succeed(
    String? messageId, {
    required String fileId,
    required int bytes,
    required DateTime now,
  }) {
    if (messageId == null) {
      return;
    }
    _guard('record progress', () {
      _store.markTransferProgress(fileId: fileId, bytesDone: bytes, now: now);
    });
    _guard('mark done', () {
      _store.markSendSucceeded(messageId: messageId, now: now);
    });
  }

  void rejected(String? messageId, DateTime now) {
    if (messageId == null) {
      return;
    }
    _guard('mark rejected', () {
      _store.setStatus(
        messageId: messageId,
        from: MessageStatus.awaitingConfirm,
        to: MessageStatus.rejected,
        now: now,
      );
    });
  }

  void failed(String? messageId, String error, DateTime now) {
    if (messageId == null) {
      return;
    }
    _guard('mark failed', () {
      _store.markSendFailed(messageId: messageId, error: error, now: now);
    });
  }

  void close() => _guard('close', _store.close);

  void _guard(String what, void Function() action) {
    try {
      action();
    } on Object catch (error) {
      _warn(what, error);
    }
  }

  void _warn(String what, Object error) {
    stderr.writeln('[history] warning: $what failed ($error)');
  }
}
