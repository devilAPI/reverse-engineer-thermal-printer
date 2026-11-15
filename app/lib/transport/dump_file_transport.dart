import 'dart:io';
import 'dart:typed_data';

import 'transport.dart';

/// Debug transport: writes the print job to the file named by the
/// THERMAL_PHOTO_DUMP environment variable. Lets the whole pipeline be tested
/// without hardware; render the result with tools/escpos_render.py.
class DumpFileTransport implements PrinterTransport {
  static final String? path = Platform.environment['THERMAL_PHOTO_DUMP'];

  @override
  String get name => 'dump';

  @override
  bool get isSupported => path != null && path!.isNotEmpty;

  @override
  Future<List<PrinterEndpoint>> discover() async =>
      [PrinterEndpoint(transport: name, id: path!, label: 'Debug: save job to $path')];

  @override
  Future<PrinterConnection> open(PrinterEndpoint endpoint) async =>
      _DumpConnection(await File(endpoint.id).open(mode: FileMode.write));
}

class _DumpConnection implements PrinterConnection {
  _DumpConnection(this._f);
  final RandomAccessFile _f;

  @override
  Future<void> write(Uint8List data) => _f.writeFrom(data);

  @override
  Future<void> close() => _f.close();
}
