/// Static description of a supported printer model.
///
/// Values come from the vendor manuals (see repo /docs). Transfer tuning
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

  /// Known USB vendor/product IDs (hex pairs) for auto-detection.
  final List<(int, int)> usbIds;

  int get bytesPerLine => (dotsPerLine + 7) ~/ 8;

  static const mp583 = PrinterProfile(
    id: 'mp583',
    name: 'MP583 (58 mm mobile)',
    paperWidthMm: 58,
    dotsPerLine: 384,
    hasCutter: false,
    bandHeight: 128, // 48 B * 128 = 6 KB per command, well under 40 KB
    chunkSize: 512,
    chunkDelay: Duration(milliseconds: 20),
  );

  static const hz8360 = PrinterProfile(
    id: 'hz8360',
    name: 'HZ-8360 (80 mm desktop)',
    paperWidthMm: 80,
    dotsPerLine: 576,
    hasCutter: true,
    bandHeight: 255,
    chunkSize: 4096,
  );

  static const all = [mp583, hz8360];

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
