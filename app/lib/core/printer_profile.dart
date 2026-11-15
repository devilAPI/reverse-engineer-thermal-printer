/// How a printer model accepts a print-density (heat) setting.
enum DensityCommand {
  /// Not supported / unknown: send nothing.
  none,

  /// `ESC 7 n1 n2 n3` — max heating dots, heating time, interval
  /// (Adafruit/CSN-A2 and some Zijiang firmwares; NOT in the MPT-II manual).
  esc7,

  /// `DC2 # n` — bits 0-4 density, bits 5-7 break time (some Chinese firmwares).
  dc2Hash,

  /// `GS E n` — "head control method", dot-line time 0.8 ms + n*0.1 ms,
  /// n = 0..15. The only darkness control in the MPT-II Programming Manual.
  gsE,
}

/// Static description of a supported printer model.
///
/// Values come from the vendor manuals (see docs/RESEARCH.md). Transfer tuning
/// (band height, chunk size, delay) is conservative until verified on hardware.
class PrinterProfile {
  const PrinterProfile({
    required this.id,
    required this.name,
    required this.paperWidthMm,
    required this.dotsPerLine,
    required this.hasCutter,
    this.bandHeight = 255,
    this.chunkSize = 4096,
    this.chunkDelay = Duration.zero,
    this.density = DensityCommand.esc7,
    this.usbIds = const [],
  });

  final String id;
  final String name;
  final int paperWidthMm;

  /// Printable width in dots at 203 dpi (8 dots/mm).
  final int dotsPerLine;
  final bool hasCutter;

  /// Lines per `GS v 0` command. Small bands keep each command under the
  /// printer's bitmap buffer limit (MP583: 40 KB per bitmap).
  final int bandHeight;

  /// Bytes per transport write, and pause between writes. Cheap printers
  /// without flow control drop data if flooded.
  final int chunkSize;
  final Duration chunkDelay;

  final DensityCommand density;

  /// Known USB vendor/product IDs (hex pairs) for auto-detection.
  final List<(int, int)> usbIds;

  int get bytesPerLine => (dotsPerLine + 7) ~/ 8;

  static const mp583 = PrinterProfile(
    id: 'mp583',
    name: 'MP583 / MPT-II (58 mm mobile)',
    paperWidthMm: 58,
    dotsPerLine: 384,
    hasCutter: false,
    bandHeight: 128, // 48 B * 128 = 6 KB per command, well under 40 KB
    chunkSize: 512,
    chunkDelay: Duration(milliseconds: 20),
    density: DensityCommand.gsE,
  );

  static const hz8360 = PrinterProfile(
    id: 'hz8360',
    name: 'HZ-8360 (80 mm desktop)',
    paperWidthMm: 80,
    dotsPerLine: 576,
    hasCutter: true,
    bandHeight: 255,
    chunkSize: 4096,
    // measured 2026-11-15: STM32 "POS80 Printer USB", printer class 07/01/02
    usbIds: [(0x0416, 0x5011)],
  );

  static const generic58 = PrinterProfile(
    id: 'generic58',
    name: 'Generic 58 mm ESC/POS',
    paperWidthMm: 58,
    dotsPerLine: 384,
    hasCutter: false,
    bandHeight: 64,
    chunkSize: 512,
    chunkDelay: Duration(milliseconds: 20),
    density: DensityCommand.none,
  );

  static const generic80 = PrinterProfile(
    id: 'generic80',
    name: 'Generic 80 mm ESC/POS',
    paperWidthMm: 80,
    dotsPerLine: 576,
    hasCutter: true,
    bandHeight: 128,
    chunkSize: 2048,
    density: DensityCommand.none,
  );

  static const all = [mp583, hz8360, generic58, generic80];

  /// Best guess for a discovered connection, or null if nothing matches.
  /// MPT-II firmware advertises Bluetooth names like "MPT-II" / "BL".
  static PrinterProfile? guess({String? label, int? vid, int? pid}) {
    for (final p in all) {
      if (vid != null && p.usbIds.contains((vid, pid))) return p;
    }
    final l = (label ?? '').toLowerCase();
    if (RegExp(r'mpt|mp58|pt-?2\d\d|58mm|pos58|pos-58').hasMatch(l)) return mp583;
    if (RegExp(r'8360|80mm|pos80|pos-80').hasMatch(l)) return hz8360;
    return null;
  }

  static PrinterProfile byId(String? id) => all.firstWhere((p) => p.id == id, orElse: () => mp583);

  /// USB IDs listed in the vendor's Android SDK (cn.com.zj.usbdemo).
  static const vendorSdkUsbIds = <(int, int)>[
    (0x1CBE, 0x0003),
    (0x1CB0, 0x0003),
    (0x0483, 0x5740),
    (0x0483, 0x5741),
    (0x0493, 0x8760),
    (0x0416, 0x5011),
    (0x0416, 0xAABB),
    (0x1659, 0x8965),
  ];
}
