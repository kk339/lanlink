/// Tests for the inbound-share bridge (0.2.18), driven through **fake method
/// channels** — the Kotlin side cannot be reached from `flutter test`, so the
/// host is simulated exactly as `MethodChannel` sees it.
///
/// What these pin (they are the "能抓错" criteria of the change):
///
///  1. `takeInitial()` answers **once**; a second call is `null` — the
///     anti-duplicate guarantee that keeps a rotation / a re-mounted intake from
///     importing the same share twice;
///  2. a 3-URI payload materialises into 3 local paths **in the sender's order**;
///  3. one URI failing still yields the other two, and the failed one is named
///     (returned in `failures` **and** logged);
///  4. `onShare` (host → Dart) reaches `incoming`, and a text-only share (no
///     uris) is ignored instead of crashing.
///
/// `AndroidShareInbox(enabled: true)` is used because the test VM is not
/// Android; the flag is the documented test seam (see the class doc).
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/data/real/android_share_inbox.dart';
import 'package:lanlink_app/domain/share_inbox.dart';

const String _shareChannel = 'lanlink/share_inbox';
const String _pickerChannel = 'lanlink/file_picker';

/// The payload shape the Android side sends (fixed contract).
Map<String, Object?> _payload(List<String> uris, {String mime = 'video/mp4'}) =>
    <String, Object?>{
      'uris': uris,
      'mime': mime,
      'multiple': uris.length > 1,
    };

void _mockChannel(
  String name,
  Future<Object?> Function(MethodCall call) handler,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(MethodChannel(name), handler);
}

/// Delivers a host → Dart message, as `invokeMethod` on the Kotlin side does.
Future<void> _deliver(String channel, MethodCall call) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    channel,
    const StandardMethodCodec().encodeMethodCall(call),
    (ByteData? _) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_shareChannel), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_pickerChannel), null);
  });

  group('takeInitial', () {
    test('answers the launch share once, then null', () async {
      int asked = 0;
      // The host deliberately keeps returning the same payload: the Dart-side
      // guard must be what stops a duplicate import.
      _mockChannel(_shareChannel, (MethodCall call) async {
        if (call.method != 'getInitialShare') {
          return null;
        }
        asked++;
        return _payload(<String>['content://media/external/video/media/123']);
      });

      final AndroidShareInbox inbox = AndroidShareInbox(enabled: true);

      final SharedPayload? first = await inbox.takeInitial();
      expect(first, isNotNull);
      expect(first!.uris, <String>['content://media/external/video/media/123']);
      expect(first.mime, 'video/mp4');
      expect(first.multiple, isFalse);

      expect(
        await inbox.takeInitial(),
        isNull,
        reason: 'the launch share must be handed over at most once — a second '
            'import would create a second draft of the same file',
      );
      expect(asked, 1, reason: 'the host must not even be asked a second time');
    });

    test('no launch share is not an error', () async {
      _mockChannel(_shareChannel, (MethodCall call) async => null);
      final AndroidShareInbox inbox = AndroidShareInbox(enabled: true);
      expect(await inbox.takeInitial(), isNull);
    });

    test('a disabled inbox (non-Android) never asks the host', () async {
      int asked = 0;
      _mockChannel(_shareChannel, (MethodCall call) async {
        asked++;
        return _payload(<String>['content://a/1']);
      });
      final AndroidShareInbox inbox = AndroidShareInbox(enabled: false);
      expect(inbox.isSupported, isFalse);
      expect(await inbox.takeInitial(), isNull);
      expect(asked, 0);
    });
  });

  group('incoming (onShare)', () {
    test('a running share is delivered to the stream', () async {
      _mockChannel(_shareChannel, (MethodCall call) async => null);
      final AndroidShareInbox inbox = AndroidShareInbox(enabled: true);
      final List<SharedPayload> received = <SharedPayload>[];
      final StreamSubscription<SharedPayload> sub =
          inbox.incoming.listen(received.add);
      addTearDown(sub.cancel);

      await _deliver(
        _shareChannel,
        MethodCall(
            'onShare', _payload(<String>['content://a/1', 'content://a/2'])),
      );
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.single.uris, <String>['content://a/1', 'content://a/2']);
      expect(received.single.multiple, isTrue);
    });

    test('a text-only share is ignored, not thrown', () async {
      _mockChannel(_shareChannel, (MethodCall call) async => null);
      final List<String> logs = <String>[];
      final AndroidShareInbox inbox =
          AndroidShareInbox(enabled: true, onLog: logs.add);
      final List<SharedPayload> received = <SharedPayload>[];
      final StreamSubscription<SharedPayload> sub =
          inbox.incoming.listen(received.add);
      addTearDown(sub.cancel);

      await _deliver(
        _shareChannel,
        const MethodCall('onShare', <String, Object?>{
          'uris': <Object?>[],
          'mime': 'text/plain',
          'multiple': false,
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(received, isEmpty);
      expect(logs.join('\n'), contains('已忽略'));
    });
  });

  group('materialize', () {
    test('3 URIs come back as 3 local paths, in the sender order', () async {
      final List<String> copied = <String>[];
      _mockChannel(_pickerChannel, (MethodCall call) async {
        if (call.method != kCopyUrisMethod) {
          return null;
        }
        final Map<Object?, Object?> args =
            call.arguments as Map<Object?, Object?>;
        final List<Object?> uris = args['uris']! as List<Object?>;
        return <Object?>[
          for (final Object? uri in uris)
            <String, Object?>{
              'uri': uri,
              'path': '/data/app/cache/lanlink-picked/$uri',
            },
        ];
      });

      final AndroidShareInbox inbox = AndroidShareInbox(enabled: true);
      final ShareImport imported = await inbox.materialize(
        SharedPayload(
          uris: <String>['content://p/1', 'content://p/2', 'content://p/3'],
          mime: 'image/*',
          multiple: true,
        ),
      );
      copied.addAll(imported.paths);

      expect(imported.paths, <String>[
        '/data/app/cache/lanlink-picked/content://p/1',
        '/data/app/cache/lanlink-picked/content://p/2',
        '/data/app/cache/lanlink-picked/content://p/3',
      ]);
      expect(imported.failures, isEmpty);
      expect(imported.hasFiles, isTrue);
      expect(copied, hasLength(3));
    });

    test('one failing URI leaves the others and is named', () async {
      final List<String> logs = <String>[];
      _mockChannel(_pickerChannel, (MethodCall call) async {
        if (call.method != kCopyUrisMethod) {
          return null;
        }
        final Map<Object?, Object?> args =
            call.arguments as Map<Object?, Object?>;
        final List<Object?> uris = args['uris']! as List<Object?>;
        return <Object?>[
          for (final Object? uri in uris)
            if (uri == 'content://p/broken')
              <String, Object?>{
                'uri': uri,
                'error': 'the content provider returned no stream',
              }
            else
              <String, Object?>{'uri': uri, 'path': '/cache/$uri'},
        ];
      });

      final AndroidShareInbox inbox =
          AndroidShareInbox(enabled: true, onLog: logs.add);

      final ShareImport imported = await inbox.materialize(
        SharedPayload(
          uris: <String>[
            'content://p/ok1',
            'content://p/broken',
            'content://p/ok2',
          ],
          multiple: true,
        ),
      );

      expect(imported.paths,
          <String>['/cache/content://p/ok1', '/cache/content://p/ok2'],
          reason: 'the two good files must still arrive, in order');
      expect(imported.failures, hasLength(1));
      expect(imported.failures.single.uri, 'content://p/broken');
      expect(imported.failures.single.reason,
          'the content provider returned no stream');
      expect(
        logs.join('\n'),
        contains('content://p/broken'),
        reason: 'the log must name WHICH uri failed, not just "some failed"',
      );
    });

    test('a whole-batch failure reports every URI instead of dropping them',
        () async {
      _mockChannel(_pickerChannel, (MethodCall call) async {
        throw PlatformException(code: 'copy_failed', message: 'no permission');
      });
      final AndroidShareInbox inbox = AndroidShareInbox(enabled: true);
      final ShareImport imported = await inbox.materialize(
        SharedPayload(uris: <String>['content://p/1', 'content://p/2']),
      );
      expect(imported.paths, isEmpty);
      expect(imported.failures, hasLength(2));
      expect(imported.failures.map((ShareImportFailure f) => f.uri),
          <String>['content://p/1', 'content://p/2']);
      expect(imported.allFailed, isTrue);
    });

    test('an empty payload is a no-op', () async {
      bool asked = false;
      _mockChannel(_pickerChannel, (MethodCall call) async {
        asked = true;
        return null;
      });
      final AndroidShareInbox inbox = AndroidShareInbox(enabled: true);
      final ShareImport imported =
          await inbox.materialize(const SharedPayload(uris: <String>[]));
      expect(imported.paths, isEmpty);
      expect(imported.failures, isEmpty);
      expect(asked, isFalse);
    });
  });

  group('SharedPayload.fromMap', () {
    test('tolerates junk', () {
      expect(SharedPayload.fromMap(null), isNull);
      expect(SharedPayload.fromMap('nope'), isNull);
      expect(SharedPayload.fromMap(<String, Object?>{'uris': 'x'}), isNull);
      expect(
        SharedPayload.fromMap(<String, Object?>{
          'uris': <Object?>[],
        }),
        isNull,
      );
    });

    test('defaults mime and multiple sensibly', () {
      final SharedPayload? payload = SharedPayload.fromMap(<String, Object?>{
        'uris': <Object?>['content://a/1', 'content://a/2'],
      });
      expect(payload, isNotNull);
      expect(payload!.mime, '*/*');
      expect(payload.multiple, isTrue, reason: 'two uris implies multiple');
    });

    test('drops non-string and empty entries', () {
      final SharedPayload? payload = SharedPayload.fromMap(<String, Object?>{
        'uris': <Object?>['content://a/1', 42, '', 'content://a/2'],
      });
      expect(payload!.uris, <String>['content://a/1', 'content://a/2']);
    });
  });
}
