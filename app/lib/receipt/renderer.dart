import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:barcode/barcode.dart' show BarcodeException;
import 'package:flutter/foundation.dart' show compute;

import '../core/image_pipeline.dart';
import '../core/mono_bitmap.dart';
import 'codes.dart';
import 'encode.dart';
import 'model.dart';
import 'tokens.dart';

/// Rasterises a [Receipt] to 1-bit bitmaps at the printer's dot width.
///
/// Text is laid out and drawn with `dart:ui` (Paragraph/Canvas) using the
/// bundled fonts, so any Unicode the fonts cover prints — the printer's own
/// code pages are never used. The canvas is read back and thresholded (no
/// dithering: text stays crisp). Image blocks are dithered with the photo
/// pipeline; QR codes, barcodes and separators are drawn straight into the
/// bitmap on whole dots. Cut blocks split the result into segments.
///
/// Must run on the UI isolate (dart:ui). Works on all platforms incl. web.
class ReceiptRenderer {
  /// Luminance below which an anti-aliased text pixel becomes a dot.
  /// A bit above mid-grey so thin strokes at small sizes survive.
  static const textThreshold = 160;

  /// Height of the canvas tiles read back from the GPU (texture size limit).
  static const _tile = 2048;

  final _imageCache = <String, MonoBitmap>{};

  Future<RenderedReceipt> render(Receipt r, {required int width, DateTime? now, int? number}) async {
    final ctx = TokenContext(now: now ?? DateTime.now(), number: number ?? r.counter);
    final warnings = <String>[];
    final segments = <List<_Piece>>[[]];
    for (final b in r.blocks) {
      if (b is CutBlock) {
        segments.add([]);
        continue;
      }
      segments.last.add(await _layout(b, width, ctx, warnings));
    }
    final bitmaps = <MonoBitmap>[];
    for (final seg in segments) {
      final h = seg.fold(0, (a, p) => a + p.height);
      if (h > 0) bitmaps.add(await _rasterize(seg, width, h));
    }
    return RenderedReceipt(
      width: width,
      segments: bitmaps,
      endsWithCut: r.blocks.isNotEmpty && r.blocks.last is CutBlock,
      warnings: warnings,
    );
  }

  // --------------------------------------------------------------- layout ---

  Future<_Piece> _layout(ReceiptBlock b, int w, TokenContext ctx, List<String> warnings) async {
    switch (b) {
      case TextBlock():
        return _text(expandTokens(b.text, ctx), b.format, b.align, b.invert, w);
      case ColumnsBlock():
        return _columns(b, w, ctx);
      case SeparatorBlock():
        final ink = separatorInk(b.style, b.thickness);
        final h = math.max(b.height, ink);
        final y0 = (h - ink) ~/ 2;
        return _Piece(h, blit: (m, y) => drawSeparator(m, b.style, y + y0, b.thickness));
      case FeedBlock():
        return _Piece((b.mm * 8).round());
      case CutBlock():
        return _Piece(0);
      case ImageBlock():
        return _image(b, w, warnings);
      case QrBlock():
        return _qr(b, w, ctx, warnings);
      case BarcodeBlock():
        return _barcode(b, w, ctx, warnings);
    }
  }

  static const _black = ui.Color(0xFF000000);
  static const _white = ui.Color(0xFFFFFFFF);

  static ui.Paragraph _paragraph(String text, TextFormat f, HAlign align, double maxWidth, {ui.Color color = _black}) {
    final weight = f.bold ? ui.FontWeight.w700 : ui.FontWeight.w400;
    final pb = ui.ParagraphBuilder(ui.ParagraphStyle(
      textAlign: switch (align) {
        HAlign.left => ui.TextAlign.left,
        HAlign.center => ui.TextAlign.center,
        HAlign.right => ui.TextAlign.right,
      },
      fontFamily: f.font.family,
      fontSize: f.size,
      fontWeight: weight,
    ))
      ..pushStyle(ui.TextStyle(
        color: color,
        fontFamily: f.font.family,
        fontSize: f.size,
        fontWeight: weight,
        decoration: f.underline ? ui.TextDecoration.underline : ui.TextDecoration.none,
        decorationColor: color,
        decorationThickness: 1.5,
      ))
      ..addText(text);
    return pb.build()..layout(ui.ParagraphConstraints(width: math.max(1, maxWidth)));
  }

  _Piece _text(String text, TextFormat f, HAlign align, bool invert, int w) {
    final pad = invert ? 6 : 0;
    final sx = f.scaleX.toDouble(), sy = f.scaleY.toDouble();
    final p = _paragraph(text, f, align, (w - 2 * pad) / sx, color: invert ? _white : _black);
    final h = (p.height * sy).ceil() + 2 * pad;
    return _Piece(h, paint: (c, y) {
      if (invert) c.drawRect(ui.Rect.fromLTWH(0, y, w.toDouble(), h.toDouble()), ui.Paint()..color = _black);
      c
        ..save()
        ..translate(pad.toDouble(), y + pad)
        ..scale(sx, sy)
        ..drawParagraph(p, ui.Offset.zero)
        ..restore();
    });
  }

  _Piece _columns(ColumnsBlock b, int w, TokenContext ctx) {
    const gap = 8;
    final f = b.format;
    final sx = f.scaleX.toDouble(), sy = f.scaleY.toDouble();
    final totalFlex = b.cells.fold(0, (a, c) => a + c.flex);
    final avail = w - gap * (b.cells.length - 1);
    final xs = <double>[], ws = <double>[], ps = <ui.Paragraph>[];
    var x = 0.0;
    for (final cell in b.cells) {
      final cw = avail * cell.flex / totalFlex;
      xs.add(x);
      ws.add(cw);
      ps.add(_paragraph(expandTokens(cell.text, ctx), f, cell.align, cw / sx));
      x += cw + gap;
    }
    final h = (ps.map((p) => p.height).reduce(math.max) * sy).ceil();

    // Dot leaders between neighbouring single-line cells.
    final leaders = <(double, double, double)>[]; // from x, to x, baseline y
    if (b.fill) {
      for (var i = 0; i < ps.length - 1; i++) {
        final a = ps[i], z = ps[i + 1];
        if (a.computeLineMetrics().length > 1 || z.computeLineMetrics().length > 1) continue;
        final aw = a.longestLine * sx, zw = z.longestLine * sx;
        final aEnd = xs[i] +
            switch (b.cells[i].align) {
              HAlign.left => aw,
              HAlign.center => (ws[i] + aw) / 2,
              HAlign.right => ws[i],
            };
        final zStart = xs[i + 1] +
            switch (b.cells[i + 1].align) {
              HAlign.left => 0,
              HAlign.center => (ws[i + 1] - zw) / 2,
              HAlign.right => ws[i + 1] - zw,
            };
        leaders.add((aEnd, zStart, a.alphabeticBaseline * sy));
      }
    }
    final d = math.max(2, (f.size * sy / 12).round()).toDouble();

    return _Piece(h, paint: (c, y) {
      for (var i = 0; i < ps.length; i++) {
        c
          ..save()
          ..translate(xs[i], y)
          ..scale(sx, sy)
          ..drawParagraph(ps[i], ui.Offset.zero)
          ..restore();
      }
      final paint = ui.Paint()..color = _black;
      for (final (from, to, base) in leaders) {
        final step = d * 3;
        // Snap dots to a global grid so leaders on consecutive rows line up.
        for (var dx = ((from + d * 2) / step).ceil() * step; dx + d <= to - d * 2; dx += step) {
          c.drawRect(ui.Rect.fromLTWH(dx.roundToDouble(), (y + base - d).roundToDouble(), d, d), paint);
        }
      }
    });
  }

  _Piece _error(String msg, int w, List<String> warnings) {
    warnings.add(msg);
    return _text('⚠ $msg', const TextFormat(size: 20), HAlign.center, false, w);
  }

  Future<_Piece> _image(ImageBlock b, int w, List<String> warnings) async {
    final bytes = b.bytes;
    if (bytes == null) {
      warnings.add('Image block without a picture');
      return _Piece(0);
    }
    final tw = (w * b.widthPercent / 100).round().clamp(8, w);
    final s = b.settings;
    final key = '${identityHashCode(bytes)}:${bytes.length}:$tw:${s.dither.name}:${s.brightness}:${s.contrast}:'
        '${s.gamma}:${s.threshold}:${s.invert}:${s.rotate90}';
    var bmp = _imageCache[key];
    if (bmp == null) {
      final MonoBitmap fresh;
      try {
        fresh = await compute(_convertImage, (bytes, tw, s));
      } on Object catch (e) {
        return _error('Image ${b.name}: $e', w, warnings);
      }
      if (_imageCache.length > 24) _imageCache.remove(_imageCache.keys.first);
      _imageCache[key] = bmp = fresh;
    }
    final pic = bmp;
    final x0 = alignOffset(b.align, w, pic.width);
    return _Piece(pic.height, blit: (m, y) => blit(m, pic, x0, y));
  }

  static MonoBitmap _convertImage((Uint8List, int, PrintSettings) a) => convertPhoto(decodePhoto(a.$1), a.$2, a.$3);

  _Piece _qr(QrBlock b, int w, TokenContext ctx, List<String> warnings) {
    final data = expandTokens(b.data, ctx);
    if (data.isEmpty) return _error('QR code without data', w, warnings);
    final List<List<bool>> mx;
    try {
      mx = qrMatrix(data, b.ecc);
    } on Object catch (e) {
      return _error('QR code: ${e is Exception ? e.toString().replaceFirst('Exception: ', '') : e}', w, warnings);
    }
    final n = mx.length;
    var ms = b.moduleSize;
    while (ms > 1 && n * ms > w) {
      ms--;
    }
    if (n * ms > w) return _error('QR code too large for the paper', w, warnings);
    const quiet = 2; // modules above and below; paper margins cover the sides
    final x0 = alignOffset(b.align, w, n * ms);
    return _Piece((n + 2 * quiet) * ms, blit: (m, y) {
      for (var r = 0; r < n; r++) {
        for (var c = 0; c < n; c++) {
          if (mx[r][c]) fillRect(m, x0 + c * ms, y + (r + quiet) * ms, ms, ms);
        }
      }
    });
  }

  _Piece _barcode(BarcodeBlock b, int w, TokenContext ctx, List<String> warnings) {
    final data = expandTokens(b.data, ctx);
    final List<bool> mods;
    try {
      mods = barcodeModules(b.symbology, data);
    } on BarcodeException catch (e) {
      return _error('${b.symbology.label}: ${e.message}', w, warnings);
    } on Object catch (e) {
      return _error('${b.symbology.label}: $e', w, warnings);
    }
    if (mods.isEmpty) return _error('${b.symbology.label}: no data', w, warnings);
    var mw = b.moduleWidth;
    while (mw > 1 && mods.length * mw > w) {
      mw--;
    }
    if (mods.length * mw > w) return _error('${b.symbology.label} too wide for the paper', w, warnings);
    final bw = mods.length * mw;
    final x0 = alignOffset(b.align, w, bw);
    const pad = 4;

    ui.Paragraph? label;
    var textX = 0.0;
    if (b.showText) {
      label = _paragraph(
        barcodeText(b.symbology, data),
        TextFormat(font: ReceiptFont.mono, size: (12 + mw * 5).clamp(16, 32).toDouble()),
        HAlign.left,
        w.toDouble(),
      );
      final lw = label.longestLine;
      textX = (x0 + bw / 2 - lw / 2).clamp(0, math.max(0, w - lw)).toDouble();
    }
    final textH = label == null ? 0 : label.height.ceil() + 2;
    return _Piece(
      pad + b.height + textH + pad,
      blit: (m, y) {
        var x = x0;
        for (final bar in mods) {
          if (bar) fillRect(m, x, y + pad, mw, b.height);
          x += mw;
        }
      },
      paint: label == null ? null : (c, y) => c.drawParagraph(label!, ui.Offset(textX, y + pad + b.height + 2)),
    );
  }

  // ------------------------------------------------------------ rasterise ---

  Future<MonoBitmap> _rasterize(List<_Piece> pieces, int w, int h) async {
    final m = MonoBitmap(w, h);
    final ys = <int>[];
    var y = 0;
    for (final p in pieces) {
      ys.add(y);
      y += p.height;
    }

    // Vector content, read back in tiles and thresholded.
    for (var t0 = 0; t0 < h; t0 += _tile) {
      final th = math.min(_tile, h - t0);
      final inTile = [
        for (var i = 0; i < pieces.length; i++)
          if (pieces[i].paint != null && ys[i] < t0 + th && ys[i] + pieces[i].height > t0) i,
      ];
      if (inTile.isEmpty) continue;
      final rec = ui.PictureRecorder();
      final c = ui.Canvas(rec, ui.Rect.fromLTWH(0, 0, w.toDouble(), th.toDouble()));
      c.drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), th.toDouble()), ui.Paint()..color = _white);
      c.translate(0, -t0.toDouble());
      for (final i in inTile) {
        pieces[i].paint!(c, ys[i].toDouble());
      }
      final pic = rec.endRecording();
      final image = await pic.toImage(w, th);
      pic.dispose();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (data == null) continue;
      final px = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      thresholdRgba(px, m, t0, textThreshold);
    }

    // Bitmap content (images, codes, rules) on exact dots.
    for (var i = 0; i < pieces.length; i++) {
      pieces[i].blit?.call(m, ys[i]);
    }
    return m;
  }
}

/// Threshold opaque RGBA rows into [m] starting at row [y0].
void thresholdRgba(Uint8List px, MonoBitmap m, int y0, int threshold) {
  final w = m.width;
  final rows = px.length ~/ (w * 4);
  final t3 = threshold * 3;
  for (var y = 0; y < rows && y0 + y < m.height; y++) {
    var o = y * w * 4;
    for (var x = 0; x < w; x++, o += 4) {
      if (px[o] + px[o + 1] + px[o + 2] < t3) m.setPixel(x, y0 + y, true);
    }
  }
}

/// A block laid out at full paper width: [height] rows, drawn by [paint]
/// (vector, thresholded) and/or [blit] (direct bitmap) at a row offset.
class _Piece {
  _Piece(this.height, {this.paint, this.blit});

  final int height;
  final void Function(ui.Canvas c, double y)? paint;
  final void Function(MonoBitmap m, int y)? blit;
}
