import 'dart:typed_data';

/// ESC/POS real-time status queries (DLE EOT n). Replies are one byte with
/// fixed bits 0x12 pattern (bit1=1, bit4=1, bit0=0, bit7=0).
class StatusQuery {
  static final printer = Uint8List.fromList([0x10, 0x04, 1]);
  static final offline = Uint8List.fromList([0x10, 0x04, 2]);
  static final error = Uint8List.fromList([0x10, 0x04, 3]);
  static final paper = Uint8List.fromList([0x10, 0x04, 4]);
}

class PrinterStatus {
  const PrinterStatus({
    this.online,
    this.coverOpen,
    this.paperOut,
    this.paperNearEnd,
    this.cutterError,
    this.unrecoverableError,
    this.feedButtonPressed,
  });

  final bool? online;
  final bool? coverOpen;
  final bool? paperOut;
  final bool? paperNearEnd;
  final bool? cutterError;
  final bool? unrecoverableError;
  final bool? feedButtonPressed;

  bool get hasProblem =>
      coverOpen == true || paperOut == true || cutterError == true || unrecoverableError == true || online == false;

  static bool _valid(int b) => (b & 0x93) == 0x12;

  /// Merge the replies to DLE EOT 1..4 (any may be null when not answered).
  factory PrinterStatus.fromReplies({int? printer, int? offline, int? error, int? paper}) {
    bool? bit(int? b, int n) => (b == null || !_valid(b)) ? null : (b & (1 << n)) != 0;
    return PrinterStatus(
      online: printer == null || !_valid(printer) ? null : !bit(printer, 3)!,
      coverOpen: bit(offline, 2),
      feedButtonPressed: bit(offline, 3),
      paperOut: _paperOut(offline, paper),
      paperNearEnd: paper == null || !_valid(paper) ? null : (paper & 0x0C) == 0x0C,
      cutterError: bit(error, 3),
      unrecoverableError: bit(error, 5),
    );
  }

  /// DLE EOT 2 bit5 = stopped by paper end; DLE EOT 4 bits5+6 = paper end sensor.
  static bool? _paperOut(int? offline, int? paper) {
    final a = offline != null && _valid(offline) ? (offline & 0x20) != 0 : null;
    final b = paper != null && _valid(paper) ? (paper & 0x60) == 0x60 : null;
    if (a == null && b == null) return null;
    return (a ?? false) || (b ?? false);
  }

  @override
  String toString() {
    final parts = <String>[
      if (online == false) 'offline',
      if (coverOpen == true) 'cover open',
      if (paperOut == true) 'paper out',
      if (paperNearEnd == true) 'paper low',
      if (cutterError == true) 'cutter error',
      if (unrecoverableError == true) 'fatal error',
    ];
    if (parts.isEmpty) return online == null && paperOut == null ? 'status unknown' : 'ready';
    return parts.join(', ');
  }
}

/// Send DLE EOT 1..4 and decode. [write]/[read] come from the connection.
Future<PrinterStatus> queryStatus(
  Future<void> Function(Uint8List) write,
  Future<Uint8List> Function({Duration timeout}) read,
) async {
  Future<int?> ask(Uint8List q) async {
    await read(timeout: const Duration(milliseconds: 30)); // drain
    await write(q);
    final r = await read(timeout: const Duration(milliseconds: 400));
    return r.isEmpty ? null : r.last;
  }

  return PrinterStatus.fromReplies(
    printer: await ask(StatusQuery.printer),
    offline: await ask(StatusQuery.offline),
    error: await ask(StatusQuery.error),
    paper: await ask(StatusQuery.paper),
  );
}
