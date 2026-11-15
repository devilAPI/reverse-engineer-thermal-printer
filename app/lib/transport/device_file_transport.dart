import 'dart:io';
import 'dart:typed_data';

import 'transport.dart';

/// Writes straight to a kernel device node — no driver install needed:
///  * Linux:  /dev/usb/lp*  (usblp, USB printer class)
///            /dev/ttyACM*  (cdc_acm, printers that enumerate as serial)
///            /dev/rfcomm*  (Bluetooth SPP bound with `rfcomm bind`)
///  * macOS:  /dev/cu.usbmodem*, /dev/cu.* (BT name) (CDC / paired SPP)
///
/// Linux needs write permission: add user to `lp`/`dialout` or install the
/// udev rule from /linux/70-thermal-printer.rules.
class DeviceFileTransport implements PrinterTransport {
  @override
  String get name => 'device';

  @override
  bool get isSupported => Platform.isLinux || Platform.isMacOS;

  @override
  Future<List<PrinterEndpoint>> discover() async {
    final found = <PrinterEndpoint>[];
    if (Platform.isLinux) {
      await _glob(Directory('/dev/usb'), RegExp(r'^lp\d+$'), found, 'USB printer');
      await _glob(Directory('/dev'), RegExp(r'^(ttyACM\d+|rfcomm\d+)$'), found, 'Serial');
    } else if (Platform.isMacOS) {
      await _glob(Directory('/dev'), RegExp(r'^cu\.(?!Bluetooth-Incoming-Port).+$'), found, 'Serial');
    }
    return found;
  }

  Future<void> _glob(Directory dir, RegExp re, List<PrinterEndpoint> out, String kind) async {
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      final base = e.path.split('/').last;
      if (re.hasMatch(base)) {
        out.add(PrinterEndpoint(transport: name, id: e.path, label: '$kind ${e.path}'));
      }
    }
  }

  @override
  Future<PrinterConnection> open(PrinterEndpoint endpoint) async {
    final raf = await File(endpoint.id).open(mode: FileMode.writeOnlyAppend);
    return _FileConnection(raf);
  }
}

class _FileConnection implements PrinterConnection {
  _FileConnection(this._raf);
  final RandomAccessFile _raf;

  @override
  Future<void> write(Uint8List data) async {
    await _raf.writeFrom(data);
    await _raf.flush();
  }

  @override
  Future<void> close() => _raf.close();
}
