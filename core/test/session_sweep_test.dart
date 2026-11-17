import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// The receive session table must not be a one-way ratchet (0.2.41).
///
/// **The bug this pins down.** `_sessions` used to only ever grow — `/cancel`
/// was the single deletion point — while `maxSessions` (64) answered `503` to
/// everything past it. `/prepare` needs no pairing and no prior `hello`, so any
/// host on the LAN could send 64 one-file prepares, upload nothing, and leave
/// **every** legitimate sender refused until the receiver was restarted. A
/// folder send makes it worse: one `prepare` holds a session for the whole
/// batch, which is minutes rather than seconds.
///
/// The fix is a lazy sweep (no timer): a later `prepare` reclaims sessions that
/// have been idle longer than [kSessionIdleTimeout] **and** have no upload in
/// flight. These tests drive the clock by injection — nothing here sleeps.
void main() {
  late Directory root;
  late DeviceCertificate serverCert;
  late DeviceCertificate clientCert;
  late DeviceInfo self;
  late Directory saveDir;
  late Directory srcDir;
  late _FakeClock clock;
  late List<String> logs;
  late PeerServer server;
  late PeerClient client;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('lanlink_sweep_');
    serverCert = await DeviceCertificate.loadOrCreate(
      directory: Directory('${root.path}${Platform.pathSeparator}server-cert'),
    );
    clientCert = await DeviceCertificate.loadOrCreate(
      directory: Directory('${root.path}${Platform.pathSeparator}client-cert'),
      commonName: 'sender',
    );
    self = DeviceInfo(
      alias: 'Sender',
      fingerprint: clientCert.fingerprint,
      port: 0,
    );
  });

  tearDownAll(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  /// Builds a receiver around the shared fake clock.
  ///
  /// [spawner] replaces the hash worker; the two cases that need to hold a
  /// `/put` in flight pass a gated backend, everything else leaves it `null`
  /// (the real worker), which is also what production does.
  ///
  /// [beforeResolveTarget] is the CR-2 ④ seam: awaited between "this session is
  /// busy" and "the landing directory exists".
  Future<void> startServer({
    HashWorkerSpawner? spawner,
    Future<void> Function(String sessionId, String fileId)? beforeResolveTarget,
  }) async {
    saveDir = await Directory.systemTemp.createTemp('lanlink_sweep_recv_');
    srcDir = await Directory.systemTemp.createTemp('lanlink_sweep_src_');
    server = PeerServer(
      alias: 'Receiver',
      certificates: serverCert,
      saveDirectory: saveDir,
      acceptUploads: true,
      port: 0,
      onLog: logs.add,
      hashWorkerSpawner: spawner,
      beforeResolveTarget: beforeResolveTarget,
      now: clock.now,
    );
    await server.start();
    client = PeerClient(
      host: '127.0.0.1',
      port: server.actualPort,
      expectedFingerprint: server.fingerprint,
    );
  }

  setUp(() {
    clock = _FakeClock();
    logs = <String>[];
  });

  tearDown(() async {
    client.close();
    await server.stop();
    for (final Directory dir in <Directory>[saveDir, srcDir]) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  /// One declared-but-never-uploaded file — the cheapest way to take a slot.
  Future<PrepareUploadResponse> takeSlot(String id) => client.prepareUpload(
        self: self,
        files: <FileMetadata>[
          FileMetadata(id: id, fileName: '$id.bin', size: 0),
        ],
      );

  // -------------------------------------------------------------------
  // 1. The stranded receiver heals itself
  // -------------------------------------------------------------------
  test('★ 64 abandoned prepares fill the table; 121 s later it is reclaimed',
      () async {
    await startServer();
    await client.register(self: self);

    // 64 one-file prepares, none of them ever uploaded, none cancelled — the
    // exact attack, at exactly the shipped cap.
    for (int i = 0; i < kDefaultMaxSessions; i++) {
      final PrepareUploadResponse prepared = await takeSlot('s$i');
      expect(prepared.sessionId, isNotEmpty);
    }
    expect(server.openSessionCount, kDefaultMaxSessions);

    // 65th: the cap is still enforced, so the fix did not turn the limit off.
    await expectLater(
      takeSlot('overflow'),
      throwsA(
        isA<PeerHttpException>()
            .having((e) => e.statusCode, 'statusCode', 503),
      ),
    );
    expect(server.openSessionCount, kDefaultMaxSessions);

    // One second past the idle timeout, the next prepare reclaims every one of
    // them *before* the cap check — the three numbers of this criterion are
    // 64, 65→503, and 121 s.
    clock.advance(kSessionIdleTimeout + const Duration(seconds: 1));
    final PrepareUploadResponse after = await takeSlot('fresh');
    expect(after.sessionId, isNotEmpty);
    expect(server.openSessionCount, 1,
        reason: 'the 64 idle sessions were reclaimed; only the new one is left');
    expect(
      logs.where((String line) => line.startsWith('session sweep:')).length, 1,
      reason: 'one aggregated line, not 64',
    );
  });

  test('the sweep runs only when it can change an answer (lazy, no timer)',
      () async {
    await startServer();
    final File source = File('${srcDir.path}${Platform.pathSeparator}idle.bin');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final PrepareUploadResponse prepared = await takeSlot('idle');
    expect(server.openSessionCount, 1);

    // Nothing sweeps here: an idle receiver does no work at all. Three timeouts
    // go by and the session is still there, because nobody asked.
    clock.advance(kSessionIdleTimeout * 3);
    expect(server.openSessionCount, 1,
        reason: 'the sweep is a query-time step, not a background timer');

    // The next prepare is what reclaims it — and the reclaimed id now behaves
    // exactly like a session that never existed.
    await takeSlot('next');
    expect(server.openSessionCount, 1);
    await expectLater(
      client.upload(
        sessionId: prepared.sessionId,
        fileId: 'idle',
        token: 'irrelevant',
        file: source,
      ),
      throwsA(
        isA<PeerHttpException>()
            .having((e) => e.statusCode, 'statusCode', 403),
      ),
    );
  });

  test('exactly at the timeout the session is kept (the boundary is >)',
      () async {
    await startServer();
    await takeSlot('edge');
    clock.advance(kSessionIdleTimeout);
    await takeSlot('edge2');
    expect(server.openSessionCount, 2,
        reason: 'idle == TTL is not yet "longer than TTL"');
  });

  // -------------------------------------------------------------------
  // 2. A session with an upload in flight is never swept
  // -------------------------------------------------------------------
  test('★ an in-flight upload keeps its session alive no matter how old', () async {
    // **How "in flight" is simulated, and two approaches that did not work.**
    //
    //  * Gating the hasher's *acks* is not enough: `IsolateHasher.add` waits for
    //    a credit slot, not for that chunk's ack, so a small body streams
    //    straight through. A mutation proved it — deleting the `activeUploads`
    //    guard did not turn the test red.
    //  * Holding the body open on the client does not work either: Dart's
    //    `HttpClientRequest` does not push a partial body (`flush()` included),
    //    so the server never leaves its pre-stream code.
    //
    // What works is holding the **digest**: the backend acks every chunk (so
    // nothing depends on how the socket happens to split the body) but never
    // answers `finish()`. The handler then parks inside its `try` at
    // `await hash.finish()`, with the body fully read and `activeUploads == 1` —
    // exactly the state a multi-minute upload sits in for most of its life.
    final Completer<void> gate = Completer<void>();
    final Completer<_HeldDigestBackend> backendReady =
        Completer<_HeldDigestBackend>();
    await startServer(
      spawner: () async {
        final _HeldDigestBackend created = _HeldDigestBackend(gate.future);
        backendReady.complete(created);
        return created;
      },
    );
    await client.register(self: self);

    const int size = 4096;
    final File source = File('${srcDir.path}${Platform.pathSeparator}big.bin');
    await source.writeAsBytes(List<int>.filled(size, 7));

    final PrepareUploadResponse prepared = await client.prepareUpload(
      self: self,
      files: <FileMetadata>[
        FileMetadata(id: 'big', fileName: 'big.bin', size: size),
      ],
    );

    final Future<int> uploading = client.upload(
      sessionId: prepared.sessionId,
      fileId: 'big',
      token: prepared.files['big']!,
      file: source,
    );
    // The whole body is in and the handler is waiting for its digest — i.e. the
    // `/put` is unmistakably still in progress.
    final _HeldDigestBackend backend = await backendReady.future;
    await backend.reachedFinish.future;

    // Ten minutes — five times the idle timeout — while the request is in flight.
    clock.advance(const Duration(minutes: 10));
    await takeSlot('while-busy'); // triggers the sweep

    expect(server.openSessionCount, 2,
        reason: '★ the busy session must survive: one upload starts no new '
            'request, so only activeUploads can protect it');

    // Release the digest: the transfer itself must be unharmed.
    gate.complete();
    expect(await uploading, size);
    final File landed = File('${saveDir.path}${Platform.pathSeparator}big.bin');
    expect(await landed.length(), size);

    // …and once it is idle again, the TTL applies to it like any other session.
    clock.advance(kSessionIdleTimeout + const Duration(seconds: 1));
    await takeSlot('after-done');
    await expectLater(
      client.upload(
        sessionId: prepared.sessionId,
        fileId: 'big',
        token: prepared.files['big']!,
        file: landed,
      ),
      throwsA(
        isA<PeerHttpException>()
            .having((e) => e.statusCode, 'statusCode', 403),
      ),
      reason: 'the reclaimed session is gone; the file on disk is not',
    );
  });

  // -------------------------------------------------------------------
  // 2b. The window *before* the bytes start flowing (CR-2 ④)
  // -------------------------------------------------------------------
  test('★ a /put whose landing directory stalls keeps its session alive',
      () async {
    // **The bug.** `activeUploads += 1` used to sit immediately before the
    // stream loop — i.e. *after* `_resolveTarget`, which really creates the
    // landing directory and runs an `exists()` loop on it. Between the
    // `lastActivityAt` stamp and that increment the only protection was the
    // timestamp, so a `_resolveTarget` slower than [kSessionIdleTimeout] (a
    // spun-down external disk, an SMB mount, a full antivirus scan) let another
    // `prepare`'s sweep delete a session that was **in use** — and every
    // remaining `put` of the batch then answered 403.
    //
    // The seam is what makes "slower than 120 s" reachable without waiting.
    final Completer<void> reachedResolve = Completer<void>();
    final Completer<void> releaseResolve = Completer<void>();
    await startServer(
      beforeResolveTarget: (String sessionId, String fileId) async {
        if (!reachedResolve.isCompleted) {
          reachedResolve.complete();
        }
        await releaseResolve.future;
      },
    );
    await client.register(self: self);

    const int size = 64;
    final File source = File('${srcDir.path}${Platform.pathSeparator}s.bin');
    await source.writeAsBytes(List<int>.filled(size, 4));

    final PrepareUploadResponse prepared = await client.prepareUpload(
      self: self,
      files: <FileMetadata>[
        FileMetadata(id: 'a', fileName: 'a.bin', size: size),
        FileMetadata(id: 'b', fileName: 'b.bin', size: size),
      ],
    );

    final Future<int> first = client.upload(
      sessionId: prepared.sessionId,
      fileId: 'a',
      token: prepared.files['a']!,
      file: source,
    );
    // The handler is now parked *inside* the landing-directory step, with the
    // session unmistakably in use and no byte streamed yet.
    await reachedResolve.future;

    // Ten minutes — five idle timeouts — then a rival `prepare`, which is what
    // runs the sweep.
    clock.advance(const Duration(minutes: 10));
    await takeSlot('rival');

    expect(server.openSessionCount, 2,
        reason: '★ the session being resolved is in use: only activeUploads '
            'can say so, and it must be raised before the I/O starts');

    releaseResolve.complete();
    expect(await first, size, reason: 'the stalled put still completes');

    // The rest of the batch must still be accepted — this is the half the user
    // notices: before the fix these answered 403 and the folder arrived short.
    final int second = await client.upload(
      sessionId: prepared.sessionId,
      fileId: 'b',
      token: prepared.files['b']!,
      file: source,
    );
    expect(second, size, reason: '★ the sibling file of the same session');
    expect(
      await File('${saveDir.path}${Platform.pathSeparator}b.bin').exists(),
      isTrue,
    );
  });

  // -------------------------------------------------------------------
  // 3. Activity extends the life of a session
  // -------------------------------------------------------------------
  test('★ five uploads 60 s apart span 300 s without being swept', () async {
    await startServer();
    await client.register(self: self);

    const int size = 128;
    final File source = File('${srcDir.path}${Platform.pathSeparator}s.bin');
    await source.writeAsBytes(List<int>.filled(size, 3));

    final Map<String, FileMetadata> files = <String, FileMetadata>{
      for (int i = 0; i < 5; i++)
        'f$i': FileMetadata(id: 'f$i', fileName: 'f$i.bin', size: size),
    };
    final PrepareUploadResponse prepared =
        await client.prepareUpload(self: self, files: files.values.toList());

    // 5 × 60 s = 300 s, i.e. 2.5× the timeout — the batch must survive it
    // because every put refreshes `lastActivityAt`.
    for (int i = 0; i < 5; i++) {
      clock.advance(const Duration(seconds: 60));
      final int sent = await client.upload(
        sessionId: prepared.sessionId,
        fileId: 'f$i',
        token: prepared.files['f$i']!,
        file: source,
      );
      expect(sent, size, reason: 'upload #${i + 1} of the same session');
    }

    // Trigger a sweep: the session was active moments ago, so it stays.
    await takeSlot('trigger');
    expect(server.openSessionCount, 2,
        reason: '★ the long-lived session is still open: no gap ever exceeded '
            'the timeout, so nothing should have reaped it');
  });

  // -------------------------------------------------------------------
  // 4. Reclaiming a slot never touches the disk
  // -------------------------------------------------------------------
  test('★ a swept session leaves its already-written file on disk', () async {
    await startServer();
    await client.register(self: self);

    const int size = 64;
    final File source = File('${srcDir.path}${Platform.pathSeparator}k.bin');
    await source.writeAsBytes(List<int>.filled(size, 9));

    final PrepareUploadResponse prepared = await client.prepareUpload(
      self: self,
      files: <FileMetadata>[
        FileMetadata(id: 'k', fileName: 'k.bin', size: size),
      ],
    );
    await client.upload(
      sessionId: prepared.sessionId,
      fileId: 'k',
      token: prepared.files['k']!,
      file: source,
    );
    final File landed =
        File('${saveDir.path}${Platform.pathSeparator}k.bin');
    expect(await landed.exists(), isTrue);

    clock.advance(kSessionIdleTimeout + const Duration(seconds: 1));
    await takeSlot('reclaim');

    expect(server.openSessionCount, 1);
    expect(
      await landed.exists(),
      isTrue,
      reason: '★ a reclaimed slot is bookkeeping, not a delete: the file belongs '
          'to the received message, which the store may already have recorded',
    );
    expect(await landed.readAsBytes(), List<int>.filled(size, 9));
  });

  // -------------------------------------------------------------------
  // 5. Unknown / reclaimed sessions answer the same way as before
  // -------------------------------------------------------------------
  test('a put for an unknown session is still 403, not a sweep-specific code',
      () async {
    await startServer();
    final File source = File('${srcDir.path}${Platform.pathSeparator}u.bin');
    await source.writeAsBytes(<int>[1]);

    for (final String sessionId in <String>['never-existed', '']) {
      await expectLater(
        client.upload(
          sessionId: sessionId,
          fileId: 'u',
          token: 't',
          file: source,
        ),
        throwsA(
          isA<PeerHttpException>()
              .having((e) => e.statusCode, 'statusCode', 403),
        ),
        reason: 'session "$sessionId" is unknown, and that answer is unchanged',
      );
    }
  });
}

/// A clock the test drives. Nothing in this file waits for real time.
class _FakeClock {
  DateTime value = DateTime.utc(2026, 1, 1, 12);

  DateTime now() => value;

  void advance(Duration delta) => value = value.add(delta);
}

/// A hash backend that **holds the digest** until the test releases it, and
/// reports when the receiver has reached that point.
///
/// Chunks are acknowledged immediately: credit is not the lever here (see the
/// note in the in-flight test — relying on it makes the test depend on how the
/// socket happens to split the body). What parks the `/put` is `finish()` never
/// answering, which keeps the handler inside its `try` — and therefore keeps
/// `activeUploads` at 1 — for as long as the test needs.
///
/// The released digest is deliberately a *failure*: the receiver then re-hashes
/// from disk (a path with its own test), so this backend needs no digest
/// arithmetic and the upload still ends in a correct `200`.
class _HeldDigestBackend implements HashWorkerBackend {
  _HeldDigestBackend(this._gate);

  final Future<void> _gate;
  final StreamController<HashWorkerEvent> _events =
      StreamController<HashWorkerEvent>();

  /// Completed when the receiver asks for the digest — i.e. the body has been
  /// read and the `/put` is waiting on the worker.
  final Completer<void> reachedFinish = Completer<void>();

  @override
  Stream<HashWorkerEvent> get events => _events.stream;

  @override
  void addChunk(Uint8List chunk) {
    if (!_events.isClosed) {
      _events.add(HashWorkerAck(chunk.length));
    }
  }

  @override
  void finish() {
    if (!reachedFinish.isCompleted) {
      reachedFinish.complete();
    }
    unawaited(
      _gate.then((_) {
        if (!_events.isClosed) {
          _events.add(const HashWorkerFailure('held-digest test worker'));
        }
      }),
    );
  }

  @override
  Future<void> dispose() async {
    if (!_events.isClosed) {
      await _events.close();
    }
  }
}
