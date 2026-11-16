import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import '../ble_transport.dart' show BleTransport;
import '../transport.dart';
import 'js_api.dart';

/// Web Bluetooth (BLE GATT), Chromium desktop + Chrome on Android. Talks to
/// the browser API directly (no universal_ble): the old path called
/// `requestDevice()` from the automatic startup scan, which browsers reject
/// without a click — that is why Bluetooth never worked on the web.
///
/// Linux Chrome hides Web Bluetooth behind
/// chrome://flags/#enable-web-bluetooth (or experimental web platform
/// features), and BlueZ often refuses LE to dual-mode printers that are
/// paired over Classic (MP583, RE log §15) — Web Serial is the better path
/// there.
class WebBluetoothTransport implements PrinterTransport, PairableTransport {
  WebBluetoothTransport({this.bytesPerSecond = 4500});
  final int bytesPerSecond;

  @override
  String get name => 'webble';

  @override
  bool get isSupported => hasWebBluetooth;

  @override
  String get pairLabel => 'Add Bluetooth LE printer';

  @override
  String get pairHint => isLinux
      ? 'On Linux, prefer "Add Bluetooth / serial printer"; LE needs chrome://flags/#enable-web-bluetooth.'
      : 'Switch the printer on, then pick it in the list.';

  final _devices = <String, JSBluetoothDevice>{};
  static const _namePrefixes = ['MPT', 'MP58', 'MP583', 'PT-2', 'PT2', 'Printer', 'POS', 'BlueTooth Printer', 'HZ', 'ZJ'];

  @override
  Future<List<PrinterEndpoint>> discover() async {
    // Previously granted devices — only with Chrome's new permissions backend.
    if (!hasBluetoothGetDevices) {
      return [for (final e in _devices.entries) _endpoint(e.value)];
    }
    try {
      for (final d in (await bluetoothGetDevices().toDart).toDart) {
        _devices[d.id] = d;
      }
    } on Object {
      // not allowed here
    }
    return [for (final d in _devices.values) _endpoint(d)];
  }

  PrinterEndpoint _endpoint(JSBluetoothDevice d) =>
      PrinterEndpoint(transport: name, id: d.id, label: 'Bluetooth LE ${d.name ?? d.id}');

  @override
  Future<PrinterEndpoint?> pair() async {
    final services = BleTransport.knownServices.keys.toList();
    final JSBluetoothDevice dev;
    try {
      dev = await bluetooth.requestDevice({
        'filters': [
          for (final s in services) {'services': [s]},
          for (final p in _namePrefixes) {'namePrefix': p},
        ],
        'optionalServices': services,
      }.jsify() as JSObject).toDart;
    } on Object catch (e) {
      if (isChooserCancelled(e)) return null;
      throw StateError(jsErrorText(e));
    }
    _devices[dev.id] = dev;
    return _endpoint(dev);
  }

  @override
  Future<PrinterConnection> open(PrinterEndpoint endpoint) async {
    final d = _devices[endpoint.id];
    if (d == null) throw StateError('Add the Bluetooth printer again (the browser forgot it after reload).');
    final gatt = d.gatt;
    if (gatt == null) throw StateError('Device has no GATT server');
    try {
      if (!gatt.connected) await gatt.connect().toDart;
    } on Object catch (e) {
      throw StateError('Bluetooth LE connect failed (${jsErrorText(e)}). '
          '${isLinux ? 'On Linux try "Add Bluetooth / serial printer" instead.' : 'Is the printer on and not connected to another device?'}');
    }
    JSGattCharacteristic? chr;
    for (final svc in (await gatt.getPrimaryServices().toDart).toDart) {
      final want = BleTransport.knownServices[svc.uuid.toLowerCase()];
      if (want == null) continue;
      for (final c in (await svc.getCharacteristics().toDart).toDart) {
        if (c.uuid.toLowerCase() == want) chr = c;
      }
      if (chr != null) break;
    }
    if (chr == null) {
      // Fallback: first characteristic that accepts write-without-response.
      outer:
      for (final svc in (await gatt.getPrimaryServices().toDart).toDart) {
        for (final c in (await svc.getCharacteristics().toDart).toDart) {
          if (c.properties.writeWithoutResponse) {
            chr = c;
            break outer;
          }
        }
      }
    }
    if (chr == null) {
      gatt.disconnect();
      throw StateError('No writable printer characteristic found');
    }
    return _WebBleConnection(gatt, chr, bytesPerSecond);
  }
}

class _WebBleConnection implements PrinterConnection {
  _WebBleConnection(this._gatt, this._chr, int bytesPerSecond)
      : _noRsp = _chr.properties.writeWithoutResponse,
        _perChunk = Duration(microseconds: _payload * 1000000 ~/ bytesPerSecond);

  final JSGattServer _gatt;
  final JSGattCharacteristic _chr;
  final bool _noRsp;
  final Duration _perChunk;

  /// Web Bluetooth can't query the MTU; 20 bytes always fits (ATT 23 - 3).
  /// Printers have no flow control over BLE, so writes are paced.
  static const _payload = 20;

  @override
  Future<void> write(Uint8List data) async {
    for (var off = 0; off < data.length; off += _payload) {
      final end = math.min(off + _payload, data.length);
      final sw = Stopwatch()..start();
      final chunk = Uint8List.sublistView(data, off, end).toJS;
      await (_noRsp ? _chr.writeValueWithoutResponse(chunk) : _chr.writeValueWithResponse(chunk)).toDart;
      final left = _perChunk - sw.elapsed;
      if (left > Duration.zero) await Future<void>.delayed(left);
    }
  }

  @override
  Future<void> close() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    _gatt.disconnect();
  }
}
