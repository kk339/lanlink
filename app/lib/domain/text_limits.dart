/// Native text-message limits for the UI (docs/13 §7.3).
///
/// **Layering (M4 §8.1):** pure Dart — `ui/**` and `data/fake/**` must not
/// import `lanlink_core` / `lanlink_store`, so these constants mirror the
/// store/core originals. Keep them equal; `enum_contract_test` fails if they
/// drift.
library;

/// Maximum length of a native text-message body, in UTF-8 **bytes** (64 KiB),
/// mirroring core's `kMaxTextBytes`.
const int kMaxTextBytes = 64 * 1024;

/// Longest conversation preview stored for a text message, in code points,
/// mirroring `store`'s `kPreviewMaxChars`.
const int kPreviewMaxChars = 120;

/// Truncates [text] to [kPreviewMaxChars] code points for a conversation
/// preview. Counting `runes` (not UTF-16 units) never splits a surrogate pair.
String truncatePreview(String text) {
  final runes = text.runes;
  if (runes.length <= kPreviewMaxChars) {
    return text;
  }
  return String.fromCharCodes(runes.take(kPreviewMaxChars));
}
