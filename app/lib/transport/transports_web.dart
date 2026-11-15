import 'ble_transport.dart';
import 'transport.dart';

// TODO(hw): WebUSB (printer class / vendor bulk) and Web Serial (CDC) in Chromium.
List<PrinterTransport> platformTransports({List<String> manualHosts = const []}) => [
      BleTransport(),
    ];
