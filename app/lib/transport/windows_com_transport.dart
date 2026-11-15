import 'dart:io';
import 'dart:typed_data';

import '../core/printer_profile.dart';
import 'transport.dart';
import 'win32_io.dart';

/// Windows COM ports — all with drivers that ship with Windows:
///  * Bluetooth Classic SPP: pairing a printer (e.g. MP583, PIN 0000) makes
///    Windows create "Standard Serial over Bluetooth link (COMn)" ports.
///    Windows creates two per device; the *outgoing* one (instance id carries
///    the printer's MAC) is the one that prints — the incoming one has
///    000000000000 and is listed last.
///  * USB CDC-ACM printers (e.g. STM32 VCP 0483:5740): usbser.sys → COMn.
///
/// Enumerated via SetupAPI GUID_DEVINTERFACE_COMPORT with friendly names;
/// I/O is overlapped with timeouts (win32_io.dart).
///
/// UNVERIFIED on hardware: developed on Linux, compiled by CI.
class WindowsComTransport implements PrinterTransport {
  @override
  String get name => 'com';

  @override
  bool get isSupported => Platform.isWindows;

  @override
  Future<List<PrinterEndpoint>> discover() async {
    final ports = <(PrinterEndpoint, int)>[];
    for (final d in Win32.instance.devices(Win32.comPortGuid)) {
      final friendly = d.friendlyName ?? '';
      final com = RegExp(r'\((COM\d+)\)').firstMatch(friendly)?.group(1);
      if (com == null) continue;
      final inst = (d.instanceId ?? '').toUpperCase();
      final hw = (d.hardwareId ?? '').toUpperCase();
      final isBt = inst.startsWith('BTHENUM') || hw.startsWith('BTHENUM');
      // BTHENUM\{00001101-...}_...\8&...&0&DC0D51D217F9_C00000000 → remote MAC
      final mac = RegExp(r'&([0-9A-F]{12})_').firstMatch(inst)?.group(1);
      final incoming = isBt && (mac == null || mac == '000000000000');
      final usb = RegExp(r'VID_([0-9A-F]{4})&PID_([0-9A-F]{4})').firstMatch(hw.isEmpty ? inst : hw);
      final vid = usb == null ? null : int.parse(usb.group(1)!, radix: 16);
      final pid = usb == null ? null : int.parse(usb.group(2)!, radix: 16);
      final known = vid != null && PrinterProfile.vendorSdkUsbIds.contains((vid, pid));
      final macText = mac == null || incoming ? '' : ' ${_mac(mac)}';
      final kind = isBt ? (incoming ? 'Bluetooth (incoming — use the other port)' : 'Bluetooth') : 'Serial';
      ports.add((
        PrinterEndpoint(
          transport: name,
          id: r'\\.\' + com, // works for COM10+ too
          label: '$kind $com$macText${known ? ' ★' : ''} — $friendly',
          usbVendorId: vid,
          usbProductId: pid,
        ),
        incoming ? 2 : (isBt ? 0 : 1),
      ));
    }
    ports.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final p in ports) p.$1];
  }

  static String _mac(String m) => [for (var i = 0; i < 12; i += 2) m.substring(i, i + 2)].join(':');

  @override
  Future<PrinterConnection> open(PrinterEndpoint endpoint) async {
    final h = Win32.instance.open(endpoint.id);
    try {
      Win32.instance.configureComPort(h);
    } on Object {
      // virtual ports may reject parts of the DCB; I/O still works
    }
    return _ComConnection(h);
  }
}

class _ComConnection implements PrinterConnection, PrinterStatusReader {
  _ComConnection(this._h);
  final int _h;

  @override
  Future<void> write(Uint8List data) async {
    Win32.instance.write(_h, data);
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<Uint8List> read({Duration timeout = const Duration(milliseconds: 500)}) async =>
      Win32.instance.read(_h, timeout);

  @override
  Future<void> close() async {
    // Bluetooth SPP: let the printer drain its ~3 KB buffer before the link drops.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    Win32.instance.closeHandle(_h);
  }
}
