import 'web/js_api.dart';
import 'transport.dart';
import 'web/bridge_transport.dart';
import 'web/web_bluetooth_transport.dart';
import 'web/web_serial_transport.dart';
import 'web/webusb_transport.dart';

/// Browser transports. Each is `isSupported` only where the browser has the
/// API (Chromium for Serial/USB/Bluetooth); the bridge works everywhere.
List<PrinterTransport> platformTransports({List<String> manualHosts = const []}) => [
      WebSerialTransport(),
      WebUsbTransport(),
      WebBluetoothTransport(),
      BridgeTransport(),
    ];

/// What this browser can do, shown above the "Add printer" buttons.
String? platformNote() {
  if (BridgeTransport.servedByBridge) {
    return 'Served by the Thermal Photo desktop app — its printers are listed under Connection.';
  }
  if (!hasWebSerial && !hasWebUsb && !hasWebBluetooth) {
    return '$browserName gives web pages no Bluetooth/USB access (only Chrome and Edge do). '
        'Print through the desktop app instead: start it on this computer and press "Use desktop app"'
        '${BridgeTransport.mixedContentBlocked ? ' — it opens this app from http://127.0.0.1:9632, the copy Safari lets print' : ''}. '
        '${browserName == 'Safari' ? 'On iPhone/iPad use the iOS app (Bluetooth LE).' : ''}';
  }
  if (isLinux && !hasWebBluetooth) {
    return 'For Bluetooth LE in Chrome on Linux enable chrome://flags/#enable-web-bluetooth. '
        'Bluetooth serial (MP583) works without it.';
  }
  return null;
}
