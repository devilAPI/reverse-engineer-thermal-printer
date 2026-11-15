import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'mono_bitmap.dart';

enum DitherMode { floydSteinberg, atkinson, ordered, threshold }

/// User-tunable conversion settings.
class PrintSettings {
  const PrintSettings({
    this.dither = DitherMode.floydSteinberg,
    this.brightness = 0.0,
    this.contrast = 1.0,
    this.gamma = 1.0,
    this.threshold = 128,
    this.invert = false,
    this.rotate90 = false,
  });

  final DitherMode dither;

  /// Added to luminance, -1..1.
  final double brightness;

  /// Multiplier around mid-grey, 0..3.
  final double contrast;

  /// >1 lightens midtones. Thermal paper tends to print dark, so ~1.2-1.6 helps.
  final double gamma;
  final int threshold;
  final bool invert;

  /// Rotate landscape photos to use the full roll length.
  final bool rotate90;

  PrintSettings copyWith({
    DitherMode? dither,
    double? brightness,
    double? contrast,
    double? gamma,
    int? threshold,
    bool? invert,
    bool? rotate90,
  }) =>
      PrintSettings(
        dither: dither ?? this.dither,
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        gamma: gamma ?? this.gamma,
        threshold: threshold ?? this.threshold,
        invert: invert ?? this.invert,
        rotate90: rotate90 ?? this.rotate90,
      );
}

/// Decode an encoded image (JPEG/PNG/WebP/...), apply EXIF orientation.
img.Image decodePhoto(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('Unsupported image format');
  return img.bakeOrientation(decoded);
}

/// Full pipeline: scale to [targetWidth] dots, tone-map, dither, pack.
MonoBitmap convertPhoto(img.Image src, int targetWidth, PrintSettings s) {
  var im = s.rotate90 ? img.copyRotate(src, angle: 90) : src;
  final h = math.max(1, (im.height * targetWidth / im.width).round());
  im = img.copyResize(im, width: targetWidth, height: h, interpolation: img.Interpolation.cubic);

  final lum = Float32List(targetWidth * h);
  var i = 0;
  for (final p in im) {
    // Composite alpha onto white paper.
    final a = p.aNormalized;
    var l = (0.299 * p.rNormalized + 0.587 * p.gNormalized + 0.114 * p.bNormalized) * a + (1 - a);
    l = (l - 0.5) * s.contrast + 0.5 + s.brightness;
    l = l.clamp(0.0, 1.0);
    if (s.gamma != 1.0) l = math.pow(l, 1 / s.gamma).toDouble();
    if (s.invert) l = 1 - l;
    lum[i++] = l * 255;
  }
  return ditherLuminance(lum, targetWidth, h, s.dither, s.threshold);
}

/// Dither a row-major 0..255 luminance buffer (0 = black) to a [MonoBitmap].
/// [lum] is modified in place for error-diffusion modes.
MonoBitmap ditherLuminance(Float32List lum, int w, int h, DitherMode mode, [int threshold = 128]) {
  final out = MonoBitmap(w, h);
  final t = threshold.toDouble();

  void spread(int x, int y, double err) {
    if (x < 0 || x >= w || y >= h) return;
    lum[y * w + x] += err;
  }

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final idx = y * w + x;
      final old = lum[idx];
      switch (mode) {
        case DitherMode.threshold:
          out.setPixel(x, y, old < t);
        case DitherMode.ordered:
          final m = _bayer8[(y & 7) * 8 + (x & 7)];
          out.setPixel(x, y, old < (m + 0.5) * 4); // 64 levels -> 0..256
        case DitherMode.floydSteinberg:
          final black = old < t;
          out.setPixel(x, y, black);
          final err = old - (black ? 0 : 255);
          spread(x + 1, y, err * 7 / 16);
          spread(x - 1, y + 1, err * 3 / 16);
          spread(x, y + 1, err * 5 / 16);
          spread(x + 1, y + 1, err * 1 / 16);
        case DitherMode.atkinson:
          final black = old < t;
          out.setPixel(x, y, black);
          final e = (old - (black ? 0 : 255)) / 8;
          spread(x + 1, y, e);
          spread(x + 2, y, e);
          spread(x - 1, y + 1, e);
          spread(x, y + 1, e);
          spread(x + 1, y + 1, e);
          spread(x, y + 2, e);
      }
    }
  }
  return out;
}

const _bayer8 = <int>[
  0, 32, 8, 40, 2, 34, 10, 42, //
  48, 16, 56, 24, 50, 18, 58, 26,
  12, 44, 4, 36, 14, 46, 6, 38,
  60, 28, 52, 20, 62, 30, 54, 22,
  3, 35, 11, 43, 1, 33, 9, 41,
  51, 19, 59, 27, 49, 17, 57, 25,
  15, 47, 7, 39, 13, 45, 5, 37,
  63, 31, 55, 23, 61, 29, 53, 21,
];
