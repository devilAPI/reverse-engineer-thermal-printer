import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import '../../core/printer_profile.dart';
import '../transport.dart';
import 'js_api.dart';

/// Web Serial (Chromium desktop): USB CDC serial printers and — since
/// Chrome 117 — Bluetooth Classic SPP (RFCOMM). The MP583 prints over SPP
/// (RE log §15), so this is the browser path for it: pair it with the OS
/// first, then "Add printer" and pick "MP583" in Chrome's port chooser.
///
/// Ports the user granted once come back from `getPorts()` without a prompt.
class WebSerialTransport implements PrinterTransport, PairableTransport {
  static const spp = '00001101-0000-1000-8000-00805f9b34fb';

  @override
  String get name => 'webserial';

  @override
  bool get isSupported => hasWebSerial;

  @override
  String get pairLabel => 'Add Bluetooth / serial printer';

  @override
  String get pairHint => 'Pair the printer with your computer first (PIN 0000), then pick it in the list.';

  /// Granted ports, indexed by the endpoint id we hand out (grant order).
  final _ports = <String, JSSerialPort>{};

  @override
  Future<List<PrinterEndpoint>> discover() async {
    final ports = (await serial.getPorts().toDart).toDart;
    _ports.clear();
    final out = <PrinterEndpoint>[];
    for (var i = 0; i < ports.length; i++) {
      out.add(_endpoint(ports[i], i));
    }
    return out;
  }

  PrinterEndpoint _endpoint(JSSerialPort p, int index) {
    final info = p.getInfo();
    final vid = info.usbVendorId, pid = info.usbProductId;
    final bt = info.bluetoothServiceClassId;
    final id = vid != null
        ? 'usb:${_hex(vid)}:${_hex(pid ?? 0)}#$index'
        : bt != null
            ? 'bt#$index'
            : 'port#$index';
    _ports[id] = p;
    final known = vid != null && PrinterProfile.vendorSdkUsbIds.contains((vid, pid));
    final label = vid != null
        ? 'Serial USB ${_hex(vid)}:${_hex(pid ?? 0)}${known ? ' ★' : ''}'
        : bt != null
            ? 'Bluetooth serial printer ${index + 1}'
            : 'Serial port ${index + 1}';
    return PrinterEndpoint(transport: name, id: id, label: label, usbVendorId: vid, usbProductId: pid);
  }

  static String _hex(int v) => v.toRadixString(16).padLeft(4, '0');

  @override
  Future<PrinterEndpoint?> pair() async {
    final JSSerialPort port;
    try {
      // No filters: show every port. Standard SPP ports are listed by default;
      // naming the UUID also covers browsers that only list allowed services.
      port = await serial.requestPort({
        'allowedBluetoothServiceClassIds': [spp],
      }.jsify() as JSObject).toDart;
    } on Object catch (e) {
      if (isChooserCancelled(e)) return null;
      throw StateError(jsErrorText(e));
    }
    final all = await discover();
    for (final e in all) {
      if (identical(_ports[e.id], port) || _ports[e.id] == port) return e;
    }
    return all.lastOrNull;
  }

  @override
  Future<PrinterConnection> open(PrinterEndpoint endpoint) async {
    if (!_ports.containsKey(endpoint.id)) await discover();
    final port = _ports[endpoint.id];
    if (port == null) throw StateError('Serial port is gone — add the printer again.');
    return _WebSerialConnection.open(port);
  }
}

class _WebSerialConnection implements PrinterConnection, PrinterStatusReader {
  _WebSerialConnection(this._port, this._writer, this._reader) {
    unawaited(_pump());
  }

  final JSSerialPort _port;
  final JSWritableStreamWriter _writer;
  final JSReadableStreamReader? _reader;
  final _rx = <int>[];
  Completer<void>? _rxWait;
  bool _closed = false, _dead = false;

  /// Bluetooth SPP connects slowly (5–25 s on Linux, RE log §17), so a
  /// released port stays open for [keepAlive] and is reused.
  static const keepAlive = Duration(minutes: 3);
  static final _parked = <JSSerialPort, (_WebSerialConnection, Timer)>{};

  static Future<_WebSerialConnection> open(JSSerialPort port) async {
    final parked = _parked.remove(port);
    if (parked != null && parked.$1._dead) {
      parked.$2.cancel();
      await parked.$1._reallyClose();
    } else if (parked != null) {
      parked.$2.cancel();
      parked.$1._closed = false;
      parked.$1._rx.clear();
      return parked.$1;
    }
    try {
      await port.open({'baudRate': 115200, 'bufferSize': 16384}.jsify() as JSObject).toDart;
    } on Object catch (e) {
      final t = jsErrorText(e);
      // Already open (e.g. a previous tab/session): try to use it anyway.
      if (!t.contains('already open')) {
        throw StateError('Could not open the port: $t. '
            'For Bluetooth: is the printer on and paired? Close other apps using it.');
      }
    }
    final w = port.writable;
    if (w == null) throw StateError('Port is not writable');
    return _WebSerialConnection(port, w.getWriter(), port.readable?.getReader());
  }

  Future<void> _pump() async {
    final r = _reader;
    if (r == null) return;
    try {
      while (true) {
        final res = await r.read().toDart;
        if (res.done) break;
        final v = res.value;
        if (v != null) {
          _rx.addAll(v.toDart);
          _rxWait?.complete();
          _rxWait = null;
        }
      }
    } on Object {
      // port closed / device lost
    }
    _dead = true;
  }

  @override
  Future<void> write(Uint8List data) async {
    try {
      await _writer.ready.toDart;
      await _writer.write(data.toJS).toDart;
    } on Object catch (e) {
      _dead = true;
      throw StateError('Serial write failed (${jsErrorText(e)}) — link lost, try again.');
    }
  }

  @override
  Future<Uint8List> read({Duration timeout = const Duration(milliseconds: 500)}) async {
    if (_rx.isEmpty) {
      final w = _rxWait ??= Completer<void>();
      await w.future.timeout(timeout, onTimeout: () {});
    }
    final out = Uint8List.fromList(_rx);
    _rx.clear();
    return out;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_dead) {
      await _reallyClose();
      return;
    }
    _parked[_port] = (
      this,
      Timer(keepAlive, () {
        _parked.remove(_port);
        unawaited(_reallyClose());
      })
    );
  }

  Future<void> _reallyClose() async {
    try {
      await _reader?.cancel().toDart;
    } on Object {/* ignore */}
    try {
      _reader?.releaseLock();
      _writer.releaseLock();
      await _port.close().toDart;
    } on Object {/* ignore */}
  }
}
