// Minimal js_interop bindings for the browser device APIs used to reach
// printers: Web Serial, WebUSB and Web Bluetooth. Only what we call.
//
// Availability (2026): Chromium desktop (Chrome, Edge, Brave, Opera) has all
// three; Chrome on Android has WebUSB + Web Bluetooth; Firefox and Safari have
// none, so they print through the desktop app's bridge (bridge_transport.dart).
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('navigator')
external JSObject get _navigator;

bool _has(String name) => _navigator.has(name) && _navigator[name] != null;

bool get hasWebSerial => _has('serial');
bool get hasWebUsb => _has('usb');
bool get hasWebBluetooth => _has('bluetooth');

/// Best-effort browser name for messages.
String get browserName {
  final ua = (_navigator['userAgent'] as JSString?)?.toDart ?? '';
  if (ua.contains('Firefox/')) return 'Firefox';
  if (ua.contains('Edg/')) return 'Edge';
  if (ua.contains('Chrome/') || ua.contains('Chromium/')) return 'Chrome';
  if (ua.contains('Safari/')) return 'Safari';
  return 'this browser';
}

bool get isLinux => ((_navigator['userAgent'] as JSString?)?.toDart ?? '').contains('Linux') && !isAndroid;
bool get isAndroid => ((_navigator['userAgent'] as JSString?)?.toDart ?? '').contains('Android');

// ---------------------------------------------------------------- streams

extension type JSWritableStream._(JSObject _) implements JSObject {
  external JSWritableStreamWriter getWriter();
}

extension type JSWritableStreamWriter._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(JSUint8Array chunk);
  external JSPromise<JSAny?> get ready;
  external void releaseLock();
}

extension type JSReadableStream._(JSObject _) implements JSObject {
  external JSReadableStreamReader getReader();
}

extension type JSReadResult._(JSObject _) implements JSObject {
  external JSUint8Array? get value;
  external bool get done;
}

extension type JSReadableStreamReader._(JSObject _) implements JSObject {
  external JSPromise<JSReadResult> read();
  external JSPromise<JSAny?> cancel();
  external void releaseLock();
}

// ------------------------------------------------------------- Web Serial

@JS('navigator.serial')
external JSSerial get serial;

extension type JSSerial._(JSObject _) implements JSObject {
  external JSPromise<JSSerialPort> requestPort([JSObject? options]);
  external JSPromise<JSArray<JSSerialPort>> getPorts();
}

extension type JSSerialPortInfo._(JSObject _) implements JSObject {
  external int? get usbVendorId;
  external int? get usbProductId;
  external String? get bluetoothServiceClassId;
}

extension type JSSerialPort._(JSObject _) implements JSObject {
  external JSSerialPortInfo getInfo();
  external JSPromise<JSAny?> open(JSObject options);
  external JSPromise<JSAny?> close();
  external JSReadableStream? get readable;
  external JSWritableStream? get writable;
}

// ----------------------------------------------------------------- WebUSB

@JS('navigator.usb')
external JSUsb get usb;

extension type JSUsb._(JSObject _) implements JSObject {
  external JSPromise<JSUsbDevice> requestDevice(JSObject options);
  external JSPromise<JSArray<JSUsbDevice>> getDevices();
}

extension type JSUsbDevice._(JSObject _) implements JSObject {
  external int get vendorId;
  external int get productId;
  external String? get productName;
  external String? get manufacturerName;
  external String? get serialNumber;
  external bool get opened;
  external JSUsbConfiguration? get configuration;
  external JSArray<JSUsbConfiguration> get configurations;
  external JSPromise<JSAny?> open();
  external JSPromise<JSAny?> close();
  external JSPromise<JSAny?> selectConfiguration(int value);
  external JSPromise<JSAny?> claimInterface(int number);
  external JSPromise<JSAny?> releaseInterface(int number);
  external JSPromise<JSUsbOutResult> transferOut(int endpoint, JSUint8Array data);
  external JSPromise<JSUsbInResult> transferIn(int endpoint, int length);
}

extension type JSUsbConfiguration._(JSObject _) implements JSObject {
  external int get configurationValue;
  external JSArray<JSUsbInterface> get interfaces;
}

extension type JSUsbInterface._(JSObject _) implements JSObject {
  external int get interfaceNumber;
  external JSUsbAlternate get alternate;
}

extension type JSUsbAlternate._(JSObject _) implements JSObject {
  external int get interfaceClass;
  external int get interfaceSubclass;
  external JSArray<JSUsbEndpoint> get endpoints;
}

extension type JSUsbEndpoint._(JSObject _) implements JSObject {
  external int get endpointNumber;
  external String get direction; // "in" | "out"
  external String get type; // "bulk" | "interrupt" | "isochronous"
  external int get packetSize;
}

extension type JSUsbOutResult._(JSObject _) implements JSObject {
  external int get bytesWritten;
  external String get status;
}

extension type JSUsbInResult._(JSObject _) implements JSObject {
  external JSDataView? get data;
  external String get status;
}

// ---------------------------------------------------------- Web Bluetooth

@JS('navigator.bluetooth')
external JSBluetooth get bluetooth;

extension type JSBluetooth._(JSObject _) implements JSObject {
  external JSPromise<JSBluetoothDevice> requestDevice(JSObject options);
  external JSPromise<JSBoolean> getAvailability();
}

/// `navigator.bluetooth.getDevices()` only exists with the
/// "new permissions backend" (Chrome flag on some platforms).
bool get hasBluetoothGetDevices => hasWebBluetooth && (_navigator['bluetooth'] as JSObject).has('getDevices');

@JS('navigator.bluetooth.getDevices')
external JSPromise<JSArray<JSBluetoothDevice>> bluetoothGetDevices();

extension type JSBluetoothDevice._(JSObject _) implements JSObject {
  external String get id;
  external String? get name;
  external JSGattServer? get gatt;
}

extension type JSGattServer._(JSObject _) implements JSObject {
  external bool get connected;
  external JSPromise<JSGattServer> connect();
  external void disconnect();
  external JSPromise<JSGattService> getPrimaryService(String uuid);
  external JSPromise<JSArray<JSGattService>> getPrimaryServices();
}

extension type JSGattService._(JSObject _) implements JSObject {
  external String get uuid;
  external JSPromise<JSArray<JSGattCharacteristic>> getCharacteristics();
}

extension type JSGattCharacteristic._(JSObject _) implements JSObject {
  external String get uuid;
  external JSCharacteristicProperties get properties;
  external JSPromise<JSAny?> writeValueWithoutResponse(JSUint8Array value);
  external JSPromise<JSAny?> writeValueWithResponse(JSUint8Array value);
  external JSPromise<JSGattCharacteristic> startNotifications();
  external JSDataView? get value;
}

extension type JSCharacteristicProperties._(JSObject _) implements JSObject {
  external bool get write;
  external bool get writeWithoutResponse;
  external bool get notify;
}

/// Error text of a rejected JS promise, e.g. "NotFoundError: No port
/// selected by the user." Works for dart2js and dart2wasm.
String jsErrorText(Object e) {
  try {
    final a = e as JSAny?;
    if (a != null && a.isA<JSObject>()) {
      final o = a as JSObject;
      final name = o['name'], msg = o['message'];
      if (name.isA<JSString>() || msg.isA<JSString>()) {
        return [
          if (name.isA<JSString>()) (name as JSString).toDart,
          if (msg.isA<JSString>()) (msg as JSString).toDart,
        ].join(': ');
      }
    }
  } on Object {
    // a plain Dart error
  }
  return '$e';
}

/// True for the DOMException a browser throws when the user closes a chooser.
bool isChooserCancelled(Object e) {
  final t = jsErrorText(e);
  return t.startsWith('NotFoundError') || t.contains('No port selected') || t.contains('cancelled');
}

// ----------------------------------------------------------- localStorage

@JS('localStorage')
external JSObject? get _localStorage;

String? storageGet(String key) {
  try {
    final r = _localStorage?.callMethod<JSAny?>('getItem'.toJS, key.toJS);
    return r.isA<JSString>() ? (r as JSString).toDart : null;
  } on Object {
    return null; // blocked (private mode, sandbox)
  }
}

void storageSet(String key, String? value) {
  try {
    if (value == null) {
      _localStorage?.callMethod<JSAny?>('removeItem'.toJS, key.toJS);
    } else {
      _localStorage?.callMethod<JSAny?>('setItem'.toJS, key.toJS, value.toJS);
    }
  } on Object {
    // ignore
  }
}

@JS('window.open')
external JSObject? _windowOpen(String url, String target);

void openWindow(String url) => _windowOpen(url, '_blank');
