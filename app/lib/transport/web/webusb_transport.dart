import 'dart:js_interop';
import 'dart:typed_data';

import '../../core/printer_profile.dart';
import '../transport.dart';
import 'js_api.dart';

/// WebUSB (Chromium desktop + Chrome on Android): bulk-OUT to the printer
/// interface, like libusb_transport.dart but inside the browser sandbox.
///
/// Platform catches (no code can avoid these):
///  * Linux: the kernel's `usblp` driver owns printer-class devices
///    (the HZ-8360), so `claimInterface` fails until it is unbound — the udev
///    rule in linux/70-thermal-printer.rules does that. Snap Chromium also
///    needs `snap connect chromium:raw-usb`.
///  * Windows: usbprint.sys owns printer-class devices; WebUSB needs WinUSB
///    instead (Zadig), which breaks the driverless desktop path. Use the
///    desktop app or its web bridge there.
///  * macOS / Android: works.
class WebUsbTransport implements PrinterTransport, PairableTransport {
  @override
  String get name => 'webusb';

  @override
  bool get isSupported => hasWebUsb;

  @override
  String get pairLabel => 'Add USB printer';

  @override
  String get pairHint => isLinux
      ? 'Linux needs the udev rule from the repo (frees the printer from usblp).'
      : 'Plug the printer in, then pick it in the list.';

  final _devices = <String, JSUsbDevice>{};

  static JSObject _filters() => {
        'filters': [
          {'classCode': 7}, // printer class (HZ-8360, most POS printers)
          for (final (v, p) in PrinterProfile.vendorSdkUsbIds) {'vendorId': v, 'productId': p},
        ],
      }.jsify() as JSObject;

  @override
  Future<List<PrinterEndpoint>> discover() async {
    final list = (await usb.getDevices().toDart).toDart;
    _devices.clear();
    final seen = <String, int>{};
    final out = <PrinterEndpoint>[];
    for (final d in list) {
      final base = '${_hex(d.vendorId)}:${_hex(d.productId)}';
      final n = seen.update(base, (v) => v + 1, ifAbsent: () => 0);
      final id = n == 0 ? base : '$base#$n';
      _devices[id] = d;
      final product = d.productName ?? 'USB printer';
      final known = PrinterProfile.vendorSdkUsbIds.contains((d.vendorId, d.productId));
      out.add(PrinterEndpoint(
        transport: name,
        id: id,
        label: 'USB $product $base${known ? ' ★' : ''}',
        usbVendorId: d.vendorId,
        usbProductId: d.productId,
      ));
    }
    return out;
  }

  static String _hex(int v) => v.toRadixString(16).padLeft(4, '0');

  @override
  Future<PrinterEndpoint?> pair() async {
    final JSUsbDevice dev;
    try {
      dev = await usb.requestDevice(_filters()).toDart;
    } on Object catch (e) {
      if (isChooserCancelled(e)) return null;
      throw StateError(jsErrorText(e));
    }
    final all = await discover();
    for (final e in all) {
      if (_devices[e.id] == dev) return e;
    }
    return all.lastOrNull;
  }

  @override
  Future<PrinterConnection> open(PrinterEndpoint endpoint) async {
    if (!_devices.containsKey(endpoint.id)) await discover();
    final d = _devices[endpoint.id];
    if (d == null) throw StateError('USB printer is gone — plug it in and add it again.');
    return _WebUsbConnection.open(d);
  }
}

class _WebUsbConnection implements PrinterConnection, PrinterStatusReader {
  _WebUsbConnection(this._d, this._iface, this._out, this._in, this._packet);
  final JSUsbDevice _d;
  final int _iface, _out, _packet;
  final int? _in;

  /// Interface ranking as in libusb_transport.dart: printer > CDC data > vendor.
  static int _rank(JSUsbAlternate a) => switch (a.interfaceClass) { 7 => 3, 10 => 2, 255 => 1, _ => 0 };

  static Future<_WebUsbConnection> open(JSUsbDevice d) async {
    try {
      if (!d.opened) await d.open().toDart;
      if (d.configuration == null) await d.selectConfiguration(1).toDart;
    } on Object catch (e) {
      throw StateError('Could not open the USB printer: ${jsErrorText(e)}');
    }
    final cfg = d.configuration!;
    JSUsbInterface? best;
    for (final i in cfg.interfaces.toDart) {
      final hasOut = i.alternate.endpoints.toDart.any((e) => e.direction == 'out' && e.type == 'bulk');
      if (!hasOut || _rank(i.alternate) == 0) continue;
      if (best == null || _rank(i.alternate) > _rank(best.alternate)) best = i;
    }
    if (best == null) throw StateError('No printer interface with a bulk-OUT endpoint');
    try {
      await d.claimInterface(best.interfaceNumber).toDart;
    } on Object catch (e) {
      final hint = isLinux
          ? ' On Linux the usblp kernel driver holds printer-class devices: install '
              'linux/70-thermal-printer.rules from the repo (it unbinds usblp), replug, retry.'
          : ' Another program or driver is using it (on Windows: usbprint.sys — use the desktop app or its web bridge).';
      throw StateError('Could not claim the USB interface (${jsErrorText(e)}).$hint');
    }
    final eps = best.alternate.endpoints.toDart;
    final out = eps.firstWhere((e) => e.direction == 'out' && e.type == 'bulk');
    final inn = eps.where((e) => e.direction == 'in' && e.type == 'bulk').firstOrNull;
    return _WebUsbConnection(d, best.interfaceNumber, out.endpointNumber, inn?.endpointNumber, out.packetSize);
  }

  @override
  Future<void> write(Uint8List data) async {
    final r = await _d.transferOut(_out, data.toJS).toDart;
    if (r.status != 'ok') throw StateError('USB write ${r.status}');
  }

  @override
  Future<Uint8List> read({Duration timeout = const Duration(milliseconds: 500)}) async {
    final ep = _in;
    if (ep == null) return Uint8List(0);
    // WebUSB has no transfer timeout; a pending transferIn stays queued and
    // would swallow the next reply, so keep at most one outstanding.
    _pending ??= _d.transferIn(ep, _packet < 64 ? 64 : _packet).toDart;
    try {
      final r = await _pending!.timeout(timeout);
      _pending = null;
      final v = r.data;
      if (v == null) return Uint8List(0);
      final bd = v.toDart;
      return bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
    } on Object {
      return Uint8List(0); // timeout: leave the transfer pending for next time
    }
  }

  Future<JSUsbInResult>? _pending;

  @override
  Future<void> close() async {
    try {
      await _d.releaseInterface(_iface).toDart;
      await _d.close().toDart;
    } on Object {
      // already gone
    }
  }
}
