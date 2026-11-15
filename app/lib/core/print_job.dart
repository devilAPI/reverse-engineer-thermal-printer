import 'dart:typed_data';

import 'escpos.dart';
import 'mono_bitmap.dart';
import 'printer_profile.dart';

/// ESC/POS bytes for printing [bmp] on [profile], centered, with trailing feed
/// (and cut on printers that have a cutter).
Uint8List buildPhotoJob(MonoBitmap bmp, PrinterProfile profile, {int feedLines = 4}) {
  final b = EscPosBuilder()
    ..init()
    ..align(1)
    ..raster(bmp, bandHeight: profile.bandHeight)
    ..align(0);
  if (profile.hasCutter) {
    b.cut(feed: 0x30); // GS V B 48: feed to cutter then cut
  } else {
    b.feedLines(feedLines);
  }
  return b.build();
}
