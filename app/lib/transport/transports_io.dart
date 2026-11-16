import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

import 'android_usb_transport.dart';
import 'ble_transport.dart';
import 'device_file_transport.dart';
import 'dump_file_transport.dart';
import 'libusb_transport.dart';
import 'linux_rfcomm_transport.dart';
import 'tcp_transport.dart';
import 'transport.dart';
import 'windows_com_transport.dart';
import 'windows_usbprint_transport.dart';

List<PrinterTransport> platformTransports({List<String> manualHosts = const []}) => [
      AndroidUsbTransport(),
      DumpFileTransport(),
      LibusbTransport(),
      WindowsUsbPrintTransport(),
      WindowsComTransport(),
      _BlueZChecked(LinuxRfcommTransport()),
      DeviceFileTransport(),
      TcpTransport(manualHosts: manualHosts),
      _BlueZChecked(BleTransport()),
    ];

/// On Linux, universal_ble (and bluetoothctl for RFCOMM) talk to BlueZ over D-Bus and throws an error we
/// can't catch (from inside the plugin) when bluetoothd isn't running — seen
/// on CI and on machines without Bluetooth. Check for the org.bluez service
/// first and skip BLE entirely if it's absent.
class _BlueZChecked implements PrinterTransport {
  _BlueZChecked(this._inner);
  final PrinterTransport _inner;
  bool? _present;

  @override
  String get name => _inner.name;

  @override
  bool get isSupported => _inner.isSupported;

  Future<bool> _bluez() async {
    if (!Platform.isLinux) return true;
    if (_present != null) return _present!;
    DBusClient? c;
    try {
      c = DBusClient.system();
      _present = await c.nameHasOwner('org.bluez').timeout(const Duration(seconds: 2));
    } on Object {
      _present = false;
    } finally {
      // close() can wait forever when the bus socket never connected.
      if (c != null) unawaited(c.close().timeout(const Duration(seconds: 1)).catchError((Object _) {}));
    }
    return _present!;
  }

  @override
  Future<List<PrinterEndpoint>> discover() async => await _bluez() ? _inner.discover() : const [];

  @override
  Future<PrinterConnection> open(PrinterEndpoint endpoint) async {
    if (!await _bluez()) throw StateError('Bluetooth service (BlueZ) is not running');
    return _inner.open(endpoint);
  }
}

String? platformNote() => null;
