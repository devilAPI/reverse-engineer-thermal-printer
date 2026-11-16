import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../bridge/bridge_protocol.dart';
import '../transport.dart';
import 'js_api.dart';

/// Prints through the desktop app's web bridge on 127.0.0.1 — the way to
/// print from Firefox and Safari (no device APIs), and from Chrome on
/// Windows (usbprint.sys blocks WebUSB). See bridge_server.dart.
///
/// Probing localhost makes Chrome show a "local network access" prompt, so
/// we only probe after the user clicked "Use desktop app" once (remembered
/// in localStorage).
class BridgeTransport implements PrinterTransport, PairableTransport {
  BridgeTransport({http.Client? client, String? base})
      : _client = client ?? http.Client(),
        base = base ?? (servedByBridge ? Uri.base.origin : 'http://127.0.0.1:$bridgePort');

  /// True when this page was loaded from the desktop app's bridge itself.
  static bool get servedByBridge =>
      Uri.base.port == bridgePort && (Uri.base.host == '127.0.0.1' || Uri.base.host == 'localhost');

  /// Safari (and anything WebKit) blocks https pages from calling
  /// http://127.0.0.1 — those must open the bridge-served copy instead.
  static bool get mixedContentBlocked => Uri.base.scheme == 'https' && browserName == 'Safari';

  final http.Client _client;
  final String base;
  static const _key = 'thermal_photo.bridge';

  @override
  String get name => 'bridge';

  @override
  bool get isSupported => true;

  @override
  String get pairLabel => 'Use desktop app (bridge)';

  @override
  String get pairHint => 'Start the Thermal Photo desktop app on this computer (web bridge on); '
      'it prints for this page. Works in every browser, including Firefox and Safari.';

  @override
  Future<List<PrinterEndpoint>> discover() async {
    if (!servedByBridge && (storageGet(_key) != '1' || mixedContentBlocked)) return const [];
    try {
      return await _list();
    } on Object {
      return const []; // desktop app not running right now
    }
  }

  Future<List<PrinterEndpoint>> _list() async {
    final r = await _client.get(Uri.parse('$base/v1/printers')).timeout(const Duration(seconds: 3));
    if (r.statusCode != 200) throw StateError('bridge answered ${r.statusCode}: ${r.body}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return [
      for (final p in (j['printers'] as List).cast<Map<String, dynamic>>())
        PrinterEndpoint(
          transport: name,
          id: jsonEncode({'t': p['transport'], 'i': p['id']}),
          label: 'Desktop app: ${p['label']}',
          usbVendorId: p['vid'] as int?,
          usbProductId: p['pid'] as int?,
        ),
    ];
  }

  @override
  Future<PrinterEndpoint?> pair() async {
    if (mixedContentBlocked) {
      // Must happen synchronously in the click, or Safari blocks the popup.
      // Same page (e.g. /reverse-engineer-thermal-printer/dev/) from the bridge.
      final path = Uri.base.path.startsWith(webAppPath) ? Uri.base.path : '/';
      openWindow('http://127.0.0.1:$bridgePort$path');
      throw StateError('Safari doesn\'t let https pages talk to the desktop app, so the copy served by the '
          'desktop app was opened (http://127.0.0.1:$bridgePort). Print from that tab. '
          'Nothing opened? Start Thermal Photo (desktop) with "Web bridge" on, then reload it.');
    }
    final List<PrinterEndpoint> list;
    try {
      list = await _list();
    } on Object catch (e) {
      throw StateError('No desktop app found on this computer ($e). Start Thermal Photo (desktop) with '
          '"Web bridge" switched on, then try again.'
          '${browserName == 'Chrome' || browserName == 'Edge' ? ' If $browserName asked about "local network" / "apps on this device", allow it.' : ''}');
    }
    storageSet(_key, '1');
    if (list.isEmpty) throw StateError('The desktop app is running but has no printer. Connect one there and refresh.');
    return list.first;
  }

  @override
  Future<PrinterConnection> open(PrinterEndpoint endpoint) async => _BridgeConnection(this, endpoint.id);

  Uri _uri(String path, String id, [Map<String, String> extra = const {}]) {
    final j = jsonDecode(id) as Map<String, dynamic>;
    return Uri.parse('$base$path').replace(queryParameters: {'transport': '${j['t']}', 'id': '${j['i']}', ...extra});
  }
}

/// Forwards the whole job in one request; the desktop app then does pacing,
/// chunking and the status query itself.
class _BridgeConnection implements PrinterConnection, WholeJobConnection {
  _BridgeConnection(this._t, this._id);
  final BridgeTransport _t;
  final String _id;

  @override
  Future<String> sendJob(Uint8List job, String what) async {
    final http.Response r;
    try {
      r = await _t._client
          .post(_t._uri('/v1/print', _id, {'what': what}), headers: {'Content-Type': 'application/octet-stream'}, body: job)
          .timeout(const Duration(minutes: 3));
    } on Object catch (e) {
      throw StateError('Desktop app not reachable ($e). Is it still running?');
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    if (j['ok'] != true) throw StateError('Desktop app: ${j['message']}');
    return 'Desktop app: ${j['message']}';
  }

  @override
  Future<String> status() async {
    final r = await _t._client.get(_t._uri('/v1/status', _id)).timeout(const Duration(seconds: 30));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return 'Desktop app: ${j['message']}';
  }

  @override
  Future<void> write(Uint8List data) => sendJob(data, 'data');

  @override
  Future<void> close() async {}
}
