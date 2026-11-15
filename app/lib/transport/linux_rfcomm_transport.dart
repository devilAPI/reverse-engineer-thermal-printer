import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'transport.dart';

/// Bluetooth Classic SPP (RFCOMM) on Linux via raw libc sockets — no root,
/// no `rfcomm bind`, no extra packages. Lists *paired* devices that offer the
/// Serial Port profile (UUID 0x1101), as reported by BlueZ (`bluetoothctl`).
///
/// Needed for dual-mode printers like the MP583: BlueZ connects them over
/// BR/EDR (classic) because they share one public address, so BLE GATT fails
/// with `br-connection-profile-unavailable` (see RE log §15).
class LinuxRfcommTransport implements PrinterTransport {
  @override
  String get name => 'rfcomm';

  @override
  bool get isSupported => Platform.isLinux;

  @override
  Future<List<PrinterEndpoint>> discover() async {
    final ProcessResult list;
    try {
      list = await Process.run('bluetoothctl', ['devices', 'Paired']);
    } on ProcessException {
      return const [];
    }
    final out = <PrinterEndpoint>[];
    for (final m in RegExp(r'^Device ([0-9A-F:]{17}) (.*)$', multiLine: true).allMatches('${list.stdout}')) {
      final mac = m.group(1)!, alias = m.group(2)!.trim();
      final info = await Process.run('bluetoothctl', ['info', mac]);
      if (!'${info.stdout}'.contains('00001101-0000-1000-8000-00805f9b34fb')) continue;
      out.add(PrinterEndpoint(transport: name, id: mac, label: 'Bluetooth $alias (SPP)'));
    }
    return out;
  }

  @override
  Future<PrinterConnection> open(PrinterEndpoint endpoint) async => _RfcommConnection.connect(endpoint.id, 1);
}

class _RfcommConnection implements PrinterConnection, PrinterStatusReader {
  _RfcommConnection(this._fd);
  final int _fd;

  static const _afBluetooth = 31, _sockStream = 1, _btprotoRfcomm = 3;

  static _RfcommConnection connect(String mac, int channel) {
    final fd = _libc.socket(_afBluetooth, _sockStream, _btprotoRfcomm);
    if (fd < 0) throw StateError('RFCOMM socket() failed');
    // struct sockaddr_rc { sa_family_t family; bdaddr_t bdaddr (6, little-endian); uint8_t channel; } -> 10 bytes
    final addr = calloc<Uint8>(10);
    try {
      addr[0] = _afBluetooth & 0xFF;
      addr[1] = _afBluetooth >> 8;
      final b = mac.split(':').map((h) => int.parse(h, radix: 16)).toList();
      for (var i = 0; i < 6; i++) {
        addr[2 + i] = b[5 - i];
      }
      addr[8] = channel;
      if (_libc.connect(fd, addr, 10) != 0) {
        _libc.close(fd);
        throw StateError('RFCOMM connect to $mac failed — printer off, out of range, or not paired?');
      }
    } finally {
      calloc.free(addr);
    }
    return _RfcommConnection(fd);
  }

  @override
  Future<void> write(Uint8List data) async {
    const max = 4096;
    final buf = malloc<Uint8>(max);
    try {
      var off = 0;
      while (off < data.length) {
        final len = (data.length - off).clamp(0, max);
        buf.asTypedList(len).setRange(0, len, data, off);
        final n = _libc.write(_fd, buf, len);
        if (n < 0) throw StateError('RFCOMM write failed');
        off += n;
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      malloc.free(buf);
    }
  }

  @override
  Future<Uint8List> read({Duration timeout = const Duration(milliseconds: 500)}) async {
    // struct pollfd { int fd; short events; short revents; }
    final pfd = calloc<Uint8>(8);
    final buf = malloc<Uint8>(256);
    try {
      pfd.cast<Int32>().value = _fd;
      (pfd + 4).cast<Int16>().value = 1; // POLLIN
      if (_libc.poll(pfd, 1, timeout.inMilliseconds) <= 0) return Uint8List(0);
      final n = _libc.read(_fd, buf, 256);
      return n <= 0 ? Uint8List(0) : Uint8List.fromList(buf.asTypedList(n));
    } finally {
      calloc.free(pfd);
      malloc.free(buf);
    }
  }

  @override
  Future<void> close() async {
    // Give the printer time to drain its ~3 KB buffer before dropping the link.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    _libc.close(_fd);
  }
}

class _Libc {
  _Libc(DynamicLibrary l)
      : socket = l.lookupFunction<Int32 Function(Int32, Int32, Int32), int Function(int, int, int)>('socket'),
        connect = l.lookupFunction<Int32 Function(Int32, Pointer<Uint8>, Uint32), int Function(int, Pointer<Uint8>, int)>(
            'connect'),
        write = l.lookupFunction<IntPtr Function(Int32, Pointer<Uint8>, IntPtr), int Function(int, Pointer<Uint8>, int)>(
            'write'),
        read = l.lookupFunction<IntPtr Function(Int32, Pointer<Uint8>, IntPtr), int Function(int, Pointer<Uint8>, int)>(
            'read'),
        poll = l.lookupFunction<Int32 Function(Pointer<Uint8>, Uint64, Int32), int Function(Pointer<Uint8>, int, int)>('poll'),
        close = l.lookupFunction<Int32 Function(Int32), int Function(int)>('close');

  final int Function(int, int, int) socket;
  final int Function(int, Pointer<Uint8>, int) connect;
  final int Function(int, Pointer<Uint8>, int) write;
  final int Function(int, Pointer<Uint8>, int) read;
  final int Function(Pointer<Uint8>, int, int) poll;
  final int Function(int) close;
}

final _libc = _Libc(DynamicLibrary.process());
