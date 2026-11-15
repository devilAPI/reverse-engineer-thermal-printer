import 'dart:typed_data';

import 'escpos.dart';
import 'image_pipeline.dart';
import 'mono_bitmap.dart';
import 'printer_profile.dart';

/// Calibration page: border box at the profile width, ruler ticks every
/// 8 dots, 16-step grey scale and a smooth gradient. Shows at a glance
/// whether width, alignment, band size and density are right.
Uint8List buildTestPage(PrinterProfile p) {
  final w = p.dotsPerLine;
  final b = EscPosBuilder()
    ..init()
    ..raw('Thermal Photo test page\n${p.name}\n$w dots, band ${p.bandHeight}\n'.codeUnits)
    ..raster(_ruler(w), bandHeight: p.bandHeight)
    ..raster(_steps(w), bandHeight: p.bandHeight)
    ..raster(_gradient(w), bandHeight: p.bandHeight);
  if (p.hasCutter) {
    b.cut(feed: 0x30);
  } else {
    b.feedLines(4);
  }
  return b.build();
}

MonoBitmap _ruler(int w) {
  const h = 48;
  final m = MonoBitmap(w, h);
  for (var x = 0; x < w; x += 8) {
    final len = x % 64 == 0 ? 32 : (x % 32 == 0 ? 20 : 10);
    for (var y = 0; y < len; y++) {
      m.setPixel(x, y, true);
    }
  }
  for (var x = 0; x < w; x++) {
    m.setPixel(x, 0, true);
    m.setPixel(x, h - 1, true);
  }
  for (var y = 0; y < h; y++) {
    m.setPixel(0, y, true);
    m.setPixel(w - 1, y, true);
  }
  return m;
}

MonoBitmap _steps(int w) {
  const h = 40;
  final lum = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      lum[y * w + x] = (x * 16 ~/ w) * 17.0;
    }
  }
  return ditherLuminance(lum, w, h, DitherMode.floydSteinberg);
}

MonoBitmap _gradient(int w) {
  const h = 40;
  final lum = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      lum[y * w + x] = 255.0 * x / (w - 1);
    }
  }
  return ditherLuminance(lum, w, h, DitherMode.atkinson);
}
