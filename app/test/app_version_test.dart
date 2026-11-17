// Drift guard (M5 §F): the code constant `kAppVersion` must equal
// `pubspec.yaml`'s `version:` — a forgotten bump becomes a **red test**, not a
// stale string nobody notices. This is the whole reason the version is a single
// constant plus this guard, instead of a runtime plugin read.
//
// A native-only test: it reads `pubspec.yaml` from disk and imports `dart:io`,
// both fine under `flutter test` on the VM.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/app_info.dart';

void main() {
  test('kAppVersion matches pubspec.yaml version (drift guard)', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final RegExpMatch? match =
        RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml must declare a version:');
    // Strip any `+build` suffix: `kAppVersion` is the version part only.
    final String declared = match!.group(1)!.split('+').first;
    // Non-empty is a hard requirement (the version is shown in the UI; it must
    // never render blank) — enforced here, not with a UI fallback branch.
    expect(kAppVersion, isNotEmpty, reason: 'the version must never be blank');
    expect(
      kAppVersion,
      declared,
      reason: 'kAppVersion ("$kAppVersion") drifted from pubspec.yaml '
          '("$declared") — update lib/app_info.dart to match.',
    );
  });
}
