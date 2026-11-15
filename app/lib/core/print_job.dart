import 'dart:typed_data';

import 'escpos.dart';
import 'mono_bitmap.dart';
import 'printer_profile.dart';

/// Per-job options independent of image processing.
class JobOptions {
  const JobOptions({this.darkness, this.feedLines = 4, this.cut = true, this.copies = 1});

  /// Print darkness 0..1, translated to the profile's density command;
  /// null = leave the printer's default.
  final double? darkness;
  final int feedLines;

  /// Only honoured on printers with a cutter.
  final bool cut;
  final int copies;

  JobOptions copyWith({double? darkness, bool clearDarkness = false, int? feedLines, bool? cut, int? copies}) =>
      JobOptions(
        darkness: clearDarkness ? null : (darkness ?? this.darkness),
        feedLines: feedLines ?? this.feedLines,
        cut: cut ?? this.cut,
        copies: copies ?? this.copies,
      );
}

/// ESC/POS bytes for printing [bmp] on [profile]: init, density, centered
/// raster bands, then feed or feed+cut, repeated for each copy.
Uint8List buildPhotoJob(MonoBitmap bmp, PrinterProfile profile, [JobOptions opts = const JobOptions()]) {
  final b = EscPosBuilder()..init();
  if (opts.darkness != null) b.raw(densityBytes(profile.density, opts.darkness!));
  for (var c = 0; c < opts.copies.clamp(1, 99); c++) {
    b
      ..align(1)
      ..raster(bmp, bandHeight: profile.bandHeight)
      ..align(0);
    if (profile.hasCutter && opts.cut) {
      b.cut(feed: 0x30); // GS V B 48: feed to cutter then partial cut
    } else {
      b.feedLines(opts.feedLines);
    }
  }
  return b.build();
}

/// Bytes that set print darkness [d] (0 = lightest, 1 = darkest).
List<int> densityBytes(DensityCommand cmd, double d) {
  d = d.clamp(0.0, 1.0);
  return switch (cmd) {
    DensityCommand.none => const [],
    // heating time 40..200 (factory ≈80), 7 = max heating dots (8*(7+1)), interval 2
    DensityCommand.esc7 => [0x1B, 0x37, 7, (40 + d * 160).round(), 2],
    DensityCommand.dc2Hash => [0x12, 0x23, (d * 31).round() & 0x1F],
    DensityCommand.gsE => [0x1D, 0x45, (d * 15).round()],
  };
}
