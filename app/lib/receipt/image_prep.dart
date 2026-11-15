import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../core/image_pipeline.dart';

/// Largest width kept for an image block (2× the widest printer, so the
/// printed result still benefits from downsampling).
const maxStoredImageWidth = 1152;

/// Make picked image bytes suitable for storing inside a receipt (JSON):
/// apply EXIF rotation and shrink big photos. Small images are kept as-is.
/// Throws [FormatException] for undecodable data. Pure; run via `compute`.
Uint8List prepareImageBytes(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('Unsupported image format');
  final rotated = decoded.exif.imageIfd.orientation != null && decoded.exif.imageIfd.orientation != 1;
  if (!rotated && decoded.width <= maxStoredImageWidth && bytes.length <= 512 * 1024) return bytes;
  var im = decodePhoto(bytes);
  if (im.width > maxStoredImageWidth) {
    im = img.copyResize(im, width: maxStoredImageWidth, interpolation: img.Interpolation.cubic);
  }
  final png = im.hasAlpha || img.findFormatForData(bytes) == img.ImageFormat.png;
  return png ? img.encodePng(im) : img.encodeJpg(im, quality: 90);
}
