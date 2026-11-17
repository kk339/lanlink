/// Untrusted **relative path** normalisation for the receive path.
///
/// Lives next to `file_name.dart` because it belongs to the same layer: it
/// turns bytes a stranger sent us into something it is safe to hand to
/// `File`/`Directory`. `sanitizeFileName` was enough while every received file
/// was flattened to a single segment; a folder transfer carries
/// `folder/relative/path` and `p.join` has none of that protection, so this is
/// the one function standing between "the peer names a subdirectory" and "the
/// peer names any directory on this machine".
///
/// The rules are a table in `docs/22` §4.3; each one is implemented here in the
/// same order and carries the reason it exists. Three things are worth stating
/// up front because they are easy to get backwards:
///
///  * **`null` in ⇒ `''` out is not an error.** An older peer sends no `path`
///    at all, which legitimately means "flat", exactly like a modern peer that
///    sends `path: ""`.
///  * **Cleaning and refusing are different answers.** A control character is
///    *cleaned* (the file is still wanted, only the byte is illegal); a segment
///    that has nothing left after cleaning is *refused* (we cannot invent a
///    name the sender will recognise). Refusing costs the whole batch, so it is
///    reserved for "this path describes a place we will not write to".
///  * **Every rule applies to every segment, not just the file name**
///    (`docs/22` §4.3a — a ruling, not an accident). So `nul/x.bin` becomes
///    `_nul/x.bin`: otherwise that directory could not be created on Windows at
///    all. A consequence the rest of the app depends on: the name on disk is
///    **not** always the name on the wire, so anything that looks a received
///    file up has to use `ReceivedFile.relativePath` (the actual landing path)
///    rather than rebuilding it from the frame.
///
/// ## Two things this file deliberately does **not** do
///
/// **No percent-/URL-decoding, ever.** `%2e%2e` is *not* `..` here — it is a
/// legal, if odd, file name, and it is written to disk verbatim. Adding a
/// `Uri.decodeComponent` "so we can catch the encoded form too" would *create*
/// the vulnerability it looks like it prevents: it turns a harmless literal into
/// a traversing `..`. There is also no end to it (`%252e%2e` decodes to
/// `%2e%2e`, which decodes to `..`), so a decode step only moves the boundary
/// one layer further from the check. The rule is therefore: validate the
/// **raw** string, and never hand it to a decoder on the way to `File`.
///
/// **No Unicode normalisation (NFC/NFD).** Two filenames that look alike but
/// differ in composition are two different files; normalising would silently
/// rename what the sender asked for, and would also make "did the sender mean
/// the file that is already here?" depend on the platform's form. The bytes the
/// peer sent are the name we use.
library;

import 'file_name.dart';

/// Maximum number of segments (directories plus the file name) in a relative
/// path. Deeper trees than this are not "a batch of material", and the depth is
/// what makes long-path failures reachable.
const int kMaxRelativePathSegments = 8;

/// Maximum length of the normalised `/`-separated relative path, in characters.
///
/// Windows' legacy `MAX_PATH` is 260 including the save directory; 180 leaves
/// room for a deep save root plus the ` (99)` suffix `resolveUniqueFile` may
/// still append (`file_name.dart`).
const int kMaxRelativePathChars = 180;

/// The most raw (pre-cleaning) segments accepted.
///
/// Rule 5 drops empty and `.` segments, so this is deliberately *not* a synonym
/// for [kMaxRelativePathSegments]: `a//b//c` is legal. It exists only so a peer
/// cannot hand us a string of slashes and make this function do thousands of
/// `sanitizeFileName` calls for free (an inbound request needs no pairing — see
/// `docs/22` R14).
///
/// Note the order: [_kMaxRawChars] rejects oversized *input* before anything is
/// split, so this check now only ever sees a string of at most 513 characters.
/// It is still worth having — "1 000 segments in 400 characters" is a shape a
/// byte cap alone cannot answer — but the multi-megabyte case is the length
/// guard's job (CR-2 ①).
const int _kMaxRawSegments = kMaxRelativePathSegments * 8;

/// The most raw (pre-cleaning) **characters** a peer's `path` may carry.
///
/// Rule 8's budget ([kMaxRelativePathChars], 180) applies to the *normalised*
/// result and can therefore only be enforced after the string has been split and
/// every segment cleaned — which is exactly the work a hostile caller wants to
/// cause. The cheapest such payload is `/` repeated: with the 8 MiB body cap in
/// `PeerServer` (and no pairing required for `prepare`), a single request used to
/// produce **8 388 609** list elements — measured at ~160 ms and hundreds of MB
/// of garbage — before rule 1 got to say "that is flat". So the input is bounded
/// first, by a length comparison that allocates nothing (CR-2 ①).
///
/// 512 is deliberately generous, not tight: 2.8x the whole normalised budget, so
/// `a//b///c` padding, folded Windows separators and eight segments of ~60
/// characters all still fit. What does **not** fit is refused, and two shapes
/// change behaviour because of it:
///
///  * a run of separators longer than the budget is refused instead of being
///    called "flat" (a 600-character separator run is not a path);
///  * a single segment longer than the budget is refused instead of being
///    silently truncated to 180 characters by rule 8. No sender can produce one
///    — every filesystem caps a name at 255 bytes, and `sanitizeFileName`
///    caps a segment at 200 — and "refuse one file" is the cheaper mistake than
///    "scan a multi-megabyte name".
const int _kMaxRawChars = 512;

final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F]');
final RegExp _trailingDotsOrSpaces = RegExp(r'[. ]+$');
final RegExp _driveLetter = RegExp(r'^[A-Za-z]:');

/// Normalises a peer-supplied relative path so it can only ever name a place
/// **inside** the receiver's folder root.
///
/// Returns the canonical `a/b/c` form (`/` separated, no leading or trailing
/// separator), or `''` meaning "flat" — one of the two always means "safe to
/// use". Returns `null` when the value must be **refused**, which the caller
/// turns into a `400` for the whole `prepare` batch.
String? normalizeRelativePath(String? raw) {
  if (raw == null) {
    return ''; // rule 1: no `path` at all — an older peer, or a flat transfer
  }

  // CR-2 ① — **before** the separator folding and before any `split`. This one
  // comparison is what keeps `'/' * 8 MiB` from becoming 8 388 609 segments;
  // the two checks that used to be first in line both needed the list to exist.
  // See [_kMaxRawChars] for why 512, and for the two pathological shapes whose
  // answer this changes from "accepted" to "refused".
  if (raw.length > _kMaxRawChars) {
    return null;
  }

  // Rule 2 next: a Windows sender writes `sub\a.bin`. Folding the separator
  // before anything else is also what makes `..\..\x` visible to rule 4.
  final String slashed = raw.replaceAll('\\', '/');

  // Rule 1, continued: nothing, or nothing but separators, is "flat". This is
  // checked before rule 3 so a lone `/` is not mistaken for an absolute path.
  if (slashed.isEmpty || slashed.split('/').every((String s) => s.isEmpty)) {
    return '';
  }

  // Rule 3: a value that names its own root — POSIX absolute, a Windows drive
  // (`C:`, `C:\x`, `C:x`) or a UNC share (`//srv/x`, which rule 2 has already
  // folded from `\\srv\x`) — is a request to choose the landing place. Refuse.
  if (slashed.startsWith('/') || _driveLetter.hasMatch(slashed)) {
    return null;
  }

  final List<String> rawSegments = slashed.split('/');

  // Rule 4: `..` is the only way to walk upwards. Refused rather than clamped
  // to the root, because silently rewriting the path would leave the user
  // believing the file went where it was asked to go.
  //
  // Note what is **not** in this list: `%2e%2e`. Nothing here decodes, so that
  // is simply a file called "%2e%2e" and it is written as one. See the library
  // doc — treating it as `..` would require a decoder, and adding that decoder
  // is what would actually introduce the traversal.
  for (final String segment in rawSegments) {
    if (segment == '..') {
      return null;
    }
  }

  if (rawSegments.length > _kMaxRawSegments) {
    return null; // see [_kMaxRawSegments] — a CPU sink, not a real path
  }

  final List<String> segments = <String>[];
  for (final String segment in rawSegments) {
    // Rule 5: `.` and stray empty segments (`a//b`, `a/`) are typos with no
    // meaning; dropping them is friendlier than refusing the batch.
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    // Rule 7b must be decided *before* `sanitizeFileName`, because that
    // function falls back to the literal `unnamed` and we would then be unable
    // to tell "nothing survived cleaning" from "the sender chose that name".
    //
    // This is the narrow refusal. Note the two cases it distinguishes, which are
    // easy to conflate:
    //  * a **raw** empty segment (`a//b`) is dropped by rule 5 above — a typo,
    //    not a request;
    //  * a segment that is **empty only after cleaning** (`a/.../b`, `a/\x01/b`)
    //    is refused here, because dropping it too would let `a/x` and `a//x`
    //    land in the same place — i.e. we would be merging two directories the
    //    sender kept apart.
    if (_isEmptyAfterCleaning(segment)) {
      return null;
    }
    // Rules 6 + 7: one existing function owns every dirty character — control
    // bytes are deleted (NUL included, so `a\u0000b` becomes `ab` and the file
    // is still accepted), `<>:"|?*` become `_`, trailing dots and spaces are
    // stripped, Windows reserved device names get a `_` prefix, and a single
    // segment is capped at 200 characters.
    //
    // Applied to a **directory** segment exactly as to a file segment
    // (`docs/22` §4.3a): `sanitizeFileName` does not know which it is looking
    // at, and must not — `nul/x.bin` has to become `_nul/x.bin`, because a
    // directory called `nul` cannot be created on Windows at all.
    segments.add(sanitizeFileName(segment));
  }

  if (segments.isEmpty) {
    return ''; // e.g. `./` — everything was dropped, so this is flat
  }

  // Rule 6b.
  if (segments.length > kMaxRelativePathSegments) {
    return null;
  }

  final int joinedLength =
      segments.fold<int>(0, (int sum, String s) => sum + s.length) +
          segments.length -
          1;
  if (joinedLength <= kMaxRelativePathChars) {
    return segments.join('/');
  }

  // Rule 8: too long. The **file** segment absorbs the cut, keeping its
  // extension so the receiver's shell still knows what the file is; a path
  // whose directory segments alone exceed the budget cannot be fixed that way
  // and is refused.
  final List<String> directories = segments.sublist(0, segments.length - 1);
  final int directoryLength = directories.isEmpty
      ? 0
      : directories.fold<int>(0, (int sum, String d) => sum + d.length) +
          directories.length; // one separator each
  final int budget = kMaxRelativePathChars - directoryLength;
  if (budget < 1) {
    return null;
  }
  final String shortened =
      _truncateFileName(segments.last, budget).replaceAll(_trailingDotsOrSpaces, '');
  if (shortened.isEmpty) {
    return null;
  }
  final String result = <String>[...directories, shortened].join('/');
  return result.length <= kMaxRelativePathChars ? result : null;
}

/// Sanitises the declared folder name (`folder.name`), which must be a single
/// segment.
///
/// Returns `''` when the sender declared no usable name, which the caller
/// treats as "this is not a folder message": flattening is honest (the files do
/// arrive), whereas inventing an `unnamed/` directory would record a name the
/// sender never used.
///
/// `sanitizeFileName` already keeps only the last path component, so a name
/// containing `/` cannot reintroduce a hierarchy here. It also brings the
/// reserved-device renaming with it, which is why a folder called `CON` lands as
/// `_CON/` — the same segment-level rule as every directory inside a folder
/// (`docs/22` §4.3a).
String sanitizeFolderName(String? raw) {
  if (raw == null) {
    return '';
  }
  final String trimmed = raw.trim();
  if (trimmed.isEmpty || _isEmptyAfterCleaning(trimmed)) {
    return '';
  }
  return sanitizeFileName(trimmed);
}

/// Whether [segment] has nothing left once the characters `sanitizeFileName`
/// deletes (control bytes) and strips (trailing dots/spaces) are accounted for.
bool _isEmptyAfterCleaning(String segment) => segment
    .replaceAll(_controlChars, '')
    .replaceAll(_trailingDotsOrSpaces, '')
    .isEmpty;

/// Shortens [name] to at most [maxChars], keeping a short extension intact.
///
/// Extensionless names are cut plainly; a name whose extension alone fills the
/// budget is cut plainly too, because "keep the extension" cannot be honoured
/// without producing an empty stem.
String _truncateFileName(String name, int maxChars) {
  if (name.length <= maxChars) {
    return name;
  }
  final int dot = name.lastIndexOf('.');
  final bool hasExtension = dot > 0 && name.length - dot <= 12;
  final String extension = hasExtension ? name.substring(dot) : '';
  final int keep = maxChars - extension.length;
  if (keep < 1) {
    return name.substring(0, maxChars);
  }
  return '${name.substring(0, keep)}$extension';
}
