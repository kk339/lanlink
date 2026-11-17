import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:path/path.dart' as pathlib;
import 'package:test/test.dart';

/// End-to-end transfer tests over a **real TLS loopback connection**:
/// register → prepare-upload → upload, exercising the exact `lanlink/v1` wire
/// format end to end (including an 8 MiB round trip).
///
/// The receiver uses a self-signed certificate and the sender pins it by
/// fingerprint, so the handshake path is the same one the product uses.
void main() {
  String p(Directory dir, String name) =>
      '${dir.path}${Platform.pathSeparator}$name';

  late Directory root;
  late DeviceCertificate serverCert;
  late DeviceCertificate clientCert;
  late DeviceInfo self;

  // The main, upload-accepting receiver, rebuilt before each test.
  late Directory saveDir;
  late Directory srcDir;
  late PeerServer server;
  late List<String> logs;
  late List<ReceivedFile> finished;
  late List<(DeviceInfo, TextMessage)> textsReceived;
  late List<(DeviceInfo, String)> seen;
  late PeerClient client;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('lanlink_e2e_');
    // Two key pairs are generated once for the whole suite (RSA key generation
    // is slow); every test reuses them.
    serverCert = await DeviceCertificate.loadOrCreate(
      directory: Directory(p(root, 'server-cert')),
    );
    clientCert = await DeviceCertificate.loadOrCreate(
      directory: Directory(p(root, 'client-cert')),
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

  setUp(() async {
    finished = <ReceivedFile>[];
    textsReceived = <(DeviceInfo, TextMessage)>[];
    seen = <(DeviceInfo, String)>[];
    logs = <String>[];
    saveDir = await Directory.systemTemp.createTemp('lanlink_e2e_recv_');
    srcDir = await Directory.systemTemp.createTemp('lanlink_e2e_src_');
    server = PeerServer(
      alias: 'Receiver',
      certificates: serverCert,
      saveDirectory: saveDir,
      acceptUploads: true,
      port: 0, // let the OS pick a free port
      onLog: logs.add,
      onPeerSeen: (DeviceInfo info, String address) =>
          seen.add((info, address)),
      onUploadFinished: finished.add,
      onTextReceived: (DeviceInfo sender, TextMessage message) =>
          textsReceived.add((sender, message)),
    );
    await server.start();
    client = PeerClient(
      host: '127.0.0.1',
      port: server.actualPort,
      expectedFingerprint: server.fingerprint,
    );
    addTearDown(() async {
      client.close();
      await server.stop();
      for (final dir in <Directory>[saveDir, srcDir]) {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    });
  });

  test('upload reports streamed bytes while the body is still on the wire',
      () async {
    // 8 MiB: more than one 1 MiB progress step, small enough to stay quick.
    const int size = 8 * 1024 * 1024;
    final source = File(p(srcDir, 'progress.bin'));
    final sink = source.openWrite();
    final List<int> chunk = List<int>.filled(64 * 1024, 7);
    for (int written = 0; written < size; written += chunk.length) {
      sink.add(chunk);
    }
    await sink.close();
    final expectedSha = await sha256FileHex(source);

    final peer = await client.register(self: self);
    expect(peer.alias, 'Receiver');
    final meta = FileMetadata(
      id: 'file-progress',
      fileName: 'progress.bin',
      size: size,
      sha256: expectedSha,
    );
    final prepared =
        await client.prepareUpload(self: self, files: <FileMetadata>[meta]);
    final token = prepared.files['file-progress'];

    final duringStream = <int>[];
    final all = <int>[];
    bool uploadReturned = false;
    final sent = await client.upload(
      sessionId: prepared.sessionId,
      fileId: 'file-progress',
      token: token!,
      file: source,
      onProgress: (int bytesSent) {
        all.add(bytesSent);
        if (!uploadReturned) {
          duringStream.add(bytesSent);
        }
      },
    );
    uploadReturned = true;

    expect(sent, size);
    // RED before this change: progress was reported only once, after the body
    // had gone, so `duringStream` stayed empty and the UI showed 0% until it
    // jumped to 100%.
    expect(duringStream, isNotEmpty);
    expect(duringStream.length, greaterThanOrEqualTo(2));
    // Monotonic (never going backwards), and the final call always lands on the
    // whole size. Not strictly increasing: a step can already land exactly on
    // the total, and the closing call then repeats it.
    for (int i = 1; i < all.length; i++) {
      expect(all[i], greaterThanOrEqualTo(all[i - 1]));
    }
    expect(all.last, size);
  });

  test('happy path: register -> prepare-upload -> upload over real TLS',
      () async {
    final bytes = List<int>.generate(64 * 1024, (index) => index % 256);
    final source = File(p(srcDir, 'payload.bin'));
    await source.writeAsBytes(bytes);
    final expectedSha = await sha256FileHex(source);

    final peer = await client.register(self: self);
    expect(peer.alias, 'Receiver'); // 1

    final meta = FileMetadata(
      id: 'file-1',
      fileName: 'payload.bin',
      size: bytes.length,
      sha256: expectedSha,
    );
    final prepared =
        await client.prepareUpload(self: self, files: <FileMetadata>[meta]);
    expect(prepared.isEmpty, isFalse); // 2
    final token = prepared.files['file-1'];
    expect(token, isNotNull); // 3

    final sent = await client.upload(
      sessionId: prepared.sessionId,
      fileId: 'file-1',
      token: token!,
      file: source,
    );
    expect(sent, bytes.length); // 4

    expect(finished, hasLength(1)); // 5
    final record = finished.single;
    expect(record.fileName, 'payload.bin'); // 6
    expect(record.sha256, expectedSha); // 7
    expect(record.sha256Matched, isTrue); // 8

    // The bytes on disk are byte-identical to the source.
    expect(await File(record.savedPath).readAsBytes(), bytes); // 9
  });

  test('a big upload logs one parseable upload-stats summary (0.2.17)',
      () async {
    // 0.2.16 made the receive direction 1.24x faster, but it is still below the
    // opposite direction (10.1 vs 12.8 MiB/s) and there was *no* data on where
    // the remaining time goes. This is the line that carries it: produced by the
    // real handler over real TLS, and parsed here so the fields the device log
    // will be read for are verified rather than assumed.
    //
    // 5 MiB + 7 B: above the 4 MiB summary threshold, with a short tail chunk so
    // the chunk-shape fields have a min and a max that differ.
    const int size = 5 * 1024 * 1024 + 7;
    final source = File(p(srcDir, 'stats.bin'));
    final IOSink sourceSink = source.openWrite();
    final List<int> block =
        List<int>.generate(64 * 1024, (int i) => (i * 31) & 0xff);
    int written = 0;
    while (written < size) {
      final int remaining = size - written;
      final int take = remaining < block.length ? remaining : block.length;
      sourceSink.add(take == block.length ? block : block.sublist(0, take));
      written += take;
    }
    await sourceSink.close();
    final expectedSha = await sha256FileHex(source);

    await client.register(self: self);
    final meta = FileMetadata(
      id: 'stats',
      fileName: 'stats.bin',
      size: size,
      sha256: expectedSha,
    );
    final prepared =
        await client.prepareUpload(self: self, files: <FileMetadata>[meta]);
    final sent = await client.upload(
      sessionId: prepared.sessionId,
      fileId: 'stats',
      token: prepared.files['stats']!,
      file: source,
    );
    expect(sent, size);
    expect(finished, hasLength(1));
    expect(finished.single.savedPath, isNotEmpty);

    final List<String> summaries = logs
        .where((String line) => line.startsWith('upload stats: '))
        .toList(growable: false);
    expect(
      summaries,
      hasLength(1),
      reason: 'exactly one summary per upload - full log: $logs',
    );

    final Map<String, String> fields = _parseStatsLine(summaries.single);
    expect(int.parse(fields['bytes']!), size,
        reason: 'bytes must be the body length actually received');
    final int chunks = int.parse(fields['chunks']!);
    expect(chunks, greaterThan(0));

    double field(String key) => double.parse(
          fields[key]!
              .replaceAll('ms', '')
              .replaceAll('KiB', '')
              .replaceAll('%', ''),
        );

    // avg is the received bytes over the chunks counted, in KiB with one
    // decimal - so the tolerance is that rounding, not a guess.
    expect(field('avg'), closeTo(size / chunks / 1024, 0.06));
    // min <= avg <= max: the shape fields describe this same stream.
    expect(field('max'), greaterThan(0));
    expect(field('min'), lessThanOrEqualTo(field('avg') + 0.05));
    expect(field('max'), greaterThanOrEqualTo(field('avg') - 0.05));
    // …and their raw-byte repeats agree with them.
    final int minB = int.parse(fields['minB']!);
    final int maxB = int.parse(fields['maxB']!);
    expect(minB, greaterThan(0), reason: 'empty chunks are never counted');
    expect(minB, lessThanOrEqualTo(maxB));
    expect(minB * chunks, lessThanOrEqualTo(size));
    expect(maxB * chunks, greaterThanOrEqualTo(size));
    // The one invariant a reader of the log will rely on: the loop cannot be
    // shorter than the two phases measured inside it.
    expect(
      field('loop'),
      greaterThanOrEqualTo(field('hash') + field('sink') - 0.2),
      reason: 'loop >= hash + sink, ${summaries.single}',
    );
    expect(field('hashAwaitPct'), inInclusiveRange(0, 100));
    expect(fields.containsKey('worker'), isTrue,
        reason: 'the hasher mode changes how hash= must be read');
    // The line the on-device measurement depends on is untouched by 0.2.17.
    expect(
      logs.where((String line) => line.startsWith('RECEIVED ')),
      hasLength(1),
    );
  });

  test('a declared sha256 mismatch deletes the file and replies 400', () async {
    final source = File(p(srcDir, 'liar.bin'));
    await source.writeAsBytes(<int>[1, 2, 3, 4]);

    // The sender lies about the hash: the bytes do not have this SHA-256.
    final meta = const FileMetadata(
      id: 'bad',
      fileName: 'liar.bin',
      size: 4,
      sha256: 'DEADBEEF',
    );
    final prepared =
        await client.prepareUpload(self: self, files: <FileMetadata>[meta]);
    final token = prepared.files['bad']!;

    await expectLater(
      client.upload(
        sessionId: prepared.sessionId,
        fileId: 'bad',
        token: token,
        file: source,
      ),
      throwsA(
        isA<PeerHttpException>().having((e) => e.statusCode, 'statusCode', 400),
      ),
    );

    // ★ Design choice: a corrupt upload must NOT leave a file behind.
    expect(finished, isEmpty);
    expect(await saveDir.list().toList(), isEmpty);
  });

  test('an upload still verifies when the hash worker cannot be spawned',
      () async {
    // 0.2.16 fallback, through the real handler: a device where the worker
    // isolate cannot start (Web build, spawn failure, handshake timeout) must
    // keep accepting files at the old inline rate instead of failing them. An
    // injected spawner that throws is the same code path.
    final fallbackLogs = <String>[];
    final fallbackDir =
        await Directory.systemTemp.createTemp('lanlink_fallback_');
    final fallbackReceived = <ReceivedFile>[];
    final fallback = PeerServer(
      alias: 'Fallback',
      certificates: serverCert,
      saveDirectory: fallbackDir,
      acceptUploads: true,
      port: 0,
      onLog: fallbackLogs.add,
      onUploadFinished: fallbackReceived.add,
      hashWorkerSpawner: () async => throw StateError('no worker here'),
    );
    await fallback.start();
    final sender = PeerClient(
      host: '127.0.0.1',
      port: fallback.actualPort,
      expectedFingerprint: fallback.fingerprint,
    );
    addTearDown(() async {
      sender.close();
      await fallback.stop();
      if (await fallbackDir.exists()) {
        await fallbackDir.delete(recursive: true);
      }
    });

    // 1 MiB + 7 bytes: several 64 KiB chunks plus a short tail, so a dropped
    // last chunk would change the digest.
    const int size = 1024 * 1024 + 7;
    final source = File(p(srcDir, 'fallback.bin'));
    await source.writeAsBytes(
      List<int>.generate(size, (int i) => i & 0xff),
    );
    final expectedSha = await sha256FileHex(source);

    await sender.register(self: self);
    final meta = FileMetadata(
      id: 'fallback',
      fileName: 'fallback.bin',
      size: size,
      sha256: expectedSha,
    );
    final prepared =
        await sender.prepareUpload(self: self, files: <FileMetadata>[meta]);
    await sender.upload(
      sessionId: prepared.sessionId,
      fileId: 'fallback',
      token: prepared.files['fallback']!,
      file: source,
    );

    expect(fallbackReceived, hasLength(1));
    expect(fallbackReceived.single.sha256, expectedSha);
    expect(fallbackReceived.single.sha256Matched, isTrue);
    expect(
      fallbackLogs.join('\n'),
      contains('falling back to inline SHA-256'),
      reason: 'the degraded path must be visible in the receiver log',
    );
  });

  test('a worker that dies mid-stream falls back to re-hashing from disk',
      () async {
    // The other half of the 0.2.16 fallback: the worker was running and then
    // died, so its digest is unrecoverable (the chunks it already folded in were
    // transferred out of this isolate). The receiver must not answer with a
    // partial digest — that would delete a perfectly good file as a "mismatch" —
    // so it re-reads the file it has already written and carries on.
    final crashLogs = <String>[];
    final crashDir =
        await Directory.systemTemp.createTemp('lanlink_worker_crash_');
    final crashReceived = <ReceivedFile>[];
    final crashingServer = PeerServer(
      alias: 'Crashy',
      certificates: serverCert,
      saveDirectory: crashDir,
      acceptUploads: true,
      port: 0,
      onLog: crashLogs.add,
      onUploadFinished: crashReceived.add,
      hashWorkerSpawner: () async => _CrashingHashBackend(),
    );
    await crashingServer.start();
    final sender = PeerClient(
      host: '127.0.0.1',
      port: crashingServer.actualPort,
      expectedFingerprint: crashingServer.fingerprint,
    );
    addTearDown(() async {
      sender.close();
      await crashingServer.stop();
      if (await crashDir.exists()) {
        await crashDir.delete(recursive: true);
      }
    });

    const int size = 512 * 1024;
    final source = File(p(srcDir, 'crash.bin'));
    await source
        .writeAsBytes(List<int>.generate(size, (int i) => (i * 7) & 0xff));
    final expectedSha = await sha256FileHex(source);

    await sender.register(self: self);
    final meta = FileMetadata(
      id: 'crash',
      fileName: 'crash.bin',
      size: size,
      sha256: expectedSha,
    );
    final prepared =
        await sender.prepareUpload(self: self, files: <FileMetadata>[meta]);
    await sender.upload(
      sessionId: prepared.sessionId,
      fileId: 'crash',
      token: prepared.files['crash']!,
      file: source,
    );

    expect(crashReceived, hasLength(1));
    expect(crashReceived.single.sha256, expectedSha);
    expect(crashReceived.single.sha256Matched, isTrue);
    expect(
      crashLogs.join('\n'),
      contains('re-hashing'),
      reason: 'the degraded path must be visible in the receiver log',
    );
  });

  test('prepare-upload is refused with 403 when uploads are disabled',
      () async {
    final closed = PeerServer(
      alias: 'Closed',
      certificates: serverCert,
      acceptUploads: false, // the default; stated explicitly for the reader
      port: 0,
    );
    await closed.start();
    final asker = PeerClient(
      host: '127.0.0.1',
      port: closed.actualPort,
      expectedFingerprint: closed.fingerprint,
    );
    addTearDown(() async {
      asker.close();
      await closed.stop();
    });

    const meta = FileMetadata(id: 'x', fileName: 'x.bin', size: 0);
    await expectLater(
      asker.prepareUpload(self: self, files: <FileMetadata>[meta]),
      throwsA(
        isA<PeerHttpException>().having((e) => e.statusCode, 'statusCode', 403),
      ),
    );
  });

  test(
      'a refused prepare-upload also reports '
      'onUploadRejected(acceptingDisabled), naming the sender (P0-7 follow-up)',
      () async {
    // Before this callback existed the receiver stayed silent while the sender
    // saw 403: the store holds no record (the refusal precedes any write), so
    // the *local* UI had nothing to show. The callback is that trace.
    final List<(DeviceInfo?, UploadRejectReason)> rejections =
        <(DeviceInfo?, UploadRejectReason)>[];
    final closed = PeerServer(
      alias: 'Closed',
      certificates: serverCert,
      acceptUploads: false, // the default; stated explicitly for the reader
      port: 0,
      onUploadRejected: (DeviceInfo? peer, UploadRejectReason reason) =>
          rejections.add((peer, reason)),
    );
    await closed.start();
    final asker = PeerClient(
      host: '127.0.0.1',
      port: closed.actualPort,
      expectedFingerprint: closed.fingerprint,
    );
    addTearDown(() async {
      asker.close();
      await closed.stop();
    });

    // `/register` is NOT gated by `acceptUploads`, so a sender that registers
    // just before it prepares is still identifiable while receiving is off —
    // this is exactly what lets the refusal name it (without reading the body
    // of the request we are about to refuse).
    final peer = await asker.register(self: self);
    expect(peer.alias, 'Closed');

    const meta = FileMetadata(id: 'x', fileName: 'x.bin', size: 0);
    await expectLater(
      asker.prepareUpload(self: self, files: <FileMetadata>[meta]),
      throwsA(
        isA<PeerHttpException>().having((e) => e.statusCode, 'statusCode', 403),
      ),
    );

    // The refusal was reported exactly once, with the right reason…
    expect(rejections, hasLength(1));
    expect(rejections.single.$2, UploadRejectReason.acceptingDisabled);
    // …and the sender was resolved from the register table by socket address.
    expect(rejections.single.$1?.alias, 'Sender');
  });

  test('a file larger than maxUploadBytes is refused with 413', () async {
    final small = PeerServer(
      alias: 'Small',
      certificates: serverCert,
      saveDirectory: saveDir,
      acceptUploads: true,
      maxUploadBytes: 1024,
      port: 0,
    );
    await small.start();
    final asker = PeerClient(
      host: '127.0.0.1',
      port: small.actualPort,
      expectedFingerprint: small.fingerprint,
    );
    addTearDown(() async {
      asker.close();
      await small.stop();
    });

    const meta = FileMetadata(id: 'big', fileName: 'big.bin', size: 4096);
    await expectLater(
      asker.prepareUpload(self: self, files: <FileMetadata>[meta]),
      throwsA(
        isA<PeerHttpException>().having((e) => e.statusCode, 'statusCode', 413),
      ),
    );
  });

  test('the session cap is enforced with 503', () async {
    final capped = PeerServer(
      alias: 'Capped',
      certificates: serverCert,
      saveDirectory: saveDir,
      acceptUploads: true,
      maxSessions: 1,
      port: 0,
    );
    await capped.start();
    final asker = PeerClient(
      host: '127.0.0.1',
      port: capped.actualPort,
      expectedFingerprint: capped.fingerprint,
    );
    addTearDown(() async {
      asker.close();
      await capped.stop();
    });

    const a = FileMetadata(id: 'a', fileName: 'a.bin', size: 1);
    final first =
        await asker.prepareUpload(self: self, files: <FileMetadata>[a]);
    expect(first.isEmpty, isFalse);
    expect(capped.openSessionCount, 1);

    const b = FileMetadata(id: 'b', fileName: 'b.bin', size: 1);
    await expectLater(
      asker.prepareUpload(self: self, files: <FileMetadata>[b]),
      throwsA(
        isA<PeerHttpException>().having((e) => e.statusCode, 'statusCode', 503),
      ),
    );
  });

  test('cancel abandons the session so a later upload is refused', () async {
    final source = File(p(srcDir, 'one.bin'));
    await source.writeAsBytes(<int>[7]);

    const meta = FileMetadata(id: 'c', fileName: 'one.bin', size: 1);
    final prepared =
        await client.prepareUpload(self: self, files: <FileMetadata>[meta]);
    final token = prepared.files['c']!;
    expect(server.openSessionCount, 1);

    await client.cancel(sessionId: prepared.sessionId);
    expect(server.openSessionCount, 0);

    await expectLater(
      client.upload(
        sessionId: prepared.sessionId,
        fileId: 'c',
        token: token,
        file: source,
      ),
      throwsA(
        isA<PeerHttpException>().having((e) => e.statusCode, 'statusCode', 403),
      ),
    );
  });

  group('native text (docs/13 §7.3)', () {
    test('a text message is accepted with an ack', () async {
      await client.register(self: self);
      await client.sendText(self: self, id: 'n1', text: '在吗？');
    });

    test('an accepted text frame is reported through onTextReceived', () async {
      await client.register(self: self);
      await client.sendText(self: self, id: 'cb-1', text: '你好');

      expect(textsReceived, hasLength(1));
      final (DeviceInfo sender, TextMessage message) = textsReceived.single;
      expect(message.id, 'cb-1');
      expect(message.text, '你好');
      // The reported sender is the frame's `peer` (our own client identity).
      expect(sender.fingerprint, clientCert.fingerprint);
    });

    test('an over-long text body is refused with 413', () async {
      await client.register(self: self);
      final tooLong = 'x' * (kMaxTextBytes + 1);
      await expectLater(
        client.sendText(self: self, id: 'n2', text: tooLong),
        throwsA(
          isA<PeerHttpException>()
              .having((e) => e.statusCode, 'statusCode', 413),
        ),
      );
    });

    test('a refused text frame does not fire onTextReceived', () async {
      await client.register(self: self);
      final tooLong = 'x' * (kMaxTextBytes + 1);
      await expectLater(
        client.sendText(self: self, id: 'cb-413', text: tooLong),
        throwsA(
          isA<PeerHttpException>()
              .having((e) => e.statusCode, 'statusCode', 413),
        ),
      );
      expect(textsReceived, isEmpty);
    });

    test('sending the same nonce twice is accepted both times', () async {
      // The transport is idempotent; de-duplication by nonce is the data
      // layer's job (`ux_messages_event`), which lives outside core.
      await client.register(self: self);
      await client.sendText(self: self, id: 'dup', text: 'hi');
      await client.sendText(self: self, id: 'dup', text: 'hi');
    });

    test('text is refused with 403 when receiving is disabled', () async {
      final List<TextMessage> closedTexts = <TextMessage>[];
      final closed = PeerServer(
        alias: 'Closed',
        certificates: serverCert,
        port: 0,
        onTextReceived: (DeviceInfo sender, TextMessage message) =>
            closedTexts.add(message),
      );
      await closed.start();
      final asker = PeerClient(
        host: '127.0.0.1',
        port: closed.actualPort,
        expectedFingerprint: closed.fingerprint,
      );
      addTearDown(() async {
        asker.close();
        await closed.stop();
      });

      await expectLater(
        asker.sendText(self: self, id: 'n3', text: 'hi'),
        throwsA(
          isA<PeerHttpException>()
              .having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
      // A refused frame must never reach the persistence callback.
      expect(closedTexts, isEmpty);
    });
  });

  // Keep-alive (docs/13 §4): the registry's only other liveness source is the
  // peer's 5s UDP announcement, so a purely-TCP transfer used to let a healthy
  // peer time out as offline after `offlineAfter` (30s) — the "发一会就掉线"
  // report. Every accepted inbound request now reports the peer through
  // `onPeerSeen`; the app wires that callback into the same registry the
  // announcements feed.
  group('keep-alive (docs/13 §4)', () {
    test('register, prepare, upload and text each report the peer', () async {
      final source = File(p(srcDir, 'keepalive.bin'));
      await source.writeAsBytes(<int>[1, 2, 3]);

      await client.register(self: self);
      final afterRegister = seen.length;
      expect(afterRegister, greaterThanOrEqualTo(1)); // /hello reports too

      const meta = FileMetadata(id: 'k', fileName: 'keepalive.bin', size: 3);
      final prepared =
          await client.prepareUpload(self: self, files: <FileMetadata>[meta]);
      final afterPrepare = seen.length;
      expect(afterPrepare, greaterThan(afterRegister)); // prepare reports

      await client.upload(
        sessionId: prepared.sessionId,
        fileId: 'k',
        token: prepared.files['k']!,
        file: source,
      );
      final afterUpload = seen.length;
      expect(afterUpload, greaterThan(afterPrepare)); // upload reports

      await client.sendText(self: self, id: 'ka', text: 'hi');
      expect(seen.length, greaterThan(afterUpload)); // text reports

      // Every report names the real sender and carries a socket address.
      expect(
        seen.map((entry) => normalizeFingerprint(entry.$1.fingerprint)).toSet(),
        <String>{normalizeFingerprint(clientCert.fingerprint)},
      );
      expect(seen.every((entry) => entry.$2.isNotEmpty), isTrue);
    });

    test('a long upload keeps refreshing the peer every ~8 MiB', () async {
      // 17 MiB ⇒ the upload handler must report at least twice *inside* the
      // stream (at ~8 MiB and ~16 MiB), which is what stops a multi-minute
      // transfer from ageing out between its start and its final ack.
      const int size = 17 * 1024 * 1024;
      final source = File(p(srcDir, 'long.bin'));
      await source.writeAsBytes(List<int>.filled(size, 7));
      final sha = await sha256FileHex(source);

      final meta = FileMetadata(
        id: 'long',
        fileName: 'long.bin',
        size: size,
        sha256: sha,
      );
      final prepared =
          await client.prepareUpload(self: self, files: <FileMetadata>[meta]);
      final afterPrepare = seen.length;

      await client.upload(
        sessionId: prepared.sessionId,
        fileId: 'long',
        token: prepared.files['long']!,
        file: source,
      );

      // Start touch + ~8 MiB + ~16 MiB ⇒ at least three.
      expect(seen.length - afterPrepare, greaterThanOrEqualTo(3));
    });
  });

  // ---------------------------------------------------------------------
  // Folder transfers: one `prepare` + N `put`s, landing in
  // `<saveDirectory>/<folder>/<relative path>` (`docs/22` §4.3).
  //
  // Every assertion below turns on a file that really exists on disk after a
  // real TLS round trip — not on a parsed value. "It accepted the frame" and
  // "the bytes are where we said they would be" are different claims, and only
  // the second one is the feature.
  // ---------------------------------------------------------------------
  group('folder transfers (docs/22 §4.3)', () {
    test('(d) a malicious relative path refuses the whole batch, writing nothing',
        () async {
      // The receive switch is off by default and needs no pairing, so any device
      // on the LAN can reach this path (`docs/22` R14). A traversal that lands
      // is therefore not a theoretical bug.
      await client.register(self: self);
      // A file that must still be there afterwards, and only it: "nothing new
      // appeared" is stronger than "the tree is empty".
      final marker = File(p(saveDir, 'existing.txt'));
      await marker.writeAsString('untouched');
      final before = await _tree(saveDir);
      expect(before, <String>['existing.txt']);

      const List<String> hostile = <String>[
        // `..` in any position (rule 4)
        '../x',
        '../../x',
        'a/../../x',
        'a/..',
        '..',
        // absolute / drive / UNC (rule 3)
        '/etc/x',
        'C:/x',
        r'C:\Windows\x',
        r'\\srv\share\x',
        // a segment that is nothing but control characters (rule 7b)
        '\u0001\u0002/x',
        // more than kMaxRelativePathSegments (rule 6b)
        'a/b/c/d/e/f/g/h/i',
      ];

      for (final String hostilePath in hostile) {
        final meta = FileMetadata(
          id: 'evil',
          fileName: 'evil.bin',
          size: 4,
          relativePath: hostilePath,
        );
        await expectLater(
          // ★ The folder is declared **on purpose**. Without one, a `path` is
          // rejected by the frame-shape rule before `normalizeRelativePath` ever
          // runs, and this group would then be proving the wrong thing — it
          // would pass even if the traversal check did nothing at all.
          client.prepareUpload(
            self: self,
            files: <FileMetadata>[meta],
            folder: FolderDescriptor(name: '素材', count: hostile.length),
          ),
          throwsA(
            isA<PeerHttpException>()
                .having((e) => e.statusCode, 'statusCode', 400),
          ),
          reason: 'path "$hostilePath" must be refused at prepare time',
        );
        // ★ The load-bearing half of this criterion: a refusal must not have
        // created *anything*, not even a directory on the way to the refusal.
        // Asserting only "the call threw" would pass even if the receiver had
        // already built half a path.
        expect(
          await _tree(saveDir),
          before,
          reason: 'path "$hostilePath" left traces on disk',
        );
      }

      // Nothing was accepted either, so no session is left dangling.
      expect(server.openSessionCount, 0);
      expect(finished, isEmpty);
      expect(await marker.readAsString(), 'untouched');
    });

    test('(B) the literals that must NOT be refused all land, 200, inside the root',
        () async {
      // ★ The red line, and the reason this group exists separately from (d):
      //
      //  * `%2e%2e` — we never percent-decode, so this is an ordinary (odd) file
      //    name and it is written verbatim. Decoding it "to catch the encoded
      //    traversal too" would *create* the vulnerability: `%2e%2e` would
      //    become `..`, and `%252e%2e` shows the chase never ends.
      //  * `a\u0000b` — a control byte is **cleaned** (`ab`), not refused. The
      //    file is still wanted; only the byte is illegal.
      //  * `CON` — **renamed** to `_CON`. On Windows `CreateFile("…\CON.txt")`
      //    succeeds and hands back the console device, so a refusal would just
      //    lose a real file.
      //  * `a//b`, `a/`, `./a` — **raw** empty/`.` segments are typos to drop,
      //    not requests to refuse.
      //
      // Every case is checked twice: the `relativePath` the record carries, and
      // the file that is actually on disk under it. Refusing these would be a
      // bug that only shows up as "somebody's folder half-arrived".
      const List<(String id, String sent, String expected)> cases =
          <(String, String, String)>[
        ('c1', 'pct/%2e%2e', 'pct/%2e%2e'),
        ('c2', 'ctl/a\u0000b', 'ctl/ab'),
        ('c3', 'dev/CON', 'dev/_CON'),
        ('c4', 'empty/a//b', 'empty/a/b'),
        ('c5', 't1/a/', 't1/a'),
        ('c6', 't2/./a', 't2/a'),
      ];

      final Map<String, File> sources = <String, File>{};
      final List<FileMetadata> metas = <FileMetadata>[];
      for (int i = 0; i < cases.length; i++) {
        final (String id, String sent, String _) = cases[i];
        final File source = File(p(srcDir, 'case-$id.bin'));
        // Distinct content per case, so "which file is this?" is checkable.
        await source.writeAsBytes(<int>[i + 1, i + 1, i + 1, i + 1]);
        sources[id] = source;
        metas.add(FileMetadata(
          id: id,
          fileName: 'case.bin',
          size: 4,
          relativePath: sent,
        ));
      }

      final prepared = await client.prepareUpload(
        self: self,
        files: metas,
        folder: FolderDescriptor(name: '素材', count: cases.length),
      );
      // The prepare itself must be a plain 200 — no 400 for any of these.
      expect(prepared.sessionId, isNotEmpty);
      expect(prepared.files, hasLength(cases.length));

      for (int i = 0; i < cases.length; i++) {
        final (String id, String _, String expected) = cases[i];
        await client.upload(
          sessionId: prepared.sessionId,
          fileId: id,
          token: prepared.files[id]!,
          file: sources[id]!,
        );
        final ReceivedFile record =
            finished.firstWhere((ReceivedFile r) => r.fileId == id);
        expect(record.relativePath, expected, reason: 'case $id ("${cases[i].$2}")');
        final File landing =
            File(pathlib.join(saveDir.path, '素材', expected));
        expect(await landing.exists(), isTrue, reason: 'expected $landing');
        expect(await landing.readAsBytes(), <int>[i + 1, i + 1, i + 1, i + 1]);
        expect(pathlib.isWithin(saveDir.path, record.savedPath), isTrue);
      }

      // …and the whole tree is exactly these six, two levels deep, under the
      // folder name. No escape, no sibling, no `unnamed/`.
      expect(await _tree(saveDir), <String>[
        '素材/',
        '素材/ctl/',
        '素材/ctl/ab',
        '素材/dev/',
        '素材/dev/_CON',
        '素材/empty/',
        '素材/empty/a/',
        '素材/empty/a/b',
        '素材/pct/',
        '素材/pct/%2e%2e',
        '素材/t1/',
        '素材/t1/a',
        '素材/t2/',
        '素材/t2/a',
      ]);
    });

    test('(e) a nested path lands two levels deep under the folder name',
        () async {
      const int size = 4096;
      final bytes = List<int>.generate(size, (int i) => i & 0xff);
      final source = File(p(srcDir, 'a.bin'));
      await source.writeAsBytes(bytes);

      final meta = FileMetadata(
        id: 'f1',
        fileName: 'a.bin',
        size: size,
        relativePath: 'sub/a.bin',
      );
      final prepared = await client.prepareUpload(
        self: self,
        files: <FileMetadata>[meta],
        folder: const FolderDescriptor(name: '素材', count: 2),
      );
      expect(prepared.sessionId, isNotEmpty);
      await client.upload(
        sessionId: prepared.sessionId,
        fileId: 'f1',
        token: prepared.files['f1']!,
        file: source,
      );

      expect(finished, hasLength(1));
      final record = finished.single;

      // What the server *told us* it did…
      expect(record.folderName, '素材');
      expect(record.folderFiles, 2);
      expect(record.relativePath, 'sub/a.bin');
      expect(record.sessionId, prepared.sessionId);
      expect(record.fileName, 'a.bin');

      // …and where the bytes actually are.
      final landing = File(pathlib.join(saveDir.path, '素材', 'sub', 'a.bin'));
      expect(await landing.exists(), isTrue, reason: 'expected $landing');
      expect(await landing.readAsBytes(), bytes);
      expect(record.savedPath, landing.path);

      // Criterion (e) asks for this in so many words, and it is worth spelling
      // out *why*: `startsWith` alone would accept
      // `<tmp>/lanlink_e2e_recv_XXX` for a sibling
      // `<tmp>/lanlink_e2e_recv_XXX_evil`, whereas `isWithin` compares whole
      // path components.
      expect(pathlib.isWithin(saveDir.path, landing.path), isTrue);

      // Extra defences beyond `isWithin`, because one check is one chance to be
      // wrong about separators/case/`..`:
      //  1. the path the record carries is exactly the root-relative path we
      //     expect, computed by the *test* from the root — so a record and a
      //     file cannot disagree;
      //  2. the whole tree under the root is exactly the two directories and one
      //     file we asked for — nothing was created beside them;
      //  3. the root itself did not gain any other entry.
      expect(
        pathlib.relative(record.savedPath, from: saveDir.path).replaceAll(r'\', '/'),
        '素材/sub/a.bin',
      );
      expect(await _tree(saveDir), <String>['素材/', '素材/sub/', '素材/sub/a.bin']);
    });

    test('(f) a duplicate name becomes "a (1).bin" and the record says so',
        () async {
      final source = File(p(srcDir, 'dup.bin'));
      await source.writeAsBytes(<int>[1, 2, 3, 4]);

      Future<ReceivedFile> sendOnce() async {
        final meta = FileMetadata(
          id: 'dup-${DateTime.now().microsecondsSinceEpoch}',
          fileName: 'a.bin',
          size: 4,
          relativePath: 'sub/a.bin',
        );
        final prepared = await client.prepareUpload(
          self: self,
          files: <FileMetadata>[meta],
          folder: const FolderDescriptor(name: '素材', count: 1),
        );
        await client.upload(
          sessionId: prepared.sessionId,
          fileId: meta.id,
          token: prepared.files[meta.id]!,
          file: source,
        );
        return finished.last;
      }

      final first = await sendOnce();
      final second = await sendOnce();

      expect(first.relativePath, 'sub/a.bin');
      // The whole point: the *stored* path is the one on disk, not the one that
      // was asked for. Recording `sub/a.bin` twice would mean opening a file
      // that the second arrival never wrote.
      expect(second.relativePath, 'sub/a (1).bin');
      expect(second.fileName, 'a (1).bin');
      expect(
        await File(pathlib.join(saveDir.path, '素材', 'sub', 'a (1).bin')).exists(),
        isTrue,
      );
      expect(
        pathlib.relative(second.savedPath, from: saveDir.path).replaceAll(r'\', '/'),
        '素材/sub/a (1).bin',
      );
      expect(pathlib.isWithin(saveDir.path, second.savedPath), isTrue);
      // Both copies survive: the first must not have been overwritten.
      expect(await _tree(saveDir), <String>[
        '素材/',
        '素材/sub/',
        '素材/sub/a (1).bin',
        '素材/sub/a.bin',
      ]);
    });

    test('(g) Windows reserved names are renamed and the bytes still read back',
        () async {
      // `CreateFile("…\CON.txt")` on Windows is not an error: it opens the
      // console device and returns success, so the file silently does not exist
      // afterwards. Renaming is the only answer that keeps the file.
      const Map<String, String> cases = <String, String>{
        'CON.txt': '_CON.txt',
        'NUL': '_NUL',
        'COM1.log': '_COM1.log',
        'aux': '_aux',
      };
      final metas = <FileMetadata>[];
      for (final entry in cases.entries) {
        metas.add(FileMetadata(
          id: entry.key,
          fileName: entry.key,
          size: entry.key.length,
          relativePath: entry.key,
        ));
      }
      final prepared = await client.prepareUpload(
        self: self,
        files: metas,
        folder: FolderDescriptor(name: '素材', count: cases.length),
      );

      for (final entry in cases.entries) {
        final source = File(p(srcDir, 'reserved-${entry.key}'));
        await source.writeAsString(entry.key);
        await client.upload(
          sessionId: prepared.sessionId,
          fileId: entry.key,
          token: prepared.files[entry.key]!,
          file: source,
        );
      }

      expect(finished, hasLength(cases.length));
      for (final entry in cases.entries) {
        final record =
            finished.firstWhere((ReceivedFile r) => r.fileId == entry.key);
        expect(record.relativePath, entry.value,
            reason: '${entry.key} must land as ${entry.value}');
        final landing = File(pathlib.join(saveDir.path, '素材', entry.value));
        expect(await landing.exists(), isTrue, reason: 'expected $landing');
        // "The file exists" is not enough on Windows — the device-name trap is
        // that it exists and is empty/missing. Reading the content back is what
        // proves the bytes went to a real file.
        expect(await landing.readAsString(), entry.key);
      }
    });

    test('(g) an over-long path is shortened and still lands', () async {
      final longName = '${'x' * 200}.bin';
      final meta = FileMetadata(
        id: 'long',
        fileName: longName,
        size: 5,
        relativePath: 'sub/$longName',
      );
      final prepared = await client.prepareUpload(
        self: self,
        files: <FileMetadata>[meta],
        folder: const FolderDescriptor(name: '素材', count: 1),
      );
      final source = File(p(srcDir, 'long.bin'));
      await source.writeAsString('12345');
      await client.upload(
        sessionId: prepared.sessionId,
        fileId: 'long',
        token: prepared.files['long']!,
        file: source,
      );

      final record = finished.single;
      expect(record.relativePath, isNotNull);
      expect(record.relativePath!.length,
          lessThanOrEqualTo(kMaxRelativePathChars));
      expect(record.relativePath, endsWith('.bin'));
      expect(record.relativePath, startsWith('sub/x'));
      expect(await File(record.savedPath).readAsString(), '12345');
    });

    test('(g) an unwritable target answers 500 in one human sentence, without '
        'leaking a local path — and the batch-mate still lands', () async {
      // A *file* where the path needs a directory. `Directory.create(recursive)`
      // throws `FileSystemException`, which is the same failure class as a full
      // disk or a permission denial.
      // The blocker lives **inside the folder root**, because a `path` without
      // a `folder` is now a refused frame (see the frame-shape rule in
      // `_handlePrepareUpload`) — this test is about a full disk, not about
      // that rule.
      final folderRoot = Directory(p(saveDir, '素材'));
      await folderRoot.create(recursive: true);
      final blocker = File(p(folderRoot, 'blocked'));
      await blocker.writeAsString('i am a file, not a directory');

      final okSource = File(p(srcDir, 'ok.bin'));
      await okSource.writeAsBytes(<int>[9, 9, 9]);
      final badSource = File(p(srcDir, 'bad.bin'));
      await badSource.writeAsBytes(<int>[7, 7, 7]);

      final prepared = await client.prepareUpload(
        self: self,
        files: <FileMetadata>[
          const FileMetadata(
              id: 'bad', fileName: 'x.bin', size: 3, relativePath: 'blocked/x.bin'),
          const FileMetadata(
              id: 'good', fileName: 'y.bin', size: 3, relativePath: 'ok/y.bin'),
        ],
        folder: const FolderDescriptor(name: '素材', count: 2),
      );

      PeerHttpException? failure;
      try {
        await client.upload(
          sessionId: prepared.sessionId,
          fileId: 'bad',
          token: prepared.files['bad']!,
          file: badSource,
        );
      } on PeerHttpException catch (error) {
        failure = error;
      }

      expect(failure, isNotNull);
      expect(failure!.statusCode, 500);
      final message =
          (jsonDecode(failure.body) as Map<String, dynamic>)['message'] as String;
      // ★ This string is shown to the *sender*, on the failing bubble
      // (`transfers.error`), so it has to be one of the three fixed sentences —
      // and it must not carry `/data/user/0/...`, which would both leak where we
      // keep files and say nothing useful.
      expect(
        message,
        anyOf(
          '接收入站文件失败：磁盘空间不足',
          '接收入站文件失败：路径过长',
          '接收入站文件失败：目标位置不可写',
        ),
      );
      expect(message, isNot(contains(saveDir.path)));
      expect(message, isNot(contains('FileSystemException')));
      // The local log may name the real reason; the wire must not.
      expect(logs.join('\n'), contains('cannot prepare the landing directory'));

      // One file's failure is not the batch's failure: each `put` is its own
      // request, so the sibling still arrives.
      await client.upload(
        sessionId: prepared.sessionId,
        fileId: 'good',
        token: prepared.files['good']!,
        file: okSource,
      );
      expect(finished, hasLength(1));
      expect(finished.single.fileId, 'good');
      expect(
          await File(pathlib.join(saveDir.path, '素材', 'ok', 'y.bin'))
              .readAsBytes(),
          <int>[9, 9, 9]);
    });

    test('(a) a flat prepare still produces a record with every new field at '
        'its old default', () async {
      // The regression red line: a pre-0.2.38 sender must not be able to tell
      // that any of this exists. `relativePath` is `null` — not `''` — so the
      // store writes the same `NULL` it always did.
      final source = File(p(srcDir, 'flat.bin'));
      await source.writeAsBytes(<int>[1, 2, 3]);
      const meta = FileMetadata(id: 'flat', fileName: 'flat.bin', size: 3);
      final prepared =
          await client.prepareUpload(self: self, files: <FileMetadata>[meta]);
      await client.upload(
        sessionId: prepared.sessionId,
        fileId: 'flat',
        token: prepared.files['flat']!,
        file: source,
      );

      final record = finished.single;
      expect(record.folderName, isNull);
      expect(record.folderFiles, 0);
      expect(record.relativePath, isNull);
      // Still useful to the store (it is what lets a *later* version aggregate),
      // but nothing else changed.
      expect(record.sessionId, prepared.sessionId);
      expect(record.savedPath, pathlib.join(saveDir.path, 'flat.bin'));
      expect(await _tree(saveDir), <String>['flat.bin']);
    });

    test('(b1) a flat MULTI-file prepare tells every record how many files it '
        'declared (0.2.52)', () async {
      // The wire has always carried this: a multi-select is ONE `prepare` with
      // N files, so the receiver can count exactly what was promised. It only
      // never left the server (`folderFiles` was hard-wired to the folder
      // descriptor's count, i.e. 0 for a flat transfer), which is what made
      // "8 selected, 3 arrived" indistinguishable from "3 selected".
      final List<FileMetadata> metas = <FileMetadata>[];
      for (int i = 0; i < 3; i++) {
        final File source = File(p(srcDir, 'batch_$i.bin'));
        await source.writeAsBytes(<int>[i, i, i]);
        metas.add(FileMetadata(
          id: 'b$i',
          fileName: 'batch_$i.bin',
          size: 3,
        ));
      }
      final prepared =
          await client.prepareUpload(self: self, files: metas);
      for (int i = 0; i < 3; i++) {
        await client.upload(
          sessionId: prepared.sessionId,
          fileId: 'b$i',
          token: prepared.files['b$i']!,
          file: File(p(srcDir, 'batch_$i.bin')),
        );
      }

      expect(finished, hasLength(3));
      for (final record in finished) {
        // ★ the declared count of the **session**, carried on every file…
        expect(record.folderFiles, 3,
            reason: 'this `prepare` declared three files');
        // …while the transfer stays flat: no descriptor, so no folder card, no
        // landing directory and no `relativePath` (`docs/22` §2.2).
        expect(record.folderName, isNull);
        expect(record.relativePath, isNull);
        expect(record.sessionId, prepared.sessionId);
        expect(pathlib.isWithin(saveDir.path, record.savedPath), isTrue);
        expect(pathlib.dirname(record.savedPath), saveDir.path,
            reason: 'nothing may be nested for a flat batch');
      }
      expect(await _tree(saveDir),
          <String>['batch_0.bin', 'batch_1.bin', 'batch_2.bin']);
    });

    test('(frame shape) a path with no folder refuses the whole batch', () async {
      await client.register(self: self);
      final marker = File(p(saveDir, 'existing.txt'));
      await marker.writeAsString('untouched');
      final before = await _tree(saveDir);

      // The frame says "this file sits in `sub/`" **and** "there is no folder".
      // Both halves cannot be honoured: honouring the path creates `sub/` for a
      // transfer the record will still call flat (a directory on disk that
      // nothing acknowledges), and dropping the path puts the file somewhere the
      // sender did not ask for. So the batch is refused, before a token exists.
      const meta = FileMetadata(
        id: 'x',
        fileName: 'x.bin',
        size: 4,
        relativePath: 'sub/x.bin',
      );
      await expectLater(
        client.prepareUpload(self: self, files: <FileMetadata>[meta]),
        throwsA(isA<PeerHttpException>()
            .having((e) => e.statusCode, 'statusCode', 400)),
      );
      // The load-bearing half, same as criterion (d): the refusal must not have
      // created `sub/` on its way to saying no.
      expect(await _tree(saveDir), before,
          reason: 'a refused frame must not leave a directory behind');
      expect(server.openSessionCount, 0);
      expect(finished, isEmpty);
      expect(await marker.readAsString(), 'untouched');

      // Even an *empty* `path` is refused in this shape: the key is present, so
      // the sender has made a claim about a folder that does not exist. No real
      // sender does this (0.2.37 emits no `path` at all), and if one ever
      // legitimately does, `_handlePrepareUpload` says where to relax it.
      const emptyPath = FileMetadata(
        id: 'e',
        fileName: 'e.bin',
        size: 1,
        relativePath: '',
      );
      await expectLater(
        client.prepareUpload(self: self, files: <FileMetadata>[emptyPath]),
        throwsA(isA<PeerHttpException>()
            .having((e) => e.statusCode, 'statusCode', 400)),
      );
      expect(await _tree(saveDir), before);
    });

    test('(frame shape) a folder whose files declare no path lands them flat '
        'inside the folder root', () async {
      // The other half of the rule, and a shape T03 may legitimately produce
      // first: a folder message whose files are all at the folder's root. That
      // is a complete message — refusing it would be a compatibility regression
      // against our own next release.
      final first = File(p(srcDir, 'flat-a.bin'));
      await first.writeAsBytes(<int>[1]);
      final second = File(p(srcDir, 'flat-b.bin'));
      await second.writeAsBytes(<int>[2]);

      final prepared = await client.prepareUpload(
        self: self,
        files: const <FileMetadata>[
          FileMetadata(id: 'a', fileName: 'a.bin', size: 1),
          FileMetadata(id: 'b', fileName: 'b.bin', size: 1),
        ],
        folder: const FolderDescriptor(name: '素材', count: 2),
      );
      expect(prepared.sessionId, isNotEmpty);

      await client.upload(
        sessionId: prepared.sessionId,
        fileId: 'a',
        token: prepared.files['a']!,
        file: first,
      );
      await client.upload(
        sessionId: prepared.sessionId,
        fileId: 'b',
        token: prepared.files['b']!,
        file: second,
      );

      expect(finished, hasLength(2));
      for (final ReceivedFile record in finished) {
        expect(record.folderName, '素材');
        // Not `null`: there *is* a folder, so "it sits at the root of that
        // folder" is a real position — the bare file name.
        expect(record.relativePath, record.fileName);
        expect(record.relativePath, isNot(isNull));
      }
      expect(await _tree(saveDir), <String>[
        '素材/',
        '素材/a.bin',
        '素材/b.bin',
      ]);
    });

    test('a folder name that normalises to nothing degrades to a flat transfer',
        () async {
      // `{"folder":{"name":"...","count":1}}` names no usable directory.
      // Flattening is honest — the file does arrive — whereas inventing an
      // `unnamed/` directory would record a name the sender never used.
      final source = File(p(srcDir, 'n.bin'));
      await source.writeAsBytes(<int>[4]);
      const meta = FileMetadata(id: 'n', fileName: 'n.bin', size: 1);
      final prepared = await client.prepareUpload(
        self: self,
        files: <FileMetadata>[meta],
        folder: const FolderDescriptor(name: '...', count: 1),
      );
      await client.upload(
        sessionId: prepared.sessionId,
        fileId: 'n',
        token: prepared.files['n']!,
        file: source,
      );

      expect(finished.single.folderName, isNull);
      expect(finished.single.relativePath, isNull);
      expect(await _tree(saveDir), <String>['n.bin']);
    });

    test('(h) metadata travels in the body only — never in the query or headers',
        () async {
      // `docs/22` §1.5 / judgement 18. This is not paranoia about style: URL
      // length limits differ per implementation (Node 8 KB, proxies 4–8 KB,
      // some Android stacks lower), so 200 Chinese file names in a query string
      // would produce a 414/431 that only appears behind *some* middlebox —
      // the hardest kind of bug to ever diagnose.
      //
      // A recording TLS endpoint is used instead of `PeerServer` because the
      // claim under test is about what the **client** puts on the wire, which is
      // the one thing a server-side assertion cannot see.
      final List<({Uri uri, String headers, String body})> recorded =
          <({Uri uri, String headers, String body})>[];
      final probe = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverCert.toSecurityContext(),
      );
      probe.listen((HttpRequest request) async {
        final String body = await utf8.decoder.bind(request).join();
        // Snapshot immediately: `HttpHeaders` is a live view of the request.
        recorded.add((
          uri: request.uri,
          headers: request.headers.toString(),
          body: body,
        ));
        final Map<String, dynamic> decoded =
            jsonDecode(body) as Map<String, dynamic>;
        final Map<String, dynamic> filesJson =
            decoded['files'] as Map<String, dynamic>;
        final List<int> reply = utf8.encode(jsonEncode(<String, dynamic>{
          'v': kFrameVersion,
          't': kFramePrepareReply,
          'session': 'probe-session',
          'tokens': <String, String>{
            for (final String id in filesJson.keys) id: 'token-$id',
          },
          'received': <String, int>{
            for (final String id in filesJson.keys) id: 0,
          },
        }));
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType =
              ContentType('application', 'json', charset: 'utf-8')
          ..contentLength = reply.length
          ..add(reply);
        await request.response.close();
      });
      final probeClient = PeerClient(
        host: '127.0.0.1',
        port: probe.port,
        expectedFingerprint: serverCert.fingerprint,
      );
      addTearDown(() async {
        probeClient.close();
        await probe.close(force: true);
      });

      const List<String> names = <String>['带空格 的文件.bin', '另一个文件.bin'];
      const List<String> paths = <String>['带空格 的文件.bin', 'sub/目录/另一个文件.bin'];
      await probeClient.prepareUpload(
        self: self,
        files: <FileMetadata>[
          const FileMetadata(
            id: 'f1',
            fileName: '带空格 的文件.bin',
            size: 3,
            relativePath: '带空格 的文件.bin',
          ),
          const FileMetadata(
            id: 'f2',
            fileName: '另一个文件.bin',
            size: 4,
            relativePath: 'sub/目录/另一个文件.bin',
          ),
        ],
        folder: const FolderDescriptor(name: '素材', count: 2),
      );

      expect(recorded, hasLength(1));
      final request = recorded.single;
      // (a) no query at all — `/prepare` has nothing to put in one.
      expect(request.uri.queryParameters, isEmpty);
      // (b) and (c): no name, no relative path, no folder name anywhere except
      // the body. `素材` and `目录` are checked as well as the file names,
      // because the folder name is metadata too.
      final List<String> needles = <String>[...names, ...paths, '素材', '目录'];
      for (final String needle in needles) {
        expect(request.uri.toString(), isNot(contains(needle)),
            reason: '"$needle" leaked into the URL');
        expect(request.headers, isNot(contains(needle)),
            reason: '"$needle" leaked into a header');
      }
      // …and they *are* in the body, so this test cannot pass by sending
      // nothing at all.
      for (final String needle in needles) {
        expect(request.body, contains(needle),
            reason: '"$needle" missing from the body');
      }
    });
  });
}

/// Every path under [root], relative to it and `/`-separated, with a trailing
/// `/` for directories, sorted.
///
/// Used to state "nothing new appeared" as an exact set rather than as "the
/// call threw" — a half-built directory is exactly the failure mode a
/// refuse-the-path test has to be able to see.
Future<List<String>> _tree(Directory root) async {
  final List<String> entries = <String>[];
  if (!await root.exists()) {
    return entries;
  }
  await for (final FileSystemEntity entity
      in root.list(recursive: true, followLinks: false)) {
    final String relative =
        pathlib.relative(entity.path, from: root.path).replaceAll(r'\', '/');
    entries.add(entity is Directory ? '$relative/' : relative);
  }
  entries.sort();
  return entries;
}


/// Splits the 0.2.17 `upload stats:` line into `key -> raw value`.
///
/// Deliberately dumb (split on spaces, split on the first `=`), because that is
/// how the line will be read off a device log — if this parser needs anything
/// cleverer, the line is not greppable enough. A leading `(` and a trailing `%)`
/// are stripped because the `fast` share is parenthesised for prose.
Map<String, String> _parseStatsLine(String line) {
  final Map<String, String> fields = <String, String>{};
  for (final String raw in line.split(' ')) {
    String token = raw;
    if (token.isEmpty) {
      continue;
    }
    if (token.startsWith('(')) {
      token = token.substring(1);
    }
    if (token.endsWith('%)')) {
      token = token.substring(0, token.length - 2);
    }
    final int eq = token.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    fields[token.substring(0, eq)] = token.substring(eq + 1);
  }
  return fields;
}

/// A backend that acks every chunk and then reports a crash instead of a digest,
/// i.e. a worker that died mid-stream. Used to drive the receiver's
/// "re-hash what is already on disk" fallback (0.2.16).
class _CrashingHashBackend implements HashWorkerBackend {
  final StreamController<HashWorkerEvent> _events =
      StreamController<HashWorkerEvent>();

  @override
  Stream<HashWorkerEvent> get events => _events.stream;

  @override
  void addChunk(Uint8List chunk) {
    _events.add(HashWorkerAck(chunk.length));
  }

  @override
  void finish() {
    _events.add(const HashWorkerFailure('simulated worker crash'));
  }

  @override
  Future<void> dispose() async {
    await _events.close();
  }
}
