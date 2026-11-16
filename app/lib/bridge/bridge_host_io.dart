import 'dart:io';

import '../ui/printer_controller.dart';
import 'bridge_host.dart';
import 'bridge_server.dart';

BridgeHost create(PrinterController c) => _IoHost(BridgeServer(c));

class _IoHost implements BridgeHost {
  _IoHost(this._s);
  final BridgeServer _s;

  @override
  bool get supported => Platform.isLinux || Platform.isMacOS || Platform.isWindows;
  @override
  bool get running => _s.running;
  @override
  String? get error => _s.error;
  @override
  Future<void> start() => _s.start();
  @override
  Future<void> stop() => _s.stop();
}
