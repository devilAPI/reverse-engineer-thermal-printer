import 'dart:typed_data';

import 'mono_bitmap.dart';

/// Minimal ESC/POS command builder: only what photo printing needs.
class EscPosBuilder {
  final BytesBuilder _b = BytesBuilder(copy: false);

  static const _esc = 0x1B;
  static const _gs = 0x1D;

  EscPosBuilder init() => _add([_esc, 0x40]);

  /// 0 = left, 1 = center, 2 = right.
  EscPosBuilder align(int a) => _add([_esc, 0x61, a.clamp(0, 2)]);

  /// Feed [lines] text lines (ESC d n).
  EscPosBuilder feedLines(int lines) => _add([_esc, 0x64, lines.clamp(0, 255)]);

  /// Feed [dots] dot rows (ESC J n).
  EscPosBuilder feedDots(int dots) => _add([_esc, 0x4A, dots.clamp(0, 255)]);

  /// Feed to cutter and partial cut (GS V B n), as the vendor SDK does.
  EscPosBuilder cut({int feed = 0}) => _add([_gs, 0x56, 0x42, feed.clamp(0, 255)]);

  /// Print [bmp] as a series of `GS v 0` raster bands of at most [bandHeight]
  /// rows each (manual limit: 4095 rows per command).
  EscPosBuilder raster(MonoBitmap bmp, {int bandHeight = 255}) {
    assert(bandHeight >= 1 && bandHeight <= 4095);
    final bpl = bmp.bytesPerLine;
    for (var y0 = 0; y0 < bmp.height; y0 += bandHeight) {
      final h = (bmp.height - y0 < bandHeight) ? bmp.height - y0 : bandHeight;
      _add([_gs, 0x76, 0x30, 0x00, bpl & 0xFF, bpl >> 8, h & 0xFF, h >> 8]);
      _b.add(Uint8List.sublistView(bmp.data, y0 * bpl, (y0 + h) * bpl));
    }
    return this;
  }

  EscPosBuilder raw(List<int> bytes) => _add(bytes);

  Uint8List build() => _b.toBytes();

  EscPosBuilder _add(List<int> bytes) {
    _b.add(bytes);
    return this;
  }
}
