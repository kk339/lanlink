/// Reads the few facts a test can check about a **PNG file on disk**: its pixel
/// size, whether its corners are transparent, and how much of it is painted.
///
/// Why hand-rolled instead of an image package: these are the assertions that
/// catch a **wrongly generated asset** (a plate baked into a mark that must be
/// transparent, an icon that is not the size its name promises), and pulling a
/// decoding dependency into the app for four numbers is not a trade worth
/// making. `dart:io`'s `zlib` plus the PNG filter rules is the whole story for
/// 8-bit non-interlaced images — which is what an asset pipeline produces.
///
/// Supported: colour type 6 (RGBA) at bit depth 8, non-interlaced. Anything else
/// fails loudly rather than silently skipping a check.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// A decoded 8-bit RGBA PNG, reduced to what geometry / transparency tests need.
class PngProbe {
  PngProbe._(this.width, this.height, this._alpha);

  /// Pixel width.
  final int width;

  /// Pixel height.
  final int height;

  /// Alpha of every pixel, row-major (`width * height` entries).
  final Uint8List _alpha;

  /// The image size in logical px (a PNG has no DPI, so 1 px = 1 unit).
  double get widthPx => width.toDouble();

  /// The image size in logical px (see [widthPx]).
  double get heightPx => height.toDouble();

  /// Reads and decodes [file] (a real file on disk, not a bundled asset).
  static PngProbe read(File file) {
    final Uint8List bytes = file.readAsBytesSync();
    expect(
      bytes.sublist(0, 8),
      <int>[137, 80, 78, 71, 13, 10, 26, 10],
      reason: '${file.path} must be a PNG',
    );

    // IHDR is always the first chunk: 8 (signature) + 4 (length) + 4 (type).
    final int width = _u32(bytes, 16);
    final int height = _u32(bytes, 20);
    final int bitDepth = bytes[24];
    final int colorType = bytes[25];
    final int interlace = bytes[28];
    expect(bitDepth, 8, reason: '${file.path}: 8-bit channels only');
    // 2 = RGB (no alpha at all: every pixel is opaque), 6 = RGBA. The chrome-
    // rendered launcher icons come out as RGB while the transparent foreground
    // layers come out as RGBA, so both are legitimate inputs here.
    expect(colorType, anyOf(2, 6),
        reason: '${file.path}: RGB or RGBA only (colour type $colorType)');
    expect(interlace, 0, reason: '${file.path}: non-interlaced only');
    final int channels = colorType == 6 ? 4 : 3;

    // Every IDAT payload, concatenated, is one zlib stream.
    final BytesBuilder compressed = BytesBuilder(copy: false);
    int pos = 8;
    while (pos < bytes.length) {
      final int length = _u32(bytes, pos);
      final String kind = String.fromCharCodes(bytes.sublist(pos + 4, pos + 8));
      if (kind == 'IDAT') {
        compressed.add(bytes.sublist(pos + 8, pos + 8 + length));
      } else if (kind == 'IEND') {
        break;
      }
      pos += 12 + length;
    }
    final List<int> raw = zlib.decode(compressed.takeBytes());

    // Undo the per-scanline filters (PNG spec §9): each row starts with the
    // filter type, and Sub/Up/Average/Paeth refer to the already-decoded
    // previous row.
    final int bpp = channels;
    final int stride = width * bpp;
    final Uint8List alpha = Uint8List(width * height);
    Uint8List previous = Uint8List(stride);
    int cursor = 0;
    for (int y = 0; y < height; y++) {
      final int filter = raw[cursor];
      final Uint8List line = Uint8List.fromList(
        raw.sublist(cursor + 1, cursor + 1 + stride),
      );
      cursor += 1 + stride;
      for (int i = 0; i < stride; i++) {
        final int left = i >= bpp ? line[i - bpp] : 0;
        final int up = previous[i];
        final int upLeft = i >= bpp ? previous[i - bpp] : 0;
        switch (filter) {
          case 0:
            break;
          case 1:
            line[i] = (line[i] + left) & 0xFF;
          case 2:
            line[i] = (line[i] + up) & 0xFF;
          case 3:
            line[i] = (line[i] + ((left + up) >> 1)) & 0xFF;
          case 4:
            final int p = left + up - upLeft;
            final int pa = (p - left).abs();
            final int pb = (p - up).abs();
            final int pc = (p - upLeft).abs();
            final int predictor =
                (pa <= pb && pa <= pc) ? left : (pb <= pc ? up : upLeft);
            line[i] = (line[i] + predictor) & 0xFF;
          default:
            fail('${file.path}: unknown PNG filter $filter on row $y');
        }
      }
      for (int x = 0; x < width; x++) {
        // RGB has no alpha channel at all: every pixel is opaque, which is the
        // truth for a full-bleed launcher icon.
        alpha[y * width + x] =
            channels == 4 ? line[x * bpp + 3] : 255;
      }
      previous = line;
    }
    return PngProbe._(width, height, alpha);
  }

  /// The alpha of one pixel.
  int alphaAt(int x, int y) => _alpha[y * width + x];

  /// The four corner alphas, in the order top-left, top-right, bottom-left,
  /// bottom-right.
  List<int> get cornerAlphas => <int>[
        alphaAt(0, 0),
        alphaAt(width - 1, 0),
        alphaAt(0, height - 1),
        alphaAt(width - 1, height - 1),
      ];

  /// The share of pixels that are clearly painted (alpha >= 128), 0..1.
  ///
  /// A mark on a transparent canvas is a minority of the pixels; a mark with a
  /// **plate** baked in is ~all of them. That is exactly the difference a
  /// "transparent background" requirement is about.
  double get opaqueFraction {
    int painted = 0;
    for (final int value in _alpha) {
      if (value >= 128) {
        painted++;
      }
    }
    return painted / (width * height);
  }

  /// The ink bounding box (any pixel with alpha > 0), as
  /// `(left, top, right, bottom)`.
  List<int> get inkBounds => inkFit.bounds;

  /// Where the ink sits on the canvas — computed in a single pass, because the
  /// launcher-icon tests need both halves of it and a second walk over a 432×432
  /// image for no reason is just slow.
  InkFit get inkFit {
    final double cx = (width - 1) / 2.0;
    final double cy = (height - 1) / 2.0;
    int left = width;
    int top = height;
    int right = -1;
    int bottom = -1;
    double maxRadius = 0;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        if (alphaAt(x, y) == 0) {
          continue;
        }
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
        final double dx = x - cx;
        final double dy = y - cy;
        final double radius = math.sqrt(dx * dx + dy * dy);
        if (radius > maxRadius) {
          maxRadius = radius;
        }
      }
    }
    return InkFit(
      bounds: <int>[left, top, right, bottom],
      canvasWidth: width.toDouble(),
      // The bbox centre, measured from the canvas centre. A perfectly centred
      // odd-sized image gives exactly 0; an even one can only be off by 0.5.
      dx: (left + right) / 2.0 - cx,
      dy: (top + bottom) / 2.0 - cy,
      maxRadius: maxRadius,
    );
  }

  static int _u32(Uint8List bytes, int offset) =>
      ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.big);
}

/// The geometry of "where is the ink" in one image.
class InkFit {
  /// Creates the summary (only [PngProbe.inkFit] does).
  const InkFit({
    required this.bounds,
    required this.canvasWidth,
    required this.dx,
    required this.dy,
    required this.maxRadius,
  });

  /// `(left, top, right, bottom)` of every painted pixel.
  final List<int> bounds;

  /// The canvas width in px (the diameter is always compared against this).
  final double canvasWidth;

  /// How far the ink bbox's centre sits from the canvas centre, per axis.
  final double dx;
  final double dy;

  /// The farthest painted pixel's distance from the canvas centre.
  final double maxRadius;

  /// `2r / width` — for an Android adaptive icon this must stay inside the
  /// 66/108 safe circle, i.e. **≤ 0.611**.
  double get diameterRatio => 2 * maxRadius / canvasWidth;
}
