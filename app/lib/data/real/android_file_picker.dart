/// Streaming Android file picker — replaces `file_selector` **on Android only**.
///
/// `file_selector_android` materialises the picked document in memory: it sizes
/// a Java `byte[]` to the whole file (`FileSelectorApiImpl.toFileResponse`),
/// hands it to Dart, and `XFile.fromData` wraps it again as a `Uint8List` — so
/// picking a large video kills the process with `OutOfMemoryError`.
///
/// This talks to `lanlink/file_picker` (`MainActivity.kt`), which copies the
/// document into the app cache in **64 KiB chunks** (the whole file is never in
/// memory) and reports byte progress. On every other OS it is unused; the
/// desktop path keeps using `file_selector` unchanged.
///
/// **Layering (M4 §8.1):** `data/real/**` — the platform behind it is Kotlin.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../domain/media_file_name.dart';
import '../../domain/platform_ports.dart';

const MethodChannel _channel = MethodChannel('lanlink/file_picker');

/// A streaming picker backed by the Android host.
class AndroidFilePicker {
  /// Creates the picker.
  const AndroidFilePicker();

  static final StreamController<FilePickProgress> _progress =
      StreamController<FilePickProgress>.broadcast();
  static bool _handlerInstalled = false;

  /// Whether this picker applies here (Android only).
  bool get isSupported => Platform.isAndroid;

  /// Byte progress of an in-flight [pick], for the UI.
  Stream<FilePickProgress> get progress => _progress.stream;

  /// Opens the system picker and returns the cached **paths** (empty on cancel).
  ///
  /// [mimeType] filters what may be chosen (`*/*` for anything). The file is
  /// copied into the app cache so the rest of the app can stream it from a real
  /// path. Throws [FilePickException] when the pick or the copy fails.
  Future<List<String>> pick({String mimeType = '*/*'}) async {
    if (!isSupported) {
      return const <String>[];
    }
    _installHandler();
    try {
      final List<Object?>? result = await _channel.invokeMethod<List<Object?>>(
          'pick', <String, Object?>{'mime': mimeType});
      return <String>[
        for (final Object? path in result ?? const <Object?>[]) path! as String,
      ];
    } on PlatformException catch (error) {
      throw FilePickException(error.message ?? error.code);
    } on MissingPluginException {
      throw FilePickException('安卓选取文件的桥不可用');
    }
  }

  /// Opens the **system gallery picker** and returns what was picked (empty on
  /// cancel).
  ///
  /// This is the 「照片」 door (0.2.53). The difference from [pick] is only the
  /// picker the platform opens — `MainActivity.startPickMedia` prefers
  /// `ACTION_PICK_IMAGES` (the gallery, with albums grouped at the top) and falls
  /// back to the document browser where that does not exist. Everything after the
  /// user's choice is the same: multi-selection, the same 64 KiB cache copy, the
  /// same [progress], the same empty list for "cancelled".
  ///
  /// **The answer is richer than [pick]'s on purpose.** A photo the system named
  /// `1000055362.jpg` is unreadable, and only the platform knows when it was
  /// taken (the cached copy's mtime is the moment of the copy). So each item
  /// carries the display name, the capture time and the MIME type back with the
  /// path; the naming decision is made in Dart
  /// (`lib/domain/media_file_name.dart`), never in Kotlin.
  ///
  /// Throws [FilePickException] when the pick or the copy fails.
  Future<List<PickedMedia>> pickMedia() async {
    if (!isSupported) {
      return const <PickedMedia>[];
    }
    _installHandler();
    final List<Object?>? result;
    try {
      result = await _channel.invokeMethod<List<Object?>>('pickMedia');
    } on PlatformException catch (error) {
      throw FilePickException(error.message ?? error.code);
    } on MissingPluginException {
      throw FilePickException('安卓选取照片的桥不可用');
    }
    final List<PickedMedia> picked = <PickedMedia>[];
    for (final Object? raw in result ?? const <Object?>[]) {
      final PickedMedia? media = _toPickedMedia(raw);
      if (media != null) {
        picked.add(media);
      }
    }
    return picked;
  }

  /// Reads one `{path, displayName, takenAtMillis, mime}` reply item.
  ///
  /// `null` when the platform sent no path at all — a row the app cannot stream
  /// is dropped rather than turned into an empty attachment. `takenAtMillis`
  /// arrives as a `num?` (Kotlin `Long?`/`Int?`) and a non-positive value is
  /// **normalised to `null`**: "no timestamp" must never look like 1970.
  static PickedMedia? _toPickedMedia(Object? raw) {
    final Map<Object?, Object?> fields =
        raw is Map<Object?, Object?> ? raw : const <Object?, Object?>{};
    final String path = (fields['path'] as String?) ?? '';
    if (path.isEmpty) {
      return null;
    }
    final num? stamp = fields['takenAtMillis'] as num?;
    return PickedMedia(
      path: path,
      displayName: (fields['displayName'] as String?) ?? '',
      takenAtMillis:
          stamp == null || stamp.toInt() <= 0 ? null : stamp.toInt(),
      mime: (fields['mime'] as String?) ?? '',
    );
  }

  /// Installs the native→Dart handler once, forwarding `progress` messages.
  void _installHandler() {
    if (_handlerInstalled) {
      return;
    }
    _handlerInstalled = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'progress') {
        return null;
      }
      final Map<Object?, Object?>? args =
          call.arguments as Map<Object?, Object?>?;
      final int done = (args?['done'] as num?)?.toInt() ?? 0;
      final int total = (args?['total'] as num?)?.toInt() ?? 0;
      _progress.add(FilePickProgress(done: done, total: total));
      return null;
    });
  }
}

/// Renames the cached copies of a photo pick to their **readable** names and
/// answers the paths to use (0.2.53).
///
/// The naming itself is the pure rule set in `lib/domain/media_file_name.dart`;
/// this is the only place that touches the disk, and it is deliberately dull:
///
///  * **a name that does not change is not renamed** — the file is left exactly
///    where the copy put it, so a pick of `IMG_1234.jpg` costs zero syscalls;
///  * **a rename that fails keeps the original path** — an ugly name is a
///    cosmetic problem, a path that points nowhere would make the message
///    unsendable (this app has already paid for that class of bug);
///  * the copy stays in the same directory: only the file name changes, so the
///    launch sweep and the send path see the same layout they always did.
///
/// Every returned path exists; that is asserted in
/// `test/media_file_name_test.dart` against real files.
Future<List<String>> applyMediaFileNames(List<PickedMedia> picked) async {
  if (picked.isEmpty) {
    return const <String>[];
  }
  final List<String> names = uniqueMediaFileNames(picked);
  final List<String> paths = <String>[];
  for (int index = 0; index < picked.length; index += 1) {
    final String source = picked[index].path;
    final String target = mediaSiblingPath(source, names[index]);
    if (target == source) {
      paths.add(source);
      continue;
    }
    try {
      final File renamed = await File(source).rename(target);
      paths.add(renamed.path);
    } on FileSystemException {
      // Never lose the file over its name.
      paths.add(source);
    }
  }
  return paths;
}
