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
