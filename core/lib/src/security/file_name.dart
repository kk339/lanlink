/// Untrusted file-name sanitisation for the (M2) receive path.
///
/// These helpers are placed here now so the security-critical logic lives in
/// one reviewed location before the upload flow is implemented.
library;

import 'dart:io';

/// Windows reserved device names (case-insensitive, extension ignored).
const Set<String> _reservedNames = {
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
};

/// Sanitises an untrusted, peer-supplied file name so the resulting path can
/// never escape the target directory.
///
/// Steps, in order:
///  1. collapse `\` to `/` and keep only the last path component;
///  2. strip control characters;
///  3. replace characters illegal on Windows (`< > : " | ? *`);
///  4. strip trailing dots and spaces (Windows silently drops them);
///  5. reject `.`, `..` and empty names;
///  6. de-fang reserved device names;
///  7. cap the total length.
///
/// It never returns an empty string.
String sanitizeFileName(String raw) {
  var name = raw.replaceAll('\\', '/');
  final lastSlash = name.lastIndexOf('/');
  if (lastSlash >= 0) {
    name = name.substring(lastSlash + 1);
  }
  name = name.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
  name = name.replaceAll(RegExp(r'[<>:"|?*]'), '_');
  name = name.replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty || name == '.' || name == '..') {
    name = 'unnamed';
  }
  final stem = name.contains('.') ? name.substring(0, name.indexOf('.')) : name;
  if (_reservedNames.contains(stem.toUpperCase())) {
    name = '_$name';
  }
  if (name.length > 200) {
    final dot = name.lastIndexOf('.');
    if (dot > 0 && name.length - dot <= 12) {
      final extension = name.substring(dot);
      name = '${name.substring(0, 200 - extension.length)}$extension';
    } else {
      name = name.substring(0, 200);
    }
  }
  return name;
}

/// Resolves a non-colliding [File] inside [directory].
///
/// Existing files are never overwritten (security checklist item "静默覆盖"):
/// a numeric suffix ` (n)` is inserted before the extension until a free name
/// is found.
Future<File> resolveUniqueFile(Directory directory, String rawFileName) async {
  await directory.create(recursive: true);
  final safe = sanitizeFileName(rawFileName);
  final separator = Platform.pathSeparator;
  var candidate = File('${directory.path}$separator$safe');
  if (!await candidate.exists()) {
    return candidate;
  }
  final dot = safe.lastIndexOf('.');
  final stem = dot > 0 ? safe.substring(0, dot) : safe;
  final extension = dot > 0 ? safe.substring(dot) : '';
  for (var index = 1; index < 100000; index++) {
    candidate = File('${directory.path}$separator$stem ($index)$extension');
    if (!await candidate.exists()) {
      return candidate;
    }
  }
  throw FileSystemException('could not resolve a unique file name', safe);
}
