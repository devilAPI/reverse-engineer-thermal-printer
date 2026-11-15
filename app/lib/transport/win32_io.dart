import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Minimal Win32 bindings shared by the Windows transports (dart:ffi, no
/// plugin): SetupAPI device enumeration and overlapped (timeout-safe) file
/// I/O on device handles. Only touched when running on Windows.
///
/// All I/O is OVERLAPPED: every read/write waits on an event with a timeout
/// and is cancelled (CancelIoEx) if the device does not answer, so a printer
/// that never replies to a status query can't hang the app.
///
/// UNVERIFIED on hardware: developed on Linux, compiled by CI.

final class Guid extends Struct {
  @Uint32()
  external int data1;
  @Uint16()
  external int data2;
  @Uint16()
  external int data3;
  @Array(8)
  external Array<Uint8> data4;

  void set(int d1, int d2, int d3, List<int> d4) {
    data1 = d1;
    data2 = d2;
    data3 = d3;
    for (var i = 0; i < 8; i++) {
      data4[i] = d4[i];
    }
  }
}

final class _SpDeviceInterfaceData extends Struct {
  @Uint32()
  external int cbSize;
  external Guid interfaceClassGuid;
  @Uint32()
  external int flags;
  @IntPtr()
  external int reserved;
}

final class _SpDevinfoData extends Struct {
  @Uint32()
  external int cbSize;
  external Guid classGuid;
  @Uint32()
  external int devInst;
  @IntPtr()
  external int reserved;
}

/// OVERLAPPED: Internal, InternalHigh (ULONG_PTR), Offset, OffsetHigh (DWORD), hEvent.
final class _Overlapped extends Struct {
  @IntPtr()
  external int internal;
  @IntPtr()
  external int internalHigh;
  @Uint32()
  external int offset;
  @Uint32()
  external int offsetHigh;
  @IntPtr()
  external int hEvent;
}

final class _CommTimeouts extends Struct {
  @Uint32()
  external int readIntervalTimeout;
  @Uint32()
  external int readTotalTimeoutMultiplier;
  @Uint32()
  external int readTotalTimeoutConstant;
  @Uint32()
  external int writeTotalTimeoutMultiplier;
  @Uint32()
  external int writeTotalTimeoutConstant;
}

/// A present device interface: its openable path plus registry details.
class WinDevice {
  WinDevice(this.path, {this.friendlyName, this.hardwareId, this.instanceId});
  final String path;
  final String? friendlyName;
  final String? hardwareId;
  final String? instanceId;
}

class Win32 {
  Win32._() {
    final setupapi = DynamicLibrary.open('setupapi.dll');
    final k = DynamicLibrary.open('kernel32.dll');
    _getClassDevs = setupapi
        .lookupFunction<
          IntPtr Function(Pointer<Guid>, Pointer<Utf16>, IntPtr, Uint32),
          int Function(Pointer<Guid>, Pointer<Utf16>, int, int)
        >('SetupDiGetClassDevsW');
    _enumInterfaces = setupapi
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<Void>, Pointer<Guid>, Uint32, Pointer<_SpDeviceInterfaceData>),
          int Function(int, Pointer<Void>, Pointer<Guid>, int, Pointer<_SpDeviceInterfaceData>)
        >('SetupDiEnumDeviceInterfaces');
    _getDetail = setupapi
        .lookupFunction<
          Int32 Function(
            IntPtr,
            Pointer<_SpDeviceInterfaceData>,
            Pointer<Uint8>,
            Uint32,
            Pointer<Uint32>,
            Pointer<_SpDevinfoData>,
          ),
          int Function(
            int,
            Pointer<_SpDeviceInterfaceData>,
            Pointer<Uint8>,
            int,
            Pointer<Uint32>,
            Pointer<_SpDevinfoData>,
          )
        >('SetupDiGetDeviceInterfaceDetailW');
    _getRegProp = setupapi
        .lookupFunction<
          Int32 Function(
            IntPtr,
            Pointer<_SpDevinfoData>,
            Uint32,
            Pointer<Uint32>,
            Pointer<Uint8>,
            Uint32,
            Pointer<Uint32>,
          ),
          int Function(int, Pointer<_SpDevinfoData>, int, Pointer<Uint32>, Pointer<Uint8>, int, Pointer<Uint32>)
        >('SetupDiGetDeviceRegistryPropertyW');
    _getInstanceId = setupapi
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<_SpDevinfoData>, Pointer<Utf16>, Uint32, Pointer<Uint32>),
          int Function(int, Pointer<_SpDevinfoData>, Pointer<Utf16>, int, Pointer<Uint32>)
        >('SetupDiGetDeviceInstanceIdW');
    _destroyList = setupapi.lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetupDiDestroyDeviceInfoList');
    _createFile = k
        .lookupFunction<
          IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr),
          int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
        >('CreateFileW');
    _writeFile = k
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<_Overlapped>),
          int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<_Overlapped>)
        >('WriteFile');
    _readFile = k
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<_Overlapped>),
          int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<_Overlapped>)
        >('ReadFile');
    _getOverlappedResult = k
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<_Overlapped>, Pointer<Uint32>, Int32),
          int Function(int, Pointer<_Overlapped>, Pointer<Uint32>, int)
        >('GetOverlappedResult');
    _cancelIoEx = k
        .lookupFunction<Int32 Function(IntPtr, Pointer<_Overlapped>), int Function(int, Pointer<_Overlapped>)>(
          'CancelIoEx',
        );
    _createEvent = k
        .lookupFunction<
          IntPtr Function(Pointer<Void>, Int32, Int32, Pointer<Utf16>),
          int Function(Pointer<Void>, int, int, Pointer<Utf16>)
        >('CreateEventW');
    _waitForSingleObject = k.lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>(
      'WaitForSingleObject',
    );
    closeHandle = k.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
    _getLastError = k.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
    _setCommTimeouts = k
        .lookupFunction<Int32 Function(IntPtr, Pointer<_CommTimeouts>), int Function(int, Pointer<_CommTimeouts>)>(
          'SetCommTimeouts',
        );
    _getCommState = k.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>(
      'GetCommState',
    );
    _setCommState = k.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>(
      'SetCommState',
    );
    _buildCommDcb = k
        .lookupFunction<Int32 Function(Pointer<Utf16>, Pointer<Uint8>), int Function(Pointer<Utf16>, Pointer<Uint8>)>(
          'BuildCommDCBW',
        );
  }

  static final instance = Win32._();

  late final int Function(Pointer<Guid>, Pointer<Utf16>, int, int) _getClassDevs;
  late final int Function(int, Pointer<Void>, Pointer<Guid>, int, Pointer<_SpDeviceInterfaceData>) _enumInterfaces;
  late final int Function(
    int,
    Pointer<_SpDeviceInterfaceData>,
    Pointer<Uint8>,
    int,
    Pointer<Uint32>,
    Pointer<_SpDevinfoData>,
  )
  _getDetail;
  late final int Function(int, Pointer<_SpDevinfoData>, int, Pointer<Uint32>, Pointer<Uint8>, int, Pointer<Uint32>)
  _getRegProp;
  late final int Function(int, Pointer<_SpDevinfoData>, Pointer<Utf16>, int, Pointer<Uint32>) _getInstanceId;
  late final int Function(int) _destroyList;
  late final int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int) _createFile;
  late final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<_Overlapped>) _writeFile;
  late final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<_Overlapped>) _readFile;
  late final int Function(int, Pointer<_Overlapped>, Pointer<Uint32>, int) _getOverlappedResult;
  late final int Function(int, Pointer<_Overlapped>) _cancelIoEx;
  late final int Function(Pointer<Void>, int, int, Pointer<Utf16>) _createEvent;
  late final int Function(int, int) _waitForSingleObject;
  late final int Function(int) closeHandle;
  late final int Function() _getLastError;
  late final int Function(int, Pointer<_CommTimeouts>) _setCommTimeouts;
  late final int Function(int, Pointer<Uint8>) _getCommState;
  late final int Function(int, Pointer<Uint8>) _setCommState;
  late final int Function(Pointer<Utf16>, Pointer<Uint8>) _buildCommDcb;

  static const _digcfPresent = 0x2, _digcfDeviceInterface = 0x10;
  static const _spdrpHardwareId = 0x1, _spdrpFriendlyName = 0xC;
  static const _genericRead = 0x80000000, _genericWrite = 0x40000000;
  static const _fileShareRead = 1, _fileShareWrite = 2, _openExisting = 3;
  static const _fileFlagOverlapped = 0x40000000;
  static const _invalidHandle = -1;
  static const _errorIoPending = 997;
  static const _waitObject0 = 0;

  /// GUID_DEVINTERFACE_USBPRINT {28d78fad-5a12-11d1-ae5b-0000f803a8c2}
  static void usbPrintGuid(Guid g) =>
      g.set(0x28d78fad, 0x5a12, 0x11d1, const [0xae, 0x5b, 0x00, 0x00, 0xf8, 0x03, 0xa8, 0xc2]);

  /// GUID_DEVINTERFACE_COMPORT {86e0d1e0-8089-11d0-9ce4-08003e301f73}
  static void comPortGuid(Guid g) =>
      g.set(0x86e0d1e0, 0x8089, 0x11d0, const [0x9c, 0xe4, 0x08, 0x00, 0x3e, 0x30, 0x1f, 0x73]);

  /// Present device interfaces of the class [setGuid] fills in.
  List<WinDevice> devices(void Function(Guid) setGuid) => using((arena) {
    final guid = arena<Guid>();
    setGuid(guid.ref);
    final set = _getClassDevs(guid, nullptr, 0, _digcfPresent | _digcfDeviceInterface);
    if (set == _invalidHandle) return const <WinDevice>[];
    final out = <WinDevice>[];
    try {
      final ifData = arena<_SpDeviceInterfaceData>()..ref.cbSize = sizeOf<_SpDeviceInterfaceData>();
      final needed = arena<Uint32>();
      for (var i = 0; _enumInterfaces(set, nullptr, guid, i, ifData) != 0; i++) {
        needed.value = 0;
        _getDetail(set, ifData, nullptr, 0, needed, nullptr);
        if (needed.value == 0) continue;
        final buf = arena<Uint8>(needed.value);
        // SP_DEVICE_INTERFACE_DETAIL_DATA_W.cbSize: 8 on 64-bit, 6 on 32-bit
        buf.cast<Uint32>().value = sizeOf<IntPtr>() == 8 ? 8 : 6;
        final devinfo = arena<_SpDevinfoData>()..ref.cbSize = sizeOf<_SpDevinfoData>();
        if (_getDetail(set, ifData, buf, needed.value, nullptr, devinfo) == 0) continue;
        out.add(
          WinDevice(
            (buf + 4).cast<Utf16>().toDartString(),
            friendlyName: _regString(arena, set, devinfo, _spdrpFriendlyName),
            hardwareId: _regString(arena, set, devinfo, _spdrpHardwareId),
            instanceId: _instanceId(arena, set, devinfo),
          ),
        );
      }
    } finally {
      _destroyList(set);
    }
    return out;
  });

  String? _regString(Arena a, int set, Pointer<_SpDevinfoData> d, int prop) {
    const size = 1024;
    final buf = a<Uint8>(size);
    if (_getRegProp(set, d, prop, nullptr, buf, size, nullptr) == 0) return null;
    // REG_SZ / REG_MULTI_SZ: first string is enough
    return buf.cast<Utf16>().toDartString();
  }

  String? _instanceId(Arena a, int set, Pointer<_SpDevinfoData> d) {
    const chars = 512;
    final buf = a<Uint16>(chars).cast<Utf16>();
    if (_getInstanceId(set, d, buf, chars, nullptr) == 0) return null;
    return buf.toDartString();
  }

  /// Open a device path (or `\\.\COMn`) for overlapped read/write.
  int open(String path) => using((arena) {
    final h = _createFile(
      path.toNativeUtf16(allocator: arena),
      _genericRead | _genericWrite,
      _fileShareRead | _fileShareWrite,
      nullptr,
      _openExisting,
      _fileFlagOverlapped,
      0,
    );
    if (h == _invalidHandle) throw StateError('CreateFile($path) failed: error ${_getLastError()}');
    return h;
  });

  /// Configure a COM port: 115200 8N1 (ignored by USB/Bluetooth virtual
  /// ports, but some drivers reject I/O until a DCB is set) and
  /// return-immediately read timeouts (our own wait does the timing).
  void configureComPort(int h) => using((arena) {
    final dcb = arena<Uint8>(64); // sizeof(DCB) = 28
    dcb.cast<Uint32>().value = 28;
    if (_getCommState(h, dcb) != 0 &&
        _buildCommDcb('baud=115200 parity=N data=8 stop=1'.toNativeUtf16(allocator: arena), dcb) != 0) {
      _setCommState(h, dcb);
    }
    final t = arena<_CommTimeouts>()
      ..ref.readIntervalTimeout =
          0xFFFFFFFF // with multiplier/constant: return as soon as bytes arrive
      ..ref.readTotalTimeoutMultiplier = 0xFFFFFFFF
      ..ref.readTotalTimeoutConstant = 1000
      ..ref.writeTotalTimeoutMultiplier = 0
      ..ref.writeTotalTimeoutConstant = 15000;
    _setCommTimeouts(h, t);
  });

  /// Write all of [data]; throws on error or if a chunk takes longer than [timeout].
  void write(int h, Uint8List data, {Duration timeout = const Duration(seconds: 15)}) => using((arena) {
    const max = 16384;
    final buf = arena<Uint8>(max);
    var off = 0;
    while (off < data.length) {
      final len = (data.length - off).clamp(0, max);
      buf.asTypedList(len).setRange(0, len, data, off);
      final n = _io(arena, h, buf, len, timeout, write: true);
      if (n < 0) throw StateError('WriteFile timed out — printer busy, offline or out of paper?');
      if (n == 0) throw StateError('WriteFile wrote nothing');
      off += n;
    }
  });

  /// Read whatever arrives within [timeout]; empty if nothing does.
  Uint8List read(int h, Duration timeout) => using((arena) {
    final buf = arena<Uint8>(512);
    final n = _io(arena, h, buf, 512, timeout, write: false);
    return n <= 0 ? Uint8List(0) : Uint8List.fromList(buf.asTypedList(n));
  });

  /// One overlapped transfer. Returns bytes transferred, or -1 on timeout
  /// (the request is cancelled before returning). Throws on other errors.
  int _io(Arena arena, int h, Pointer<Uint8> buf, int len, Duration timeout, {required bool write, int offset = 0}) {
    final ev = _createEvent(nullptr, 1, 0, nullptr);
    if (ev == 0) throw StateError('CreateEvent failed: error ${_getLastError()}');
    try {
      final ov = arena<_Overlapped>()
        ..ref.internal = 0
        ..ref.internalHigh = 0
        ..ref.offset = offset & 0xFFFFFFFF
        ..ref.offsetHigh = offset >> 32
        ..ref.hEvent = ev;
      final n = arena<Uint32>()..value = 0;
      final ok = write ? _writeFile(h, buf, len, nullptr, ov) : _readFile(h, buf, len, nullptr, ov);
      if (ok == 0) {
        final err = _getLastError();
        if (err != _errorIoPending) throw StateError('${write ? 'WriteFile' : 'ReadFile'} failed: error $err');
        if (_waitForSingleObject(ev, timeout.inMilliseconds) != _waitObject0) {
          _cancelIoEx(h, ov);
          _getOverlappedResult(h, ov, n, 1); // wait for the cancellation to finish
          return -1;
        }
      }
      if (_getOverlappedResult(h, ov, n, 0) == 0) {
        throw StateError('${write ? 'write' : 'read'} failed: error ${_getLastError()}');
      }
      return n.value;
    } finally {
      closeHandle(ev);
    }
  }
}
