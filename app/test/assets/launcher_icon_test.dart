/// The **launcher icons themselves**, checked per density.
///
/// Why this file exists: before it, nothing under `test/` mentioned
/// `ic_launcher` or `mipmap` at all — the adaptive foreground's centring and its
/// 66/108 safe circle were verified **by a human measuring pixels once**, so any
/// later edit to the SVG transform would have shipped silently with the full
/// suite still green. These are file-level assertions, not widget ones: they read
/// the PNGs that actually go into the APK.
///
/// The geometry being pinned (Android's adaptive-icon contract):
/// * the **foreground** is a transparent 108dp canvas whose artwork may be
///   cropped by the launcher to a 66/108 circle — so the ink must be centred and
///   must fit inside that circle (diameter ≤ 61% of the canvas; we sit at ~60%);
/// * the **legacy** `ic_launcher.png` is the pre-API-26 icon: a **full-bleed
///   square**, because the launcher applies its own mask. A rounded or padded
///   plate baked in here would be rounded twice and shrink the artwork.
///
/// `PngProbe` (test/support) decodes the alpha channel; it accepts both RGB
/// (chrome writes the opaque legacy icons as colour type 2) and RGBA.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/png_probe.dart';

/// Where the Android res folder lives, relative to the package root.
const String _res = 'android/app/src/main/res';

/// Each density bucket and the **exact** pixel size its two icons must be.
///
/// The sizes are the Android density scale (mdpi = 1x): 48dp legacy icon and a
/// 108dp adaptive foreground.
const Map<String, List<int>> _buckets = <String, List<int>>{
  // bucket: [legacy ic_launcher, adaptive foreground]
  'mdpi': <int>[48, 108],
  'hdpi': <int>[72, 162],
  'xhdpi': <int>[96, 216],
  'xxhdpi': <int>[144, 324],
  'xxxhdpi': <int>[192, 432],
};

/// The safe-circle limit, as a share of the canvas: Android may crop an adaptive
/// icon's foreground to a 66/108 circle = 61.1%; we assert against 61%.
const double _maxDiameterRatio = 0.61;

void main() {
  // ── 1. the adaptive foreground: transparent, centred, inside the circle ──
  _buckets.forEach((String bucket, List<int> sizes) {
    final int expected = sizes[1];
    test(
        'adaptive foreground $bucket (${expected}px): transparent, centred, '
        'inside the 66/108 safe circle', () {
      final File file =
          File('$_res/mipmap-$bucket/ic_launcher_foreground.png');
      expect(file.existsSync(), isTrue,
          reason: 'mipmap-$bucket/ic_launcher_foreground.png is missing: there '
              'is no adaptive icon without it');

      final PngProbe png = PngProbe.read(file);
      final InkFit fit = png.inkFit;
      // Every failure below names the bucket and the measured value: "one of the
      // five is wrong" is not an actionable message.
      // ignore: avoid_print
      print('LAUNCHERICON fg $bucket ${png.width}x${png.height} '
          'bbox=${fit.bounds} d=(${fit.dx.toStringAsFixed(2)},'
          '${fit.dy.toStringAsFixed(2)}) '
          'maxR=${fit.maxRadius.toStringAsFixed(2)} '
          'ratio=${(100 * fit.diameterRatio).toStringAsFixed(2)}% '
          'corners=${png.cornerAlphas}');

      // (a) the bucket holds the size it promises — catches a file pasted into
      //     the wrong density folder, which Android would silently rescale.
      expect(<int>[png.width, png.height], <int>[expected, expected],
          reason: 'mipmap-$bucket/ic_launcher_foreground.png is '
              '${png.width}x${png.height}, must be ${expected}x$expected');

      // (b) transparent background: the plate lives in the *background* layer,
      //     so a foreground with opaque corners would paint a white square over
      //     the whole icon on a launcher that crops to a circle.
      expect(png.cornerAlphas, <int>[0, 0, 0, 0],
          reason: 'mipmap-$bucket/ic_launcher_foreground.png has opaque corners '
              '(${png.cornerAlphas}) — the foreground must be transparent');

      // (c) centred: |bbox centre - canvas centre| ≤ 1px per axis. Exactly what
      //     the 0.2.9 build got wrong (it centred on the triangle's centroid,
      //     which is 40 units — 7.6% of the canvas — above the ink's centre).
      expect(fit.dx.abs(), lessThanOrEqualTo(1.0),
          reason: 'mipmap-$bucket: ink is ${fit.dx.toStringAsFixed(2)}px off '
              'centre horizontally (limit 1px)');
      expect(fit.dy.abs(), lessThanOrEqualTo(1.0),
          reason: 'mipmap-$bucket: ink is ${fit.dy.toStringAsFixed(2)}px off '
              'centre vertically (limit 1px) — this is the defect 0.2.10 fixed '
              '(the mark used to sit 7.6% high)');

      // (d) inside the safe circle, or the apex gets clipped by a round mask.
      expect(fit.diameterRatio, lessThanOrEqualTo(_maxDiameterRatio),
          reason: 'mipmap-$bucket: ink spans '
              '${(100 * fit.diameterRatio).toStringAsFixed(2)}% of the canvas, '
              'which is outside the 66/108 safe circle (limit 61%)');
    });
  });

  // ── 2. the legacy icon: a full-bleed square with opaque corners ──────────
  _buckets.forEach((String bucket, List<int> sizes) {
    final int expected = sizes[0];
    test(
        'legacy ic_launcher $bucket (${expected}px): full-bleed square, '
        'opaque corners (no pre-baked rounded plate)', () {
      final File file = File('$_res/mipmap-$bucket/ic_launcher.png');
      expect(file.existsSync(), isTrue,
          reason: 'mipmap-$bucket/ic_launcher.png is missing: API < 26 has no '
              'adaptive icon to fall back on');

      final PngProbe png = PngProbe.read(file);
      final InkFit fit = png.inkFit;
      // ignore: avoid_print
      print('LAUNCHERICON legacy $bucket ${png.width}x${png.height} '
          'corners=${png.cornerAlphas} bbox=${fit.bounds} '
          'opaque=${(100 * png.opaqueFraction).toStringAsFixed(1)}%');

      expect(<int>[png.width, png.height], <int>[expected, expected],
          reason: 'mipmap-$bucket/ic_launcher.png is '
              '${png.width}x${png.height}, must be ${expected}x$expected');

      // Android 8+ applies its own mask to a legacy icon. A PNG whose corners
      // are already rounded (or transparent) gets rounded **twice** and the
      // artwork shrinks inside it — the exact regression the 0.2.9 re-render
      // was written to avoid.
      expect(png.cornerAlphas, everyElement(255),
          reason: 'mipmap-$bucket/ic_launcher.png has non-opaque corners '
              '(${png.cornerAlphas}) — the plate must be a full-bleed square; '
              'the launcher owns the mask');

      // …and full-bleed means edge to edge: a padded plate would leave a ring.
      expect(fit.bounds,
          <int>[0, 0, png.width - 1, png.height - 1],
          reason: 'mipmap-$bucket/ic_launcher.png leaves a margin inside the '
              'canvas (ink bbox ${fit.bounds} on a ${png.width}x${png.height} '
              'canvas) — the legacy plate must reach every edge');
    });
  });

  // ── 3. the wiring: without this XML the foreground PNGs are dead weight ──
  test('the adaptive icon is wired: mipmap-anydpi-v26/ic_launcher.xml names a '
      'background and the foreground layer', () {
    final File xml = File('$_res/mipmap-anydpi-v26/ic_launcher.xml');
    expect(xml.existsSync(), isTrue,
        reason: 'without mipmap-anydpi-v26/ic_launcher.xml Android never uses '
            'an adaptive icon — the five ic_launcher_foreground.png files would '
            'be shipped and ignored');
    final String text = xml.readAsStringSync();
    expect(text, contains('<adaptive-icon'));
    expect(text, contains('@drawable/ic_launcher_background'),
        reason: 'the plate must come from the background layer');
    expect(text, contains('@mipmap/ic_launcher_foreground'),
        reason: 'the artwork must come from the per-density foreground layers');

    final File plate = File('$_res/drawable/ic_launcher_background.xml');
    expect(plate.existsSync(), isTrue,
        reason: '@drawable/ic_launcher_background is referenced but missing');
  });
}
