/// Where a **received** file actually lives on Android (0.2.24).
///
/// **Why this is a file of its own.** 0.2.19 publishes every accepted file into
/// the public `Download/lanlink` collection (`MediaStore.Downloads` on Android
/// 10+, `Environment.getExternalStoragePublicDirectory` below it — see
/// `data/real/android_public_storage.dart` and `MainActivity.publishToDownloads`).
/// The UI now offers 「在下载里查看」 for exactly those files, so "is this path
/// inside that folder?" has to be answerable **before** the menu is built.
///
/// That question is asked in `ui/widgets/attachment_menu.dart`, which must stay
/// Web-buildable and therefore cannot import `dart:io` or ask the platform. So
/// the answer is a **pure path test** here, and the platform is only asked to
/// *perform* the action (`PlatformPorts.viewInDownloads`).
///
/// **Why the test is on the path and not on a stored flag.** Files received by
/// an **older** build are still recorded in the database with a private path
/// (`/data/user/0/<pkg>/files/lanlink/received/x.mp4`) — they were never
/// published. Offering 「在下载里查看」 for one of those would be a button that
/// cannot land on the file, which is the exact failure shape this project keeps
/// removing (docs/18 §8.2: a control that cannot be tapped must not look
/// tappable). The path is the fact that decides it, so the path is what is read.
///
/// **0.2.29: the folder is configurable, the *shape* of the answer is not.** The
/// user may now choose any folder under `Download` (`Download/素材`), so every
/// function here takes the sub-directory as a parameter with
/// [kLanlinkDownloadsSubdirectory] as the default. What did **not** change is the
/// rule that makes the predicate useful: a file **strictly inside** that folder,
/// never the folder itself. The "which sub-directory is current?" value lives in
/// `AppSettings.receivedSubdirectory`; this file only knows how to read it.
library;

import 'package:path/path.dart' as p;

/// The public directory every received Android file is published into
/// (`Environment.DIRECTORY_DOWNLOADS`).
///
/// Spelled `Download` (singular) because that is the on-disk name Android uses —
/// `Environment.DIRECTORY_DOWNLOADS` is the string `"Download"`, and the
/// MediaStore `RELATIVE_PATH` written by `publishWithMediaStore` is built from
/// that same constant.
const String kDownloadsDirectoryName = 'Download';

/// The sub-directory of [kDownloadsDirectoryName] that lanlink owns **by
/// default** (`lanlink`).
///
/// Mirrors `MainActivity.defaultDownloadsSubdirectory` (`"lanlink"`). The two
/// spellings have to agree: if either side is retyped, files would still be
/// published (to one folder) while the UI looked for them in another — the
/// 「在下载里查看」 entry would simply stop appearing, with nothing failing.
///
/// **0.2.29 made it a default instead of the answer.** The user can now pick a
/// folder inside `Download` (`Download/素材`), and the chosen name is stored in
/// `AppSettings.receivedSubdirectory`. Everything that needs "which folder?"
/// takes it as a parameter and falls back to this constant — see
/// [normalizeDownloadsSubdirectory] for the one place that decides what a
/// missing/blank value means.
const String kLanlinkDownloadsSubdirectory = 'lanlink';

/// The folder written the way a **file manager** shows it: `Download/lanlink`,
/// i.e. [downloadsFolderPath] with the default sub-directory.
///
/// Used for the two things a *string* is good for here (0.2.26):
///  * the clipboard fallback, when the platform cannot open the folder — the
///    user pastes this into a search box / a message, so it must be the readable
///    path, never the `content://com.android.externalstorage.documents/…` URI the
///    intent carries (that one is meaningless outside Android's own resolver);
///  * a log line.
///
/// It is **not** used to decide anything: [isInLanlinkDownloadsFolder] still
/// judges whole file paths, and still says "no" for the folder itself. With a
/// user-chosen folder, use [downloadsFolderPath] — this constant is only the
/// default case.
const String kLanlinkDownloadsPath =
    '$kDownloadsDirectoryName/$kLanlinkDownloadsSubdirectory';

/// The same folder as the phone's settings row labels it: `下载 / lanlink`
/// ([downloadsFolderLabel] with the default sub-directory).
///
/// Two words instead of a path because the value sits in the settings row:
/// `Download/lanlink` at that size reads as a leftover technical string, while
/// 「下载 / lanlink」 is what the phone's own file manager calls the place. Spaces
/// around the slash on purpose — the same spacing the row already used in prose
/// before 0.2.26.
const String kLanlinkDownloadsLabel =
    '下载 / $kLanlinkDownloadsSubdirectory';

/// **The one place that decides what a missing or malformed sub-directory
/// means**: the default (`lanlink`).
///
/// Called on both sides of every boundary that can carry a blank:
///
///  * **reading the settings document** — a `null`, an absent key, `""`, `"  "`,
///    `/`, `..` or a value that normalises to nothing all mean "the user never
///    chose anything" ⇒ `lanlink`. That is what makes "空配置 = 默认" true even
///    for a hand-edited or truncated file (the same defensive posture as
///    `acceptByDefault` in `SystemPlatformPorts.loadSettings`);
///  * **before handing it to the platform** — the native side sanitises again
///    (it must not depend on Dart having done it), so both must agree on the
///    default, which is [kLanlinkDownloadsSubdirectory].
///
/// Multi-segment names are kept (`素材/2026` is a legal folder), separators are
/// normalised to `/`, and any empty, `.` or `..` segment is dropped — a path
/// fragment from a document picker that tries to climb out of `Download/` must
/// never be able to name a different tree.
String normalizeDownloadsSubdirectory(String? raw) {
  if (raw == null) {
    return kLanlinkDownloadsSubdirectory;
  }
  final List<String> segments = <String>[
    for (final String segment in raw.replaceAll(r'\', '/').split('/'))
      if (segment.trim().isNotEmpty &&
          segment.trim() != '.' &&
          segment.trim() != '..')
        segment.trim(),
  ];
  if (segments.isEmpty) {
    return kLanlinkDownloadsSubdirectory;
  }
  return segments.join('/');
}

/// Whether [raw] already names the default folder (used by the settings row to
/// decide whether 「恢复默认」 is worth offering).
bool isDefaultDownloadsSubdirectory(String? raw) =>
    normalizeDownloadsSubdirectory(raw) == kLanlinkDownloadsSubdirectory;

/// The folder as a path relative to the storage root: `Download/素材`.
String downloadsFolderPath([String? subdirectory]) =>
    '$kDownloadsDirectoryName/${normalizeDownloadsSubdirectory(subdirectory)}';

/// The folder as the settings row labels it: `下载 / 素材`.
String downloadsFolderLabel([String? subdirectory]) =>
    '下载 / ${normalizeDownloadsSubdirectory(subdirectory)}';

/// Whether [path] is a file **strictly inside** `Download/<subdirectory>`.
///
/// [subdirectory] defaults to the shipped folder ([kLanlinkDownloadsSubdirectory]);
/// callers pass the value the user configured (0.2.29).
///
/// Strictly: `…/Download/lanlink/x.mp4` is in, `…/Download/lanlink` itself and
/// `…/Download/x.mp4` are out, and so is every private path
/// (`/data/user/0/…/received/x.mp4`) — see the library doc for why that
/// direction matters just as much as the other.
///
/// **The "the folder itself is not a file in the folder" rule is deliberately
/// not relaxed** for user-chosen folders, even though a picker handily returns
/// the folder. Loosening it would also loosen 「在下载里查看」's judgement (it would
/// start offering the row for the folder and for anything that merely shares the
/// prefix), which is precisely the "a control that cannot land on the file"
/// failure this predicate exists to prevent.
///
/// **POSIX segments on purpose.** The check runs on paths produced by Android
/// (`/storage/emulated/0/Download/lanlink/…`), but the *tests* run on a Windows
/// host: `p.posix` keeps the answer identical in both places instead of
/// switching separator rules with the machine. Backslashes are folded to forward
/// slashes first, so a Windows-form path in a test still parses the same way.
bool isInLanlinkDownloadsFolder(String path, {String? subdirectory}) {
  if (path.isEmpty) {
    return false;
  }
  final List<String> segments = p.posix
      .split(path.replaceAll(r'\', '/'))
      .where((String segment) => segment.isNotEmpty && segment != '/')
      .toList(growable: false);
  // `Download/<sub…>` — the folder's own segments, in order.
  final List<String> folder = <String>[
    kDownloadsDirectoryName,
    ...normalizeDownloadsSubdirectory(subdirectory).split('/'),
  ];
  // Need at least `Download/<sub>/<name>`: the folder itself is not a file in
  // the folder, and a shorter path cannot carry every folder segment plus a name.
  if (segments.length < folder.length + 1) {
    return false;
  }
  // Compare the segments immediately left of the file name against the folder,
  // so `Download/a/b/x` matches `a/b` but `Download/a/bc/x` does not.
  final int start = segments.length - 1 - folder.length;
  for (int index = 0; index < folder.length; index++) {
    if (segments[start + index] != folder[index]) {
      return false;
    }
  }
  return true;
}
