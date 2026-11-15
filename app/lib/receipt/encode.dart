import 'dart:typed_data';

import '../core/escpos.dart';
import '../core/mono_bitmap.dart';
import '../core/print_job.dart';
import '../core/printer_profile.dart';

/// A receipt rasterised at a printer's dot width: one bitmap per paper piece
/// between Cut blocks. Pure data, produced by `ReceiptRenderer`.
class RenderedReceipt {
  RenderedReceipt({required this.width, required this.segments, this.endsWithCut = false, this.warnings = const []});

  final int width;

  /// Printable content between cuts, top to bottom. Never contains empty
  /// bitmaps: leading, trailing and repeated cuts are collapsed.
  final List<MonoBitmap> segments;

  /// The last block was a Cut: the job ends with a cut even when the
  /// "cut after printing" job option is off.
  final bool endsWithCut;

  /// Problems found while rendering (invalid barcode data, QR too long...).
  final List<String> warnings;

  int get height => segments.fold(0, (h, s) => h + s.height);
  int get bytes => segments.fold(0, (n, s) => n + s.data.length);
}

/// ESC/POS bytes for printing [copies] (one rendering per copy, so running
/// numbers can differ) on [profile].
///
/// Per copy: every segment is sent as `GS v 0` bands; between segments the
/// paper is cut (`GS V B 48`) on cutter printers or fed for tearing off
/// otherwise; after the last segment the [opts] decide cut vs. feed, exactly
/// like the photo job.
Uint8List buildReceiptJob(List<RenderedReceipt> copies, PrinterProfile profile, [JobOptions opts = const JobOptions()]) {
  final b = EscPosBuilder()..init();
  if (opts.darkness != null) b.raw(densityBytes(profile.density, opts.darkness!));
  b.align(0);
  void separate() => profile.hasCutter ? b.cut(feed: 0x30) : b.feedLines(opts.feedLines);

  for (final r in copies) {
    assert(r.width <= profile.dotsPerLine, 'rendered for a wider printer');
    for (var i = 0; i < r.segments.length; i++) {
      b.raster(r.segments[i], bandHeight: profile.bandHeight);
      if (i < r.segments.length - 1) separate();
    }
    if (profile.hasCutter && (opts.cut || r.endsWithCut)) {
      b.cut(feed: 0x30);
    } else {
      b.feedLines(opts.feedLines);
    }
  }
  return b.build();
}
