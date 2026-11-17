import 'dart:async';

import '../../domain/id_factory.dart';
import '../../domain/models.dart';
import '../../domain/transfer_service.dart';

/// In-memory, fully controllable [TransferService].
///
/// Pure Dart (M4 §8.1): imports only `dart:async` and this app's `domain/`.
/// By default every send succeeds; a test can arm a rejection (`403/413/503`),
/// a thrown error, or a fixed uploaded-byte count before calling, and can push
/// inbound `received` / `registrations` events on demand.
class FakeTransferService implements TransferService {
  /// Creates the fake. [accepting] / [localPort] are the initial receiver
  /// state; [localPort] of `null` means "no receiver running".
  ///
  /// [accepting] defaults to **`true`**, mirroring production since 0.2.25: the
  /// real receiver is built with `acceptUploads: settings.acceptByDefault`
  /// (`create_deps_native.dart`), and that default is now on. A fake that kept
  /// `false` here would let a test prove "the switch works" against a state a
  /// fresh install can no longer be in — the green would be about the fake, not
  /// the product.
  FakeTransferService({
    required IdFactory ids,
    bool accepting = true,
    int? localPort = 53317,
    String alias = 'This device',
    String saveDirectory = '/fake/received',
  })  : _ids = ids,
        _accepting = accepting,
        _localPort = localPort,
        _alias = alias,
        _saveDirectory = saveDirectory;

  final IdFactory _ids;

  final StreamController<ReceivedTransfer> _received =
      StreamController<ReceivedTransfer>.broadcast();
  final StreamController<DiscoveredPeer> _registrations =
      StreamController<DiscoveredPeer>.broadcast();
  final StreamController<UploadRejected> _uploadRejected =
      StreamController<UploadRejected>.broadcast();
  final StreamController<ReceivedText> _receivedText =
      StreamController<ReceivedText>.broadcast();

  bool _accepting;
  int? _localPort;
  String _alias;

  /// The directory the fake's receiver "writes" into (0.2.23).
  ///
  /// A fake has no files to write, but it must still answer the same port:
  /// `saveDirectory` names the value **in force**, so a test can assert that a
  /// refused change really rolled back instead of only checking that an error
  /// was shown.
  String _saveDirectory;

  int? _rejectPrepareCode;
  String _rejectPrepareMessage = '';
  Object? _prepareError;
  Completer<void>? _prepareHold;
  Object? _uploadError;
  int? _uploadedBytesOverride;
  Completer<void>? _uploadHold;
  Completer<void>? _uploadCancel;
  int? _burstCount;
  void Function()? _burstStep;
  int? _rejectTextCode;
  String _rejectTextMessage = '';
  Object? _textError;

  final List<String> cancelledSessions = <String>[];

  /// Every [cancel] call as `(peer, sessionId)` (0.2.22), so a test can pin that
  /// the abort targeted the peer and session the bytes were actually going to.
  final List<({PeerDevice peer, String sessionId})> cancels =
      <({PeerDevice peer, String sessionId})>[];

  /// Every session id this fake has handed out from [prepare], in order — the
  /// reference a cancel test compares [cancels] against.
  final List<String> preparedSessions = <String>[];

  /// The `files` of the most recent [prepare] (0.2.38).
  ///
  /// This is what a test reads to prove the **whole batch** reached the wire —
  /// `folder.count == 3` alone would also hold for an implementation that
  /// declared three and sent two, which is exactly the kind of green that means
  /// nothing.
  List<OutgoingFile> lastPreparedFiles = const <OutgoingFile>[];

  /// The `folder` of the most recent [prepare], or `null` for a flat send.
  FolderRef? lastPreparedFolder;

  /// How many times [prepare] was called — lets a test prove "nothing was sent"
  /// (criterion d2: a misaligned `relativePaths` must throw before any byte).
  int prepareCalls = 0;

  /// Every text frame sent through [sendText], in order (test convenience).
  final List<({String id, String text})> sentTexts =
      <({String id, String text})>[];

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
  int? get localPort => _localPort;

  @override
  Future<void> startReceiver() async {
    _localPort ??= 53317;
  }

  @override
  Future<void> stopReceiver() async {
    _localPort = null;
  }

  @override
  Future<void> setAccepting(bool value) async {
    _accepting = value;
  }

  @override
  Future<void> setAlias(String alias) async {
    _alias = alias;
  }

  /// The alias most recently set through [setAlias] (test convenience).
  String get alias => _alias;

  @override
  String get saveDirectory => _saveDirectory;

  /// Arms a refusal for [setSaveDirectory]: the next call throws a
  /// [SaveDirectoryException] instead of applying (0.2.23).
  String? failSaveDirectoryWith;

  @override
  Future<void> setSaveDirectory(String directory) async {
    final String? refusal = failSaveDirectoryWith;
    if (refusal != null) {
      failSaveDirectoryWith = null;
      // The real adapter probes the path *before* touching the receiver, so a
      // refused change leaves the previous directory in force. Mirror that here
      // — a fake that applied the value anyway would let a rollback bug pass.
      throw SaveDirectoryException(directory, refusal);
    }
    _saveDirectory = directory;
    saveDirectoryChanges.add(directory);
  }

  /// Every directory accepted by [setSaveDirectory], in order (test convenience).
  final List<String> saveDirectoryChanges = <String>[];

  @override
  Future<PreparedUpload> prepare({
    required PeerDevice peer,
    required List<OutgoingFile> files,
    FolderRef? folder,
  }) async {
    // Recorded before any of the failure hooks below: a test asserting "the
    // folder reached `prepare`" must be able to see it even on the paths that
    // then throw (a rejected prepare is precisely where the frame matters).
    lastPreparedFiles = List<OutgoingFile>.unmodifiable(files);
    lastPreparedFolder = folder;
    prepareCalls += 1;
    // A held prepare parks the send in `awaitingConfirm`, which is the one window
    // a 0.2.22 test needs to observe (cancel before the peer has answered — i.e.
    // before a session id exists).
    final hold = _prepareHold;
    if (hold != null) {
      _prepareHold = null;
      await hold.future;
    }
    final prepareError = _prepareError;
    if (prepareError != null) {
      _prepareError = null;
      throw prepareError;
    }
    final rejectCode = _rejectPrepareCode;
    if (rejectCode != null) {
      _rejectPrepareCode = null;
      throw PeerRejectedException(rejectCode, _rejectPrepareMessage);
    }
    final sessionId = _ids.newId();
    preparedSessions.add(sessionId);
    final tokens = <String, String>{
      for (final file in files) file.id: _ids.newId(),
    };
    return PreparedUpload(sessionId: sessionId, tokens: tokens);
  }

  @override
  Future<int> upload({
    required PeerDevice peer,
    required PreparedUpload prepared,
    required OutgoingFile file,
    void Function(int bytesSent)? onProgress,
  }) async {
    // A held upload parks here *before* reporting progress, so a test can
    // observe the in-flight window (progress ticker, live percentage) instead
    // of racing an upload that otherwise finishes in one microtask.
    //
    // Since 0.2.22 the hold is also what a [cancel] can abort: the real client
    // stops streaming the moment the socket is closed, and the upload then
    // throws [TransferCanceledException]. Reproducing that here is what lets a
    // cancel-mid-transfer test assert the *outcome* rather than only the call.
    final hold = _uploadHold;
    if (hold != null) {
      _uploadHold = null;
      final cancelSignal = _uploadCancel = Completer<void>();
      try {
        await Future.any(<Future<void>>[hold.future, cancelSignal.future]);
      } finally {
        if (identical(_uploadCancel, cancelSignal)) {
          _uploadCancel = null;
        }
      }
      if (cancelSignal.isCompleted) {
        throw const TransferCanceledException('canceled by a test');
      }
    }
    // A burst emits [n] callbacks the way a real upload would (one per MiB),
    // calling the hook before each so a test can advance its fixed clock and
    // simulate the elapsed wall time of the transfer.
    final burst = _burstCount;
    if (burst != null) {
      _burstCount = null;
      final hook = _burstStep;
      _burstStep = null;
      for (var i = 1; i <= burst; i++) {
        hook?.call();
        onProgress?.call((file.size * i / burst).round());
      }
    }
    // The fake finishes in one go, so it reports the whole size — the same
    // contract the real client keeps (a final call always lands).
    onProgress?.call(file.size);
    final uploadError = _uploadError;
    if (uploadError != null) {
      _uploadError = null;
      throw uploadError;
    }
    return _uploadedBytesOverride ?? file.size;
  }

  @override
  Future<void> sendText({
    required PeerDevice peer,
    required String id,
    required String text,
  }) async {
    final textError = _textError;
    if (textError != null) {
      _textError = null;
      throw textError;
    }
    final rejectCode = _rejectTextCode;
    if (rejectCode != null) {
      _rejectTextCode = null;
      throw PeerRejectedException(rejectCode, _rejectTextMessage);
    }
    sentTexts.add((id: id, text: text));
  }

  @override
  Future<void> cancel({
    required PeerDevice peer,
    required String sessionId,
  }) async {
    cancelledSessions.add(sessionId);
    cancels.add((peer: peer, sessionId: sessionId));
    // Same shape as the real adapter (0.2.22): aborting a session also stops the
    // upload that is streaming under it. A test that holds an upload and then
    // cancels therefore sees `upload` throw [TransferCanceledException], exactly
    // as the production client does when its socket is force-closed.
    final Completer<void>? signal = _uploadCancel;
    if (signal != null && !signal.isCompleted) {
      signal.complete();
    }
  }

  // ── programmable control (test / preview only) ────────────────────────

  /// The next [prepare] throws a [PeerRejectedException] with [statusCode].
  void rejectNextPrepare(int statusCode, [String message = '']) {
    _rejectPrepareCode = statusCode;
    _rejectPrepareMessage = message;
  }

  /// The next [prepare] throws [error] (e.g. a simulated network failure).
  void failNextPrepare(Object error) => _prepareError = error;

  /// Holds the next [prepare] until [gate] completes, so a test can cancel while
  /// the message is still `awaitingConfirm` (0.2.22).
  void holdNextPrepare(Completer<void> gate) => _prepareHold = gate;

  /// The next [upload] throws [error].
  void failNextUpload(Object error) => _uploadError = error;

  /// Forces the byte count the next [upload] reports (default: file size).
  void setUploadedBytes(int bytes) => _uploadedBytesOverride = bytes;

  /// Holds the next [upload] until [gate] completes.
  ///
  /// Used to keep a send "in flight" long enough to observe the progress ticker
  /// (0.2.12: `resend` used to skip starting it, so a re-send sat at 0%).
  void holdNextUpload(Completer<void> gate) => _uploadHold = gate;

  /// Makes the next [upload] report [count] progress callbacks, calling [onStep]
  /// before each one.
  ///
  /// A real upload reports once per MiB while wall time passes, which is exactly
  /// what the orchestrator's persistence throttle has to cope with; a test can
  /// pass `onStep: () => clock.advance(...)` to reproduce that without sleeping.
  void reportProgressInBurst({required int count, void Function()? onStep}) {
    _burstCount = count;
    _burstStep = onStep;
  }

  /// The next [sendText] throws a [PeerRejectedException] with [statusCode].
  void rejectNextText(int statusCode, [String message = '']) {
    _rejectTextCode = statusCode;
    _rejectTextMessage = message;
  }

  /// The next [sendText] throws [error] (e.g. a simulated network failure).
  void failNextText(Object error) => _textError = error;

  /// Pushes a completed inbound transfer (E1–E13 / A3 preview).
  void emitReceived(ReceivedTransfer transfer) => _received.add(transfer);

  /// Pushes an accepted inbound text frame (docs/13 §7.3).
  void emitReceivedText(ReceivedText text) => _receivedText.add(text);

  /// Pushes a `/register` hit for [peer].
  void emitRegistration(DiscoveredPeer peer) => _registrations.add(peer);

  /// Pushes a refusal (the receiver turned away an inbound request).
  void emitUploadRejected(UploadRejected event) => _uploadRejected.add(event);

  /// Releases the event streams.
  void dispose() {
    _received.close();
    _registrations.close();
    _uploadRejected.close();
    _receivedText.close();
  }
}
