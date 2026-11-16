import 'dart:typed_data';

/// A discovered printer endpoint, transport-agnostic.
class PrinterEndpoint {
  const PrinterEndpoint({
    required this.transport,
    required this.id,
    required this.label,
    this.usbVendorId,
    this.usbProductId,
  });

  /// Which [PrinterTransport] can open this endpoint.
  final String transport;

  /// Transport-specific address: device path, host:port, BLE id, ...
  final String id;
  final String label;
  final int? usbVendorId;
  final int? usbProductId;

  /// Identity is (transport, id): rescans create new objects for the same device.
  @override
  bool operator ==(Object other) => other is PrinterEndpoint && other.transport == transport && other.id == id;

  @override
  int get hashCode => Object.hash(transport, id);

  @override
  String toString() => '$label [$transport:$id]';
}

/// An open, writable byte pipe to a printer.
abstract class PrinterConnection {
  Future<void> write(Uint8List data);
  Future<void> close();
}

/// A way of reaching printers (USB, TCP, BLE, ...).
abstract class PrinterTransport {
  String get name;

  /// Whether this transport works on the current platform.
  bool get isSupported;

  Future<List<PrinterEndpoint>> discover();

  Future<PrinterConnection> open(PrinterEndpoint endpoint);
}

/// Send [job] in [chunkSize] pieces with [delay] between them, reporting progress 0..1.
Future<void> sendChunked(
  PrinterConnection conn,
  Uint8List job, {
  required int chunkSize,
  Duration delay = Duration.zero,
  void Function(double progress)? onProgress,
}) async {
  for (var off = 0; off < job.length; off += chunkSize) {
    final end = (off + chunkSize < job.length) ? off + chunkSize : job.length;
    await conn.write(Uint8List.sublistView(job, off, end));
    onProgress?.call(end / job.length);
    if (delay > Duration.zero && end < job.length) await Future<void>.delayed(delay);
  }
}

/// Optional capability: connections that can read bytes back from the printer
/// (status replies to DLE EOT / GS r / GS I). BLE notify, libusb bulk-IN, serial.
abstract class PrinterStatusReader {
  Future<Uint8List> read({Duration timeout = const Duration(milliseconds: 500)});
}

/// Optional capability: transports that must ask the user to pick a device
/// (browser device choosers: Web Serial, WebUSB, Web Bluetooth). [pair] must
/// be called directly from a click handler — browsers require a user gesture.
abstract class PairableTransport {
  /// Button text, e.g. "Add Bluetooth / serial printer".
  String get pairLabel;

  /// One line shown next to the button (where it works, what to pick).
  String get pairHint;

  /// Opens the chooser; returns the picked printer, or null if cancelled.
  Future<PrinterEndpoint?> pair();
}

/// Optional capability: connections that forward a whole job to another
/// program which does chunking and the status query itself (the web
/// bridge). Returns that program's result message.
abstract class WholeJobConnection {
  Future<String> sendJob(Uint8List job, String what);
  Future<String> status();
}
