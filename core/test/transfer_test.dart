import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// Unit tests for the v1 transfer wire models and the native text frame.
void main() {
  const sender = DeviceInfo(alias: 'Sender', fingerprint: 'AABB', port: 49494);

  group('FileMetadata', () {
    test('round-trips through JSON', () {
      const meta = FileMetadata(
        id: 'f1',
        fileName: 'photo.png',
        size: 1234,
        fileType: 'image/png',
        sha256: 'DEADBEEF',
        preview: 'AAAA',
        offset: 8,
      );

      final restored = FileMetadata.fromJson(meta.toJson());

      expect(restored.id, 'f1');
      expect(restored.fileName, 'photo.png');
      expect(restored.size, 1234);
      expect(restored.fileType, 'image/png');
      expect(restored.sha256, 'DEADBEEF');
      expect(restored.preview, 'AAAA');
      expect(restored.offset, 8);
    });

    test('serialises to the new keys and omits null optionals', () {
      const meta = FileMetadata(id: 'f1', fileName: 'a.bin', size: 3);
      final json = meta.toJson();

      expect(json['id'], 'f1');
      expect(json['name'], 'a.bin');
      expect(json['size'], 3);
      expect(json['offset'], 0);
      expect(json.containsKey('mime'), isFalse);
      expect(json.containsKey('sha256'), isFalse);
      expect(json.containsKey('thumb'), isFalse);
    });

    test('reads the new keys', () {
      final meta = FileMetadata.fromJson(<String, dynamic>{
        'id': 'x',
        'name': 'n',
        'size': 5,
        'mime': 'text/plain',
        'thumb': 'ZZ',
        'offset': 2,
      });

      expect(meta.fileName, 'n');
      expect(meta.fileType, 'text/plain');
      expect(meta.preview, 'ZZ');
      expect(meta.offset, 2);
    });

    test('falls back to defaults on a sparse payload', () {
      final meta = FileMetadata.fromJson(<String, dynamic>{});

      expect(meta.id, isEmpty);
      expect(meta.fileName, 'unnamed');
      expect(meta.size, -1);
      expect(meta.fileType, isNull);
      expect(meta.sha256, isNull);
      expect(meta.preview, isNull);
      expect(meta.offset, 0);
    });

    test('copyWith replaces only the given fields', () {
      const meta = FileMetadata(id: 'f1', fileName: 'a.bin', size: 3);
      final updated = meta.copyWith(id: 'f2', size: 9);

      expect(updated.id, 'f2');
      expect(updated.size, 9);
      expect(updated.fileName, 'a.bin');
    });

    group('relativePath (wire key "path")', () {
      test('is null when the sender declared no path', () {
        // Judgement (a): a pre-0.2.38 frame. `null` — never `''` — because the
        // store writes `NULL` for "flat" and a `''` would be a third state.
        final meta = FileMetadata.fromJson(<String, dynamic>{
          'id': 'f1',
          'name': 'a.bin',
          'size': 3,
        });
        expect(meta.relativePath, isNull);
        expect(meta.toJson().containsKey('path'), isFalse);
      });

      test('round-trips, and is omitted from the wire when null', () {
        const flat = FileMetadata(id: 'f1', fileName: 'a.bin', size: 3);
        expect(flat.toJson().containsKey('path'), isFalse);

        const nested = FileMetadata(
          id: 'f1',
          fileName: 'a.bin',
          size: 3,
          relativePath: 'sub/deep/a.bin',
        );
        expect(nested.toJson()['path'], 'sub/deep/a.bin');
        expect(FileMetadata.fromJson(nested.toJson()).relativePath,
            'sub/deep/a.bin');
      });

      test('is carried through copyWith', () {
        const meta = FileMetadata(id: 'f1', fileName: 'a.bin', size: 3);
        expect(meta.copyWith(relativePath: 'a/b.bin').relativePath, 'a/b.bin');
        // A null argument means "keep", which is why the server keeps the
        // normalised value on its own per-file record instead of writing back.
        expect(
          meta.copyWith(relativePath: 'a/b.bin').copyWith(size: 4).relativePath,
          'a/b.bin',
        );
      });

      test('does not leak into fileName — the two mean different things', () {
        // `name` is a single segment throughout the product (tiles, previews,
        // copy-file-name); folding the hierarchy into it would make every one of
        // those "sometimes a path".
        final meta = FileMetadata.fromJson(<String, dynamic>{
          'id': 'f1',
          'name': 'a.bin',
          'size': 3,
          'path': 'sub/a.bin',
        });
        expect(meta.fileName, 'a.bin');
        expect(meta.relativePath, 'sub/a.bin');
      });
    });
  });

  group('FolderDescriptor', () {
    test('round-trips name + count', () {
      const folder = FolderDescriptor(name: '素材', count: 20);
      final json = folder.toJson();
      expect(json, <String, dynamic>{'name': '素材', 'count': 20});

      final restored = FolderDescriptor.fromJson(json);
      expect(restored.name, '素材');
      expect(restored.count, 20);
    });

    test('is lenient: a sparse object yields empty defaults, never a throw', () {
      // An added optional key must not be able to make an otherwise readable
      // frame unreadable. `count: 0` is the receiver's cue to fall back to the
      // number of files it actually saw.
      final restored = FolderDescriptor.fromJson(<String, dynamic>{});
      expect(restored.name, '');
      expect(restored.count, 0);

      // A `count` that arrived as a double still reads.
      expect(
        FolderDescriptor.fromJson(<String, dynamic>{'count': 3.0}).count,
        3,
      );
    });
  });

  group('PrepareUploadRequest', () {
    final request = PrepareUploadRequest(
      info: sender,
      files: <String, FileMetadata>{
        'f1': const FileMetadata(id: 'f1', fileName: 'a.bin', size: 10),
      },
      pin: '123456',
    );

    test('round-trips peer + files + pin through JSON', () {
      final restored = PrepareUploadRequest.fromJson(request.toJson());

      expect(restored.info.alias, 'Sender');
      expect(restored.info.fingerprint, 'AABB');
      expect(restored.files.keys.single, 'f1');
      expect(restored.files['f1']!.fileName, 'a.bin');
      expect(restored.pin, '123456');
    });

    test('serialises as a "prepare" frame carrying a peer object', () {
      final json = request.toJson();

      expect(json['v'], kFrameVersion);
      expect(json['t'], kFramePrepare);
      expect(json['peer'], isA<Map<String, dynamic>>());
      expect(json.containsKey('info'), isFalse);
    });

    test('omits the pin when it is null', () {
      final withoutPin = PrepareUploadRequest(
        info: sender,
        files: <String, FileMetadata>{
          'f1': const FileMetadata(id: 'f1', fileName: 'a.bin', size: 10),
        },
      );
      expect(withoutPin.toJson().containsKey('pin'), isFalse);
    });

    test('uses the map key as the file id when the entry omits it', () {
      final restored = PrepareUploadRequest.fromJson(<String, dynamic>{
        'peer': sender.toJson(),
        'files': <String, dynamic>{
          'key-1': <String, dynamic>{'name': 'x.bin', 'size': 1},
        },
      });

      expect(restored.files.keys.single, 'key-1');
      expect(restored.files['key-1']!.id, 'key-1');
    });

    test('throws a FormatException when peer or files is missing/not a map',
        () {
      expect(
        () => PrepareUploadRequest.fromJson(<String, dynamic>{
          'files': <String, dynamic>{},
        }),
        throwsFormatException,
      );
      expect(
        () => PrepareUploadRequest.fromJson(<String, dynamic>{
          'peer': sender.toJson(),
          'files': 5,
        }),
        throwsFormatException,
      );
    });

    test('throws a FormatException when a file entry is not an object', () {
      expect(
        () => PrepareUploadRequest.fromJson(<String, dynamic>{
          'peer': sender.toJson(),
          'files': <String, dynamic>{'f1': 'not-an-object'},
        }),
        throwsFormatException,
      );
    });

    test('carries an optional folder, and omits the key when there is none', () {
      final flat = PrepareUploadRequest(
        info: sender,
        files: <String, FileMetadata>{
          'f1': const FileMetadata(id: 'f1', fileName: 'a.bin', size: 10),
        },
      );
      expect(flat.toJson().containsKey('folder'), isFalse);
      expect(
        PrepareUploadRequest.fromJson(flat.toJson()).folder,
        isNull,
        reason: 'a frame without a folder must parse to null, not to a stub',
      );

      final folder = PrepareUploadRequest(
        info: sender,
        files: <String, FileMetadata>{
          'f1': const FileMetadata(
            id: 'f1',
            fileName: 'a.bin',
            size: 10,
            relativePath: 'sub/a.bin',
          ),
        },
        folder: const FolderDescriptor(name: '素材', count: 1),
      );
      final restored = PrepareUploadRequest.fromJson(folder.toJson());
      expect(restored.folder!.name, '素材');
      expect(restored.folder!.count, 1);
      expect(restored.files['f1']!.relativePath, 'sub/a.bin');
    });

    test('ignores a "folder" that is not an object instead of rejecting', () {
      // Same rule as an unknown key: the files themselves are still perfectly
      // deliverable, so refusing the batch would be a compatibility regression.
      final restored = PrepareUploadRequest.fromJson(<String, dynamic>{
        'peer': sender.toJson(),
        'files': <String, dynamic>{
          'f1': <String, dynamic>{'id': 'f1', 'name': 'a.bin', 'size': 1},
        },
        'folder': 'not-an-object',
      });
      expect(restored.folder, isNull);
      expect(restored.files.keys, <String>['f1']);
    });

    // ------------------------------------------------------------------
    // Judgement (a) — the old frame is still a valid frame
    // ------------------------------------------------------------------
    test('(a) a pre-0.2.38 frame parses with every new field null', () {
      // Exactly what 0.2.37 puts on the wire: `{v, t, peer, files}` and per file
      // only `id`/`name`/`size`/`sha256`/`offset`. Nothing may be required.
      final restored = PrepareUploadRequest.fromJson(<String, dynamic>{
        'v': kFrameVersion,
        't': kFramePrepare,
        'peer': sender.toJson(),
        'files': <String, dynamic>{
          'f1': <String, dynamic>{
            'id': 'f1',
            'name': 'a.bin',
            'size': 10,
            'sha256': 'DEADBEEF',
            'offset': 0,
          },
        },
      });

      expect(restored.folder, isNull);
      expect(restored.files['f1']!.relativePath, isNull);
      expect(restored.files['f1']!.fileName, 'a.bin');
    });

    // ------------------------------------------------------------------
    // Judgement (b) — unknown keys are tolerated, on purpose
    // ------------------------------------------------------------------
    test('(b) unknown keys, at any level, do not stop the frame parsing', () {
      // This is a *compatibility* assertion, not a laxness one. Turning the
      // reader into a strict schema validator would make a 0.2.37 peer and a
      // newer one refuse each other the moment either adds a field, which is
      // exactly what `docs/13` §13.1 forbids.
      final restored = PrepareUploadRequest.fromJson(<String, dynamic>{
        'v': kFrameVersion,
        't': kFramePrepare,
        'futureField': 1,
        'peer': sender.toJson(),
        'folder': <String, dynamic>{
          'name': '素材',
          'count': 2,
          'futureFolderKey': true,
        },
        'files': <String, dynamic>{
          'f1': <String, dynamic>{
            'id': 'f1',
            'name': 'a.bin',
            'size': 10,
            'path': 'sub/a.bin',
            'futureKey': <String, dynamic>{'nested': 1},
          },
        },
      });

      expect(restored.folder!.name, '素材');
      expect(restored.folder!.count, 2);
      expect(restored.files['f1']!.relativePath, 'sub/a.bin');

      // And nothing unknown is echoed back: `toJson` writes known keys only, so
      // an old peer never receives a key it has never heard of.
      final out = restored.toJson();
      expect(out.containsKey('futureField'), isFalse);
      expect(
        (out['folder']! as Map<String, dynamic>).containsKey('futureFolderKey'),
        isFalse,
      );
      expect(
        (out['files']! as Map<String, dynamic>)['f1']
            .containsKey('futureKey'),
        isFalse,
      );
    });
  });

  group('PrepareUploadResponse', () {
    test('reports emptiness from an empty session id', () {
      expect(
        const PrepareUploadResponse(sessionId: '', files: <String, String>{})
            .isEmpty,
        isTrue,
      );
      expect(
        const PrepareUploadResponse(sessionId: 's1', files: <String, String>{})
            .isEmpty,
        isFalse,
      );
    });

    test('round-trips session/tokens/received through JSON', () {
      const response = PrepareUploadResponse(
        sessionId: 's1',
        files: <String, String>{'f1': 'tok'},
        received: <String, int>{'f1': 0},
      );

      final json = response.toJson();
      expect(json['v'], kFrameVersion);
      expect(json['t'], kFramePrepareReply);

      final restored = PrepareUploadResponse.fromJson(json);
      expect(restored.sessionId, 's1');
      expect(restored.files, <String, String>{'f1': 'tok'});
      expect(restored.received, <String, int>{'f1': 0});
      expect(restored.isEmpty, isFalse);
    });
  });

  group('TextMessage', () {
    test('round-trips through JSON as a "text" frame', () {
      final message = TextMessage(peer: sender, id: 'n1', text: '在吗？');
      final json = message.toJson();

      expect(json['v'], kFrameVersion);
      expect(json['t'], kFrameText);

      final restored = TextMessage.fromJson(json);
      expect(restored.peer.alias, 'Sender');
      expect(restored.id, 'n1');
      expect(restored.text, '在吗？');
    });
  });

  group('ReceivedFile', () {
    test('defaults sha256Matched to true and carries the sender', () {
      const record = ReceivedFile(
        fileId: 'f1',
        fileName: 'a.bin',
        savedPath: r'C:\recv\a.bin',
        size: 10,
        sha256: 'DEADBEEF',
        sender: sender,
      );

      expect(record.sha256Matched, isTrue);
      expect(record.sender!.alias, 'Sender');
      expect(record.toString(), contains('a.bin'));
    });

    test('defaults every folder field, so old construction sites still compile',
        () {
      // `docs/22` §1.3: all four new fields have defaults. This is what keeps
      // every existing constructor call — app, cli and tests — source
      // compatible, and it is why a flat arrival is byte-identical to 0.2.37.
      const record = ReceivedFile(
        fileId: 'f1',
        fileName: 'a.bin',
        savedPath: '/recv/a.bin',
        size: 10,
        sha256: 'DEADBEEF',
      );

      expect(record.sessionId, isEmpty);
      expect(record.folderName, isNull);
      expect(record.folderFiles, 0);
      expect(record.relativePath, isNull);
    });

    test('describes a folder arrival', () {
      const record = ReceivedFile(
        fileId: 'f1',
        fileName: 'a (1).bin',
        savedPath: '/recv/素材/sub/a (1).bin',
        size: 10,
        sha256: 'DEADBEEF',
        sessionId: 'sess',
        folderName: '素材',
        folderFiles: 20,
        relativePath: 'sub/a (1).bin',
      );

      expect(record.sessionId, 'sess');
      expect(record.folderName, '素材');
      expect(record.folderFiles, 20);
      // The *actual* name on disk, so opening it works.
      expect(record.relativePath, 'sub/a (1).bin');
      expect(record.fileName, 'a (1).bin');
    });
  });
}
