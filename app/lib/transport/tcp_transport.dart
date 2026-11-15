import 'dart:io';
import 'dart:typed_data';

import 'transport.dart';

/// Raw TCP (JetDirect / port 9100) — HZ-8360 LAN/WiFi variants.
/// Works on every platform except web.
class TcpTransport implements PrinterTransport {
  TcpTransport({this.manualHosts = const []});

  /// "host" or "host:port" entries the user typed in.
  final List<String> manualHosts;

  @override
  String get name => 'tcp';

  @override
  bool get isSupported => true;

  @override
  Future<List<PrinterEndpoint>> discover() async => [
        for (final h in manualHosts)
          PrinterEndpoint(transport: name, id: h.contains(':') ? h : '$h:9100', label: 'Network $h'),
      ];

  @override
  Future<PrinterConnection> open(PrinterEndpoint endpoint) async {
    final parts = endpoint.id.split(':');
    final socket = await Socket.connect(parts[0], int.parse(parts[1]), timeout: const Duration(seconds: 5));
    return _SocketConnection(socket);
  }
}

class _SocketConnection implements PrinterConnection {
  _SocketConnection(this._s);
  final Socket _s;

  @override
  Future<void> write(Uint8List data) async {
    _s.add(data);
    await _s.flush();
  }

  @override
  Future<void> close() async {
    await _s.flush();
    await _s.close();
  }
}
