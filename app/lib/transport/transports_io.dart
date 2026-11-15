import 'android_usb_transport.dart';
import 'ble_transport.dart';
import 'device_file_transport.dart';
import 'dump_file_transport.dart';
import 'libusb_transport.dart';
import 'linux_rfcomm_transport.dart';
import 'tcp_transport.dart';
import 'transport.dart';
import 'windows_usbprint_transport.dart';

List<PrinterTransport> platformTransports({List<String> manualHosts = const []}) => [
      AndroidUsbTransport(),
      DumpFileTransport(),
      LibusbTransport(),
      WindowsUsbPrintTransport(),
      LinuxRfcommTransport(),
      DeviceFileTransport(),
      TcpTransport(manualHosts: manualHosts),
      BleTransport(),
    ];
