/// Turning a picked photo's **display name** into something a human can read —
/// pure functions, no `dart:io`, no platform (0.2.53).
///
/// The problem this exists for: on a real device the system photo picker hands
/// back names like `1000055362.jpg`. They are unique and useless — the bubble, the
/// 最近文件 list and the saved file all say a number, and the user asked for
/// 「能看懂的名字」.
///
/// **Only the picker knows when the photo was taken.** The cached copy's own mtime
/// is the moment of the copy (a whole batch shares one second), so the timestamp
/// must come from the platform (`MainActivity`, `DATE_TAKEN`) and arrive here as
/// data. This file therefore decides **the name only**; the rename itself is done
/// next to the cache copy (`android_file_picker.dart`), and the native side never
/// names anything.
///
/// The rules, in the order they matter:
///  1. a name that is **not** all digits is returned **byte-for-byte unchanged**
///     (`IMG_1234.jpg`, `微信图片_2026.jpg` are already readable — renaming them
///     would be destroying information we did not create);
///  2. an all-digit stem **with** a timestamp becomes `yyyyMMdd_HHmmss` + the same
///     extension, in **local** time (this is a label a person reads, not a record
///     to compare across machines);
///  3. an all-digit stem **without** a timestamp keeps its name: a wrong date is
///     worse than an ugly one;
///  4. the extension is always kept; when the name has none it is inferred from
///     the MIME type, and when that fails nothing is appended (never a guess);
///  5. collisions **inside one batch** take `-2`, `-3`, … before the extension.
///     Nothing is checked on disk: every pick copies into a fresh
///     `lanlink-picked/<uuid>/` directory, so the only possible clash is a sibling
///     in the same batch.
library;

/// One file the platform picked, with the two facts only the platform knows.
///
/// [path] is the **cached copy** (the app never reads the picked URI again), so
/// it is what the rest of the app streams; [displayName] is the name the system
/// reported, which may be `1000055362.jpg`.
///
/// [takenAtMillis] is **null when unknown**, never `0`: "no timestamp" and "1st
/// January 1970" must not be able to look the same, or a photo with a missing
/// column would be renamed to 1970.
class PickedMedia {
  /// Creates one picked file.
  const PickedMedia({
    required this.path,
    required this.displayName,
    this.takenAtMillis,
    this.mime = '',
  });

  /// The cached path the app will stream from.
  final String path;

  /// The name the platform reported.
  final String displayName;

  /// Capture time in milliseconds since the epoch, or `null` when the platform
  /// could not answer.
  final int? takenAtMillis;

  /// The platform's MIME type (`image/jpeg`), or `''`.
  final String mime;

  @override
  String toString() =>
      'PickedMedia($path, $displayName, takenAt: $takenAtMillis, mime: $mime)';
}

/// Extensions used when a name carries none. Only formats a phone actually
/// produces, and only the ones this app can show; anything else gets **no**
/// extension rather than an invented one.
const Map<String, String> _extensionByMime = <String, String>{
  'image/jpeg': '.jpg',
  'image/jpg': '.jpg',
  'image/png': '.png',
  'image/webp': '.webp',
  'image/gif': '.gif',
  'image/heic': '.heic',
  'image/heif': '.heic',
  'image/heic-sequence': '.heic',
  'video/mp4': '.mp4',
  'video/quicktime': '.mov',
  'video/webm': '.webm',
  'video/x-matroska': '.mkv',
};

/// Whether [stem] is **only** digits — the "the system named this" shape.
final RegExp _allDigits = RegExp(r'^\d+$');

/// Splits `Picture.JPG` into (`Picture`, `.JPG`).
///
/// Deliberately not `p.extension`: a leading dot (`.nomedia`), a trailing dot
/// (`shot.`) and a dotless name all have to land on "no extension", and the
/// extension is carried through **verbatim** (case included) so a rename cannot
/// change `IMG.JPG` into `IMG.jpg`.
({String stem, String extension}) splitMediaName(String name) {
  final int dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) {
    return (stem: name, extension: '');
  }
  return (stem: name.substring(0, dot), extension: name.substring(dot));
}

/// The final name for one picked file — see the library docs for the rules.
///
/// Returns [displayName] **unchanged** whenever the name is already readable, the
/// timestamp is missing, or the name is empty. Never returns an empty string for
/// a non-empty input.
String mediaFileName({
  required String displayName,
  int? takenAtMillis,
  String mime = '',
}) {
  if (displayName.isEmpty) {
    return displayName;
  }
  final ({String stem, String extension}) parts = splitMediaName(displayName);
  if (takenAtMillis == null || takenAtMillis <= 0) {
    return displayName;
  }
  if (!_allDigits.hasMatch(parts.stem)) {
    return displayName;
  }
  final String extension = parts.extension.isNotEmpty
      ? parts.extension
      : (_extensionByMime[mime.toLowerCase()] ?? '');
  return '${_stamp(takenAtMillis)}$extension';
}

/// Names for a whole batch, de-duplicated in order.
///
/// A collision can only happen **inside** this batch (a fresh
/// `lanlink-picked/<uuid>/` per pick), so a `Set` of the names already handed out
/// is the whole rule — no disk is consulted.
List<String> uniqueMediaFileNames(List<PickedMedia> picked) {
  final Set<String> used = <String>{};
  final List<String> names = <String>[];
  for (final PickedMedia item in picked) {
    final String base = mediaFileName(
      displayName: item.displayName.isEmpty
          ? mediaBaseName(item.path)
          : item.displayName,
      takenAtMillis: item.takenAtMillis,
      mime: item.mime,
    );
    String candidate = base;
    if (used.contains(candidate)) {
      final ({String stem, String extension}) parts = splitMediaName(base);
      int suffix = 2;
      do {
        candidate = '${parts.stem}-$suffix${parts.extension}';
        suffix += 1;
      } while (used.contains(candidate));
    }
    used.add(candidate);
    names.add(candidate);
  }
  return names;
}

/// The last path segment of [path] (`/a/b/c.jpg` → `c.jpg`).
///
/// Handles both separators because the cache paths are POSIX (Android) while the
/// tests that exercise the rename run on Windows.
String mediaBaseName(String path) {
  final int slash = path.lastIndexOf('/');
  final int backslash = path.lastIndexOf(r'\');
  final int cut = slash > backslash ? slash : backslash;
  return cut < 0 ? path : path.substring(cut + 1);
}

/// [path] renamed to [fileName] **in its own directory** (the cached copy stays
/// where it is; only its name changes).
String mediaSiblingPath(String path, String fileName) {
  final int slash = path.lastIndexOf('/');
  final int backslash = path.lastIndexOf(r'\');
  final int cut = slash > backslash ? slash : backslash;
  if (cut < 0) {
    return fileName;
  }
  return '${path.substring(0, cut + 1)}$fileName';
}

/// `yyyyMMdd_HHmmss` in the machine's **local** timezone.
String _stamp(int millis) {
  final DateTime moment = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${moment.year.toString().padLeft(4, '0')}'
      '${two(moment.month)}${two(moment.day)}'
      '_${two(moment.hour)}${two(moment.minute)}${two(moment.second)}';
}
