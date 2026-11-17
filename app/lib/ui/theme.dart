/// Light theme and the seven-status colour palette (spec §2: `ui/theme.dart`).
///
/// The **text** for a status lives in `ui/format.dart` (spec §8.4 — the single
/// source of copy); the **colour** for a status lives here. Widgets must not
/// inline colours: they read [statusColor] so the palette stays in one place.
///
/// Layering (spec §8.1): `ui/**` may import `package:flutter/*` and this
/// package's `domain/**`; it never imports `lanlink_core` / `lanlink_store` /
/// `dart:io`.
library;

import 'package:flutter/material.dart';

import '../domain/models.dart';
import 'fonts.dart';

/// The seed colour the light theme is derived from.
const Color kSeedColor = Color(0xFF3B6EF6);

/// Background of the left navigation rail — the darkest of the three surfaces
/// ("退到后面", PRD §2.1 / design §9.1).
const Color kSurfaceRail = Color(0xFFDFE6F4);

/// Background of the middle list pane (PRD §2.1 / design §9.1).
const Color kSurfaceList = Color(0xFFF7F8FA);

/// The hairline divider between panes and between list rows (PRD §2.1).
const Color kDividerColor = Color(0xFFE5E7EB);

/// The fill behind a selected list row: the brand colour at 10% alpha.
///
/// Derived from [kSeedColor] so there is still exactly one blue — never a
/// second hand-written value (PRD §2.1 / design §9.1).
final Color kSelectionFill = kSeedColor.withValues(alpha: 0.10);

/// The fill behind a selected **middle-pane list row** (docs/18d §4).
///
/// **A separate slot from [kSelectionFill], because Feishu genuinely uses two
/// colours**: its list selection is `#D2DEF5` (b−r = 35) while its rail
/// selection is a near-white `#F8FAFD` (b−r = 5). One slot cannot be both.
///
/// **Why this must be an explicit constant and not an alpha of the seed**: our
/// [kSelectionFill] is the seed at 10%, which composites to roughly `(228,234,250)`
/// — a spread of ≈21 — while `#D2DEF5` has a spread of 35. **No alpha reproduces
/// it** (docs/18d §4).
///
/// ★ The rail's near-white is deliberately **not** copied to our rail: that
/// near-white only reads because Feishu's rail background is the blue-grey
/// `#DFE6F4`. Ours is not, so copying it would produce an **invisible
/// selection** (docs/18d §4). [selectionFill] stays as it is.
const Color kSelectionFillList = Color(0xFFD2DEF5);

/// The fill painted behind a row while the pointer hovers it
/// (PRD §2.5 "点击反馈": hovering a row must give visible feedback).
///
/// A **neutral** tint, not the brand one, so hover stays distinguishable from
/// the brand-tinted [kSelectionFill] (10%) when both could apply, and the
/// palette keeps exactly one blue.
///
/// **8% (alpha `0x14`) — deliberately, not the usual ~5%.** In a hover/no-hover
/// side-by-side screenshot the 5% fill was indistinguishable over the light
/// panes, even though the ink host was correct. 8% reads clearly while staying
/// below [kSelectionFill], so hover never looks like "selected".
const Color kHoverFill = Color(0x14000000);

/// The width of the selected row's leading brand-coloured bar (PRD §2.1).
const double kSelectionBarWidth = 2;

/// Corner radius for cards and message bubbles (design §9.2).
const double kRadiusCard = 12;

/// Corner radius for thumbnails and file rows (design §9.2).
///
/// **4, not the M3 "Small" 8**: on the phone review this moved from an off-scale
/// 6 to the M3 ladder; 4 and 8 are both 2 px from 6 (a tie), and M3 assigns 4
/// ("Extra small") to small elements — which is what this radius is used on
/// (thumbnails, a row's hover shape). See `test/widget/tap_target_probe_test.dart`.
const double kRadiusThumb = 4;

/// Corner radius of the capsule input field (design §9.2).
const double kRadiusInput = 20;

/// The duration of a short UI transition — a row's hover / selection fill, a
/// module or conversation swap (PRD §2.5 / design §9.2).
///
/// Kept in the 120–180 ms band: long enough to read as motion rather than a
/// hard cut, short enough that `pumpAndSettle` settles quickly. Every animation
/// that uses it is **bounded** — nothing here repeats (an unbounded animation
/// would hang `pumpAndSettle`; see `FadeIn`).
const Duration kTransitionDuration = Duration(milliseconds: 150);

/// The fixed height of a middle-pane list row (design §9.2 / §6.2).
const double kRowHeight = 40;

/// The minimum size of a **touch target** (Material's 48×48 dp floor).
///
/// Applies to the *hit box*, not the artwork: Material's accessibility guidance
/// is explicit that "touch targets … extend beyond the visual bounds of an
/// element" ("an icon may appear to be 24 x 24 dp, but the padding surrounding
/// it comprises the full 48 x 48 dp touch target" —
/// https://material.io/archive/guidelines/usability/accessibility.html).
///
/// Introduced with the two measured sub-48 targets — the phone receive status
/// bar (36) and a file row (44); see `test/widget/tap_target_fix_test.dart`,
/// which asserts both the measured size **and** that a tap 2 px inside the edge
/// still reaches the control.
const double kMinTapTarget = 48;

/// The diameter of a list row's circular leading icon (design §9.2).
const double kListIconDiameter = 40;

/// The diameter of the detail header / rail self avatar (design §9.2).
const double kDetailAvatarDiameter = 36;

/// A message bubble's **absolute** maximum width in logical pixels (PRD §2.4).
///
/// A percentage-only cap scales with the window, so on a wide screen both the
/// `in` and `out` bubbles hug the cap, look equal, and the left/right split
/// stops reading. This absolute cap (the WeChat / Feishu order of magnitude)
/// keeps a bubble clearly narrower than the pane, so which side a message is on
/// is obvious at a glance.
const double kBubbleMaxWidthPx = 460;

/// A message bubble's maximum width as a fraction of its pane — the
/// **narrow-window fallback**, used only when it is smaller than
/// [kBubbleMaxWidthPx] (design §9.2 / PRD §2.4).
const double kBubbleMaxWidthFactor = 0.78;

/// Builds the app's light theme (M4 is light-only, spec §2).
///
/// `dividerColor` / `hoverColor` are pinned to the original constants so every
/// `Divider` / `InkWell` that used to name them explicitly renders identically
/// (M5c §7 moved those to the theme, so the dark theme can differ).
ThemeData buildLightTheme() => _withCjkFallback(ThemeData(
      colorSchemeSeed: kSeedColor,
      brightness: Brightness.light,
      dividerColor: kDividerColor,
      dividerTheme: const DividerThemeData(color: kDividerColor, thickness: 1),
    ));

/// Builds the app's **dark** theme (M5c §7).
///
/// Same seed and shapes, dark brightness; chosen by the OS through
/// `ThemeMode.system` in `app.dart`. The **light** appearance is unchanged — a
/// light OS keeps [buildLightTheme] byte-for-byte.
ThemeData buildDarkTheme() => _withCjkFallback(ThemeData(
      colorSchemeSeed: kSeedColor,
      brightness: Brightness.dark,
      dividerColor: kDarkDividerColor,
      hoverColor: kDarkHoverFill,
      dividerTheme:
          const DividerThemeData(color: kDarkDividerColor, thickness: 1),
    ));

/// Attaches the **CJK fallback chain** to a finished theme (0.2.36).
///
/// Both builders above go through here, so "which font draws Chinese" has one
/// answer for the whole app (see `ui/fonts.dart` for why it is a *fallback* and
/// why nothing is bundled). It changes no colour, size or padding: the fallback
/// list is consulted only for code points the primary family cannot draw, so
/// Latin text and every metric in this file stay exactly as they were.
ThemeData _withCjkFallback(ThemeData base) => base.copyWith(
      textTheme: withCjkFallback(base.textTheme),
      primaryTextTheme: withCjkFallback(base.primaryTextTheme),
    );

/// The dark-theme divider hairline (M5c §7).
const Color kDarkDividerColor = Color(0xFF3A3C40);

/// The dark-theme row-hover fill (M5c §7) — a white tint, so hover stays visible.
const Color kDarkHoverFill = Color(0x1FFFFFFF);

// ── theme-aware surfaces (M5c §7) ────────────────────────────────────────────
//
// The rail / list / divider / fills below used to be fixed light values, which
// stayed light (and glaring) under a dark theme. These resolve per [theme]; the
// **light** branch returns the original constants, so light rendering is
// unchanged.

/// The left-rail / status-bar surface for [theme].
Color surfaceRail(ThemeData theme) => theme.brightness == Brightness.dark
    ? const Color(0xFF1C1D20)
    : kSurfaceRail;

/// The middle-pane surface for [theme].
Color surfaceList(ThemeData theme) => theme.brightness == Brightness.dark
    ? const Color(0xFF232428)
    : kSurfaceList;

// ── the pane sheet + its seams (docs/19 §8-②) ────────────────────────────────
//
// Measured on the reference (a Feishu window at 1767 image px):
// * the **middle and right** columns share **one** near-neutral white
//   (`#FCFCFC`), while the rail keeps a tinted surface of its own;
// * between them sits a **~9 image px band** (`#EDF1FC`) — a *seam*, not a rule.
//   9 / 1.13 ≈ 8 logical px.
//
// We used to run three different tinted surfaces (rail / list `#F7F8FA` /
// detail `#FAF8FF`) joined by 1px `VerticalDivider`s, which reads as three
// bands stitched with a line instead of one sheet cut by a seam.

/// The shared surface of the **middle and right** panes.
const Color kPaneSurface = Color(0xFFFCFCFC);

/// The shared pane surface for [theme] (the dark branch keeps the previous
/// dark list surface, so only the light rendering changes).
Color paneSurface(ThemeData theme) => theme.brightness == Brightness.dark
    ? const Color(0xFF232428)
    : kPaneSurface;

/// The width of the seam between two panes, in logical px.
const double kPaneSeam = 8;

/// The seam's fill in the light theme (measured `#EDF1FC` on the reference).
const Color kPaneSeamColor = Color(0xFFEDF1FC);

/// The seam's fill for [theme]. The dark branch is a translucent white so it
/// reads as "one step away from the pane" on any dark surface.
Color paneSeamColor(ThemeData theme) => theme.brightness == Brightness.dark
    ? const Color(0x14FFFFFF)
    : kPaneSeamColor;

/// **Not** a slot: the rail's selected item keeps [kNavItemInset] (8).
///
/// 2026-10-17 re-measured the reference: rail `x 0..269`, selected block
/// `x 12..257` — the reference **insets** it ~12 image px on each side
/// (12 / 270 = 4.4% × our 168 ≈ 7.5 ≈ 8), so "the highlight runs the full rail
/// width" was an eyeball error, retracted in `docs/19 §8-③`.

// ── the incoming bubble (docs/19 §8-⑦) ───────────────────────────────────────
//
// Measured on the reference: an incoming message's fill is a **light blue**
// (`#D1E3FE`), not a neutral grey. Ours was `surfaceContainerHighest`
// (`#E3E1E9`), which reads as a card rather than as a message.
//
// Desktop only: the phone follows Flix, so it keeps the old fill.

/// An incoming bubble's fill on the desktop.
const Color kIncomingBubbleFill = Color(0xFFD1E3FE);

/// [kIncomingBubbleFill] for [theme] — the dark branch is a desaturated blue
/// that still reads as "one step away from the pane".
Color incomingBubbleFill(ThemeData theme) => theme.brightness == Brightness.dark
    ? const Color(0xFF2C3550)
    : kIncomingBubbleFill;

/// The diameter of the avatar drawn **outside** an incoming bubble (desktop).
///
/// **26 is an eyeball value, not a measurement** ✗ — the reference's avatar sits
/// on a busy background and my first attempt to isolate it failed (the probe
/// caught the whole region). It is a single constant on purpose: resize it in
/// one place once it has been looked at, rather than sprinkling sizes around.
/// (22 → 26 on 2026-10-17: at 22 it read as detached from the bubble.)
const double kMessageAvatar = 26;

/// The hairline divider for [theme].
Color dividerColor(ThemeData theme) => theme.brightness == Brightness.dark
    ? const Color(0xFF3A3C40)
    : kDividerColor;

/// The selected-row fill for [theme] — derived from [kSeedColor], so there is
/// still exactly one blue (a brighter alpha on dark, to read over a dark pane).
Color selectionFill(ThemeData theme) => theme.brightness == Brightness.dark
    ? kSeedColor.withValues(alpha: 0.24)
    : kSelectionFill;

/// The middle-pane **list** selection fill for [theme] (docs/18d §4).
///
/// Light: [kSelectionFillList] verbatim. Dark: a darker-pane variant following
/// this file's idiom, at a **higher alpha than the rail's** so the two slots
/// stay distinguishable on dark as well as light.
Color selectionFillList(ThemeData theme) => theme.brightness == Brightness.dark
    ? kSeedColor.withValues(alpha: 0.32)
    : kSelectionFillList;

/// The row-hover fill for [theme] — a neutral tint, inverted on dark so the
/// hover stays visible (a black tint vanishes on a dark pane).
Color hoverFill(ThemeData theme) =>
    theme.brightness == Brightness.dark ? const Color(0x1FFFFFFF) : kHoverFill;

/// The colour used to render each [MessageStatus].
///
/// Exhaustive by construction: adding a status to the enum is a compile error
/// here until it is given a colour. `pending` / `canceled` are neutral (inert);
/// `awaiting_confirm` / `transferring` are the two blues; `done` is green;
/// `failed` is red; `rejected` is amber so the two failure states stay distinct.
Color statusColor(MessageStatus status) => switch (status) {
      MessageStatus.pending => const Color(0xFF8A8A8E),
      MessageStatus.awaitingConfirm => kSeedColor,
      MessageStatus.transferring => const Color(0xFF1E88E5),
      MessageStatus.done => const Color(0xFF2E7D32),
      MessageStatus.failed => const Color(0xFFC62828),
      MessageStatus.canceled => const Color(0xFF9E9E9E),
      MessageStatus.rejected => const Color(0xFFEF6C00),
    };

// ── semantic colour slots (docs/18 §1) ───────────────────────────────────────
//
// One definition per **meaning**, so no widget has to inline a hex and a future
// theme only has to change this one file. The values are placeholders chosen by
// the user (docs/18 §1.3, "candidate B"). The shape follows the rest of the
// file: a value that never varies is a `const`, a value that depends on the
// theme is a function.

/// **Accent** — primary buttons / send, the selected state, the key action.
///
/// Placeholder = our own brand blue. ★ **Never Flix's orange** (`#FF9623` /
/// `#ED7A4E`) — the user ruled that out (docs/18 §1.2), and
/// `test/theme_slots_test.dart` asserts it so it cannot creep back in.
const Color accent = kSeedColor;

/// **Accent, soft** — the light fill behind chips and a selected row.
///
/// Deliberately an **alias** of the existing selection fill (docs/18 §1.1:
/// "不新增值，复用"): a second hand-written blue is exactly what §1 forbids.
Color accentSoft(ThemeData theme) => selectionFill(theme);

/// **Dangerous action** — destructive text/icon actions (clear history, delete).
const Color dangerAction = Color(0xFFC62828);

/// **Broken / damaged state** — a file that is gone or corrupt.
///
/// Lighter and more orange than [dangerAction]: Flix itself carries two, and
/// these two states must never read as one.
const Color dangerBroken = Color(0xFFD9603F);

/// **Network status = up** — this device's own connectivity / multicast.
///
/// docs/18 §1.3 candidate B keeps this in the blue family **and** keeps it a
/// separate slot from [accent]: the two are told apart by **position + icon +
/// copy**, never by colour. Reuses the palette's existing in-flight blue rather
/// than introducing a second hand-written one.
const Color statusNetwork = Color(0xFF1E88E5);

/// **Network status = down** — not connected, or discovery failed.
Color statusNetworkOff(ThemeData theme) => theme.colorScheme.outline;

/// **Device connected** — a peer row's "grey → colour" (docs/18 §5).
///
/// The same green the `done` status uses, so "it is working" reads consistently.
const Color statusDeviceOn = Color(0xFF2E7D32);

/// **Device offline** — the current grey, so a peer row stays subdued.
Color statusDeviceOff(ThemeData theme) => theme.colorScheme.onSurfaceVariant;

// ── white-card slots (docs/18 §2.1) ──────────────────────────────────────────
//
// The **phone** home list draws each device as a card — air *between* cards,
// the 1px line only *inside* one — instead of full-bleed rows. Only the narrow
// (`carded`) branch reads these; the wide / compact rendering keeps the exact
// widget tree it had, so the wide-screen baseline (docs/18 §7.1) still holds
// line for line.
//
// The card's corner radius is **not** a new slot: it reuses [kRadiusCard] (12,
// above), which already means "cards and message bubbles".

/// The light card fill (docs/18 §2.1: Flix's card is `#FFFFFF`).
const Color kCardSurface = Color(0xFFFFFFFF);

/// The card fill for [theme].
///
/// ★ The dark branch is **not optional** (docs/18 §8.2): a pure-white card over
/// the dark list surface glares. The light branch returns [kCardSurface]
/// verbatim, so light rendering is untouched — the same const + function shape
/// the rest of this file uses ([kSurfaceList] / [surfaceList]).
Color cardSurface(ThemeData theme) => theme.brightness == Brightness.dark
    ? const Color(0xFF2A2B2F)
    : kCardSurface;

/// The vertical gap **between** two phone cards (docs/18 §2.1: Flix ≈9dp
/// 【量到·±3dp】). The card list gets its separation from this air, never from
/// an inter-row 1px line.
const double kCardGap = 9;

/// A phone card's height (docs/18 §2.1: Flix ≈67dp 【量到·±3dp】).
///
/// **67, not the 56 a wide row uses.** The user asked to copy Flix's "七条一屏"
/// without compromise, and 67 + [kCardGap] is the arithmetic behind it. The cost
/// (§2.1 records it): a screen drops from ≈10–11 rows to ≈7 cards. The
/// acceptance criterion is nevertheless a **lower bound** (≥6 complete cards,
/// docs/18 §7.2) so a future status line can take a slot without a fight.
const double kCardHeight = 67;

/// The horizontal page inset of a phone card (docs/18 §2.1: Flix's page inset
/// ≈15dp 【量到】) — the margin between the pane edge and the card, not the
/// padding inside it.
const double kListRowPadding = 15;

/// The ring behind a device row's leading icon (docs/18 §5.2).
///
/// **Connected** → a tint of [statusDeviceOn] (the "灰→彩" the user asked for),
/// derived from that slot rather than hand-written — the same idiom as
/// [kSelectionFill]. **Not connected** → today's neutral
/// `colorScheme.surfaceContainerHighest`, so an offline row is byte-identical to
/// what it was before this change.
Color deviceRingFill(ThemeData theme, {required bool online}) => online
    ? statusDeviceOn.withValues(alpha: 0.14)
    : theme.colorScheme.surfaceContainerHighest;

/// The corner radius of a rail's **selected-item capsule** (desktop, Feishu
/// alignment — comparison-table row 1).
///
/// ★ **Derived by ratio, not chosen** (docs/18d §5). The reference's radius is a
/// **band of 8–10 image px**; 8–10 ÷ the inferred scale 1.13 ≈ 7.1–8.8, so **8
/// falls inside the band**. No alpha or guesswork: the band is the measurement,
/// 8 is where it lands. (The 1.13 scale is itself **inferred** — it rests on
/// "ink ≈ 0.88 × font size" and on our pane width matching Feishu's proportion.)
///
/// Kept on the record (both are retractions, and both still matter):
/// (1) I once wrote that the reference image was "1080px wide" — it is
/// **1767×1068**; 1080 is Flix's *phone* batch, a source mix-up;
/// (2) an earlier "±2px" error bar came from eyeballing a **downscaled** view,
/// so it was never an error bar at all. The capsule's own radius could **not**
/// be isolated from the pixels (the rail's glyph pixels dominate any colour
/// threshold I tried) — which is why the band, not a point, is what we use.
///
/// Measuring the real pixels: the window's top strip ends at y≈39 (40px), so if
/// that strip is the standard 32 logical px the DPR is ~1.25 and the radius a
/// DPR-corrected eyeball would give is nearer **6**. The capsule's own radius
/// could **not** be isolated from the image (the rail's glyph pixels dominate
/// any colour threshold I tried).
///
/// **Why the band beats the 6** — and this is the part to keep straight:
/// the band 8–10 comes from **two mutually independent readings** (two different
/// predicates, on two different blocks), whereas the 6 was a **single isolated
/// estimate** — and at that time the capsule's own corner could not even be
/// isolated (see above). Two independent readings outrank one isolated one, so
/// **we take the band**, and 8 is where it lands. (8 also happens to be M3's
/// "small" step — a coincidence, not the reason.)
///
/// **The 6 is kept, not deleted**: it sits just below the band's lower edge
/// (7.1), and hiding a dissenting reading is how the next person loses the
/// ability to re-judge this.
const double kRadiusNavItem = 8;

/// How far a rail's selected-item capsule is **inset** from the rail's edges
/// (comparison-table row 1: Feishu's selected item does not run the full width).
///
/// The **inset itself is structural** (readable from the reference without a
/// ruler). **The amount 8 is derived by ratio, from two independent paths that
/// both land on 8** (docs/18d §5):
///  · middle-pane row block: 9 image px inset ÷ 360 content width = 2.50%,
///    applied to our 320-wide pane ⟹ **8.0**;
///  · rail capsule:          12 image px inset ÷ 252 rail width  = 4.76%,
///    applied to our 168-wide rail ⟹ **8.0**.
///
/// ★ The ratios are **inferred** (same 1.13-scale premise as [kRadiusNavItem]).
/// ★ One choice stays on the record: the rail's *absolute* value would be
/// 12 ÷ 1.13 ≈ 10.6 — we took the **proportional** 8 instead. Left visible so
/// nobody later reads 12 beside 8 and concludes someone mis-computed.
const double kNavItemInset = 8;

/// The vertical gap that separates **sections** — a rail's identity / modules /
/// receive toggle, and a pane's module header from its body — now that they are
/// divided by **air instead of a 1px line** (Feishu alignment, comparison-table
/// row 3; Feishu almost never uses rules).
///
/// **16 because it sits inside _both_ candidate readings** of the reference's
/// section gap: the measured ≈16-24 image px gives ≈13-19 logical at DPR 1.25
/// and 16-24 at DPR 1.0 — 16 is the one value true under either, so the
/// still-unsettled DPR cannot make this choice wrong.
const double kSectionGap = 16;

/// The fill behind a search field (Feishu alignment, comparison-table row 7:
/// controls are **filled, not outlined**).
///
/// The value is the **lead's pixel scan** of the reference (`rgb(213,222,232)`),
/// not mine — I did not re-derive it. Note the phone's search box follows Flix
/// instead and is filled with [cardSurface]; the two references differ, so the
/// two ends differ on purpose.
const Color kSearchFill = Color(0xFFD5DEE8);

// ── reserved slot names, deliberately left without values (docs/18 §1.2) ─────
//
// `typeIconImage` / `typeIconOther` (per-file-type colours) are **not** defined
// this round, and that is a decision rather than an omission: there is no
// "file-type colour" mechanism to add a value to — `type_icon.dart` draws the
// glyph and the *caller* supplies the colour, and nothing in the repo picks a
// colour by file type. Introducing one would mean building a new mechanism, not
// choosing a colour. The names are recorded here so that decision stays visible
// at the one place colours live. See docs/18 §1.2 and §8.2.
