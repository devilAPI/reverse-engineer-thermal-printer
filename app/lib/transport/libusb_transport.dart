import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../core/printer_profile.dart';
import 'transport.dart';

/// Raw USB via libusb-1.0 (dart:ffi, no plugin) — Linux and macOS.
///
/// Finds any device with a bulk-OUT endpoint on a printer-class (0x07),
/// CDC-data (0x0A) or vendor (0xFF) interface, detaches the kernel driver
/// (usblp / cdc_acm) while printing, and reattaches it afterwards.
///
/// Linux: needs the udev rule in /linux. macOS: `brew install libusb`, or
/// bundle libusb-1.0.dylib with the app.
class LibusbTransport implements PrinterTransport {
  @override
  String get name => 'libusb';

  @override
  bool get isSupported => (Platform.isLinux || Platform.isMacOS) && _Libusb.instance != null;

  @override
  Future<List<PrinterEndpoint>> discover() async {
    final lib = _Libusb.instance!;
    return lib.withContext((ctx) {
      final out = <PrinterEndpoint>[];
      final listPtr = calloc<Pointer<Pointer<Void>>>();
      try {
        final n = lib.getDeviceList(ctx, listPtr);
        for (var i = 0; i < n; i++) {
          final dev = listPtr.value[i];
          final info = lib.describe(dev);
          if (info == null) continue;
          final known = PrinterProfile.vendorSdkUsbIds.contains((info.vid, info.pid));
          // Vendor-class interfaces are everywhere (phones/ADB, dongles): only
          // offer them for known printer controllers.
          if (info.ifClass == 0xFF && !known) continue;
          final cls = switch (info.ifClass) { 0x07 => 'printer', 0x0A => 'CDC', 0xFF => 'vendor', _ => '0x${info.ifClass.toRadixString(16)}' };
          out.add(PrinterEndpoint(
            transport: name,
            id: '${info.bus}:${info.address}:${_hex(info.vid)}:${_hex(info.pid)}',
            label: 'USB ${_hex(info.vid)}:${_hex(info.pid)} ($cls)${known ? ' ★' : ''}',
            usbVendorId: info.vid,
            usbProductId: info.pid,
          ));
        }
        if (n >= 0) lib.freeDeviceList(listPtr.value, 1);
      } finally {
        calloc.free(listPtr);
      }
      return out;
    });
  }

  @override
  Future<PrinterConnection> open(PrinterEndpoint endpoint) async {
    final lib = _Libusb.instance!;
    final parts = endpoint.id.split(':');
    final bus = int.parse(parts[0]), addr = int.parse(parts[1]);
    final ctxPtr = calloc<Pointer<Void>>();
    _check(lib.init(ctxPtr), 'libusb_init');
    final ctx = ctxPtr.value;
    calloc.free(ctxPtr);

    final listPtr = calloc<Pointer<Pointer<Void>>>();
    Pointer<Void>? handle;
    _DevInfo? info;
    try {
      final n = lib.getDeviceList(ctx, listPtr);
      for (var i = 0; i < n; i++) {
        final dev = listPtr.value[i];
        if (lib.getBusNumber(dev) == bus && lib.getDeviceAddress(dev) == addr) {
          info = lib.describe(dev);
          final hp = calloc<Pointer<Void>>();
          final r = lib.open(dev, hp);
          handle = hp.value;
          calloc.free(hp);
          _check(r, 'libusb_open (permission? install the udev rule)');
          break;
        }
      }
      if (n >= 0) lib.freeDeviceList(listPtr.value, 1);
    } finally {
      calloc.free(listPtr);
    }
    if (handle == null || info == null) {
      lib.exit(ctx);
      throw StateError('USB device ${endpoint.id} is gone');
    }
    var detached = false;
    if (lib.kernelDriverActive(handle, info.ifNumber) == 1) {
      _check(lib.detachKernelDriver(handle, info.ifNumber), 'detach kernel driver');
      detached = true;
    }
    final c = lib.claimInterface(handle, info.ifNumber);
    if (c < 0) {
      if (detached) lib.attachKernelDriver(handle, info.ifNumber);
      lib.close(handle);
      lib.exit(ctx);
      _check(c, 'claim interface');
    }
    return _LibusbConnection(lib, ctx, handle, info, detached);
  }

  static String _hex(int v) => v.toRadixString(16).padLeft(4, '0');
}

class _LibusbConnection implements PrinterConnection, PrinterStatusReader {
  _LibusbConnection(this._lib, this._ctx, this._h, this._info, this._detached);
  final _Libusb _lib;
  final Pointer<Void> _ctx;
  final Pointer<Void> _h;
  final _DevInfo _info;
  final bool _detached;

  @override
  Future<void> write(Uint8List data) async {
    const max = 16384;
    final buf = malloc<Uint8>(max);
    final transferred = calloc<Int32>();
    try {
      var off = 0;
      while (off < data.length) {
        final len = (data.length - off).clamp(0, max);
        buf.asTypedList(len).setRange(0, len, data, off);
        _check(_lib.bulkTransfer(_h, _info.epOut, buf, len, transferred, 10000), 'bulk write');
        off += transferred.value;
        // Yield so the UI stays responsive between blocking transfers.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      malloc.free(buf);
      calloc.free(transferred);
    }
  }

  @override
  Future<Uint8List> read({Duration timeout = const Duration(milliseconds: 500)}) async {
    final ep = _info.epIn;
    if (ep == null) return Uint8List(0);
    final buf = malloc<Uint8>(512);
    final transferred = calloc<Int32>();
    try {
      final r = _lib.bulkTransfer(_h, ep, buf, 512, transferred, timeout.inMilliseconds);
      if (r < 0 && r != _Libusb.errorTimeout) _check(r, 'bulk read');
      return Uint8List.fromList(buf.asTypedList(transferred.value));
    } finally {
      malloc.free(buf);
      calloc.free(transferred);
    }
  }

  @override
  Future<void> close() async {
    _lib.releaseInterface(_h, _info.ifNumber);
    if (_detached) _lib.attachKernelDriver(_h, _info.ifNumber);
    _lib.close(_h);
    _lib.exit(_ctx);
  }
}

void _check(int r, String what) {
  if (r < 0) throw StateError('$what failed: libusb error $r');
}

class _DevInfo {
  _DevInfo(this.vid, this.pid, this.bus, this.address, this.ifNumber, this.ifClass, this.epOut, this.epIn);
  final int vid, pid, bus, address, ifNumber, ifClass, epOut;
  final int? epIn;
}

// ---------------------------------------------------------------- libusb FFI --

// struct libusb_device_descriptor (18 bytes, packed on byte boundaries)
final class _DeviceDescriptor extends Struct {
  @Uint8() external int bLength;
  @Uint8() external int bDescriptorType;
  @Uint16() external int bcdUSB;
  @Uint8() external int bDeviceClass;
  @Uint8() external int bDeviceSubClass;
  @Uint8() external int bDeviceProtocol;
  @Uint8() external int bMaxPacketSize0;
  @Uint16() external int idVendor;
  @Uint16() external int idProduct;
  @Uint16() external int bcdDevice;
  @Uint8() external int iManufacturer;
  @Uint8() external int iProduct;
  @Uint8() external int iSerialNumber;
  @Uint8() external int bNumConfigurations;
}

final class _EndpointDescriptor extends Struct {
  @Uint8() external int bLength;
  @Uint8() external int bDescriptorType;
  @Uint8() external int bEndpointAddress;
  @Uint8() external int bmAttributes;
  @Uint16() external int wMaxPacketSize;
  @Uint8() external int bInterval;
  @Uint8() external int bRefresh;
  @Uint8() external int bSynchAddress;
  external Pointer<Uint8> extra;
  @Int32() external int extraLength;
}

final class _InterfaceDescriptor extends Struct {
  @Uint8() external int bLength;
  @Uint8() external int bDescriptorType;
  @Uint8() external int bInterfaceNumber;
  @Uint8() external int bAlternateSetting;
  @Uint8() external int bNumEndpoints;
  @Uint8() external int bInterfaceClass;
  @Uint8() external int bInterfaceSubClass;
  @Uint8() external int bInterfaceProtocol;
  @Uint8() external int iInterface;
  external Pointer<_EndpointDescriptor> endpoint;
  external Pointer<Uint8> extra;
  @Int32() external int extraLength;
}

final class _Interface extends Struct {
  external Pointer<_InterfaceDescriptor> altsetting;
  @Int32() external int numAltsetting;
}

final class _ConfigDescriptor extends Struct {
  @Uint8() external int bLength;
  @Uint8() external int bDescriptorType;
  @Uint16() external int wTotalLength;
  @Uint8() external int bNumInterfaces;
  @Uint8() external int bConfigurationValue;
  @Uint8() external int iConfiguration;
  @Uint8() external int bmAttributes;
  @Uint8() external int maxPower;
  external Pointer<_Interface> interface;
  external Pointer<Uint8> extra;
  @Int32() external int extraLength;
}

typedef _Ctx = Pointer<Void>;
typedef _Dev = Pointer<Void>;
typedef _Handle = Pointer<Void>;

class _Libusb {
  _Libusb(DynamicLibrary l)
      : init = l.lookupFunction<Int32 Function(Pointer<_Ctx>), int Function(Pointer<_Ctx>)>('libusb_init'),
        exit = l.lookupFunction<Void Function(_Ctx), void Function(_Ctx)>('libusb_exit'),
        getDeviceList = l.lookupFunction<IntPtr Function(_Ctx, Pointer<Pointer<_Dev>>), int Function(_Ctx, Pointer<Pointer<_Dev>>)>(
            'libusb_get_device_list'),
        freeDeviceList =
            l.lookupFunction<Void Function(Pointer<_Dev>, Int32), void Function(Pointer<_Dev>, int)>('libusb_free_device_list'),
        getDeviceDescriptor = l.lookupFunction<Int32 Function(_Dev, Pointer<_DeviceDescriptor>),
            int Function(_Dev, Pointer<_DeviceDescriptor>)>('libusb_get_device_descriptor'),
        getActiveConfig = l.lookupFunction<Int32 Function(_Dev, Pointer<Pointer<_ConfigDescriptor>>),
            int Function(_Dev, Pointer<Pointer<_ConfigDescriptor>>)>('libusb_get_active_config_descriptor'),
        getConfigByIndex = l.lookupFunction<Int32 Function(_Dev, Uint8, Pointer<Pointer<_ConfigDescriptor>>),
            int Function(_Dev, int, Pointer<Pointer<_ConfigDescriptor>>)>('libusb_get_config_descriptor'),
        freeConfig = l.lookupFunction<Void Function(Pointer<_ConfigDescriptor>), void Function(Pointer<_ConfigDescriptor>)>(
            'libusb_free_config_descriptor'),
        getBusNumber = l.lookupFunction<Uint8 Function(_Dev), int Function(_Dev)>('libusb_get_bus_number'),
        getDeviceAddress = l.lookupFunction<Uint8 Function(_Dev), int Function(_Dev)>('libusb_get_device_address'),
        open = l.lookupFunction<Int32 Function(_Dev, Pointer<_Handle>), int Function(_Dev, Pointer<_Handle>)>('libusb_open'),
        close = l.lookupFunction<Void Function(_Handle), void Function(_Handle)>('libusb_close'),
        kernelDriverActive =
            l.lookupFunction<Int32 Function(_Handle, Int32), int Function(_Handle, int)>('libusb_kernel_driver_active'),
        detachKernelDriver =
            l.lookupFunction<Int32 Function(_Handle, Int32), int Function(_Handle, int)>('libusb_detach_kernel_driver'),
        attachKernelDriver =
            l.lookupFunction<Int32 Function(_Handle, Int32), int Function(_Handle, int)>('libusb_attach_kernel_driver'),
        claimInterface = l.lookupFunction<Int32 Function(_Handle, Int32), int Function(_Handle, int)>('libusb_claim_interface'),
        releaseInterface =
            l.lookupFunction<Int32 Function(_Handle, Int32), int Function(_Handle, int)>('libusb_release_interface'),
        bulkTransfer = l.lookupFunction<Int32 Function(_Handle, Uint8, Pointer<Uint8>, Int32, Pointer<Int32>, Uint32),
            int Function(_Handle, int, Pointer<Uint8>, int, Pointer<Int32>, int)>('libusb_bulk_transfer');

  static const errorTimeout = -7;

  static final _Libusb? instance = () {
    for (final name in [
      if (Platform.isLinux) ...['libusb-1.0.so.0', 'libusb-1.0.so'],
      if (Platform.isMacOS) ...[
        'libusb-1.0.0.dylib',
        '/opt/homebrew/lib/libusb-1.0.0.dylib',
        '/usr/local/lib/libusb-1.0.0.dylib',
      ],
    ]) {
      try {
        return _Libusb(DynamicLibrary.open(name));
      } on Object {
        continue;
      }
    }
    return null;
  }();

  final int Function(Pointer<_Ctx>) init;
  final void Function(_Ctx) exit;
  final int Function(_Ctx, Pointer<Pointer<_Dev>>) getDeviceList;
  final void Function(Pointer<_Dev>, int) freeDeviceList;
  final int Function(_Dev, Pointer<_DeviceDescriptor>) getDeviceDescriptor;
  final int Function(_Dev, Pointer<Pointer<_ConfigDescriptor>>) getActiveConfig;
  final int Function(_Dev, int, Pointer<Pointer<_ConfigDescriptor>>) getConfigByIndex;
  final void Function(Pointer<_ConfigDescriptor>) freeConfig;
  final int Function(_Dev) getBusNumber;
  final int Function(_Dev) getDeviceAddress;
  final int Function(_Dev, Pointer<_Handle>) open;
  final void Function(_Handle) close;
  final int Function(_Handle, int) kernelDriverActive;
  final int Function(_Handle, int) detachKernelDriver;
  final int Function(_Handle, int) attachKernelDriver;
  final int Function(_Handle, int) claimInterface;
  final int Function(_Handle, int) releaseInterface;
  final int Function(_Handle, int, Pointer<Uint8>, int, Pointer<Int32>, int) bulkTransfer;

  T withContext<T>(T Function(_Ctx ctx) body) {
    final p = calloc<_Ctx>();
    _check(init(p), 'libusb_init');
    final ctx = p.value;
    calloc.free(p);
    try {
      return body(ctx);
    } finally {
      exit(ctx);
    }
  }

  /// Printer-like interface on [dev], or null. Reads cached descriptors
  /// (no device open needed, so works without permissions for listing).
  _DevInfo? describe(_Dev dev) {
    final dd = calloc<_DeviceDescriptor>();
    final cfgPtr = calloc<Pointer<_ConfigDescriptor>>();
    try {
      if (getDeviceDescriptor(dev, dd) < 0) return null;
      final d = dd.ref;
      if (d.bDeviceClass == 0x09) return null; // hub
      var r = getActiveConfig(dev, cfgPtr);
      if (r < 0) r = getConfigByIndex(dev, 0, cfgPtr);
      if (r < 0) return null;
      final cfg = cfgPtr.value.ref;
      _DevInfo? best;
      var bestRank = 99;
      for (var i = 0; i < cfg.bNumInterfaces; i++) {
        final itf = cfg.interface[i];
        if (itf.numAltsetting < 1) continue;
        final alt = itf.altsetting[0];
        final rank = switch (alt.bInterfaceClass) { 0x07 => 0, 0x0A => 1, 0xFF => 2, _ => 99 };
        if (rank >= bestRank) continue;
        int? out, inp;
        for (var e = 0; e < alt.bNumEndpoints; e++) {
          final ep = alt.endpoint[e];
          if ((ep.bmAttributes & 3) != 2) continue; // bulk only
          if (ep.bEndpointAddress & 0x80 != 0) {
            inp ??= ep.bEndpointAddress;
          } else {
            out ??= ep.bEndpointAddress;
          }
        }
        if (out == null) continue;
        bestRank = rank;
        best = _DevInfo(d.idVendor, d.idProduct, getBusNumber(dev), getDeviceAddress(dev), alt.bInterfaceNumber,
            alt.bInterfaceClass, out, inp);
      }
      freeConfig(cfgPtr.value);
      return best;
    } finally {
      calloc.free(dd);
      calloc.free(cfgPtr);
    }
  }
}
