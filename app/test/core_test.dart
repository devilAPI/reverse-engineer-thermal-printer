import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:thermal_photo/core/escpos.dart';
import 'package:thermal_photo/core/image_pipeline.dart';
import 'package:thermal_photo/core/mono_bitmap.dart';
import 'package:thermal_photo/core/print_job.dart';
import 'package:thermal_photo/core/printer_profile.dart';

void main() {
  group('MonoBitmap', () {
    test('packs MSB-first, black = 1', () {
      final b = MonoBitmap(10, 1)
        ..setPixel(0, 0, true)
        ..setPixel(9, 0, true);
      expect(b.bytesPerLine, 2);
      expect(b.data, [0x80, 0x40]);
      expect(b.getPixel(9, 0), isTrue);
      expect(b.getPixel(1, 0), isFalse);
    });
  });

  group('EscPosBuilder.raster', () {
    test('splits into GS v 0 bands with correct headers', () {
      final bmp = MonoBitmap(384, 300);
      bmp.data.fillRange(0, bmp.data.length, 0xAA);
      final out = EscPosBuilder().raster(bmp, bandHeight: 255).build();

      // band 1: 255 rows
      expect(out.sublist(0, 8), [0x1D, 0x76, 0x30, 0x00, 48, 0, 255, 0]);
      final second = 8 + 48 * 255;
      expect(out.sublist(second, second + 8), [0x1D, 0x76, 0x30, 0x00, 48, 0, 45, 0]);
      expect(out.length, 8 * 2 + 48 * 300);
      expect(out[8], 0xAA);
    });
  });

  group('image pipeline', () {
    test('white image -> no dots, black image -> all dots', () {
      final white = img.Image(width: 100, height: 50)..clear(img.ColorRgb8(255, 255, 255));
      final black = img.Image(width: 100, height: 50)..clear(img.ColorRgb8(0, 0, 0));
      for (final mode in DitherMode.values) {
        final w = convertPhoto(white, 384, PrintSettings(dither: mode));
        final b = convertPhoto(black, 384, PrintSettings(dither: mode));
        expect(w.width, 384);
        expect(w.height, 192);
        expect(w.data.every((v) => v == 0), isTrue, reason: '$mode white');
        expect(b.data.every((v) => v == 0xFF), isTrue, reason: '$mode black');
      }
    });

    test('50% grey dithers to roughly half coverage', () {
      final lum = Float32List(64 * 64)..fillRange(0, 64 * 64, 127.5);
      final bmp = ditherLuminance(lum, 64, 64, DitherMode.floydSteinberg);
      var black = 0;
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          if (bmp.getPixel(x, y)) black++;
        }
      }
      expect(black / (64 * 64), closeTo(0.5, 0.05));
    });

    test('rotate90 swaps orientation', () {
      final land = img.Image(width: 200, height: 100);
      final bmp = convertPhoto(land, 384, const PrintSettings(rotate90: true));
      expect(bmp.height, 768);
    });
  });

  group('print job', () {
    test('cutter printer ends with GS V B, mobile ends with feed', () {
      final bmp = MonoBitmap(8, 1);
      final cut = buildPhotoJob(bmp, PrinterProfile.hz8360);
      expect(cut.sublist(0, 2), [0x1B, 0x40]);
      expect(cut.sublist(cut.length - 4), [0x1D, 0x56, 0x42, 0x30]);
      final feed = buildPhotoJob(bmp, PrinterProfile.mp583);
      expect(feed.sublist(feed.length - 3), [0x1B, 0x64, 4]);
    });
  });
}
