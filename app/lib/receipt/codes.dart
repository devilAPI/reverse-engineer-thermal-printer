import 'package:barcode/barcode.dart';
import 'package:qr/qr.dart';

import '../core/mono_bitmap.dart';
import 'model.dart';

/// QR / 1D barcode encoding into module patterns, and the small bitmap
/// helpers the receipt renderer uses. Pure Dart. Codes are drawn straight
/// into the [MonoBitmap] with integer module sizes, so they are pixel-exact
/// (no anti-aliasing, no scaling blur) and scan reliably.

/// QR module matrix (true = dark), without quiet zone.
List<List<bool>> qrMatrix(String data, QrEcc ecc) {
  final level = switch (ecc) {
    QrEcc.low => QrErrorCorrectLevel.L,
    QrEcc.medium => QrErrorCorrectLevel.M,
    QrEcc.quartile => QrErrorCorrectLevel.Q,
    QrEcc.high => QrErrorCorrectLevel.H,
  };
  final img = QrImage(QrCode.fromData(data: data, errorCorrectLevel: level));
  final n = img.moduleCount;
  return [
    for (var r = 0; r < n; r++) [for (var c = 0; c < n; c++) img.isDark(r, c)],
  ];
}

Barcode _barcodeFor(BarcodeSymbology s) => switch (s) {
      BarcodeSymbology.code128 => Barcode.code128(),
      BarcodeSymbology.ean13 => Barcode.ean13(),
      BarcodeSymbology.ean8 => Barcode.ean8(),
      BarcodeSymbology.upcA => Barcode.upcA(),
      BarcodeSymbology.code39 => Barcode.code39(),
    };

/// Bar pattern of a 1D barcode, one bool per module (true = bar), without
/// quiet zone. Throws [BarcodeException] (a [FormatException]-like error with
/// a readable message) for invalid data.
List<bool> barcodeModules(BarcodeSymbology s, String data) {
  final bc = _barcodeFor(s);
  bc.verify(data);
  // The package lays out runs of equal modules as bars (black and white,
  // contiguous) over the requested width. Every supported symbology has
  // 1-module runs, so the narrowest run gives the module width; rebuild the
  // integer module pattern from that so bars land on whole printer dots.
  const width = 100000.0;
  final bars = bc.make(data, width: width, height: 1).whereType<BarcodeBar>().toList();
  if (bars.isEmpty) return const [];
  final unit = bars.map((b) => b.width).reduce((a, b) => a < b ? a : b);
  return [
    for (final b in bars) ...List.filled((b.width / unit).round(), b.black),
  ];
}

/// Human-readable line printed under a barcode (adds EAN/UPC check digit).
String barcodeText(BarcodeSymbology s, String data) {
  final full = switch (s) {
    BarcodeSymbology.ean13 => 13,
    BarcodeSymbology.ean8 => 8,
    BarcodeSymbology.upcA => 12,
    _ => 0,
  };
  if (full > 0 && data.length == full - 1 && RegExp(r'^\d+$').hasMatch(data)) {
    return data + _mod10(data);
  }
  if (s == BarcodeSymbology.code39) return '*$data*';
  return data;
}

String _mod10(String digits) {
  var sum = 0;
  for (var i = 0; i < digits.length; i++) {
    final d = digits.codeUnitAt(digits.length - 1 - i) - 0x30;
    sum += i.isEven ? d * 3 : d;
  }
  return '${(10 - sum % 10) % 10}';
}

// ------------------------------------------------------------- bitmap ops ---

void fillRect(MonoBitmap m, int x0, int y0, int w, int h, [bool black = true]) {
  final x1 = (x0 + w).clamp(0, m.width);
  final y1 = (y0 + h).clamp(0, m.height);
  for (var y = y0.clamp(0, m.height); y < y1; y++) {
    for (var x = x0.clamp(0, m.width); x < x1; x++) {
      m.setPixel(x, y, black);
    }
  }
}

/// Copy [src] into [dst] at (dx, dy), clipped. Copies both black and white.
void blit(MonoBitmap dst, MonoBitmap src, int dx, int dy) {
  for (var y = 0; y < src.height; y++) {
    final ty = dy + y;
    if (ty < 0 || ty >= dst.height) continue;
    for (var x = 0; x < src.width; x++) {
      final tx = dx + x;
      if (tx < 0 || tx >= dst.width) continue;
      dst.setPixel(tx, ty, src.getPixel(x, y));
    }
  }
}

/// X offset for content of width [w] aligned within [total].
int alignOffset(HAlign a, int total, int w) => switch (a) {
      HAlign.left => 0,
      HAlign.center => ((total - w) / 2).floor().clamp(0, total),
      HAlign.right => (total - w).clamp(0, total),
    };

/// Draw a separator line of [style] across [m] at rows y..y+thickness.
/// [dash]/[gap] override the automatic dash (or dot) length and spacing.
void drawSeparator(MonoBitmap m, SeparatorStyle style, int y, int thickness, {int? dash, int? gap}) {
  final w = m.width;
  switch (style) {
    case SeparatorStyle.blank:
      return;
    case SeparatorStyle.solid:
      fillRect(m, 0, y, w, thickness);
    case SeparatorStyle.double:
      fillRect(m, 0, y, w, thickness);
      fillRect(m, 0, y + thickness * 2, w, thickness);
    case SeparatorStyle.dashed:
      final d = dash ?? 6 + thickness * 3, g = gap ?? 4 + thickness * 2;
      for (var x = 0; x < w; x += d + g) {
        fillRect(m, x, y, d, thickness);
      }
    case SeparatorStyle.dotted:
      final d = dash ?? thickness, g = gap ?? thickness * 2 + 1;
      for (var x = 0; x < w; x += d + g) {
        fillRect(m, x, y, d, thickness);
      }
  }
}

/// Rows a separator line occupies (thickness, or 3× for double).
int separatorInk(SeparatorStyle s, int thickness) => switch (s) {
      SeparatorStyle.blank => 0,
      SeparatorStyle.double => thickness * 3,
      _ => thickness,
    };
