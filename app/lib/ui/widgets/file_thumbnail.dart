/// The file thumbnail: an image decoded from bytes fetched through
/// `PlatformPorts.readFileBytes` (PRD §5, design §5).
///
/// **Why a module-level, path-keyed LRU lives here (spec §5.1 — a correctness
/// requirement, not an optimisation):** `Image.memory`'s cache key is the
/// *decoded bytes object*, not the file path. Two reads of the same path yield
/// two distinct `Uint8List` instances, so Flutter's image cache never hits and
/// the file would be re-read from disk on every rebuild (scroll, pane switch).
/// This widget therefore caches the **bytes by path**, bounded to
/// [_kCacheCapacity] entries, and the negative result too.
///
/// It only ever reads when the file is an **image** with a non-empty path and is
/// not [unavailable]; every other case renders a plain [TypeIcon] and never
/// touches the port (PRD §8-G28/G30). A port call that *throws* (the Web stub's
/// `UnsupportedError`) is treated exactly like `null` — fall back to the icon,
/// never a broken-image or a surfaced error (PRD §8-G29 / design §11-R9).
///
/// The same "never surface an error" rule covers bytes that are read fine but
/// turn out **not to be a decodable image**: the [Image.memory] is given an
/// [ImageErrorWidgetBuilder] that renders a plain [_errorBox], so the widget
/// keeps its `edge × edge` contract for **every** input instead of letting
/// Flutter's red debug error widget (a full-width, one-line `Stack`) take over
/// the slot (PRD §8-G31).
///
/// Layering (spec §8.1 / §9.6): `ui/**` imports only `package:flutter/**` and
/// this package's `domain/**`; the bytes come **only** from the port, so this
/// file never imports `dart:io`.
library;

import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../domain/platform_ports.dart';
import '../../domain/selectors.dart';
import '../scope.dart';
import '../theme.dart';
import 'type_icon.dart';

/// The maximum number of bytes read for a single thumbnail (8 MiB, spec §9.2).
///
/// Passed as `readFileBytes`'s `maxBytes`: a larger file must return `null`
/// (never a truncated prefix), so the widget falls back to the type icon.
const int kThumbnailMaxBytes = 8 * 1024 * 1024;

/// The maximum number of cached thumbnail entries (spec §5.3).
const int _kCacheCapacity = 96;

/// Process-wide, insertion-ordered cache of thumbnail bytes, keyed by path.
///
/// A value of `null` is a **negative cache** entry (the read failed or the file
/// exceeded [kThumbnailMaxBytes]); it is cached too so a bad file is not re-read
/// on every rebuild. Insertion order is the LRU order (a hit re-inserts at the
/// tail; eviction drops the head).
final LinkedHashMap<String, Uint8List?> _thumbCache =
    LinkedHashMap<String, Uint8List?>();

bool _cacheHas(String path) => _thumbCache.containsKey(path);

/// Reads [path] and marks it most-recently-used. Call only when [_cacheHas].
Uint8List? _cacheGet(String path) {
  final Uint8List? value = _thumbCache.remove(path);
  _thumbCache[path] = value;
  return value;
}

/// Inserts [bytes] (possibly `null` — a negative entry) and evicts the oldest
/// entries beyond [_kCacheCapacity].
void _cachePut(String path, Uint8List? bytes) {
  _thumbCache.remove(path);
  _thumbCache[path] = bytes;
  while (_thumbCache.length > _kCacheCapacity) {
    _thumbCache.remove(_thumbCache.keys.first);
  }
}

/// Empties the thumbnail byte cache (test / preview only).
@visibleForTesting
void clearThumbnailCache() => _thumbCache.clear();

/// A rounded image **or video-cover** thumbnail decoded from bytes read via the
/// port.
///
/// Two shapes, selected by [preserveAspect]:
/// * **square** (default) — a fixed [edge] × [edge] box with [BoxFit.cover],
///   used by the middle-pane / conversation-file **list rows** (fixed row
///   height; design §6.2). The decode keeps the source ratio (a single
///   `cacheWidth`) so `cover` genuinely **crops** the overflow instead of the
///   image being squashed into a square at decode time.
/// * **aspect** ([preserveAspect] `true`) — bounded by [edge] × [edge] but
///   keeping the image's own ratio, used by a message bubble's **single image**
///   and the file-detail preview (PRD §5): a wide screenshot stays wide instead
///   of being squashed.
///
/// A **video** gets a cover on **both Windows and Android** (M5 §C; the desktop
/// leg is docs/19 §9.5): its frame comes from
/// `PlatformPorts.readVideoThumbnail` (one scaled frame, never the whole
/// video), and a ▶ badge always marks it as playable. When the frame cannot be
/// extracted — an unsupported container, no shell thumbnail provider, Web — it
/// falls back to the plain type icon. See [_shouldLoad] for why this is decided
/// by **capability** rather than by platform.
class FileThumbnail extends StatefulWidget {
  /// Creates a thumbnail.
  ///
  /// [edge] is the box cap: the square side length, or the max width/height in
  /// aspect mode. A `null` / empty [path], [unavailable] `true`, or a
  /// non-image/video [fileName] all skip the read and render a [TypeIcon].
  const FileThumbnail({
    super.key,
    required this.fileName,
    this.mime,
    this.path,
    this.unavailable = false,
    required this.edge,
    this.radius = kRadiusThumb,
    this.preserveAspect = false,
    this.onTap,
  });

  /// File name — the extension-classification fallback.
  final String fileName;

  /// MIME type, or `null` to classify by [fileName].
  final String? mime;

  /// Source path to read bytes from, or `null` to never read.
  final String? path;

  /// Whether the source file is gone — skips the read entirely.
  final bool unavailable;

  /// Square side length in logical pixels (also the decode dimensions).
  final double edge;

  /// Corner radius.
  final double radius;

  /// Whether to keep the image's aspect ratio (bounded by [edge] × [edge])
  /// instead of sizing to a fixed square.
  ///
  /// `false` (list rows) renders a fixed [edge] × [edge] square — the design
  /// keeps every list row a constant height. `true` (a message bubble's single
  /// image) lets the box take the image's own ratio so a wide screenshot is not
  /// distorted (PRD §5).
  final bool preserveAspect;

  /// Called when the thumbnail is tapped (mobile: open the file), or `null`
  /// (not tappable — the desktop default, unchanged).
  final VoidCallback? onTap;

  @override
  State<FileThumbnail> createState() => _FileThumbnailState();
}

class _FileThumbnailState extends State<FileThumbnail> {
  Uint8List? _bytes;
  bool _loading = false;
  String? _resolvedPath;

  /// Whether this file is a video (its cover is only extracted for videos).
  bool _isVideo = false;

  FileClass get _fileClass => classifyFile(widget.fileName, mime: widget.mime);

  /// Whether a thumbnail should be read at all.
  ///
  /// **Images** are always read. **Video** is now read wherever the port can
  /// actually produce a frame — Windows asks the shell thumbnail service
  /// (docs/19 §9.5), Android uses MediaMetadataRetriever.
  ///
  /// The old rule was `video && mobile`, i.e. it encoded a **capability** as a
  /// **platform** assumption. That aged badly: a bubble's video card is 240px, so
  /// with the read suppressed the desktop could only ever draw a blown-up type
  /// icon — a large empty block. A port that cannot answer returns `null` and the
  /// icon comes back exactly as before, so nothing is promised that is not there.
  bool _shouldLoad() {
    if (widget.unavailable || !(widget.path?.isNotEmpty ?? false)) {
      return false;
    }
    final FileClass cls = _fileClass;
    return cls == FileClass.image || cls == FileClass.video;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Resolve here (not initState): `context.deps` depends on `AppScope`.
    _sync();
  }

  @override
  void didUpdateWidget(covariant FileThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.mime != widget.mime ||
        oldWidget.fileName != widget.fileName ||
        oldWidget.unavailable != widget.unavailable) {
      _sync();
    }
  }

  /// Resolves the widget into one of: fallback (no read), a cached result, or a
  /// fresh load. Only ever mutates state (no `setState`), since it is called
  /// from `didChangeDependencies` / `didUpdateWidget`, both followed by a build.
  void _sync() {
    _isVideo = _fileClass == FileClass.video;
    if (!_shouldLoad()) {
      _loading = false;
      _bytes = null;
      _resolvedPath = null;
      return;
    }
    final String path = widget.path!;
    if (_resolvedPath == path) {
      return; // already resolved or in flight for this path — never re-read
    }
    if (_cacheHas(path)) {
      _bytes = _cacheGet(path);
      _loading = false;
      _resolvedPath = path;
      return;
    }
    _loading = true;
    _bytes = null;
    _resolvedPath = path;
    _load(path, video: _isVideo);
  }

  Future<void> _load(String path, {required bool video}) async {
    final PlatformPorts platform = context.deps.platform;
    Uint8List? result;
    try {
      // Video → one extracted frame; image → the file's bytes. Both are capped,
      // and a failure is `null` (the type-icon fallback), never a surfaced error.
      result = video
          ? await platform.readVideoThumbnail(path,
              maxBytes: kThumbnailMaxBytes)
          : await platform.readFileBytes(path, maxBytes: kThumbnailMaxBytes);
    } on Object {
      result = null; // a throwing stub (Web) is treated like a failed read
    }
    _cachePut(path, result);
    if (!mounted || widget.path != path) {
      return;
    }
    setState(() {
      _bytes = result;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Widget content = _content();
    // A video always reads as a video (a ▶ over its cover, or over the icon
    // fallback) — and, when a tap is offered, becomes opener-tappable.
    final Widget thumb = _isVideo ? _playBadge(content) : content;
    final VoidCallback? onTap = widget.onTap;
    if (onTap == null) {
      return thumb;
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(widget.radius),
      child: thumb,
    );
  }

  Widget _content() {
    if (_shouldLoad()) {
      final Uint8List? bytes = _bytes;
      if (bytes != null) {
        return _image(bytes);
      }
      if (_loading) {
        return _loadingBox();
      }
    }
    return _fallback();
  }

  /// The smallest edge that can carry the ▶ badge.
  ///
  /// **64dp, and the number is deliberate:** below it the badge (36dp, fixed)
  /// covers most of the frame — that is the user's report ("挡住了看不清") on the
  /// **list** row, whose thumbnail is `kListIconDiameter` (40dp). 64 sits in the
  /// **gap** between the smallest real caller (40dp) and the next one (96dp, the
  /// bubble's grid), so **no caller is near the line** and a few dp of drift
  /// cannot flip any of them.
  static const double _playBadgeMinEdge = 64;

  /// A centred ▶ overlay marking a video (M5 §C/§D) — **only when there is room
  /// for it.** At the list size it is dropped rather than shrunk: a smaller badge
  /// on a 40dp frame is still an obscured frame, and the file name/size beside
  /// the row already say what it is.
  Widget _playBadge(Widget child) => widget.edge < _playBadgeMinEdge
      ? child
      : Stack(
          alignment: Alignment.center,
          children: <Widget>[
            child,
            const Icon(Icons.play_circle_fill, size: 36, color: Colors.white70),
          ],
        );

  Widget _image(Uint8List bytes) {
    final int decodeCap =
        (widget.edge * MediaQuery.devicePixelRatioOf(context)).round();
    if (widget.preserveAspect) {
      // Aspect mode (a bubble's single image / the file-detail preview, PRD §5):
      // the width must not be forced to the height. The decode keeps the ratio
      // by passing **only** `cacheWidth` — `dart:ui` maintains the intrinsic
      // aspect ratio when exactly one target dimension is given, whereas
      // `cacheWidth` + `cacheHeight` together stretch the image to *exactly*
      // that box (the distortion the square branch below deliberately avoids by
      // decoding on a single axis and letting `BoxFit.cover` crop). The box then
      // takes the image's own ratio — RenderImage does this when width/height
      // are null — clamped to `edge × edge` (`FileThumbnail.edge` is the cap).
      return ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: widget.edge, maxHeight: widget.edge),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.radius),
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            cacheWidth: decodeCap,
            gaplessPlayback: true,
            errorBuilder:
                (BuildContext context, Object error, StackTrace? stackTrace) =>
                    _errorBox(),
          ),
        ),
      );
    }
    // Square branch (list rows, the multi-image grid — design §6.2): the box is
    // a fixed square (`width`/`height`), but the **decode** must not be forced
    // square. A single `cacheWidth` lets `dart:ui` keep the source ratio; the
    // engine scales that ratio to fit the square box, and `BoxFit.cover` then
    // shows the centre and crops the overflow — a true square thumbnail. Giving
    // **both** `cacheWidth` and `cacheHeight` would instead stretch the image
    // into a square at decode time, turning `cover` into the identity and
    // leaving the thumbnail *squashed* rather than *cropped*.
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: Image.memory(
        bytes,
        width: widget.edge,
        height: widget.edge,
        fit: BoxFit.cover,
        cacheWidth: decodeCap,
        gaplessPlayback: true,
        // Undecodable bytes must not surface an error nor let Flutter's debug
        // error widget (a full-width `Stack`) expand the slot; keep the plain
        // `edge × edge` box so the contract holds for every input (G31).
        errorBuilder:
            (BuildContext context, Object error, StackTrace? stackTrace) =>
                _errorBox(),
      ),
    );
  }

  /// The decode-failure placeholder: a plain `edge × edge` rounded box, never a
  /// surfaced error and never Flutter's red debug error widget (G29 / R9).
  Widget _errorBox() => Container(
        width: widget.edge,
        height: widget.edge,
        decoration: BoxDecoration(
          color: surfaceRail(Theme.of(context)),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      );

  /// The loading placeholder: a gray rounded square with a centred type icon
  /// (never a spinning progress ball — spec §5.4).
  Widget _loadingBox() => Container(
        width: widget.edge,
        height: widget.edge,
        decoration: BoxDecoration(
          color: surfaceRail(Theme.of(context)),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
        alignment: Alignment.center,
        child: _icon(),
      );

  /// The fallback: just the type icon, centred in the slot (no box, no error).
  Widget _fallback() => SizedBox(
        width: widget.edge,
        height: widget.edge,
        child: Center(child: _icon()),
      );

  Widget _icon() => TypeIcon(
        fileName: widget.fileName,
        mime: widget.mime,
        size: widget.edge * 0.6,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );
}
