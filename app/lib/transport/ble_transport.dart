import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import 'transport.dart';

/// Bluetooth Low Energy "transparent UART" printers (MPT-II / PT-210 family).
/// Works on Android, iOS, macOS, Windows, Linux and Chromium-based Web.
///
/// The printer has no flow control over BLE, so writes are paced open-loop
/// (see docs/RESEARCH.md: ~182 B every 40 ms in the GOOJPRT reference SDK).
class BleTransport implements PrinterTransport {
  BleTransport({this.scanTime = const Duration(seconds: 4), this.bytesPerSecond = 4500});

  final Duration scanTime;
  final int bytesPerSecond;

  /// Known printer services and their write characteristics.
  static const knownServices = <String, String>{
    '49535343-fe7d-4ae5-8fa9-9fafd205e455': '49535343-8841-43f4-a8d4-ecbe34729bb3', // ISSC
    '000018f0-0000-1000-8000-00805f9b34fb': '00002af1-0000-1000-8000-00805f9b34fb', // 18F0/2AF1
    '0000ff00-0000-1000-8000-00805f9b34fb': '0000ff02-0000-1000-8000-00805f9b34fb', // FF00/FF02
    '0000ffe0-0000-1000-8000-00805f9b34fb': '0000ffe1-0000-1000-8000-00805f9b34fb', // HM-10 style
  };

  static final _namePattern = RegExp(r'MPT|PT-?2|MP58|MP583|printer|POS|BlueTooth Printer|HZ|ZJ', caseSensitive: false);

  @override
  String get name => 'ble';

  @override
  bool get isSupported => true;

  @override
  Future<List<PrinterEndpoint>> discover() async {
    if (await UniversalBle.getBluetoothAvailabilityState() != AvailabilityState.poweredOn) return [];
    await UniversalBle.requestPermissions();

    final found = <String, PrinterEndpoint>{};
    final sub = UniversalBle.scanStream.listen((d) {
      final label = d.name ?? d.rawName ?? '';
      final advertisesKnown = d.services.any((s) => knownServices.containsKey(s.toLowerCase()));
      if (advertisesKnown || _namePattern.hasMatch(label)) {
        found[d.deviceId] = PrinterEndpoint(
          transport: name,
          id: d.deviceId,
          label: 'BLE ${label.isEmpty ? d.deviceId : label}',
        );
      }
    });
    try {
      await UniversalBle.startScan(
        // Web Bluetooth only allows access to services declared up front.
        platformConfig: PlatformConfig(web: WebOptions(optionalServices: knownServices.keys.toList())),
      );
      if (!kIsWeb) await Future<void>.delayed(scanTime);
    } finally {
      await UniversalBle.stopScan();
      await sub.cancel();
    }
    return found.values.toList();
  }

  @override
  Future<PrinterConnection> open(PrinterEndpoint endpoint) async {
    final id = endpoint.id;
    await UniversalBle.connect(id, timeout: const Duration(seconds: 15));
    try {
      final services = await UniversalBle.discoverServices(id);
      final (svc, chr, noRsp) = _pickWriteCharacteristic(services);

      var payload = 20; // ATT default MTU 23 - 3
      try {
        final mtu = await UniversalBle.requestMtu(id, 247);
        payload = math.max(20, math.min(mtu - 3, 180));
      } on Object {
        // Not supported on this platform; Apple/Windows/Linux negotiate automatically,
        // but we can't query it, so stay conservative.
        if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS)) {
          payload = 180;
        }
      }
      return _BleConnection(id, svc, chr, noRsp, payload, bytesPerSecond);
    } on Object {
      await UniversalBle.disconnect(id);
      rethrow;
    }
  }

  static (String, String, bool) _pickWriteCharacteristic(List<BleService> services) {
    for (final s in services) {
      final want = knownServices[s.uuid.toLowerCase()];
      if (want == null) continue;
      for (final c in s.characteristics) {
        if (c.uuid.toLowerCase() == want) {
          return (s.uuid, c.uuid, c.properties.contains(CharacteristicProperty.writeWithoutResponse));
        }
      }
    }
    // Fallback: first characteristic that accepts write-without-response.
    for (final s in services) {
      for (final c in s.characteristics) {
        if (c.properties.contains(CharacteristicProperty.writeWithoutResponse)) return (s.uuid, c.uuid, true);
      }
    }
    throw StateError('No writable printer characteristic found');
  }
}

class _BleConnection implements PrinterConnection {
  _BleConnection(this.id, this.svc, this.chr, this.noRsp, this.payload, int bytesPerSecond)
      : _perChunk = Duration(microseconds: payload * 1000000 ~/ bytesPerSecond);

  final String id, svc, chr;
  final bool noRsp;
  final int payload;
  final Duration _perChunk;

  @override
  Future<void> write(Uint8List data) async {
    for (var off = 0; off < data.length; off += payload) {
      final end = math.min(off + payload, data.length);
      final sw = Stopwatch()..start();
      await UniversalBle.write(id, svc, chr, Uint8List.sublistView(data, off, end), withoutResponse: noRsp);
      final left = _perChunk - sw.elapsed;
      if (left > Duration.zero) await Future<void>.delayed(left);
    }
  }

  @override
  Future<void> close() async {
    // Let the printer drain its buffer before dropping the link.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await UniversalBle.disconnect(id);
  }
}
