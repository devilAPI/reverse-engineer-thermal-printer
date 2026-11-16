import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/printer_profile.dart';
import '../transport/transport.dart';
import '../ui/printer_controller.dart';
import 'bridge_protocol.dart';

/// Local HTTP server exposing the desktop app's printers to the web app
/// (protocol in bridge_protocol.dart). Binds to loopback only.
class BridgeServer {
  BridgeServer(this.controller, {this.port = bridgePort, String? upstream})
      : upstream = upstream ?? Platform.environment['THERMAL_PHOTO_WEB_UPSTREAM'] ?? webAppUpstream;

  final PrinterController controller;
  final int port;

  /// Where the web app is fetched from (env override for testing a local build).
  final String upstream;
  HttpServer? _server;
  String? error;

  bool get running => _server != null;

  /// Largest accepted job (a long photo at 576 dots is ~1–2 MB).
  static const maxJob = 16 * 1024 * 1024;

  Future<void> start() async {
    if (_server != null) return;
    try {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _server = s;
      error = null;
      s.listen(_handle, onError: (Object _) {});
    } on Object catch (e) {
      error = 'Web bridge could not listen on 127.0.0.1:$port ($e). Is another copy of the app running?';
    }
  }

  Future<void> stop() async {
    _upstream?.close(force: true);
    _upstream = null;
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final origin = req.headers.value('origin');
    // Browsers omit Origin on plain cross-site GETs (<img>, no-cors fetch) but
    // always send Sec-Fetch-Site; refuse those too.
    final site = req.headers.value('sec-fetch-site');
    if (origin == null && site != null && site != 'none' && site != 'same-origin') {
      res.statusCode = HttpStatus.forbidden;
      await res.close();
      return;
    }
    if (origin != null) {
      if (!isAllowedOrigin(origin)) {
        res.statusCode = HttpStatus.forbidden;
        res.write('origin not allowed');
        await res.close();
        return;
      }
      res.headers
        ..set('Access-Control-Allow-Origin', origin)
        ..set('Vary', 'Origin')
        ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        ..set('Access-Control-Allow-Headers', 'Content-Type')
        ..set('Access-Control-Max-Age', '600');
      // Chrome Private Network Access / Local Network Access preflights.
      if (req.headers.value('access-control-request-private-network') != null) {
        res.headers.set('Access-Control-Allow-Private-Network', 'true');
      }
    }
    try {
      if (req.method == 'OPTIONS') {
        res.statusCode = HttpStatus.noContent;
      } else if (req.method == 'GET' && req.uri.path == '/v1/printers') {
        _json(res, {
          'app': 'thermal_photo',
          'bridge': bridgeVersion,
          'printers': [
            for (final e in controller.endpoints)
              {
                'transport': e.transport,
                'id': e.id,
                'label': e.label,
                'vid': e.usbVendorId,
                'pid': e.usbProductId,
                'profile': PrinterProfile.guess(label: e.label, vid: e.usbVendorId, pid: e.usbProductId)?.id,
                'selected': e == controller.endpoint,
              },
          ],
        });
      } else if (req.method == 'POST' && req.uri.path == '/v1/print') {
        final ep = _endpoint(req.uri);
        if (ep == null) return _json(res, {'ok': false, 'message': 'Unknown printer'}, HttpStatus.notFound);
        final b = BytesBuilder(copy: false);
        await for (final c in req) {
          b.add(c);
          if (b.length > maxJob) return _json(res, {'ok': false, 'message': 'Job too large'}, HttpStatus.requestEntityTooLarge);
        }
        final what = req.uri.queryParameters['what'] ?? 'web job';
        final (ok, msg) = await controller.sendTo(ep, b.takeBytes(), '$what (web)');
        _json(res, {'ok': ok, 'message': msg}, ok ? HttpStatus.ok : HttpStatus.badGateway);
      } else if (req.method == 'GET' && req.uri.path == '/v1/status') {
        final ep = _endpoint(req.uri);
        if (ep == null) return _json(res, {'ok': false, 'message': 'Unknown printer'}, HttpStatus.notFound);
        final (ok, msg) = await controller.statusOf(ep);
        _json(res, {'ok': ok, 'message': msg});
      } else if (req.method == 'GET' && (req.uri.path == '/' || req.uri.path == webAppPath.substring(0, webAppPath.length - 1))) {
        res.statusCode = HttpStatus.found;
        res.headers.set('Location', webAppPath);
      } else if (req.method == 'GET' && req.uri.path.startsWith(webAppPath)) {
        await _proxy(req.uri, res);
      } else {
        res.statusCode = HttpStatus.notFound;
      }
    } on Object catch (e) {
      _json(res, {'ok': false, 'message': '$e'}, HttpStatus.internalServerError);
    } finally {
      await res.close();
    }
  }

  final _cache = <String, (List<int>, String?)>{};
  HttpClient? _upstream;

  /// Serve the web app from GitHub Pages; the last good copy of each file is
  /// kept in memory so a reload works offline while the app runs.
  Future<void> _proxy(Uri u, HttpResponse res) async {
    final path = u.path.contains('..') ? webAppPath : u.path;
    final key = path.endsWith('/') ? '${path}index.html' : path;
    List<int>? body;
    String? type;
    try {
      final c = _upstream ??= HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final r = await (await c.getUrl(Uri.parse('$upstream$path'))).close().timeout(const Duration(seconds: 20));
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in r) {
        bytes.add(chunk);
      }
      if (r.statusCode == 200) {
        body = bytes.takeBytes();
        type = r.headers.contentType?.toString();
        _cache[key] = (body, type);
      } else if (r.statusCode == 404) {
        res.statusCode = HttpStatus.notFound;
        return;
      }
    } on Object {
      // offline: fall back to the cache below
    }
    final hit = body == null ? _cache[key] : null;
    body ??= hit?.$1;
    type ??= hit?.$2;
    if (body == null) {
      res.statusCode = HttpStatus.badGateway;
      res.headers.contentType = ContentType.text;
      res.write('The web app is loaded from $upstream$webAppPath and this computer is offline.');
      return;
    }
    if (type != null) res.headers.set('Content-Type', type);
    res.headers.set('Cache-Control', 'no-cache');
    res.add(body);
  }

  PrinterEndpoint? _endpoint(Uri u) {
    final t = u.queryParameters['transport'], id = u.queryParameters['id'];
    return controller.endpoints.where((e) => e.transport == t && e.id == id).firstOrNull;
  }

  void _json(HttpResponse res, Object body, [int code = HttpStatus.ok]) {
    res.statusCode = code;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
  }
}
