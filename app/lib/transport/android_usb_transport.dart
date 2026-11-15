import 'dart:io';

import 'package:flutter/services.dart';

import '../core/printer_profile.dart';
import 'transport.dart';

/// Android USB Host transport, backed by UsbPrinterChannel.kt.
class AndroidUsbTransport implements PrinterTransport {
  static const _ch = MethodChannel('thermal_photo/usb');

  @override
  String get name => 'usb';

  @override
  bool get isSupported => Platform.isAndroid;

  @override
  Future<List<PrinterEndpoint>> discover() async {
    final list = await _ch.invokeListMethod<Map<Object?, Object?>>('list') ?? const [];
    return [
      for (final d in list)
        PrinterEndpoint(
          transport: name,
          id: d['name']! as String,
          label: _label(d),
          usbVendorId: d['vendorId'] as int?,
          usbProductId: d['productId'] as int?,
        ),
    ];
  }

  static String _label(Map<Object?, Object?> d) {
    final vid = (d['vendorId']! as int).toRadixString(16).padLeft(4, '0');
    final pid = (d['productId']! as int).toRadixString(16).padLeft(4, '0');
    final known = PrinterProfile.vendorSdkUsbIds.contains((d['vendorId'], d['productId'])) ? ' ★' : '';
    final product = d['product'] ?? 'USB device';
    return 'USB $product ($vid:$pid)$known';
  }

  @override
  Future<PrinterConnection> open(PrinterEndpoint endpoint) async {
    final ok = await _ch.invokeMethod<bool>('requestPermission', {'name': endpoint.id}) ?? false;
    if (!ok) throw StateError('USB permission denied');
    await _ch.invokeMethod<void>('open', {'name': endpoint.id});
    return _AndroidUsbConnection(endpoint.id);
  }
}

class _AndroidUsbConnection implements PrinterConnection {
  _AndroidUsbConnection(this._name);
  final String _name;

  @override
  Future<void> write(Uint8List data) =>
      AndroidUsbTransport._ch.invokeMethod<int>('write', {'name': _name, 'data': data});

  @override
  Future<void> close() => AndroidUsbTransport._ch.invokeMethod<void>('close', {'name': _name});
}
