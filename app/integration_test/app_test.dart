// End-to-end test of the real desktop app without printer hardware.
// Run on Linux:
//   THERMAL_PHOTO_DUMP=/tmp/tp_job.bin flutter test integration_test -d linux
// The receipt test also leaves its jobs next to the dump file
// (<dump>.label.bin, <dump>.shop.bin) for tools/escpos_render.py.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:thermal_photo/core/printer_profile.dart';
import 'package:thermal_photo/main.dart';

Future<void> pumpUntil(WidgetTester t, bool Function() cond, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TestFailure('timed out');
    await t.pump(const Duration(milliseconds: 200));
  }
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

int countOf(List<int> hay, List<int> needle) {
  var n = 0;
  outer:
  for (var i = 0; i <= hay.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    n++;
  }
  return n;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final dump = Platform.environment['THERMAL_PHOTO_DUMP'];

  // Fresh in-memory settings per test: never read or modify the user's prefs.
  setUp(() => SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty());

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

    // Default profile is MP583 (384 dots).
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

  testWidgets('receipt editor: template, add cut + text, print to dump transport', (t) async {
    expect(dump, isNotNull, reason: 'set THERMAL_PHOTO_DUMP');
    final dumpFile = File(dump!);
    if (dumpFile.existsSync()) dumpFile.deleteSync();

    await t.pumpWidget(const ThermalPhotoApp());
    await pumpUntil(t, () => find.textContaining('Debug: save job').evaluate().isNotEmpty);

    // Switch to the 80 mm cutter printer (576 dots) in the shared printer panel.
    await t.tap(find.text(PrinterProfile.mp583.name));
    await settle(t);
    await t.tap(find.text(PrinterProfile.hz8360.name).last);
    await settle(t);

    // Receipt tab.
    await t.tap(find.text('Receipt'));
    await settle(t);
    await pumpUntil(t, () => find.textContaining('576 dots ·').evaluate().isNotEmpty);

    // Open the price label sample (ends with a Cut block).
    await t.tap(find.byTooltip('Templates & saved receipts'));
    await settle(t);
    await t.tap(find.text('Price label'));
    await settle(t);
    expect(find.text('Receipt · Price label'), findsOneWidget);
    await pumpUntil(t, () => find.textContaining('· 1 piece ·').evaluate().isNotEmpty);

    // Append a text block after the cut: a second slip with Unicode.
    await t.tap(find.byKey(const Key('add-block')));
    await settle(t);
    await t.tap(find.byKey(const Key('add-text')));
    await settle(t);
    await pumpUntil(t, () => find.byKey(const Key('block-text')).evaluate().isNotEmpty);
    await t.enterText(find.byKey(const Key('block-text')), 'Zweiter Beleg: Grüße ✓ Nr. {n}');
    await settle(t);
    await pumpUntil(t, () => find.textContaining('· 2 pieces ·').evaluate().isNotEmpty);

    await t.tap(find.text('Print receipt'));
    await pumpUntil(t, () => find.textContaining('Sent receipt').evaluate().isNotEmpty);
    var job = dumpFile.readAsBytesSync();
    dumpFile.copySync('$dump.label.bin');
    expect(job.sublist(0, 2), [0x1B, 0x40]);
    expect(countOf(job, [0x1D, 0x76, 0x30, 0x00, 72, 0]), greaterThanOrEqualTo(2), reason: 'GS v 0, 72 bytes/row, per slip');
    expect(countOf(job, [0x1D, 0x56, 0x42, 0x30]), 2, reason: 'cut between slips + final cut');
    // ignore: avoid_print
    print('label receipt job: ${job.length} bytes');

    // {n} advanced after printing (scroll the block list back to the top).
    await t.drag(find.byType(CustomScrollView), const Offset(0, 3000));
    await settle(t);
    expect(find.textContaining('{n} = 2'), findsOneWidget);

    // Undo the added text, then print the shop sample (QR + barcode).
    await t.tap(find.byTooltip('Templates & saved receipts'));
    await settle(t);
    await t.tap(find.text('Shop receipt'));
    await settle(t);
    await pumpUntil(t, () => find.text('Receipt · Shop receipt').evaluate().isNotEmpty);
    await pumpUntil(t, () => find.textContaining('· 1 piece ·').evaluate().isNotEmpty);
    await t.tap(find.byTooltip('Undo (Ctrl+Z)'));
    await settle(t);
    expect(find.text('Receipt · Price label'), findsOneWidget, reason: 'undo restores the previous document');
    await t.tap(find.byTooltip('Redo (Ctrl+Y)'));
    await settle(t);
    await pumpUntil(t, () => find.text('Receipt · Shop receipt').evaluate().isNotEmpty);
    await pumpUntil(t, () => find.textContaining('· 1 piece ·').evaluate().isNotEmpty);

    await t.tap(find.byIcon(Icons.close)); // clear the previous "Sent" status
    await settle(t);
    await t.tap(find.text('Print receipt'));
    await pumpUntil(t, () => find.textContaining('Sent receipt').evaluate().isNotEmpty);
    job = dumpFile.readAsBytesSync();
    dumpFile.copySync('$dump.shop.bin');
    expect(countOf(job, [0x1D, 0x56, 0x42, 0x30]), 1);
    // ignore: avoid_print
    print('shop receipt job: ${job.length} bytes');
  });
}
