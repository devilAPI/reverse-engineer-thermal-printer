import '../ui/printer_controller.dart';
import 'bridge_host.dart';

BridgeHost create(PrinterController c) => _None();

class _None implements BridgeHost {
  @override
  bool get supported => false;
  @override
  bool get running => false;
  @override
  String? get error => null;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}
