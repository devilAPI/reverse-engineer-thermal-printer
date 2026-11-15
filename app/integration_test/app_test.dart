// End-to-end test of the real desktop app without printer hardware.
// Run on Linux:
//   THERMAL_PHOTO_DUMP=/tmp/tp_job.bin flutter test integration_test -d linux \
//     --dart-define=THERMAL_PHOTO_TEST=true
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:thermal_photo/main.dart';
import 'package:thermal_photo/transport/libusb_transport.dart';
import 'package:thermal_photo/ui/prefs.dart';

Future<void> pumpUntil(WidgetTester t, bool Function() cond, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TestFailure('timed out');
    await t.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final dump = Platform.environment['THERMAL_PHOTO_DUMP'];

  setUp(() async {
    expect(Prefs.testMode, isTrue, reason: 'run with --dart-define=THERMAL_PHOTO_TEST=true');
    await (await Prefs.load()).clear();
  });

  testWidgets('open photo, print to dump transport, test page', (t) async {
    expect(dump, isNotNull, reason: 'set THERMAL_PHOTO_DUMP');
    final dumpFile = File(dump!);
    if (dumpFile.existsSync()) dumpFile.deleteSync();

    // 600x400 test photo: horizontal gradient with a dark disc.
    final photo = img.Image(width: 600, height: 400);
    for (final p in photo) {
      final v = (255 * p.x / 599).round();
      final inDisc = (p.x - 300) * (p.x - 300) + (p.y - 200) * (p.y - 200) < 100 * 100;
      p.setRgb(inDisc ? 20 : v, inDisc ? 20 : v, inDisc ? 20 : v);
    }
    final path = '${Directory.systemTemp.path}/tp_integration.png';
    File(path).writeAsBytesSync(img.encodePng(photo));

    await t.pumpWidget(ThermalPhotoApp(initialImage: path));
    await pumpUntil(t, () => find.textContaining('dots ·').evaluate().isNotEmpty);
    await pumpUntil(t, () => find.textContaining('Debug: save job').evaluate().isNotEmpty);

    // Select MP583 profile explicitly would need dropdown taps; default profile is MP583 (384 dots).
    expect(find.textContaining('384×256 dots'), findsOneWidget);

    await t.tap(find.text('Print'));
    await pumpUntil(t, () => find.textContaining('Sent ').evaluate().isNotEmpty);
    final job = dumpFile.readAsBytesSync();
    expect(job.sublist(0, 2), [0x1B, 0x40]);
    final s = String.fromCharCodes(job);
    expect(s.contains('\x1dv0\x00\x30\x00'), isTrue, reason: 'GS v 0 with 48 bytes per row');
    // ignore: avoid_print
    print('photo job: ${job.length} bytes');

    await t.tap(find.text('Test page'));
    await pumpUntil(t, () => find.textContaining('Sent test page').evaluate().isNotEmpty);
    final page = dumpFile.readAsBytesSync();
    expect(String.fromCharCodes(page), contains('Thermal Photo test page'));

    await t.tap(find.byIcon(Icons.close));
    await t.pump();
  });

  testWidgets('load photo from URL', (t) async {
    final png = img.encodePng(img.Image(width: 300, height: 150)..clear(img.ColorRgb8(128, 128, 128)));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      req.response.headers.contentType = ContentType('image', 'png');
      req.response.add(png);
      req.response.close();
    });
    try {
      await t.pumpWidget(const ThermalPhotoApp());
      await t.pumpAndSettle(const Duration(milliseconds: 500));
      await t.tap(find.text('Load from URL'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).last, 'http://127.0.0.1:${server.port}/grey.png');
      await t.tap(find.text('Load'));
      await pumpUntil(t, () => find.textContaining('dots ·').evaluate().isNotEmpty);
      expect(find.textContaining('×192 dots'), findsOneWidget); // 300x150 -> 384x192
    } finally {
      await server.close(force: true);
    }
  });

  test('libusb loads and enumerates without crashing', () async {
    final t = LibusbTransport();
    if (!t.isSupported) {
      markTestSkipped('libusb-1.0 not installed');
      return;
    }
    // ignore: avoid_print
    print('libusb candidates: ${await t.discover()}');
  });
}
