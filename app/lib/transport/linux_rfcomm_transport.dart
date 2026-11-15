import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
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
      list = await Process.run('bluetoothctl', ['devices', 'Paired']).timeout(const Duration(seconds: 4));
    } on Object {
      return const []; // not installed, or BlueZ not answering
    }
    final out = <PrinterEndpoint>[];
    for (final m in RegExp(r'^Device ([0-9A-F:]{17}) (.*)$', multiLine: true).allMatches('${list.stdout}')) {
      final mac = m.group(1)!, alias = m.group(2)!.trim();
      final ProcessResult info;
      try {
        info = await Process.run('bluetoothctl', ['info', mac]).timeout(const Duration(seconds: 4));
      } on Object {
        continue;
      }
      if (!'${info.stdout}'.contains('00001101-0000-1000-8000-00805f9b34fb')) continue;
      out.add(PrinterEndpoint(transport: name, id: mac, label: 'Bluetooth $alias (SPP)'));
    }
    return out;
  }

  @override
  Future<PrinterConnection> open(PrinterEndpoint endpoint) => _RfcommConnection.connect(endpoint.id, 1);
}

class _RfcommConnection implements PrinterConnection, PrinterStatusReader {
  _RfcommConnection(this._fd, this._mac);
  final int _fd;
  final String _mac;
  bool _closed = false, _dead = false;

  /// Paging the printer can take 5–25 s, so a released link is kept open for
  /// [keepAlive] and reused by the next print (RE log §17).
  static const keepAlive = Duration(minutes: 3);
  static final _parked = <String, (int, Timer)>{};

  static const _pollIn = 0x1, _pollErr = 0x8, _pollHup = 0x10;

  static const _afBluetooth = 31, _sockStream = 1, _btprotoRfcomm = 3;

  static const _ehostdown = 112, _etimedout = 110, _ehostunreach = 113;

  /// Paging the MP583 takes ~4.5 s, right at the Linux default page timeout
  /// of 5.12 s, so a single connect() fails with EHOSTDOWN about half the
  /// time (RE log §17). Retry those errors; each attempt blocks for up to
  /// ~5 s, so it runs in a helper isolate to keep the UI responsive.
  static Future<_RfcommConnection> connect(String mac, int channel, {int attempts = 5}) async {
    final parked = _parked.remove(mac);
    if (parked != null) {
      parked.$2.cancel();
      if (_alive(parked.$1)) return _RfcommConnection(parked.$1, mac);
      _libc.close(parked.$1);
    }
    var err = 0;
    for (var i = 0; i < attempts; i++) {
      final r = await Isolate.run(() => _connectOnce(mac, channel));
      if (r >= 0) return _RfcommConnection(r, mac);
      err = -r;
      if (err != _ehostdown && err != _etimedout && err != _ehostunreach) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    throw StateError('RFCOMM connect to $mac failed (errno $err${err == _ehostdown ? ', host is down' : ''}) — '
        'printer off, out of range, or not paired? (Slow to answer? see README: Bluetooth on Linux)');
  }

  /// True if the socket is still connected; drains stale input.
  static bool _alive(int fd) {
    final pfd = calloc<Uint8>(8);
    final buf = malloc<Uint8>(256);
    try {
      pfd.cast<Int32>().value = fd;
      (pfd + 4).cast<Int16>().value = _pollIn;
      for (var i = 0; i < 64; i++) {
        (pfd + 6).cast<Int16>().value = 0;
        if (_libc.poll(pfd, 1, 0) <= 0) return true; // nothing pending (EINTR: assume fine)
        final rev = (pfd + 6).cast<Int16>().value;
        if (rev & (_pollErr | _pollHup) != 0) return false;
        if (_libc.read(fd, buf, 256) <= 0) return false;
      }
      return true;
    } finally {
      calloc.free(pfd);
      malloc.free(buf);
    }
  }

  static const _eintr = 4, _einprogress = 115, _ealready = 114;

  /// Waits (up to 30 s) for a pending connect; returns 0 or an errno.
  static int _awaitConnect(int fd) {
    final pfd = calloc<Uint8>(8);
    final err = calloc<Int32>();
    final len = calloc<Uint32>()..value = 4;
    try {
      pfd.cast<Int32>().value = fd;
      (pfd + 4).cast<Int16>().value = 4; // POLLOUT
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (true) {
        final n = _libc.poll(pfd, 1, 1000);
        if (n > 0) break;
        if (n < 0 && _libc.errno() != _eintr) return _libc.errno();
        if (DateTime.now().isAfter(deadline)) return _etimedout;
      }
      // getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
      if (_libc.getsockopt(fd, 1, 4, err, len) != 0) return _libc.errno();
      return err.value;
    } finally {
      calloc.free(pfd);
      calloc.free(err);
      calloc.free(len);
    }
  }

  /// Returns the socket fd, or -errno.
  static int _connectOnce(String mac, int channel) {
    final fd = _libc.socket(_afBluetooth, _sockStream, _btprotoRfcomm);
    if (fd < 0) return -_libc.errno();
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
      var e = _libc.connect(fd, addr, 10) == 0 ? 0 : _libc.errno();
      // The Dart VM's signals interrupt the blocking connect (EINTR); the
      // kernel keeps connecting in the background, so wait for it and fetch
      // the real result via SO_ERROR.
      if (e == _eintr || e == _einprogress || e == _ealready) e = _awaitConnect(fd);
      if (e != 0) {
        _libc.close(fd);
        return -e;
      }
      return fd;
    } finally {
      calloc.free(addr);
    }
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
        if (n < 0) {
          final e = _libc.errno();
          if (e == _eintr) continue;
          _dead = true;
          throw StateError('RFCOMM write failed (errno $e) — link lost, try again');
        }
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
      (pfd + 4).cast<Int16>().value = _pollIn;
      final sw = Stopwatch()..start();
      while (true) {
        final left = timeout.inMilliseconds - sw.elapsedMilliseconds;
        if (left <= 0) return Uint8List(0);
        final r = _libc.poll(pfd, 1, left);
        if (r > 0) break;
        if (r == 0) return Uint8List(0);
        if (_libc.errno() != _eintr) return Uint8List(0);
        // interrupted by a VM signal: poll again for the remaining time
      }
      final n = _libc.read(_fd, buf, 256);
      return n <= 0 ? Uint8List(0) : Uint8List.fromList(buf.asTypedList(n));
    } finally {
      calloc.free(pfd);
      malloc.free(buf);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_dead) {
      _libc.close(_fd);
      return;
    }
    // Keep the link up for the next print instead of re-paging the printer.
    _parked.remove(_mac)?.$2.cancel();
    _parked[_mac] = (
      _fd,
      Timer(keepAlive, () {
        if (_parked[_mac]?.$1 == _fd) _parked.remove(_mac);
        _libc.close(_fd);
      })
    );
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
        close = l.lookupFunction<Int32 Function(Int32), int Function(int)>('close'),
        getsockopt = l.lookupFunction<Int32 Function(Int32, Int32, Int32, Pointer<Int32>, Pointer<Uint32>),
            int Function(int, int, int, Pointer<Int32>, Pointer<Uint32>)>('getsockopt'),
        _errnoLocation = l.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>('__errno_location');

  final int Function(int, int, int) socket;
  final int Function(int, Pointer<Uint8>, int) connect;
  final int Function(int, Pointer<Uint8>, int) write;
  final int Function(int, Pointer<Uint8>, int) read;
  final int Function(Pointer<Uint8>, int, int) poll;
  final int Function(int) close;
  final int Function(int, int, int, Pointer<Int32>, Pointer<Uint32>) getsockopt;
  final Pointer<Int32> Function() _errnoLocation;
  int errno() => _errnoLocation().value;
}

final _libc = _Libc(DynamicLibrary.process());
