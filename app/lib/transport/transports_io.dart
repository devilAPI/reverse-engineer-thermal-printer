import 'android_usb_transport.dart';
import 'ble_transport.dart';
import 'device_file_transport.dart';
import 'tcp_transport.dart';
import 'transport.dart';

// TODO(hw): add once USB enumeration is known — libusb (macOS), Windows usbprint.
List<PrinterTransport> platformTransports({List<String> manualHosts = const []}) => [
      AndroidUsbTransport(),
      DeviceFileTransport(),
      TcpTransport(manualHosts: manualHosts),
      BleTransport(),
    ];
