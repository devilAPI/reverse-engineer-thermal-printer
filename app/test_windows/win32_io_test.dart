// Runs on the Windows CI runner only (flutter test test_windows):
// exercises the real Win32 FFI used by the usbprint and COM transports.
@TestOn('windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thermal_photo/transport/win32_io.dart';
import 'package:thermal_photo/transport/windows_com_transport.dart';
import 'package:thermal_photo/transport/windows_usbprint_transport.dart';

void main() {
  test('SetupAPI enumeration of USB printers and COM ports does not crash', () async {
    final usb = await WindowsUsbPrintTransport().discover();
    final com = await WindowsComTransport().discover();
    // ignore: avoid_print
    print('usbprint: $usb\ncom: $com');
  });

  test('overlapped write/read round-trip through a file handle', () {
    final dir = Directory.systemTemp.createTempSync('tp_win32');
    final path = '${dir.path}\\io.bin';
    File(path).writeAsBytesSync(const []);
    final w = Win32.instance;
    final h = w.open(path);
    try {
      final data = Uint8List.fromList(List.generate(40000, (i) => i & 0xFF)); // > one 16 KB chunk
      w.write(h, data);
    } finally {
      w.closeHandle(h);
    }
    expect(File(path).readAsBytesSync().length, 40000);

    final h2 = w.open(path);
    try {
      final got = w.read(h2, const Duration(seconds: 2)); // offset 0, up to 512 bytes
      expect(got.length, 512);
      expect(got[0], 0);
      expect(got[511], 511 & 0xFF);
    } finally {
      w.closeHandle(h2);
    }
    dir.deleteSync(recursive: true);
  });

  test('opening a missing device fails cleanly', () {
    expect(() => Win32.instance.open(r'\\.\COM250'), throwsStateError);
  });

  test('a read with no data times out instead of hanging (named pipe)', () async {
    // A pipe server that never writes: our overlapped read must return empty
    // after the timeout — the exact situation of a printer that ignores DLE EOT.
    final name = '\\\\.\\pipe\\thermal_photo_test_${DateTime.now().microsecondsSinceEpoch}';
    final server = await Process.start('powershell', [
      '-NoProfile',
      '-Command',
      '\$p = New-Object System.IO.Pipes.NamedPipeServerStream("${name.substring(9)}", "InOut", 1, "Byte", "Asynchronous"); '
          '\$p.WaitForConnection(); Start-Sleep -Seconds 5',
    ]);
    try {
      int? h;
      for (var i = 0; i < 50 && h == null; i++) {
        try {
          h = Win32.instance.open(name);
        } on StateError {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      expect(h, isNotNull, reason: 'pipe server did not start');
      final sw = Stopwatch()..start();
      final got = Win32.instance.read(h!, const Duration(milliseconds: 300));
      sw.stop();
      expect(got, isEmpty);
      expect(sw.elapsedMilliseconds, lessThan(2000));
      Win32.instance.closeHandle(h);
    } finally {
      server.kill();
    }
  });
}
