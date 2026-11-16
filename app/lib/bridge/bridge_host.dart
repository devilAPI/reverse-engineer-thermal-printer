import '../ui/printer_controller.dart';
import 'bridge_host_stub.dart' if (dart.library.io) 'bridge_host_io.dart' as impl;

/// The web bridge as seen by the UI: desktop builds can serve it, web and
/// mobile builds can't.
abstract class BridgeHost {
  bool get supported;
  bool get running;
  String? get error;
  Future<void> start();
  Future<void> stop();

  factory BridgeHost(PrinterController c) => impl.create(c);
}
