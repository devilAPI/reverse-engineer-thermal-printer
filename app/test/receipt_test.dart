import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:thermal_photo/core/image_pipeline.dart';
import 'package:thermal_photo/core/mono_bitmap.dart';
import 'package:thermal_photo/core/print_job.dart';
import 'package:thermal_photo/core/printer_profile.dart';
import 'package:thermal_photo/receipt/codes.dart';
import 'package:thermal_photo/receipt/editor.dart';
import 'package:thermal_photo/receipt/encode.dart';
import 'package:thermal_photo/receipt/model.dart';
import 'package:thermal_photo/receipt/renderer.dart';
import 'package:thermal_photo/receipt/templates.dart';
import 'package:thermal_photo/receipt/tokens.dart';

/// Fonts declared in pubspec are not loaded automatically in widget tests.
Future<void> loadReceiptFonts() async {
  for (final (family, files) in [
    ('ReceiptSans', ['DejaVuSans.ttf', 'DejaVuSans-Bold.ttf']),
    ('ReceiptMono', ['DejaVuSansMono.ttf', 'DejaVuSansMono-Bold.ttf']),
  ]) {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(rootBundle.load('assets/fonts/$f'));
    }
    await loader.load();
  }
}

int blackIn(MonoBitmap m, [int x0 = 0, int y0 = 0, int? x1, int? y1]) {
  var n = 0;
  for (var y = y0; y < (y1 ?? m.height); y++) {
    for (var x = x0; x < (x1 ?? m.width); x++) {
      if (m.getPixel(x, y)) n++;
    }
  }
  return n;
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

Uint8List testPng() {
  final im = img.Image(width: 40, height: 20)..clear(img.ColorRgb8(0, 0, 0));
  return img.encodePng(im);
}

Receipt everyBlock() => Receipt(
  name: 'All blocks',
  counter: 42,
  blocks: [
    TextBlock(
      text: 'Hello\nWörld {date}',
      align: HAlign.center,
      invert: true,
      format: const TextFormat(font: ReceiptFont.mono, size: 30, bold: true, underline: true, scaleX: 2, scaleY: 3),
    ),
    ColumnsBlock(
      cells: const [
        ColumnCell(text: '2x', flex: 1),
        ColumnCell(text: 'Tea', flex: 4, align: HAlign.center),
        ColumnCell(text: '4.00', flex: 2, align: HAlign.right),
      ],
      fill: true,
      format: const TextFormat(size: 20),
    ),
    SeparatorBlock(style: SeparatorStyle.double, thickness: 3, height: 30),
    ImageBlock(
      bytes: testPng(),
      name: 'logo.png',
      widthPercent: 50,
      align: HAlign.right,
      settings: const PrintSettings(
        dither: DitherMode.ordered,
        brightness: 0.1,
        contrast: 1.2,
        gamma: 1.5,
        threshold: 100,
        invert: true,
        rotate90: true,
      ),
    ),
    QrBlock(data: 'https://example.com/{n}', moduleSize: 4, ecc: QrEcc.high, align: HAlign.left),
    BarcodeBlock(
      symbology: BarcodeSymbology.ean13,
      data: '400638133393',
      moduleWidth: 3,
      height: 50,
      showText: false,
      align: HAlign.right,
    ),
    FeedBlock(mm: 7.5),
    CutBlock(),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('model JSON', () {
    test('round-trips every block type', () {
      final r = everyBlock();
      final json = r.encode(pretty: true);
      final back = Receipt.decode(json);
      expect(back.encode(pretty: true), json);
      expect(back.name, 'All blocks');
      expect(back.counter, 42);
      expect(back.blocks.map((b) => b.type), ['text', 'columns', 'separator', 'image', 'qr', 'barcode', 'feed', 'cut']);
      final t = back.blocks[0] as TextBlock;
      expect(t.format, r.blocks[0] is TextBlock ? (r.blocks[0] as TextBlock).format : null);
      expect((back.blocks[3] as ImageBlock).bytes, (r.blocks[3] as ImageBlock).bytes);
      // ids are per session, not serialised
      expect(back.blocks[0].id, isNot(r.blocks[0].id));
      expect(json, isNot(contains('"id"')));
      expect(r.toJson()['version'], receiptFormatVersion);
      expect(r.toJson()['format'], receiptFormatTag);
    });

    test('spacing options round-trip and default to nothing in JSON', () {
      final doc = Receipt(
        marginLeft: 12,
        marginRight: 36,
        blocks: [
          TextBlock(
            text: 'x',
            format: const TextFormat(stretch: 0.8, letterSpacing: -1, lineHeight: 21.5),
            spacing: const BlockSpacing(before: 3, after: 4, left: 5, right: 6),
          ),
          ColumnsBlock(gap: 2),
          SeparatorBlock(dash: 6, gap: 4),
          TextBlock(text: 'plain'),
        ],
      );
      final back = Receipt.decode(doc.encode());
      expect(back.marginLeft, 12);
      expect(back.marginRight, 36);
      final t = back.blocks[0] as TextBlock;
      expect(t.format, doc.blocks[0] is TextBlock ? (doc.blocks[0] as TextBlock).format : null);
      expect(t.spacing, const BlockSpacing(before: 3, after: 4, left: 5, right: 6));
      expect((back.blocks[1] as ColumnsBlock).gap, 2);
      expect((back.blocks[2] as SeparatorBlock).dash, 6);
      expect((back.blocks[2] as SeparatorBlock).gap, 4);
      final plain = back.blocks[3].toJson();
      expect(plain.keys, isNot(contains('spaceBefore')));
      expect(plain.keys, isNot(contains('lineHeight')));
      // withSpacing keeps the id and content
      final b = back.blocks[0];
      final moved = b.withSpacing(const BlockSpacing(before: 99));
      expect(moved.id, b.id);
      expect(moved.spacing.before, 99);
      expect(moved.spacing.left, 0);
      expect((moved as TextBlock).format, t.format);
    });

    test('templates round-trip', () {
      for (final t in builtInTemplates) {
        final r = t.build();
        expect(Receipt.decode(r.encode()).encode(), r.encode(), reason: t.name);
      }
    });

    test('tolerant reading: defaults, clamping, unknown blocks skipped', () {
      final r = Receipt.decode(
        '{"version": 99, "blocks": ['
        '{"type": "text", "text": "x", "size": 9999, "scaleX": 9},'
        '{"type": "hologram"},'
        '{"type": "columns", "cells": [{"text": "only one"}]},'
        '{"type": "cut"}]}',
      );
      expect(r.blocks.map((b) => b.type), ['text', 'columns', 'cut']);
      final t = r.blocks[0] as TextBlock;
      expect(t.format.size, 400);
      expect(t.format.scaleX, 4);
      expect(t.align, HAlign.left);
      expect((r.blocks[1] as ColumnsBlock).cells, hasLength(2));
    });

    test('rejects non-receipts', () {
      expect(() => Receipt.decode('[1, 2]'), throwsFormatException);
      expect(() => Receipt.decode('{"format": "something.else", "blocks": []}'), throwsFormatException);
      expect(() => Receipt.decode('{"name": "x"}'), throwsFormatException);
    });

    test('duplicate gets a new id and equal content', () {
      final b = everyBlock().blocks[1];
      final d = b.duplicate();
      expect(d.id, isNot(b.id));
      expect(d.toJson(), b.toJson());
    });
  });

  group('tokens', () {
    final ctx = TokenContext(now: DateTime(2026, 3, 4, 5, 6, 7), number: 7);
    test('date, time, custom patterns, counter', () {
      expect(expandTokens('{date} {time} {datetime}', ctx), '2026-03-04 05:06 2026-03-04 05:06');
      expect(expandTokens('{date:dd.MM.yy HH:mm:ss}', ctx), '04.03.26 05:06:07');
      expect(expandTokens('No. {n} / {n:0000}', ctx), 'No. 7 / 0007');
      expect(expandTokens('{{date} {unknown} {', ctx), '{date} {unknown} {');
    });
    test('usesCounter', () {
      expect(usesCounter('a {n:00} b'), isTrue);
      expect(usesCounter('{date}'), isFalse);
      expect(receiptUsesCounter(shopReceipt()), isTrue);
      expect(receiptUsesCounter(priceLabel()), isFalse);
    });
  });

  group('codes', () {
    test('EAN-13 has 95 modules and gets its check digit', () {
      final m = barcodeModules(BarcodeSymbology.ean13, '400638133393');
      expect(m, hasLength(95));
      expect(m.sublist(0, 3), [true, false, true]); // start guard
      expect(barcodeText(BarcodeSymbology.ean13, '400638133393'), '4006381333931');
    });
    test('Code 128 module pattern ends with the stop pattern', () {
      final m = barcodeModules(BarcodeSymbology.code128, 'R000001');
      expect(m.sublist(m.length - 13).map((b) => b ? 1 : 0).join(), '1100011101011');
    });
    test('invalid data throws', () {
      expect(() => barcodeModules(BarcodeSymbology.ean13, 'abc'), throwsA(anything));
    });
    test('QR matrix has finder patterns', () {
      final q = qrMatrix('hello', QrEcc.medium);
      expect(q.length, 21);
      expect(q[0].sublist(0, 7), everyElement(isTrue));
      expect(q[1].sublist(1, 6), everyElement(isFalse));
    });
  });

  group('editor', () {
    test('add/duplicate/move/remove with undo & redo', () {
      final e = ReceiptEditor(
        Receipt(
          blocks: [
            TextBlock(text: 'a'),
            TextBlock(text: 'b'),
          ],
        ),
      );
      String texts() => e.doc.blocks.map((b) => b is TextBlock ? b.text : b.type).join(',');
      e.select(e.doc.blocks[0].id);
      e.add(CutBlock());
      expect(texts(), 'a,cut,b');
      e.duplicate(e.doc.blocks[0].id);
      expect(texts(), 'a,a,cut,b');
      e.move(3, 0); // b to the top
      expect(texts(), 'b,a,a,cut');
      e.remove(e.doc.blocks[3].id);
      expect(texts(), 'b,a,a');
      e.undo();
      expect(texts(), 'b,a,a,cut');
      e.undo();
      e.undo();
      expect(texts(), 'a,cut,b');
      e.redo();
      expect(texts(), 'a,a,cut,b');
      e.add(FeedBlock()); // new edit clears redo
      expect(e.canRedo, isFalse);
    });

    test('typing coalesces into one undo step', () {
      final e = ReceiptEditor(Receipt(blocks: [TextBlock(text: '')]));
      final b = e.doc.blocks[0] as TextBlock;
      for (final s in ['H', 'He', 'Hel', 'Hell', 'Hello']) {
        e.update(b.copyWith(text: s), 'text');
      }
      expect((e.doc.blocks[0] as TextBlock).text, 'Hello');
      e.undo();
      expect((e.doc.blocks[0] as TextBlock).text, '');
      expect(e.canUndo, isFalse);
    });

    test('library upsert by name, encode/decode', () {
      var lib = upsertReceipt([], Receipt(name: 'b'));
      lib = upsertReceipt(lib, Receipt(name: 'A', counter: 1));
      lib = upsertReceipt(lib, Receipt(name: 'A', counter: 2));
      expect(lib.map((r) => '${r.name}${r.counter}'), ['A2', 'b1']);
      expect(decodeLibrary(encodeLibrary(lib)).map((r) => r.name), ['A', 'b']);
      expect(decodeLibrary('garbage'), isEmpty);
      expect(decodeLibrary(null), isEmpty);
    });
  });

  group('encode', () {
    MonoBitmap seg(int w, int h) => MonoBitmap(w, h)..data.fillRange(0, ((w + 7) ~/ 8) * h, 0xFF);

    test('segments are split by GS V B on cutter printers', () {
      final r = RenderedReceipt(width: 576, segments: [seg(576, 10), seg(576, 20), seg(576, 5)]);
      final job = buildReceiptJob([r], PrinterProfile.hz8360);
      expect(job.sublist(0, 2), [0x1B, 0x40]);
      expect(countOf(job, [0x1D, 0x76, 0x30, 0x00, 72, 0]), 3);
      expect(countOf(job, [0x1D, 0x56, 0x42, 0x30]), 3); // 2 between + final
      expect(job.sublist(job.length - 4), [0x1D, 0x56, 0x42, 0x30]);
    });

    test('final cut follows job options unless the receipt ends with a cut', () {
      final opts = const JobOptions(cut: false);
      final plain = buildReceiptJob(
        [
          RenderedReceipt(width: 576, segments: [seg(576, 4)]),
        ],
        PrinterProfile.hz8360,
        opts,
      );
      expect(countOf(plain, [0x1D, 0x56, 0x42]), 0);
      expect(plain.sublist(plain.length - 3), [0x1B, 0x64, 4]);
      final cut = buildReceiptJob(
        [
          RenderedReceipt(width: 576, segments: [seg(576, 4)], endsWithCut: true),
        ],
        PrinterProfile.hz8360,
        opts,
      );
      expect(cut.sublist(cut.length - 4), [0x1D, 0x56, 0x42, 0x30]);
    });

    test('no cutter: tear-off feeds, 48 bytes per row, darkness, copies', () {
      final r = RenderedReceipt(width: 384, segments: [seg(384, 300), seg(384, 2)]);
      final job = buildReceiptJob([r, r], PrinterProfile.mp583, const JobOptions(darkness: 1));
      expect(job.sublist(2, 5), [0x1D, 0x45, 15]); // GS E after ESC @
      expect(countOf(job, [0x1D, 0x56]), 0);
      // 300 rows in bands of 128 = 3 commands + 1 for the 2-row segment, per copy
      expect(countOf(job, [0x1D, 0x76, 0x30, 0x00, 48, 0]), 8);
      expect(countOf(job, [0x1B, 0x64, 4]), 4);
    });
  });

  group('renderer', () {
    setUpAll(loadReceiptFonts);
    final now = DateTime(2026, 11, 15, 12, 0);

    test('renders at the profile width, cut splits into segments', () async {
      final doc = Receipt(
        blocks: [
          CutBlock(), // leading cut: no empty slip
          TextBlock(text: 'First'),
          CutBlock(),
          CutBlock(), // repeated cut collapses
          TextBlock(text: 'Second', format: const TextFormat(size: 40, bold: true)),
          CutBlock(),
        ],
      );
      for (final w in [384, 576]) {
        final r = await ReceiptRenderer().render(doc, width: w, now: now);
        expect(r.segments, hasLength(2));
        expect(r.segments.every((s) => s.width == w), isTrue);
        expect(r.endsWithCut, isTrue);
        expect(blackIn(r.segments[0]), greaterThan(50));
        expect(r.segments[1].height, greaterThan(r.segments[0].height));
        expect(r.warnings, isEmpty);
      }
    });

    test('feed and separator heights are exact', () async {
      final r = await ReceiptRenderer().render(
        Receipt(
          blocks: [
            FeedBlock(mm: 10),
            SeparatorBlock(style: SeparatorStyle.solid, thickness: 4, height: 20),
          ],
        ),
        width: 384,
      );
      final m = r.segments.single;
      expect(m.height, 80 + 20);
      expect(blackIn(m, 0, 0, null, 80), 0);
      expect(blackIn(m, 0, 80), 384 * 4);
      expect(m.getPixel(0, 88) && m.getPixel(383, 91), isTrue);
    });

    test('spacing: before/after rows, indents and receipt margins are exact', () async {
      final r = await ReceiptRenderer().render(
        Receipt(
          marginLeft: 20,
          marginRight: 30,
          blocks: [
            SeparatorBlock(
              style: SeparatorStyle.solid,
              thickness: 2,
              height: 2,
              spacing: const BlockSpacing(before: 10, after: 6, left: 5, right: 7),
            ),
          ],
        ),
        width: 576,
      );
      final m = r.segments.single;
      expect(m.height, 10 + 2 + 6);
      expect(blackIn(m, 0, 0, null, 10), 0, reason: 'space before is blank');
      expect(blackIn(m, 0, 12), 0, reason: 'space after is blank');
      // line spans x = margin 20 + indent 5 .. 576 - 30 - 7
      expect(m.getPixel(24, 10), isFalse);
      expect(m.getPixel(25, 10), isTrue);
      expect(m.getPixel(538, 11), isTrue);
      expect(m.getPixel(539, 10), isFalse);
      expect(blackIn(m), (539 - 25) * 2);
    });

    test('separator dash/gap pattern is exact', () async {
      final r = await ReceiptRenderer().render(
        Receipt(blocks: [SeparatorBlock(style: SeparatorStyle.dashed, thickness: 1, height: 1, dash: 5, gap: 3)]),
        width: 64,
      );
      final row = [for (var x = 0; x < 16; x++) r.segments.single.getPixel(x, 0) ? 1 : 0];
      expect(row, [1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0]);
    });

    test('line pitch, stretch and letter spacing change the layout', () async {
      Future<MonoBitmap> one(TextFormat f, [String t = 'A\nA\nA']) async => (await ReceiptRenderer().render(
        Receipt(
          blocks: [TextBlock(text: t, format: f)],
        ),
        width: 576,
      )).segments.single;
      const base = TextFormat(font: ReceiptFont.mono, size: 20);
      expect((await one(base.copyWith(lineHeight: 30))).height, 90, reason: '3 lines x 30 dots');
      expect((await one(base.copyWith(lineHeight: 21.5))).height, 66, reason: 'pitch rounds to whole dots (22)');
      int inkWidth(MonoBitmap m) {
        var maxX = 0;
        for (var y = 0; y < m.height; y++) {
          for (var x = 0; x < m.width; x++) {
            if (m.getPixel(x, y) && x > maxX) maxX = x;
          }
        }
        return maxX;
      }

      final normal = inkWidth(await one(base, 'MMMMMMMMMM'));
      final narrow = inkWidth(await one(base.copyWith(stretch: 0.75), 'MMMMMMMMMM'));
      final spaced = inkWidth(await one(base.copyWith(letterSpacing: 4), 'MMMMMMMMMM'));
      expect(narrow, closeTo(normal * 0.75, 4));
      expect(spaced, closeTo(normal + 9 * 4, 3));
    });

    test('alignment and inverted text', () async {
      final r = await ReceiptRenderer().render(
        Receipt(
          blocks: [
            TextBlock(text: 'R', align: HAlign.right),
            TextBlock(text: 'INV', invert: true),
          ],
        ),
        width: 576,
      );
      final m = r.segments.single;
      final first = (r.segments.single.height / 2).floor();
      // right-aligned glyph only in the right quarter
      expect(blackIn(m, 0, 0, 432, first ~/ 2), 0);
      expect(blackIn(m, 432, 0, 576, first ~/ 2), greaterThan(0));
      // inverted block: mostly black, full width
      final y = m.height - 3;
      expect(m.getPixel(0, y) && m.getPixel(575, y), isTrue);
    });

    test('QR code is drawn on whole dots with finder patterns', () async {
      final r = await ReceiptRenderer().render(
        Receipt(
          blocks: [QrBlock(data: 'hello', moduleSize: 4, align: HAlign.left)],
        ),
        width: 384,
      );
      final m = r.segments.single;
      expect(m.height, (21 + 4) * 4);
      const top = 2 * 4; // quiet zone
      // finder pattern: 7x7 modules dark border, light ring, dark 3x3 core
      expect(blackIn(m, 0, top, 28, top + 4), 28 * 4);
      expect(blackIn(m, 4, top + 4, 24, top + 8), 0);
      expect(blackIn(m, 8, top + 8, 20, top + 20), 12 * 12);
      expect(blackIn(m, 21 * 4, 0), 0, reason: 'nothing right of the code');
    });

    test('barcode bars use the module width; invalid data becomes a warning', () async {
      final r = await ReceiptRenderer().render(
        Receipt(
          blocks: [
            BarcodeBlock(symbology: BarcodeSymbology.ean13, data: '400638133393', moduleWidth: 2, showText: false),
          ],
        ),
        width: 576,
      );
      final m = r.segments.single;
      final row = m.height ~/ 2;
      final xs = [
        for (var x = 0; x < 576; x++)
          if (m.getPixel(x, row)) x,
      ];
      expect(xs.last - xs.first + 1, 95 * 2);
      expect(xs.first, (576 - 190) ~/ 2);

      final bad = await ReceiptRenderer().render(
        Receipt(
          blocks: [BarcodeBlock(symbology: BarcodeSymbology.ean13, data: 'nope')],
        ),
        width: 576,
      );
      expect(bad.warnings.single, startsWith('EAN-13'));
      expect(bad.segments, hasLength(1)); // the warning is printed in place
    });

    test('image block is dithered at the requested width and aligned', () async {
      final r = await ReceiptRenderer().render(
        Receipt(
          blocks: [ImageBlock(bytes: testPng(), widthPercent: 50, align: HAlign.right)],
        ),
        width: 576,
      );
      final m = r.segments.single;
      expect(m.height, 144); // 40x20 scaled to 288 wide
      expect(blackIn(m, 0, 0, 288), 0);
      expect(blackIn(m, 288, 0, 576), 288 * 144);
    });

    test('tokens are expanded with the given number', () async {
      final doc = Receipt(blocks: [TextBlock(text: '{n}')]);
      final a = await ReceiptRenderer().render(doc, width: 384, number: 1);
      final b = await ReceiptRenderer().render(doc, width: 384, number: 1);
      final c = await ReceiptRenderer().render(doc, width: 384, number: 8);
      expect(a.segments.single.data, b.segments.single.data);
      expect(a.segments.single.data, isNot(c.segments.single.data));
    });

    // THERMAL_PHOTO_RENDER_DIR=/tmp/x flutter test test/receipt_test.dart
    // writes every template's ESC/POS job for tools/escpos_render.py.
    test('dump template jobs when THERMAL_PHOTO_RENDER_DIR is set', () async {
      final dir = Platform.environment['THERMAL_PHOTO_RENDER_DIR'];
      if (dir == null) return;
      for (final t in builtInTemplates) {
        for (final p in [PrinterProfile.hz8360, PrinterProfile.mp583]) {
          final r = await ReceiptRenderer().render(t.build(), width: p.dotsPerLine, now: now);
          final name = t.name.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
          File('$dir/${name}_${p.dotsPerLine}.bin').writeAsBytesSync(buildReceiptJob([r], p));
        }
      }
    }, testOn: 'vm');

    // G1_CALIBRATE=1 flutter test test/receipt_test.dart --plain-name 'G1 calibration'
    // prints, per g1Layout line rendered alone: height and first ink row.
    // tools/calibrate_g1.py turns that into the g1Before table.
    test('G1 calibration metrics', () async {
      if (Platform.environment['G1_CALIBRATE'] == null) return;
      final rows = <String>[];
      for (final e in g1Layout) {
        // 20 dots of headroom: tight line pitches draw caps above the block top.
        final b = e.build(BlockSpacing(before: 20, left: e.left, right: e.right));
        final r = await ReceiptRenderer().render(Receipt(marginRight: 34, blocks: [b]), width: 576);
        final m = r.segments.single;
        var top = -1;
        for (var y = 0; y < m.height && top < 0; y++) {
          for (var x = 0; x < m.width; x++) {
            if (m.getPixel(x, y)) {
              top = y;
              break;
            }
          }
        }
        rows.add('${e.target} ${m.height - 20} ${top - 20}');
      }
      final head = await ReceiptRenderer().render(
        Receipt(marginRight: 34, blocks: g1Receipt().blocks.take(2).toList()),
        width: 576,
      );
      // ignore: avoid_print
      print('G1CAL head ${head.segments.single.height}\nG1CAL ${rows.join('\nG1CAL ')}');
    }, testOn: 'vm');

    test('built-in templates render without warnings on both widths', () async {
      for (final t in builtInTemplates) {
        for (final w in [384, 576]) {
          final r = await ReceiptRenderer().render(t.build(), width: w, now: now);
          expect(r.warnings, isEmpty, reason: '${t.name} @ $w');
          expect(r.height, greaterThan(200));
        }
      }
    });
  });
}
