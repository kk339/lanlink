/// The single file-type icon widget (spec §2 `type_icon.dart`, §8.4).
///
/// Thumbnails are never generated (`thumbnail_path` is always NULL), so a file
/// is always represented by the icon `ui/format.dart::fileTypeIcon` resolves
/// from its mime (falling back to its extension). This widget adds no
/// classification logic of its own — it only draws that icon at a requested
/// size/colour, so there is exactly one place a file icon is rendered.
///
/// Layering (M4 §8.1): `ui/**` imports only `package:flutter/**` and this
/// package's `domain/**`; never `lanlink_core` / `lanlink_store` / `dart:io`.
library;

import 'package:flutter/material.dart';

import '../format.dart';

/// Renders the type icon for a file, resolved from mime then extension.
class TypeIcon extends StatelessWidget {
  /// Creates a type icon.
  ///
  /// [fileName] and [mime] drive the classification (mime first, extension as
  /// the fallback). [size] is the icon's logical size; [color] overrides the
  /// ambient [IconTheme] colour (e.g. a bubble's on-colour).
  const TypeIcon({
    super.key,
    required this.fileName,
    this.mime,
    this.size = 24,
    this.color,
  });

  /// File name on the wire — the extension-classification fallback.
  final String fileName;

  /// MIME type, or `null` to classify by [fileName] alone.
  final String? mime;

  /// Icon size in logical pixels.
  final double size;

  /// Icon colour override, or `null` to inherit the ambient [IconTheme].
  final Color? color;

  @override
  Widget build(BuildContext context) => Icon(
        fileTypeIcon(fileName, mime: mime),
        size: size,
        color: color,
      );
}
