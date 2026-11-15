import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../core/printer_profile.dart';
import 'transport.dart';

/// Windows: raw I/O to USB printer-class devices through the inbox
/// usbprint.sys ("USB Printing Support") — no driver install, no Zadig, no
/// print queue. Device paths come from SetupAPI with
/// GUID_DEVINTERFACE_USBPRINT {28d78fad-5a12-11d1-ae5b-0000f803a8c2};
/// then CreateFile/WriteFile/ReadFile (same approach as the Rust `escpos`
/// crate's usbprint example, see docs/RESEARCH.md).
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
    for (final path in _Win.instance.usbPrintPaths()) {
      final m = RegExp(r'vid_([0-9a-f]{4})&pid_([0-9a-f]{4})', caseSensitive: false).firstMatch(path);
      final vid = m == null ? null : int.parse(m.group(1)!, radix: 16);
      final pid = m == null ? null : int.parse(m.group(2)!, radix: 16);
      final known = vid != null && PrinterProfile.vendorSdkUsbIds.contains((vid, pid));
      out.add(PrinterEndpoint(
        transport: name,
        id: path,
        label: 'USB printer ${m == null ? '' : '${m.group(1)}:${m.group(2)}'}${known ? ' ★' : ''}',
        usbVendorId: vid,
        usbProductId: pid,
      ));
    }
    return out;
  }

  @override
  Future<PrinterConnection> open(PrinterEndpoint endpoint) async => _UsbPrintConnection(_Win.instance.open(endpoint.id));
}

class _UsbPrintConnection implements PrinterConnection, PrinterStatusReader {
  _UsbPrintConnection(this._h);
  final int _h;

  @override
  Future<void> write(Uint8List data) async {
    _Win.instance.write(_h, data);
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<Uint8List> read({Duration timeout = const Duration(milliseconds: 500)}) async =>
      _Win.instance.read(_h, timeout);

  @override
  Future<void> close() async => _Win.instance.closeHandle(_h);
}

// ------------------------------------------------------------------ Win32 ---

final class _Guid extends Struct {
  @Uint32() external int data1;
  @Uint16() external int data2;
  @Uint16() external int data3;
  @Array(8) external Array<Uint8> data4;
}

final class _SpDeviceInterfaceData extends Struct {
  @Uint32() external int cbSize;
  external _Guid interfaceClassGuid;
  @Uint32() external int flags;
  @IntPtr() external int reserved;
}

final class _CommTimeouts extends Struct {
  @Uint32() external int readIntervalTimeout;
  @Uint32() external int readTotalTimeoutMultiplier;
  @Uint32() external int readTotalTimeoutConstant;
  @Uint32() external int writeTotalTimeoutMultiplier;
  @Uint32() external int writeTotalTimeoutConstant;
}

class _Win {
  _Win._() {
    final setupapi = DynamicLibrary.open('setupapi.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    _getClassDevs = setupapi.lookupFunction<IntPtr Function(Pointer<_Guid>, Pointer<Utf16>, IntPtr, Uint32),
        int Function(Pointer<_Guid>, Pointer<Utf16>, int, int)>('SetupDiGetClassDevsW');
    _enumInterfaces = setupapi.lookupFunction<
        Int32 Function(IntPtr, Pointer<Void>, Pointer<_Guid>, Uint32, Pointer<_SpDeviceInterfaceData>),
        int Function(int, Pointer<Void>, Pointer<_Guid>, int, Pointer<_SpDeviceInterfaceData>)>('SetupDiEnumDeviceInterfaces');
    _getDetail = setupapi.lookupFunction<
        Int32 Function(IntPtr, Pointer<_SpDeviceInterfaceData>, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
        int Function(int, Pointer<_SpDeviceInterfaceData>, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>(
        'SetupDiGetDeviceInterfaceDetailW');
    _destroyList = setupapi.lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetupDiDestroyDeviceInfoList');
    _createFile = kernel32.lookupFunction<
        IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr),
        int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)>('CreateFileW');
    _writeFile = kernel32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
        int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('WriteFile');
    _readFile = kernel32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
        int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('ReadFile');
    _closeHandle = kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
    _getLastError = kernel32.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
    _setCommTimeouts = kernel32.lookupFunction<Int32 Function(IntPtr, Pointer<_CommTimeouts>),
        int Function(int, Pointer<_CommTimeouts>)>('SetCommTimeouts');
  }

  static final instance = _Win._();

  late final int Function(Pointer<_Guid>, Pointer<Utf16>, int, int) _getClassDevs;
  late final int Function(int, Pointer<Void>, Pointer<_Guid>, int, Pointer<_SpDeviceInterfaceData>) _enumInterfaces;
  late final int Function(int, Pointer<_SpDeviceInterfaceData>, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>) _getDetail;
  late final int Function(int) _destroyList;
  late final int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int) _createFile;
  late final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>) _writeFile;
  late final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>) _readFile;
  late final int Function(int) _closeHandle;
  late final int Function() _getLastError;
  late final int Function(int, Pointer<_CommTimeouts>) _setCommTimeouts;

  static const _digcfPresent = 0x2, _digcfDeviceInterface = 0x10;
  static const _genericRead = 0x80000000, _genericWrite = 0x40000000;
  static const _fileShareRead = 1, _fileShareWrite = 2, _openExisting = 3;
  static const _invalidHandle = -1;

  Pointer<_Guid> _usbPrintGuid(Allocator a) {
    // {28d78fad-5a12-11d1-ae5b-0000f803a8c2}
    final g = a<_Guid>();
    g.ref
      ..data1 = 0x28d78fad
      ..data2 = 0x5a12
      ..data3 = 0x11d1;
    const d4 = [0xae, 0x5b, 0x00, 0x00, 0xf8, 0x03, 0xa8, 0xc2];
    for (var i = 0; i < 8; i++) {
      g.ref.data4[i] = d4[i];
    }
    return g;
  }

  List<String> usbPrintPaths() => using((arena) {
        final guid = _usbPrintGuid(arena);
        final set = _getClassDevs(guid, nullptr, 0, _digcfPresent | _digcfDeviceInterface);
        if (set == _invalidHandle) return const <String>[];
        final paths = <String>[];
        try {
          final ifData = arena<_SpDeviceInterfaceData>()..ref.cbSize = sizeOf<_SpDeviceInterfaceData>();
          final needed = arena<Uint32>();
          for (var i = 0; _enumInterfaces(set, nullptr, guid, i, ifData) != 0; i++) {
            _getDetail(set, ifData, nullptr, 0, needed, nullptr);
            if (needed.value == 0) continue;
            final buf = arena<Uint8>(needed.value);
            // SP_DEVICE_INTERFACE_DETAIL_DATA_W.cbSize: 8 on 64-bit, 6 on 32-bit
            buf.cast<Uint32>().value = sizeOf<IntPtr>() == 8 ? 8 : 6;
            if (_getDetail(set, ifData, buf, needed.value, nullptr, nullptr) == 0) continue;
            paths.add((buf + 4).cast<Utf16>().toDartString());
          }
        } finally {
          _destroyList(set);
        }
        return paths;
      });

  int open(String path) => using((arena) {
        final h = _createFile(path.toNativeUtf16(allocator: arena), _genericRead | _genericWrite,
            _fileShareRead | _fileShareWrite, nullptr, _openExisting, 0, 0);
        if (h == _invalidHandle) throw StateError('CreateFile($path) failed: error ${_getLastError()}');
        return h;
      });

  void write(int h, Uint8List data) => using((arena) {
        const max = 16384;
        final buf = arena<Uint8>(max);
        final written = arena<Uint32>();
        var off = 0;
        while (off < data.length) {
          final len = (data.length - off).clamp(0, max);
          buf.asTypedList(len).setRange(0, len, data, off);
          if (_writeFile(h, buf, len, written, nullptr) == 0) {
            throw StateError('WriteFile failed: error ${_getLastError()}');
          }
          off += written.value;
        }
      });

  Uint8List read(int h, Duration timeout) => using((arena) {
        // usbprint honours COMMTIMEOUTS for reads; ignore failure (blocking read risk is
        // then bounded by the device's own timeout).
        final t = arena<_CommTimeouts>()
          ..ref.readTotalTimeoutConstant = timeout.inMilliseconds
          ..ref.readIntervalTimeout = 0
          ..ref.readTotalTimeoutMultiplier = 0;
        _setCommTimeouts(h, t);
        final buf = arena<Uint8>(512);
        final got = arena<Uint32>();
        if (_readFile(h, buf, 512, got, nullptr) == 0) return Uint8List(0);
        return Uint8List.fromList(buf.asTypedList(got.value));
      });

  void closeHandle(int h) => _closeHandle(h);
}
