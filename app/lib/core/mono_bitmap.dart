import 'dart:typed_data';

/// 1-bit packed bitmap, MSB = leftmost pixel, bit set = black (burned dot).
/// This is exactly the row format `GS v 0` expects.
class MonoBitmap {
  MonoBitmap(this.width, this.height)
      : bytesPerLine = (width + 7) ~/ 8,
        data = Uint8List(((width + 7) ~/ 8) * height);

  final int width;
  final int height;
  final int bytesPerLine;
  final Uint8List data;

  bool getPixel(int x, int y) =>
      (data[y * bytesPerLine + (x >> 3)] & (0x80 >> (x & 7))) != 0;

  void setPixel(int x, int y, bool black) {
    final i = y * bytesPerLine + (x >> 3);
    final m = 0x80 >> (x & 7);
    data[i] = black ? data[i] | m : data[i] & ~m;
  }
}
