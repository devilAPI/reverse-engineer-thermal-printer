import 'dart:io';
import 'dart:typed_data';

import '../core/printer_profile.dart';
import 'transport.dart';
import 'win32_io.dart';

/// Windows: raw I/O to USB printer-class devices through the inbox
/// usbprint.sys ("USB Printing Support") — no driver install, no Zadig, no
/// print queue. Device paths come from SetupAPI with
/// GUID_DEVINTERFACE_USBPRINT; then overlapped CreateFile/WriteFile/ReadFile
/// with timeouts (see win32_io.dart). Same approach as the Rust `escpos`
/// crate's usbprint example (docs/RESEARCH.md).
///
/// Measured: the HZ-8360 (0416:5011) is printer class 07/01/02, so Windows
/// binds usbprint.sys to it automatically.
///
/// UNVERIFIED on hardware: developed on Linux, compiled by CI.
class WindowsUsbPrintTransport implements PrinterTransport {
  @override
  String get name => 'usbprint';

  @override
  bool get isSupported => Platform.isWindows;

  @override
  Future<List<PrinterEndpoint>> discover() async {
    final out = <PrinterEndpoint>[];
    for (final d in Win32.instance.devices(Win32.usbPrintGuid)) {
      final m = RegExp(r'vid_([0-9a-f]{4})&pid_([0-9a-f]{4})', caseSensitive: false).firstMatch(d.path);
      final vid = m == null ? null : int.parse(m.group(1)!, radix: 16);
      final pid = m == null ? null : int.parse(m.group(2)!, radix: 16);
      final known = vid != null && PrinterProfile.vendorSdkUsbIds.contains((vid, pid));
      final ids = m == null ? '' : ' ${m.group(1)!.toLowerCase()}:${m.group(2)!.toLowerCase()}';
      out.add(
        PrinterEndpoint(
          transport: name,
          id: d.path,
          label: 'USB printer$ids${known ? ' ★' : ''}',
          usbVendorId: vid,
          usbProductId: pid,
        ),
      );
    }
    return out;
  }

  @override
  Future<PrinterConnection> open(PrinterEndpoint endpoint) async =>
      _UsbPrintConnection(Win32.instance.open(endpoint.id));
}

class _UsbPrintConnection implements PrinterConnection, PrinterStatusReader {
  _UsbPrintConnection(this._h);
  final int _h;
  bool _primed = false;

  @override
  Future<void> write(Uint8List data) async {
    Win32.instance.write(_h, data);
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<Uint8List> read({Duration timeout = const Duration(milliseconds: 500)}) async {
    if (!_primed) {
      // Known usbprint quirk: the first bulk-IN byte after opening is often
      // junk (0x2B). Send one throw-away DLE EOT 1 and discard the answer.
      _primed = true;
      Win32.instance.write(_h, Uint8List.fromList([0x10, 0x04, 0x01]));
      Win32.instance.read(_h, const Duration(milliseconds: 300));
    }
    return Win32.instance.read(_h, timeout);
  }

  @override
  Future<void> close() async => Win32.instance.closeHandle(_h);
}
