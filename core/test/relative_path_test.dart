import 'package:lanlink_core/lanlink_core.dart';
import 'package:test/test.dart';

/// The receive path's only defence against a peer naming the place its file
/// lands (`docs/22` §4.3).
///
/// Every case below is a row of the rule table in that section, written out so
/// the table can be read against the code. The two answers that are easy to
/// confuse are kept visible in the test names:
///
///  * `''` — **legal**, means "flat" (an old peer sends no `path` at all);
///  * `null` — **refused**, and the caller turns that into a `400` for the whole
///    `prepare` batch.
void main() {
  group('normalizeRelativePath — A 组：必须拒绝', () {
    // Rule 3 + 4: anything that names its own root, or walks upwards. These are
    // the shapes that turn "receive a file" into "write anywhere".
    //
    // ★ `%2e%2e` is deliberately **not** here — see the B group below.
    const List<String> refused = <String>[
      '../x',
      '../../x',
      'a/../../x',
      'a/..',
      '..',
      '/etc/passwd',
      'C:/x',
      r'C:\Windows\x',
      '//srv/x',
      r'\\srv\share\x',
      'a/./../x',
    ];

    for (final String raw in refused) {
      test('refuses ${_show(raw)}', () {
        expect(normalizeRelativePath(raw), isNull);
      });
    }

    test('refuses more than kMaxRelativePathSegments segments', () {
      // 9 segments: one past the limit.
      expect(
        normalizeRelativePath('a/b/c/d/e/f/g/h/i'),
        isNull,
      );
      // The limit itself is still fine.
      expect(
        normalizeRelativePath('a/b/c/d/e/f/g/h'),
        'a/b/c/d/e/f/g/h',
      );
    });

    test('refuses a segment that is nothing but control characters', () {
      // Rule 7b: cleaning removes the bytes, and what is left is not a name —
      // so we cannot honour the request at all. This is *not* the same as "the
      // name is ugly": see the B group's `a\u0000b` case, which is cleaned and
      // accepted.
      expect(normalizeRelativePath('\u0001\u0002'), isNull);
      expect(normalizeRelativePath('a/\u0001\u0002/b.bin'), isNull);
      // Only dots/spaces in a segment is the same situation.
      expect(normalizeRelativePath('a/.../b.bin'), isNull);
      expect(normalizeRelativePath('a/   /b.bin'), isNull);
    });
  });

  group('normalizeRelativePath — B 组：必须接受', () {
    test('★ `%2e%2e` is a literal file name, never decoded to `..`', () {
      // The red line: this file performs **no** percent decoding. `%2e%2e` is
      // therefore just a file called "%2e%2e" and it is accepted verbatim.
      //
      // The tempting "fix" — decode so the encoded form can be caught too —
      // would be the bug: it turns a harmless literal into a traversing `..`,
      // and `%252e%2e` shows the chase never ends (decode once ⇒ `%2e%2e`,
      // twice ⇒ `..`). Correctness here comes from validating the raw string,
      // not from decoding harder.
      expect(normalizeRelativePath('%2e%2e'), '%2e%2e');
      expect(normalizeRelativePath('%2e%2e/%2e%2e/etc'), '%2e%2e/%2e%2e/etc');
      expect(normalizeRelativePath('%252e%2e'), '%252e%2e');
      expect(normalizeRelativePath('sub/%2E%2E.bin'), 'sub/%2E%2E.bin');
    });

    test('a NUL byte inside a name is cleaned away, not refused', () {
      // Rule 6, not 7b: the segment is not *only* control bytes, so there is a
      // name left after scrubbing and the file is still wanted. `sanitizeFileName`
      // deletes every `[\x00-\x1F\x7F]`, NUL included.
      expect(normalizeRelativePath('a\u0000b'), 'ab');
      expect(normalizeRelativePath('sub/a\u0000b.bin'), 'sub/ab.bin');
    });

    test('treats a missing or empty path as flat', () {
      // Rule 1. Not an error: a 0.2.37 peer sends no `path` at all.
      expect(normalizeRelativePath(null), '');
      expect(normalizeRelativePath(''), '');
      expect(normalizeRelativePath('/'), '');
      expect(normalizeRelativePath('//'), '');
      expect(normalizeRelativePath('./'), '');
      expect(normalizeRelativePath('.//.'), '');
    });

    test('folds Windows separators into "/" (rule 2)', () {
      expect(normalizeRelativePath(r'sub\a.bin'), 'sub/a.bin');
      expect(normalizeRelativePath(r'sub\deep\a.bin'), 'sub/deep/a.bin');
      // …which is also what makes a Windows-style traversal visible to rule 4.
      expect(normalizeRelativePath(r'a\..\..\x'), isNull);
    });

    test('drops **raw** empty and "." segments (rule 5), without erroring', () {
      // The distinction the rule turns on: a raw empty segment is a typo and is
      // dropped; a segment that is empty only *after cleaning* is refused (A
      // group), because dropping it would merge two directories the sender kept
      // apart.
      expect(normalizeRelativePath('a//b'), 'a/b');
      expect(normalizeRelativePath('a/'), 'a');
      expect(normalizeRelativePath('./a'), 'a');
      expect(normalizeRelativePath('a/./b'), 'a/b');
      expect(normalizeRelativePath('a///b///c'), 'a/b/c');
      expect(normalizeRelativePath('/a/b/') /* leading slash wins */, isNull);
    });

    test('cleans Windows-illegal characters instead of refusing (rule 7)', () {
      // Cleaning, not refusing: the file is still wanted, only the byte is
      // illegal. `sanitizeFileName` owns this table.
      expect(normalizeRelativePath('a<b>.bin'), 'a_b_.bin');
      expect(normalizeRelativePath('sub/na:me.bin'), 'sub/na_me.bin');
      // Control bytes (other than a whole-segment case) are deleted.
      expect(normalizeRelativePath('a\u0001b.bin'), 'ab.bin');
      // Trailing dots and spaces are stripped (Windows silently drops them).
      expect(normalizeRelativePath('a. /b.bin'), 'a/b.bin');
    });

    test('de-fangs Windows reserved device names (rule 7)', () {
      // `CreateFile("…\CON.txt")` on Windows is not a failure — it opens the
      // console device and *succeeds*, which shows up as "the file vanished".
      // Renaming is therefore the only answer that keeps the file, and it is a
      // rename, **not** a refusal.
      expect(normalizeRelativePath('CON'), '_CON');
      expect(normalizeRelativePath('CON.txt'), '_CON.txt');
      expect(normalizeRelativePath('NUL'), '_NUL');
      expect(normalizeRelativePath('COM1.log'), '_COM1.log');
      expect(normalizeRelativePath('sub/LPT9'), 'sub/_LPT9');
      // Case-insensitive, as the device namespace is.
      expect(normalizeRelativePath('con.txt'), '_con.txt');
      // A name that merely starts with a reserved stem is untouched.
      expect(normalizeRelativePath('console.txt'), 'console.txt');
    });

    test('does not normalise Unicode (NFC/NFD stays as sent)', () {
      // Normalising would silently rename what the sender asked for, and would
      // make "is this the file already here?" depend on the platform's form.
      const String nfd = 'e\u0301.bin'; // e + combining acute
      const String nfc = '\u00e9.bin'; // é
      expect(normalizeRelativePath(nfd), nfd);
      expect(normalizeRelativePath(nfc), nfc);
      expect(normalizeRelativePath(nfd), isNot(normalizeRelativePath(nfc)));
    });

    test('truncates an over-long path, keeping the file extension (rule 8)',
        () {
      final String long = 'x' * 200; // already at sanitizeFileName's own cap
      final String? result = normalizeRelativePath('sub/$long.bin');
      expect(result, isNotNull);
      expect(result!.length, lessThanOrEqualTo(kMaxRelativePathChars));
      expect(result, startsWith('sub/'));
      expect(result, endsWith('.bin'));
      // The directory segment is never touched — only the file segment absorbs
      // the cut.
      expect(result.split('/').first, 'sub');
    });

    test('refuses when the directory segments alone exhaust the budget', () {
      // Four 60-character directories: 4*60 + 4 separators = 244 > 180, so there
      // is no room left for a file name at all. Shortening the *file* cannot fix
      // this, and silently dropping directories would move the file somewhere
      // the sender did not ask for.
      final String dir = 'd' * 60;
      expect(normalizeRelativePath('$dir/$dir/$dir/$dir/a.bin'), isNull);
    });

    test('leaves a legal nested path byte-identical', () {
      expect(normalizeRelativePath('sub/a.bin'), 'sub/a.bin');
      expect(normalizeRelativePath('素材/2026/照片.jpg'), '素材/2026/照片.jpg');
    });
  });

  // CR-2 ① — the *cost* of a hostile input, not only its verdict.
  //
  // The old code counted segments with `slashed.split('/')` **twice**, so the
  // guard that exists to stop "a few MB of slashes" could only run after those
  // few MB had already become millions of list elements. `/` repeated is the
  // cheapest payload a stranger can send: a `prepare` frame needs no pairing and
  // the body cap is 8 MiB (`PeerServer`).
  group('normalizeRelativePath — C 组：输入规模（CR-2 ①）', () {
    test('★ an 8 MiB run of separators is refused, and costs far less than the '
        'list it avoids', () {
      final String payload = '/' * (8 * 1024 * 1024);

      // Calibration: this *is* the allocation the guard must avoid — 8 388 609
      // elements, ~160 ms and hundreds of MB of garbage on this machine.
      //
      // Timing is normally a poor assertion, and this is the one shape where it
      // is not: the numbers are compared as a **ratio against the very work the
      // fix removes**, measured on the same machine, moments apart. A slow box
      // slows both sides down and the ratio holds; a regression cannot hide in
      // "the machine was busy" because the baseline moved with it.
      final Stopwatch calibration = Stopwatch()..start();
      final List<String> segments = payload.split('/');
      final int splitMicros = calibration.elapsedMicroseconds;
      expect(
        segments.length,
        greaterThan(1000 * 1000),
        reason: 'the calibration must really be the million-object shape, '
            'otherwise the ratio below proves nothing',
      );
      segments.clear();

      final Stopwatch measured = Stopwatch()..start();
      final String? result = normalizeRelativePath(payload);
      final int micros = measured.elapsedMicroseconds;

      expect(result, isNull,
          reason: 'a multi-megabyte run of separators is not a path');
      expect(
        micros * 10,
        lessThan(splitMicros),
        reason: 'refusing must cost at least 10x less than the list it avoids '
            '(took ${micros}us; splitting the same string took ${splitMicros}us)',
      );
    });

    test('the same guard bounds a single absurd segment', () {
      // No truncation rescue: rule 8 would happily cut a 8 MiB name down to 180
      // characters, but only after scanning the whole thing. Nothing can carry
      // such a name (every filesystem caps one at 255 bytes), so refusing is the
      // cheap answer.
      expect(normalizeRelativePath('a' * (8 * 1024 * 1024)), isNull);
    });

    test('the raw budget is generous enough that legal paths never notice', () {
      // 512 raw characters is 2.8x the normalised budget, so `a//b///c` padding
      // and folded Windows separators are still "long but fine".
      final String longName = 'a' * 400;
      expect(normalizeRelativePath('a' * 512), isNotNull);
      expect(normalizeRelativePath('sub/$longName.bin'), isNotNull);
      // …while the boundary itself is exactly where it says it is.
      expect(normalizeRelativePath('a' * 513), isNull);
      // A path that is only slashes stays "flat" as long as it fits the budget;
      // past it there is no such thing as a 600-character separator run.
      expect(normalizeRelativePath('/' * 512), '');
      expect(normalizeRelativePath('/' * 513), isNull);
    });
  });

  group('sanitizeFolderName', () {
    test('keeps a normal name, including non-ASCII', () {
      expect(sanitizeFolderName('素材'), '素材');
      expect(sanitizeFolderName('lanlink-电脑版-0.2.33'), 'lanlink-电脑版-0.2.33');
    });

    test('returns "" when nothing usable was declared', () {
      // "" means "not a folder message" to the caller — flattening is honest,
      // whereas inventing an `unnamed/` directory would record a name the
      // sender never used.
      expect(sanitizeFolderName(null), '');
      expect(sanitizeFolderName(''), '');
      expect(sanitizeFolderName('   '), '');
      expect(sanitizeFolderName('\u0001\u0002'), '');
      expect(sanitizeFolderName('...'), '');
    });

    test('is a single segment: a slash cannot reintroduce a hierarchy', () {
      // `sanitizeFileName` keeps only the last component, so a hostile folder
      // name cannot escape the save root through this field either.
      expect(sanitizeFolderName('a/../../etc'), 'etc');
      expect(sanitizeFolderName('/etc'), 'etc');
      expect(sanitizeFolderName(r'..\..\x'), 'x');
      expect(sanitizeFolderName('a/b'), 'b');
    });

    test('de-fangs reserved device names', () {
      expect(sanitizeFolderName('CON'), '_CON');
      expect(sanitizeFolderName('aux'), '_aux');
    });
  });
}

/// Renders a control-character payload readably in a test name.
String _show(String raw) {
  final String visible = raw.replaceAll('\x00', r'\0').replaceAll('\n', r'\n');
  return visible;
}
