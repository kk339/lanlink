import 'dart:io';

import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// Unit tests for untrusted file-name sanitisation and collision-free resolution
/// — the security-critical part of the M2 receive path.
void main() {
  group('sanitizeFileName', () {
    test('keeps a plain name untouched', () {
      expect(sanitizeFileName('holiday.png'), 'holiday.png');
      expect(sanitizeFileName('my report 2026.pdf'), 'my report 2026.pdf');
    });

    test('keeps only the last path component', () {
      expect(sanitizeFileName('a/b/c.txt'), 'c.txt');
      expect(sanitizeFileName(r'C:\Users\me\Desktop\notes.md'), 'notes.md');
    });

    test('defuses path traversal', () {
      expect(sanitizeFileName(r'..\..\etc\passwd'), 'passwd');
      expect(sanitizeFileName('../../secret.txt'), 'secret.txt');
      expect(sanitizeFileName('..'), 'unnamed');
    });

    test('replaces characters that are illegal on Windows', () {
      expect(sanitizeFileName('a<b>c:d"e|f?g*h.txt'), 'a_b_c_d_e_f_g_h.txt');
    });

    test('strips control characters', () {
      expect(sanitizeFileName('a\u0000b\u001F c'), 'ab c');
    });

    test('strips trailing dots and spaces (Windows drops them silently)', () {
      expect(sanitizeFileName('report.txt...'), 'report.txt');
      expect(sanitizeFileName('report.   '), 'report');
    });

    test('de-fangs reserved device names', () {
      expect(sanitizeFileName('CON'), '_CON');
      expect(sanitizeFileName('nul.txt'), '_nul.txt');
      expect(sanitizeFileName('LPT1'), '_LPT1');
      expect(sanitizeFileName('com9.log'), '_com9.log');
    });

    test('never returns an empty name', () {
      expect(sanitizeFileName(''), 'unnamed');
      expect(sanitizeFileName('   '), 'unnamed');
      expect(sanitizeFileName('...'), 'unnamed');
      expect(sanitizeFileName('.'), 'unnamed');
    });

    test('caps the total length while keeping a short extension', () {
      final long = '${'a' * 300}.txt';
      final sanitized = sanitizeFileName(long);
      expect(sanitized.length, lessThanOrEqualTo(200));
      expect(sanitized.endsWith('.txt'), isTrue);
    });
  });

  group('resolveUniqueFile', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('lanlink_names_');
    });

    tearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    test('returns the sanitised name when the file does not exist', () async {
      final file = await resolveUniqueFile(dir, 'note.txt');
      expect(file.path, endsWith('note.txt'));
    });

    test('never overwrites an existing file', () async {
      final first = await resolveUniqueFile(dir, 'dup.txt');
      await first.writeAsString('one');

      final second = await resolveUniqueFile(dir, 'dup.txt');

      expect(second.path, isNot(first.path));
      expect(second.path, endsWith('dup (1).txt'));
      expect(await first.readAsString(), 'one');
    });

    test('inserts the suffix before the extension', () async {
      await File(
        '${dir.path}${Platform.pathSeparator}archive.tar.gz',
      ).writeAsString('x');

      final next = await resolveUniqueFile(dir, 'archive.tar.gz');

      expect(next.path, endsWith('archive.tar (1).gz'));
    });

    test('sanitises the name before resolving', () async {
      final file = await resolveUniqueFile(dir, r'..\..\etc\passwd');
      expect(file.path, endsWith('passwd'));
    });

    test('creates the target directory when it is missing', () async {
      final nested = Directory(
        '${dir.path}${Platform.pathSeparator}inbox',
      );
      expect(await nested.exists(), isFalse);

      final file = await resolveUniqueFile(nested, 'a.bin');

      expect(await nested.exists(), isTrue);
      expect(file.path, endsWith('a.bin'));
    });
  });
}
