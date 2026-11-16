@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thermal_photo/bridge/bridge_protocol.dart';
import 'package:thermal_photo/bridge/bridge_server.dart';
import 'package:thermal_photo/transport/dump_file_transport.dart';
import 'package:thermal_photo/transport/transport.dart';
import 'package:thermal_photo/ui/printer_controller.dart';

class _Fake implements PrinterTransport {
  final written = BytesBuilder();
  @override
  String get name => 'fake';
  @override
  bool get isSupported => true;
  @override
  Future<List<PrinterEndpoint>> discover() async =>
      [const PrinterEndpoint(transport: 'fake', id: 'p1', label: 'POS80 Printer USB', usbVendorId: 0x0416, usbProductId: 0x5011)];
  @override
  Future<PrinterConnection> open(PrinterEndpoint e) async => _Conn(this);
}

class _Conn implements PrinterConnection, PrinterStatusReader {
  _Conn(this.t);
  final _Fake t;
  @override
  Future<void> write(Uint8List d) async => t.written.add(d);
  @override
  Future<Uint8List> read({Duration timeout = const Duration(milliseconds: 500)}) async => Uint8List.fromList([0x12]);
  @override
  Future<void> close() async {}
}

void main() {
  late _Fake fake;
  late PrinterController c;
  late BridgeServer server;
  late HttpClient http;
  const port = 19632;
  final base = 'http://127.0.0.1:$port';

  setUp(() async {
    fake = _Fake();
    c = PrinterController(transports: [fake]);
    await c.scan();
    server = BridgeServer(c, port: port);
    await server.start();
    expect(server.error, isNull);
    http = HttpClient();
  });

  tearDown(() async {
    http.close(force: true);
    await server.stop();
  });

  Future<(int, Map<String, String>, String)> req(String method, String path,
      {String? origin, List<int>? body, Map<String, String> headers = const {}}) async {
    final r = await http.openUrl(method, Uri.parse('$base$path'));
    if (origin != null) r.headers.set('Origin', origin);
    headers.forEach(r.headers.set);
    if (body != null) r.add(body);
    final res = await r.close();
    final h = <String, String>{};
    res.headers.forEach((k, v) => h[k] = v.join(','));
    return (res.statusCode, h, await utf8.decodeStream(res));
  }

  test('origin allowlist', () {
    expect(isAllowedOrigin('https://devilapi.github.io'), isTrue);
    expect(isAllowedOrigin('http://localhost:8080'), isTrue);
    expect(isAllowedOrigin('http://127.0.0.1:5000'), isTrue);
    expect(isAllowedOrigin('https://evil.example'), isFalse);
    expect(isAllowedOrigin('https://devilapi.github.io.evil.example'), isFalse);
    expect(isAllowedOrigin('null'), isFalse);
  });

  test('lists printers with CORS for the Pages origin', () async {
    final (code, h, body) = await req('GET', '/v1/printers', origin: 'https://devilapi.github.io');
    expect(code, 200);
    expect(h['access-control-allow-origin'], 'https://devilapi.github.io');
    final j = jsonDecode(body) as Map<String, dynamic>;
    expect(j['bridge'], bridgeVersion);
    final p = (j['printers'] as List).single as Map<String, dynamic>;
    expect(p['id'], 'p1');
    expect(p['profile'], 'hz8360');
  });

  test('other websites are refused', () async {
    final (code, h, _) = await req('GET', '/v1/printers', origin: 'https://evil.example');
    expect(code, 403);
    expect(h['access-control-allow-origin'], isNull);
    final (pcode, _, _) = await req('POST', '/v1/print?transport=fake&id=p1', origin: 'https://evil.example', body: [1, 2]);
    expect(pcode, 403);
    expect(fake.written.length, 0);
  });

  test('cross-site requests without Origin are refused', () async {
    final (code, _, _) = await req('GET', '/v1/status?transport=fake&id=p1', headers: {'Sec-Fetch-Site': 'cross-site'});
    expect(code, 403);
  });

  test('preflight allows private network access', () async {
    final (code, h, _) = await req('OPTIONS', '/v1/print', origin: 'https://devilapi.github.io', headers: {
      'Access-Control-Request-Method': 'POST',
      'Access-Control-Request-Private-Network': 'true',
    });
    expect(code, 204);
    expect(h['access-control-allow-private-network'], 'true');
    expect(h['access-control-allow-methods'], contains('POST'));
  });

  test('print forwards the exact bytes and reports status', () async {
    final job = List<int>.generate(50000, (i) => i & 0xFF);
    final (code, _, body) = await req('POST', '/v1/print?transport=fake&id=p1&what=photo',
        origin: 'https://devilapi.github.io', body: job, headers: {'Content-Type': 'application/octet-stream'});
    expect(code, 200, reason: body);
    final j = jsonDecode(body) as Map<String, dynamic>;
    expect(j['ok'], isTrue);
    expect(j['message'], contains('Printer:'));
    // The job, then the DLE EOT status queries.
    expect(fake.written.toBytes().sublist(0, job.length), job);
  });

  test('unknown printer is 404', () async {
    final (code, _, _) = await req('POST', '/v1/print?transport=fake&id=nope', body: [1]);
    expect(code, 404);
  });

  // Manual end-to-end harness for real browsers (tools/web_e2e.mjs): serves
  // the real bridge on 127.0.0.1:9632 with the dump transport for
  // BRIDGE_E2E_SECONDS. Run with THERMAL_PHOTO_DUMP=/path/job.bin.
  final e2e = int.tryParse(Platform.environment['BRIDGE_E2E_SECONDS'] ?? '');
  test('e2e harness', () async {
    // BRIDGE_E2E_REAL=1: the platform's real transports (actual printers).
    final pc = Platform.environment['BRIDGE_E2E_REAL'] == '1'
        ? PrinterController()
        : PrinterController(transports: [DumpFileTransport()]);
    await pc.scan();
    final s = BridgeServer(pc);
    await s.start();
    expect(s.error, isNull);
    // ignore: avoid_print
    print('BRIDGE READY ${pc.endpoints}');
    await Future<void>.delayed(Duration(seconds: e2e!));
    await s.stop();
  }, skip: e2e == null ? 'set BRIDGE_E2E_SECONDS' : null, timeout: const Timeout(Duration(hours: 1)));

  test('second instance reports the busy port', () async {
    final other = BridgeServer(c, port: port);
    await other.start();
    expect(other.running, isFalse);
    expect(other.error, contains('127.0.0.1:$port'));
  });
}

