/// The native [TransferService]: the resident receiver (`PeerServer`) plus the
/// outbound `prepare` / `upload` / `cancel` path (`PeerClient`) — M4 spec §1.3
/// port 5 / §1.5 / §2.
///
/// **Layering (M4 §8.1):** `data/real/**` — the only layer allowed to import
/// `package:lanlink_core` / `dart:io`. Referenced only by
/// `bootstrap/create_deps_native.dart`, so the Web build never parses it.
///
/// Because `PeerServer.alias` / `.acceptUploads` are `final`, toggling accepting
/// or renaming means **rebuilding** the server (spec §1.5). The rebuild keeps
/// the fixed TCP port, so peers are unaware; on failure the previous
/// configuration is restored and the error is rethrown — never a silent
/// downgrade to "unreachable".
library;

import 'dart:async';
import 'dart:io';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:path/path.dart' as p;

import '../../domain/clock.dart';
import '../../domain/models.dart';
import '../../domain/received_file_publisher.dart';
import '../../domain/transfer_service.dart';
import 'mappers.dart';

/// One line describing the rate an upload actually achieved over [elapsed].
///
/// Kept separate and pure so the units can be pinned by a test: [deltaBytes] is
/// bytes and the number printed is **MiB/s** — confusing those is the classic
/// way a "throughput" line misleads whoever reads it.
///
/// Why log a rate at all: the only way to tell "this link is simply slow" from
/// "the phone's Wi-Fi is power-saving" is the *shape* of the curve — a rate that
/// ramps up over the first seconds versus one that is flat from the start.
String formatTransferRate({
  required int deltaBytes,
  required Duration elapsed,
  required int sentBytes,
  required int totalBytes,
}) {
  const int mib = 1024 * 1024;
  final double seconds = elapsed.inMicroseconds / 1000000;
  final String rate =
      seconds <= 0 ? '0.0' : (deltaBytes / mib / seconds).toStringAsFixed(1);
  final String sent = (sentBytes / mib).toStringAsFixed(1);
  final String total = (totalBytes / mib).toStringAsFixed(1);
  return 'upload rate: $rate MiB/s ($sent/$total MiB)';
}

/// [TransferService] backed by the frozen core [PeerServer] / [PeerClient].
class LanTransferService implements TransferService {
  /// Creates the adapter. The receiver is **not** started until
  /// [startReceiver] is called.
  ///
  /// [publisher] is the "publish a received file where the user can find it"
  /// policy (0.2.19). It is **optional on purpose**: `null` restores the 0.2.18
  /// behaviour exactly (record the private path), which is what the fake and
  /// every existing test keep getting. The native bootstrap always passes one —
  /// on desktop its port answers "nothing to do", so both platforms share one
  /// code path and only the platform port differs.
  LanTransferService({
    required DeviceCertificate certificate,
    required Clock clock,
    required String alias,
    required int tcpPort,
    required String saveDirectory,
    bool acceptUploads = false,
    int maxUploadBytes = kDefaultMaxUploadBytes,
    int maxSessions = kDefaultMaxSessions,
    DeviceType deviceType = DeviceType.desktop,
    String? deviceModel,
    ReceivedFilePublisher? publisher,
    void Function(String message)? onLog,
  })  : _certificate = certificate,
        _clock = clock,
        _alias = alias,
        _tcpPort = tcpPort,
        _saveDirectory = saveDirectory,
        _accepting = acceptUploads,
        _maxUploadBytes = maxUploadBytes,
        _maxSessions = maxSessions,
        _deviceType = deviceType,
        _deviceModel = deviceModel,
        _publisher = publisher,
        _onLog = onLog;

  final DeviceCertificate _certificate;
  final Clock _clock;
  final int _tcpPort;
  final int _maxUploadBytes;
  final int _maxSessions;
  final DeviceType _deviceType;
  final String? _deviceModel;
  final ReceivedFilePublisher? _publisher;
  final void Function(String message)? _onLog;

  /// Where accepted files are written **right now** (0.2.23).
  ///
  /// It used to be `final`, seeded once from the persisted setting — which is
  /// why changing 保存位置 only took effect after a restart: the running
  /// `PeerServer` had already captured the old `Directory`, and nothing ever
  /// rebuilt it. [setSaveDirectory] rebuilds, and only a **successful** rebuild
  /// moves this field, so it always names the directory in force.
  String _saveDirectory;

  /// Serialises the publish step so inbound files keep the order they finished
  /// in. Publishing is a real file copy (seconds for a video), so without this
  /// chain two files that land together could be recorded out of order — and
  /// the conversation would show them in the wrong sequence.
  Future<void> _publishChain = Future<void>.value();

  final StreamController<ReceivedTransfer> _received =
      StreamController<ReceivedTransfer>.broadcast();
  final StreamController<DiscoveredPeer> _registrations =
      StreamController<DiscoveredPeer>.broadcast();
  final StreamController<UploadRejected> _uploadRejected =
      StreamController<UploadRejected>.broadcast();
  final StreamController<ReceivedText> _receivedText =
      StreamController<ReceivedText>.broadcast();

  PeerServer? _server;
  String _alias;
  bool _accepting;

  /// How often a long outbound upload re-reports the peer as active.
  ///
  /// Must stay well below `PeerRegistry.offlineAfter` (30s) so a purely-TCP
  /// transfer keeps the peer online in this device's own view (docs/13 §4).
  static const Duration _kPeerActivityInterval = Duration(seconds: 10);

  /// The uploads this device is **streaming right now**, keyed by the peer's
  /// session id (0.2.22).
  ///
  /// It exists because `cancel` used to be a message to the peer and nothing
  /// else: the local `upload` kept pumping bytes into a socket the receiver had
  /// already abandoned, so `await client.upload(...)` did not return until the OS
  /// TCP keepalive gave up (minutes, hours on a sleeping phone) — the bubble sat
  /// on 传输中 and 取消 did nothing. Closing the entry's client is what actually
  /// stops the bytes, and it is what makes the concurrent `upload` throw
  /// [TransferCanceledException] instead of hanging.
  final Map<String, List<_ActiveUpload>> _activeUploads =
      <String, List<_ActiveUpload>>{};

  /// Runs [body] with an [entry] registered under [sessionId], so a concurrent
  /// [cancel] can reach it; always unregisters, whatever the outcome.
  Future<int> _withActiveUpload(
    String sessionId,
    _ActiveUpload entry,
    Future<int> Function() body,
  ) async {
    (_activeUploads[sessionId] ??= <_ActiveUpload>[]).add(entry);
    try {
      return await body();
    } on TransferCanceledException {
      rethrow;
    } catch (error) {
      // A forced `close()` surfaces as a `SocketException` / `ClientException`
      // ("Connection closed before full header was received"), which must not be
      // reported as a network failure: this side asked for it.
      if (entry.canceled) {
        throw const TransferCanceledException('closed locally');
      }
      rethrow;
    } finally {
      final List<_ActiveUpload>? live = _activeUploads[sessionId];
      live?.remove(entry);
      if (live != null && live.isEmpty) {
        _activeUploads.remove(sessionId);
      }
    }
  }

  @override
  Stream<ReceivedTransfer> get received => _received.stream;

  @override
  Stream<DiscoveredPeer> get registrations => _registrations.stream;

  @override
  Stream<UploadRejected> get uploadRejected => _uploadRejected.stream;

  @override
  Stream<ReceivedText> get receivedText => _receivedText.stream;

  @override
  bool get accepting => _accepting;

  @override
  int? get localPort => _server?.actualPort;

  // ── resident receiver (P0-8 / P0-7) ────────────────────────────────────────

  @override
  Future<void> startReceiver() async {
    if (_server != null) {
      return;
    }
    _server = await _startServer(accepting: _accepting, alias: _alias);
  }

  @override
  Future<void> stopReceiver() async {
    final server = _server;
    _server = null;
    await server?.stop();
  }

  @override
  Future<void> setAccepting(bool value) async {
    if (_server == null) {
      _accepting = value;
      return;
    }
    if (value == _accepting) {
      return;
    }
    await _rebuild(accepting: value, alias: _alias);
  }

  @override
  Future<void> setAlias(String alias) async {
    if (alias == _alias) {
      return;
    }
    if (_server == null) {
      _alias = alias;
      return;
    }
    await _rebuild(accepting: _accepting, alias: alias);
  }

  @override
  String get saveDirectory => _saveDirectory;

  @override
  Future<void> setSaveDirectory(String directory) async {
    final String next = directory.trim();
    if (next.isEmpty) {
      throw const SaveDirectoryException('', '保存位置不能为空');
    }
    if (next == _saveDirectory) {
      return;
    }
    // 1. Prove the new directory is usable **before** touching the receiver.
    //    Without this probe a bad path would be adopted silently and only fail
    //    at the next receive — the invisible half of the bug being fixed.
    await _ensureDirectory(next);
    if (_server == null) {
      // No receiver running: the value alone is the whole change; the next
      // `startReceiver` builds its server from it.
      _saveDirectory = next;
      return;
    }
    // 2. Rebuild. `_rebuild` restores the previous directory (and rethrows) if
    //    the new server cannot be started, so a failure never leaves the setting
    //    pointing at a directory the receiver is not using.
    await _rebuild(
      accepting: _accepting,
      alias: _alias,
      saveDirectory: next,
    );
  }

  // ── outbound ────────────────────────────────────────────────────────────────

  @override
  Future<PreparedUpload> prepare({
    required PeerDevice peer,
    required List<OutgoingFile> files,
    FolderRef? folder,
  }) async {
    final client = _clientFor(peer);
    _reportPeerActivity(peer);
    try {
      final response = await client.prepareUpload(
        self: _selfInfo(),
        files: files.map(fileMetadataFromOutgoing).toList(growable: false),
        // 0.2.38 — the folder object and the per-file `path` travel in the JSON
        // **body**, never in the query or a header (`docs/22` §1.5: 200 Chinese
        // file names in a URL would hit a 414/431 behind *some* middlebox and
        // nowhere else). Both are optional keys, so a flat send serialises to
        // exactly the 0.2.37 frame.
        folder: folderDescriptorFromRef(folder),
      );
      // `204 No Content` (nothing to accept) surfaces as an empty response and
      // is mapped to a rejection (spec O1 / §4.4).
      if (response.isEmpty || response.sessionId.isEmpty) {
        throw PeerRejectedException(
          HttpStatus.noContent,
          'the peer has no file to accept',
        );
      }
      return PreparedUpload(
        sessionId: response.sessionId,
        tokens: response.files,
      );
    } on PeerHttpException catch (error) {
      // A `prepare-upload` refusal (403/413/503/…) is a "rejected" outcome.
      throw PeerRejectedException(error.statusCode, error.message);
    } finally {
      client.close();
    }
  }

  @override
  Future<int> upload({
    required PeerDevice peer,
    required PreparedUpload prepared,
    required OutgoingFile file,
    void Function(int bytesSent)? onProgress,
  }) async {
    final token = prepared.tokens[file.id];
    if (token == null || token.isEmpty) {
      throw StateError(
        'the peer granted no upload token for fileId=${file.id}',
      );
    }
    final client = _clientFor(peer);
    final _ActiveUpload active = _ActiveUpload(client);
    // Keep-alive (docs/13 §4): mark the peer active now, then keep re-marking it
    // while the (possibly multi-minute) upload streams, so it never times out as
    // offline in this device's own view while its bytes are still arriving.
    _reportPeerActivity(peer);
    final keepAlive = Timer.periodic(
      _kPeerActivityInterval,
      (_) => _reportPeerActivity(peer),
    );
    // Throughput probe (approved): one log line a second with the rate actually
    // achieved, so "the link is slow" and "the phone's Wi-Fi is power-saving"
    // can be told apart by the *shape* of the curve. This only *observes* — it
    // is handed to `client.upload` as the progress callback that already
    // exists, so the transfer path itself is untouched.
    var latestBytes = 0;
    var lastReportedBytes = 0;
    final Stopwatch sinceRate = Stopwatch()..start();
    final rateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final int sentNow = latestBytes;
      final Duration elapsed = sinceRate.elapsed;
      sinceRate.reset();
      final int delta = sentNow - lastReportedBytes;
      lastReportedBytes = sentNow;
      if (_onLog == null) {
        return;
      }
      _onLog(
        formatTransferRate(
          deltaBytes: delta,
          elapsed: elapsed,
          sentBytes: sentNow,
          totalBytes: file.size,
        ),
      );
    });
    try {
      // Any `PeerHttpException` / IO error propagates: an upload failure is a
      // `failed` outcome, not a rejection (spec §4.4), and the orchestrator maps
      // it with `markSendFailed`. A local abort is the one exception — see
      // [_withActiveUpload].
      return await _withActiveUpload(
        prepared.sessionId,
        active,
        () => client.upload(
          sessionId: prepared.sessionId,
          fileId: file.id,
          token: token,
          file: File(file.localPath),
          // Forward the streamed-bytes report so the UI can show real progress
          // instead of sitting at 0% until the upload finishes. Also feeds the
          // rate probe above.
          onProgress: (int bytesSent) {
            latestBytes = bytesSent;
            onProgress?.call(bytesSent);
          },
        ),
      );
    } finally {
      rateTimer.cancel();
      keepAlive.cancel();
      client.close();
    }
  }

  @override
  Future<void> sendText({
    required PeerDevice peer,
    required String id,
    required String text,
  }) async {
    final client = _clientFor(peer);
    _reportPeerActivity(peer);
    try {
      await client.sendText(self: _selfInfo(), id: id, text: text);
    } on PeerHttpException catch (error) {
      // A `403` (receiving off) / `413` (too large) refusal; anything else (an
      // IO error) propagates and becomes a `failed` outcome upstream.
      throw PeerRejectedException(error.statusCode, error.message);
    } finally {
      client.close();
    }
  }

  @override
  Future<void> cancel({
    required PeerDevice peer,
    required String sessionId,
  }) async {
    if (sessionId.isEmpty) {
      return;
    }
    // 1. Abort the **local** stream (0.2.22). This is the half that was missing:
    //    `close(force: true)` tears the connection down, so the pending
    //    `addStream` / `request.close()` throws and `upload` surfaces a
    //    [TransferCanceledException] instead of streaming into the void until the
    //    OS keepalive gives up.
    final List<_ActiveUpload>? active = _activeUploads.remove(sessionId);
    if (active != null) {
      for (final _ActiveUpload entry in active) {
        entry.canceled = true;
        entry.client.close();
      }
    }
    // 2. Then tell the peer (best effort, separate client): it stops its own
    //    session timer and frees the partial file at once instead of waiting for
    //    its timeout. Errors are the caller's to swallow — the orchestrator does,
    //    because a peer that just vanished is exactly this case.
    final client = _clientFor(peer);
    try {
      await client.cancel(sessionId: sessionId);
    } finally {
      client.close();
    }
  }

  /// Stops the receiver (if running) and releases the event streams.
  Future<void> dispose() async {
    await stopReceiver();
    if (!_received.isClosed) {
      await _received.close();
    }
    if (!_registrations.isClosed) {
      await _registrations.close();
    }
    if (!_uploadRejected.isClosed) {
      await _uploadRejected.close();
    }
    if (!_receivedText.isClosed) {
      await _receivedText.close();
    }
  }

  // ── internals ───────────────────────────────────────────────────────────────

  /// Rebuilds the receiver with a new configuration, restoring the previous one
  /// on failure (spec §1.5). Rethrows the original failure.
  ///
  /// [saveDirectory] is optional so the accepting / alias paths keep their exact
  /// 0.2.22 shape; when it is given, the new server writes accepted files there
  /// and [_saveDirectory] only moves **after** the server started.
  Future<void> _rebuild({
    required bool accepting,
    required String alias,
    String? saveDirectory,
  }) async {
    final previous = _server;
    final previousAccepting = _accepting;
    final previousAlias = _alias;
    final previousSaveDirectory = _saveDirectory;
    await previous?.stop();
    _server = null;
    try {
      _server = await _startServer(
        accepting: accepting,
        alias: alias,
        saveDirectory: saveDirectory,
      );
    } on Object {
      try {
        _server = await _startServer(
          accepting: previousAccepting,
          alias: previousAlias,
        );
      } on Object {
        _server = null;
        _accepting = previousAccepting;
        _alias = previousAlias;
        _saveDirectory = previousSaveDirectory;
      }
      rethrow;
    }
  }

  /// Creates [directory] if needed and proves it is a **writable directory**.
  ///
  /// Throws [SaveDirectoryException] with a short, user-legible reason instead of
  /// a raw `FileSystemException`. The probe writes a tiny file and deletes it:
  /// `Directory.create` alone accepts plenty of paths the receiver cannot
  /// actually write to (an existing directory owned by another user, a mount
  /// that is read-only at the file level), and adopting one of those would put
  /// the failure back where it is invisible — at the next receive.
  Future<void> _ensureDirectory(String path) async {
    try {
      final Directory directory = Directory(path);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      if (!await directory.exists()) {
        throw const FileSystemException('directory was not created');
      }
      final File probe = File(p.join(path, '.lanlink-write-probe'));
      await probe.writeAsString('lanlink', flush: true);
      await probe.delete();
    } on Object catch (error) {
      _onLog?.call('SAVE 保存位置不可用：$path（$error）');
      throw SaveDirectoryException(path, _shortReason(path, error));
    }
  }

  /// A short reason for a rejected directory, for the settings error banner.
  String _shortReason(String path, Object error) {
    if (error is FileSystemException) {
      final String message = error.osError?.message ?? error.message;
      return '无法写入 $path（$message）';
    }
    return '无法写入 $path（$error）';
  }

  /// Builds and starts a [PeerServer], retrying the bind a few times.
  ///
  /// Windows can report "address in use" for a moment right after
  /// `close(force: true)` released the fixed port, so a rebind is retried three
  /// times, 150 ms apart (spec §1.5).
  ///
  /// [saveDirectory] overrides the current one for this build only (the
  /// `setSaveDirectory` rebuild); omitting it uses [_saveDirectory]. The field
  /// is updated **on success only**, so it never names a directory the running
  /// receiver is not using.
  Future<PeerServer> _startServer({
    required bool accepting,
    required String alias,
    String? saveDirectory,
  }) async {
    final String directoryPath = saveDirectory ?? _saveDirectory;
    final directory = Directory(directoryPath);
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      final server = PeerServer(
        alias: alias,
        certificates: _certificate,
        port: _tcpPort,
        saveDirectory: directory,
        acceptUploads: accepting,
        maxUploadBytes: _maxUploadBytes,
        maxSessions: _maxSessions,
        deviceType: _deviceType,
        deviceModel: _deviceModel,
        onLog: _onLog,
        onPeerSeen: _onPeerSeen,
        onUploadFinished: _onUploadFinished,
        onUploadRejected: _onUploadRejected,
        onTextReceived: _onTextReceived,
      );
      try {
        await server.start();
        _accepting = accepting;
        _alias = alias;
        _saveDirectory = directoryPath;
        return server;
      } on Object catch (error) {
        lastError = error;
        if (attempt < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
    }
    throw lastError!;
  }

  void _onPeerSeen(DeviceInfo info, String remoteAddress) {
    if (normalizeFingerprint(info.fingerprint).isEmpty) {
      return;
    }
    _registrations.add(
      discoveredPeerFromInfo(
        info,
        address: remoteAddress,
        isOnline: true,
        lastSeen: _clock.nowUtc(),
      ),
    );
  }

  /// Reports an **outbound** exchange with [peer] on the same channel
  /// [registrations] uses for inbound `/register` hits.
  ///
  /// The registry's only other liveness source is the peer's 5s UDP
  /// announcement, so while this device is the sender of a long transfer the
  /// receiver would otherwise be timed out as offline mid-stream (docs/13 §4).
  /// Emitting here makes discovery `touch` the peer, so a live TCP conversation
  /// keeps it online. Skipped for an unidentifiable fingerprint (it can own no
  /// registry row).
  void _reportPeerActivity(PeerDevice peer) {
    if (_registrations.isClosed ||
        normalizeFingerprint(peer.fingerprint).isEmpty) {
      return;
    }
    _registrations.add(
      DiscoveredPeer(
        fingerprint: peer.fingerprint,
        alias: peer.alias,
        kind: peer.kind,
        address: peer.lastIp ?? '',
        port: peer.lastPort ?? 0,
        isOnline: true,
        lastSeen: _clock.nowUtc(),
        model: peer.model,
      ),
    );
  }

  /// Turns one verified inbound file into a [ReceivedTransfer] event.
  ///
  /// **0.2.19 — publish before emitting.** The core receiver writes into this
  /// app's private directory, which no file manager on Android can open. So the
  /// bytes are first *published* to the user-visible store (`publishTransfer`),
  /// and the event emitted here already carries the public path — which is what
  /// `TransferOrchestrator` persists, and therefore what 复制文件路径 hands out.
  ///
  /// The `null`-publisher branch is the 0.2.18 path untouched: emit immediately,
  /// synchronously, with the private path.
  void _onUploadFinished(ReceivedFile file) {
    final ReceivedTransfer transfer =
        receivedTransferFromReceived(file, now: _clock.nowUtc());
    final ReceivedFilePublisher? publisher = _publisher;
    if (publisher == null) {
      _received.add(transfer);
      return;
    }
    // Queued (not awaited) so the core's callback returns immediately, and
    // chained so two files landing together are still recorded in order. The
    // catchError belt-and-braces: one failed publish must never stall the chain
    // and strand every later file.
    _publishChain = _publishChain
        .then((_) => _publishThenEmit(publisher, transfer))
        .catchError((Object error) {
      _onLog?.call(
        'PUBLISH 导出失败：${transfer.file.fileName}（$error），文件仍在应用内部',
      );
    });
  }

  /// Publishes [transfer]'s file, then emits the event with the recorded path.
  ///
  /// `publishTransfer` never throws by contract; the guard is there so a defect
  /// in it can still not lose the event (the file exists on disk either way, and
  /// a history row is better than none).
  Future<void> _publishThenEmit(
    ReceivedFilePublisher publisher,
    ReceivedTransfer transfer,
  ) async {
    ReceivedTransfer recorded = transfer;
    try {
      recorded = await publisher.publishTransfer(transfer);
    } on Object catch (error) {
      _onLog?.call(
        'PUBLISH 导出失败：${transfer.file.fileName}（$error），文件仍在应用内部',
      );
    }
    if (_received.isClosed) {
      return;
    }
    _received.add(recorded);
  }

  /// Converts the core server's refusal callback into this layer's event stream
  /// (core speaks callbacks; the app-facing port speaks streams, like
  /// [received]).
  void _onUploadRejected(DeviceInfo? peer, UploadRejectReason reason) {
    _uploadRejected.add(
      uploadRejectedFromCore(peer, reason, now: _clock.nowUtc()),
    );
  }

  /// Turns the core server's accepted-text callback into this layer's stream
  /// (docs/13 §7.3), the same way [_onUploadFinished] does for files.
  void _onTextReceived(DeviceInfo sender, TextMessage message) {
    _receivedText.add(
      receivedTextFromCore(sender, message, now: _clock.nowUtc()),
    );
  }

  DeviceInfo _selfInfo() => DeviceInfo(
        alias: _alias,
        fingerprint: _certificate.fingerprint,
        port: _server?.actualPort ?? _tcpPort,
        deviceType: _deviceType,
        deviceModel: _deviceModel,
        protocol: ProtocolScheme.https,
        download: _accepting,
        announce: false,
      );

  PeerClient _clientFor(PeerDevice peer) {
    final host = peer.lastIp;
    final port = peer.lastPort;
    if (host == null || host.isEmpty || port == null || port <= 0) {
      throw StateError(
        'peer ${peer.fingerprint} is not dialable '
        '(${host ?? 'no address'}:${port ?? 'no port'})',
      );
    }
    return PeerClient(
      host: host,
      port: port,
      expectedFingerprint: peer.fingerprint,
      certificate: _certificate,
      onLog: _onLog,
    );
  }
}

/// One upload currently streaming inside [LanTransferService] (0.2.22).
///
/// Holds the [PeerClient] that owns the socket so a [LanTransferService.cancel]
/// can force it shut: the cancel runs on a **different** client instance, so
/// without this registry it had no handle on the transfer it was meant to stop.
class _ActiveUpload {
  /// Registers the client streaming one file.
  _ActiveUpload(this.client);

  /// The client whose connection is carrying this file's bytes.
  final PeerClient client;

  /// Set by a cancel before the client is closed, so the resulting
  /// `SocketException` is reported as **our** abort rather than a network fault.
  bool canceled = false;
}
