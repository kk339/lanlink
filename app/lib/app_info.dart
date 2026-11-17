/// App identity constants (M5 §F).
///
/// **The version lives here — one place in code, with `pubspec.yaml` as the
/// source.** A guard test (`test/app_version_test.dart`) reads `pubspec.yaml` and
/// fails if this constant ever drifts from it, so the two cannot silently
/// disagree. That is the point: a forgotten bump becomes a **red test**, not a
/// stale string nobody notices.
///
/// A build **may** override it with `--dart-define=APP_VERSION=…` (e.g. a CI
/// tag); with no override it is the pubspec value below. Deliberately **no**
/// runtime plugin read — one constant, one guard, zero dependencies.
library;

/// The app's display name.
const String kAppName = 'lanlink';

/// The in-app brand mark (transparent PNG, the three prisms + the centre dot).
///
/// **Where it comes from:** the user drew the app icon themselves; the vector
/// source is the project's own vector artwork (kept outside this repo,
/// next to the delivered APK assets). `assets/brand/mark.png` is that artwork
/// **alone** — no plate, no shadow, no stroke — rasterised at 96px, i.e. 4x the
/// 24dp slot the bar draws it at, so it is sharp on every screen density.
/// (`assets/brand/mark@2x.png` is a 192px copy for reuse outside the app;
/// Flutter does **not** interpret the `@2x` filename suffix — only `2.0x/`
/// variant directories — so the widget always loads this one file.)
///
/// Held as a constant so there is exactly one spelling of the path: the phone
/// top bar draws it (`phone_shell.dart`) and `pubspec.yaml` publishes the
/// directory. A second hand-written string is how an asset silently 404s.
const String kBrandMarkAsset = 'assets/brand/mark.png';

/// The **same** artwork at 192px, for the one place the mark is drawn large:
/// the 关于 page's 64dp icon (0.2.21).
///
/// **Why a second constant instead of a `2.0x/` variant directory:** 96px is
/// only 1.5x the 64dp slot, so on a 3x phone the mark would be upscaled 2x and
/// read soft — and the user's instruction for that slot was, in one word, "别糊".
/// A real `assets/brand/2.0x/` variant is the textbook fix, but it would bundle
/// the artwork twice and add a second pubspec entry for a single widget; the
/// 192px file is **already published** (`assets/brand/`, 0.2.9), so naming it
/// here costs one line and no new asset.
///
/// ★ It is a **named constant on purpose**: `mark@2x.png` written inline at the
/// call site is the exact "second hand-written string" this file exists to
/// prevent (the `@2x` filename suffix is *not* interpreted by Flutter — see
/// [kBrandMarkAsset] — so a typo in it would ship a broken image, not a variant).
const String kBrandMarkAssetHiRes = 'assets/brand/mark@2x.png';

/// The app's display version.
///
/// Kept in step with `pubspec.yaml`'s `version:` by the guard test; overridable
/// at build time with `--dart-define=APP_VERSION=<value>`.
const String kAppVersion =
    String.fromEnvironment('APP_VERSION', defaultValue: '0.2.63');
