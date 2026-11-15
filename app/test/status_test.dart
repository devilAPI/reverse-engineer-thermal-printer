import 'package:flutter_test/flutter_test.dart';
import 'package:thermal_photo/core/print_job.dart';
import 'package:thermal_photo/core/mono_bitmap.dart';
import 'package:thermal_photo/core/printer_profile.dart';
import 'package:thermal_photo/core/status.dart';
import 'package:thermal_photo/core/test_page.dart';

void main() {
  test('all-good replies decode as ready', () {
    final s = PrinterStatus.fromReplies(printer: 0x16, offline: 0x12, error: 0x12, paper: 0x12);
    expect(s.hasProblem, isFalse);
    expect(s.toString(), 'ready');
  });

  test('paper end + cover open', () {
    final s = PrinterStatus.fromReplies(printer: 0x16, offline: 0x12 | 0x04 | 0x20, error: 0x12, paper: 0x12 | 0x60);
    expect(s.paperOut, isTrue);
    expect(s.coverOpen, isTrue);
    expect(s.toString(), contains('paper out'));
  });

  test('no replies -> unknown, garbage ignored', () {
    expect(PrinterStatus.fromReplies().toString(), 'status unknown');
    expect(PrinterStatus.fromReplies(paper: 0xFF).paperOut, isNull);
  });

  test('density and copies', () {
    final bmp = MonoBitmap(8, 1);
    final j = buildPhotoJob(bmp, PrinterProfile.mp583, const JobOptions(darkness: 1, copies: 2));
    expect(j.sublist(0, 5), [0x1B, 0x40, 0x1D, 0x45, 15]); // MP583: GS E
    expect(RegExp('\x1dv0').allMatches(String.fromCharCodes(j)).length, 2);
    final none = buildPhotoJob(bmp, PrinterProfile.generic58, const JobOptions(darkness: 0.5));
    expect(none.sublist(0, 4), [0x1B, 0x40, 0x1B, 0x61]);
  });

  test('test page builds for every profile', () {
    for (final p in PrinterProfile.all) {
      expect(buildTestPage(p).length, greaterThan(p.bytesPerLine * 100));
    }
  });

  test('density byte mapping', () {
    expect(densityBytes(DensityCommand.esc7, 0.25), [0x1B, 0x37, 7, 80, 2]);
    expect(densityBytes(DensityCommand.dc2Hash, 1), [0x12, 0x23, 31]);
    expect(densityBytes(DensityCommand.gsE, 0), [0x1D, 0x45, 0]);
    expect(densityBytes(DensityCommand.none, 1), isEmpty);
  });
}
