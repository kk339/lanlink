import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/ui/theme.dart';

/// The semantic colour slots (docs/18 §1) — **one definition each**, so no
/// widget has to inline a hex, and the user's "don't copy Flix's orange" ruling
/// is something a test asserts rather than something we remember.
void main() {
  // Flix's two oranges: measured off the reference shots, and explicitly ruled
  // out by the user. §1.2 also says type colours are a *new mechanism*, not a
  // palette entry, so they are deliberately absent.
  const Color flixSendArrow = Color(0xFFFF9623);
  const Color flixFileIcon = Color(0xFFED7A4E);

  List<Color> allSlots(ThemeData theme) => <Color>[
        accent,
        accentSoft(theme),
        dangerAction,
        dangerBroken,
        statusNetwork,
        statusNetworkOff(theme),
        statusDeviceOn,
        statusDeviceOff(theme),
      ];

  test('every planned slot resolves (light and dark)', () {
    expect(allSlots(buildLightTheme()), hasLength(8));
    expect(allSlots(buildDarkTheme()), hasLength(8));
  });

  test('accent is our own brand blue, never Flix orange', () {
    expect(accent, kSeedColor);
    expect(accent, isNot(flixSendArrow));
    expect(accent, isNot(flixFileIcon));
  });

  test('accentSoft reuses the existing selection fill — no second value', () {
    // §1.1: "不新增值，复用" — so it must track the existing fill exactly, in
    // both themes, rather than being a new hand-written colour.
    expect(accentSoft(buildLightTheme()), kSelectionFill);
    expect(accentSoft(buildDarkTheme()), selectionFill(buildDarkTheme()));
  });

  test('the two danger slots are distinguishable', () {
    // Flix itself carries two reds/oranges; ours must not collapse into one.
    expect(dangerAction, isNot(dangerBroken));
  });

  test('accent and statusNetwork stay separate slots (candidate B)', () {
    // §1.3 B keeps both blue and distinguishes them by *position + icon + copy*,
    // never by colour — but they must still be two slots, not one alias.
    expect(statusNetwork, isNot(accent));
  });

  test('no slot is a Flix orange', () {
    for (final ThemeData theme in <ThemeData>[
      buildLightTheme(),
      buildDarkTheme(),
    ]) {
      final List<Color> slots = allSlots(theme);
      expect(slots, isNot(contains(flixSendArrow)));
      expect(slots, isNot(contains(flixFileIcon)));
    }
  });
}
