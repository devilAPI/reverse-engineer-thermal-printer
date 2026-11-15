import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'model.dart';

/// Built-in sample receipts, offered in the editor's template menu.
/// Functions (not constants) so each call gets fresh block ids.
class BuiltInTemplate {
  const BuiltInTemplate(this.name, this.description, this.build);

  final String name;
  final String description;
  final Receipt Function() build;
}

final builtInTemplates = <BuiltInTemplate>[
  BuiltInTemplate('Shop receipt', 'Header, items with prices, total, QR code, barcode', shopReceipt),
  BuiltInTemplate('Note / to-do list', 'Inverted title, date, check boxes', todoNote),
  BuiltInTemplate('Price label', 'Product name, EAN-13 barcode, big price, cut', priceLabel),
  BuiltInTemplate(
    'G1',
    'Boutique sales slip: logo, brand, ticket header, item, payment, VAT, return policy',
    g1Receipt,
  ),
];

Receipt shopReceipt() {
  const mono = TextFormat(font: ReceiptFont.mono, size: 22);
  ColumnsBlock item(String name, String price) => ColumnsBlock(
    cells: [
      ColumnCell(text: name, flex: 3),
      ColumnCell(text: price, align: HAlign.right),
    ],
    format: mono,
    fill: true,
  );
  return Receipt(
    name: 'Shop receipt',
    blocks: [
      TextBlock(
        text: 'CORNER CAFÉ',
        align: HAlign.center,
        format: const TextFormat(size: 30, bold: true, scaleX: 1, scaleY: 2),
      ),
      TextBlock(
        text: 'Hauptstraße 12 · 10115 Berlin\nTel. 030 1234567',
        align: HAlign.center,
        format: const TextFormat(size: 20),
      ),
      SeparatorBlock(style: SeparatorStyle.blank, height: 8),
      ColumnsBlock(
        cells: const [
          ColumnCell(text: '{date:dd.MM.yyyy}'),
          ColumnCell(text: 'No. {n:0000}', align: HAlign.center),
          ColumnCell(text: '{time}', align: HAlign.right),
        ],
        format: const TextFormat(size: 20),
      ),
      SeparatorBlock(style: SeparatorStyle.dashed),
      item('Cappuccino', '3.20'),
      item('Croissant', '2.10'),
      item('Käsekuchen', '3.90'),
      item('Orange juice 0.3 l', '3.50'),
      SeparatorBlock(style: SeparatorStyle.double, thickness: 2, height: 20),
      ColumnsBlock(
        cells: const [
          ColumnCell(text: 'TOTAL', flex: 2),
          ColumnCell(text: '€ 12.70', align: HAlign.right, flex: 2),
        ],
        format: const TextFormat(font: ReceiptFont.mono, size: 26, bold: true, scaleY: 2),
      ),
      ColumnsBlock(
        cells: const [
          ColumnCell(text: 'incl. 7% VAT', flex: 2),
          ColumnCell(text: '0.83', align: HAlign.right),
        ],
        format: const TextFormat(font: ReceiptFont.mono, size: 20),
      ),
      SeparatorBlock(style: SeparatorStyle.dashed),
      TextBlock(
        text: 'Thank you & see you soon!',
        align: HAlign.center,
        format: const TextFormat(size: 24, bold: true),
      ),
      TextBlock(text: 'Rate your visit:', align: HAlign.center, format: const TextFormat(size: 20)),
      QrBlock(data: 'https://example.com/feedback?r={n}', moduleSize: 5),
      BarcodeBlock(data: 'R{n:000000}', height: 60, moduleWidth: 2),
      FeedBlock(mm: 3),
    ],
  );
}

Receipt todoNote() => Receipt(
  name: 'Note / to-do list',
  blocks: [
    TextBlock(text: 'TO DO', align: HAlign.center, invert: true, format: const TextFormat(size: 36, bold: true)),
    TextBlock(text: '{date:dd.MM.yyyy}', align: HAlign.right, format: const TextFormat(size: 20)),
    SeparatorBlock(style: SeparatorStyle.blank, height: 8),
    TextBlock(
      text: '☐ Buy milk & eggs\n☐ Call Grandma\n☐ Return library books\n☐ Water the plants',
      format: const TextFormat(size: 28),
    ),
    SeparatorBlock(style: SeparatorStyle.dotted, height: 24),
    TextBlock(text: 'Notes:', format: const TextFormat(size: 22, bold: true, underline: true)),
    FeedBlock(mm: 20),
  ],
);

Receipt priceLabel() => Receipt(
  name: 'Price label',
  blocks: [
    TextBlock(text: 'Organic Honey', align: HAlign.center, format: const TextFormat(size: 32, bold: true)),
    TextBlock(text: '500 g · from local beekeepers', align: HAlign.center, format: const TextFormat(size: 20)),
    SeparatorBlock(style: SeparatorStyle.solid, thickness: 2, height: 16),
    BarcodeBlock(symbology: BarcodeSymbology.ean13, data: '400638133393', moduleWidth: 3, height: 90),
    TextBlock(
      text: '€ 6.49',
      align: HAlign.center,
      format: const TextFormat(size: 40, bold: true, scaleX: 2, scaleY: 2),
    ),
    FeedBlock(mm: 2),
    CutBlock(),
  ],
);

/// Placeholder logo for templates: a solid quatrefoil emblem (replace it with
/// your own logo in the image block). Generated, so no asset is needed.
Uint8List placeholderLogoPng() {
  const n = 240;
  final im = img.Image(width: n, height: n)..clear(img.ColorRgb8(255, 255, 255));
  const r = 58.0, c = n / 2, off = 52.0;
  const centers = [(c, c - off), (c, c + off), (c - off, c), (c + off, c)];
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      final inPetal = centers.any((p) => (x - p.$1) * (x - p.$1) + (y - p.$2) * (y - p.$2) <= r * r);
      final inCore = (x - c) * (x - c) + (y - c) * (y - c) <= 40 * 40;
      if (inPetal || inCore) im.setPixelRgb(x, y, 0, 0, 0);
    }
  }
  return img.encodePng(im);
}

/// "G1": layout of a French luxury-boutique sales slip — logo, brand, store
/// address, ticket header table, client, item with reference, big total,
/// payment, VAT breakdown, salesperson and bilingual return policy.
/// All names/addresses/amounts are placeholders.
///
/// Spacing is calibrated 1:1 to a photographed original (80 mm paper):
/// every line's cap top sits at the measured dot position (see
/// docs/RECEIPT_EDITOR.md, "G1 calibration"). Content is 542 dots wide
/// (right margin 34 of 576) like the original; it starts ~12 dots further
/// right because this printer's printable area begins further from the edge.
Receipt g1Receipt() {
  final blocks = <ReceiptBlock>[
    ImageBlock(bytes: placeholderLogoPng(), name: 'logo (replace me)', widthPercent: 30),
    TextBlock(
      text: 'BRAND',
      align: HAlign.center,
      format: const TextFormat(size: 34, bold: true, scaleX: 2),
      spacing: const BlockSpacing(after: 24),
    ),
    for (final (i, e) in g1Layout.indexed) e.build(BlockSpacing(before: g1Before[i], left: e.left, right: e.right)),
  ];
  return Receipt(name: 'G1', marginRight: 34, blocks: blocks);
}

/// One measured line of G1: block factory, target cap-top (dots, relative to
/// the store-ID line) and horizontal indents.
class G1Line {
  const G1Line(this.target, this.build, {this.left = 3, this.right = 0});
  final int target;
  final ReceiptBlock Function(BlockSpacing sp) build;
  final int left, right;
}

const _small = TextFormat(font: ReceiptFont.mono, size: 23, stretch: 0.7, lineHeight: 21);
const _hdr = TextFormat(font: ReceiptFont.mono, size: 23, stretch: 0.72, lineHeight: 24);
const _body = TextFormat(font: ReceiptFont.mono, size: 23, lineHeight: 26);
const _ref = TextFormat(font: ReceiptFont.mono, size: 23, stretch: 0.74, lineHeight: 24);
const _policy = TextFormat(font: ReceiptFont.mono, size: 23, stretch: 0.74, lineHeight: 22);

SeparatorBlock _sep(BlockSpacing sp) =>
    SeparatorBlock(style: SeparatorStyle.dashed, thickness: 2, height: 2, dash: 6, gap: 4, spacing: sp);

final g1Layout = <G1Line>[
  // store block, centred, condensed
  G1Line(-64, (sp) => TextBlock(text: '1 Rue Exemple', align: HAlign.center, format: _small, spacing: sp)),
  G1Line(-43, (sp) => TextBlock(text: '75000 PARIS', align: HAlign.center, format: _small, spacing: sp)),
  G1Line(-21, (sp) => TextBlock(text: 'TEL : 01 23 45 67 89', align: HAlign.center, format: _small, spacing: sp)),
  G1Line(0, (sp) => TextBlock(text: 'FR0000000000000', align: HAlign.center, format: _small, spacing: sp)),
  // ticket header: column starts measured at 5/108/203/287/362/436 dots
  G1Line(
    30,
    (sp) => _hdrRow(['Numero', 'Date', 'Heure', 'Etab', 'Caisse', 'Vd'], _hdr.copyWith(bold: true), sp),
    left: 5,
  ),
  G1Line(54, (sp) => _hdrRow(['{n:00000}', '{date:dd/MM/yy}', '{time}', 'FR1', 'FR1C1', 'ABC'], _hdr, sp), left: 5),
  G1Line(88, (sp) => TextBlock(text: 'Client :    F0000001', format: _body, spacing: sp)),
  G1Line(116, (sp) => TextBlock(text: 'M. / Mme CLIENT', format: _body, spacing: sp)),
  G1Line(141, (sp) => TextBlock(text: '1 RUE DU CLIENT', format: _body, spacing: sp)),
  G1Line(168, (sp) => TextBlock(text: '00000 VILLE', format: _body, spacing: sp)),
  G1Line(192, (sp) => TextBlock(text: 'FRANCE', format: _body, spacing: sp)),
  G1Line(234, _sep, left: 0),
  G1Line(
    254,
    (sp) => ColumnsBlock(
      cells: const [
        ColumnCell(text: 'Désignation'),
        ColumnCell(text: 'Montant TTC', align: HAlign.right),
      ],
      format: _body,
      spacing: sp,
    ),
  ),
  G1Line(288, _sep, left: 0),
  // item: "1x" at 5, description at 58, price right-aligned
  G1Line(
    310,
    (sp) => ColumnsBlock(
      cells: const [
        ColumnCell(text: '1x'),
        ColumnCell(text: 'PORTE-CARTES', flex: 6),
        ColumnCell(text: '250,00', align: HAlign.right, flex: 2),
      ],
      format: _body,
      gap: 0,
      spacing: sp,
    ),
  ),
  G1Line(336, (sp) => TextBlock(text: 'REF0000000000', format: _ref, spacing: sp), left: 58),
  G1Line(
    379,
    (sp) => ColumnsBlock(
      cells: const [
        ColumnCell(text: '*****', flex: 2),
        ColumnCell(text: '250,00 €', align: HAlign.center, flex: 3),
        ColumnCell(text: '*****', align: HAlign.right, flex: 2),
      ],
      format: const TextFormat(font: ReceiptFont.mono, size: 23, bold: true, scaleX: 2, scaleY: 2, lineHeight: 52),
      gap: 0,
      spacing: sp,
    ),
  ),
  G1Line(
    437,
    (sp) => TextBlock(
      text: '1 article',
      align: HAlign.center,
      format: const TextFormat(font: ReceiptFont.mono, size: 21, bold: true, stretch: 0.8, lineHeight: 22),
      spacing: sp,
    ),
  ),
  G1Line(493, _sep, left: 0),
  G1Line(514, (sp) => TextBlock(text: 'Règlement', align: HAlign.center, format: _body, spacing: sp)),
  G1Line(546, _sep, left: 0),
  G1Line(
    566,
    (sp) => ColumnsBlock(
      cells: const [
        ColumnCell(text: 'Carte bancaire', flex: 3),
        ColumnCell(text: '250,00', align: HAlign.right),
      ],
      format: _body,
      spacing: sp,
    ),
  ),
  G1Line(609, _sep, left: 0),
  // VAT table: right edges of Montant/Taux/Base measured at 260/370/542
  G1Line(629, (sp) => _vatRow(['Taxe', 'Montant', 'Taux', 'Base HT'], sp)),
  G1Line(663, _sep, left: 0),
  G1Line(682, (sp) => _vatRow(['TVA', '41,67', '20,00%', '208,33'], sp)),
  G1Line(746, (sp) => TextBlock(text: '1 Rue Exemple', align: HAlign.center, format: _body, spacing: sp)),
  G1Line(
    781,
    (sp) => TextBlock(text: 'Vous avez été conseillé(e) par', align: HAlign.center, format: _body, spacing: sp),
  ),
  G1Line(806, (sp) => TextBlock(text: 'Prénom', align: HAlign.center, format: _body.copyWith(bold: true), spacing: sp)),
  // policy: 48 characters per line (~498 dots), 22-dot pitch
  G1Line(
    842,
    (sp) => _policyText(
      'Les articles non portés et retournés dans leur emballage d\'origine peuvent être échangés ou '
      'faire l\'objet d\'un avoir dans les trente (30) jours suivant l\'achat, sur présentation de ce '
      'ticket dans la boutique d\'achat. L\'avoir est valable six (6) mois. Aucun remboursement.',
      sp,
    ),
    right: 44,
  ),
  G1Line(
    1047,
    (sp) => _policyText(
      'Les articles personnalisés et les commandes spéciales ne sont ni repris ni échangés. '
      'Pour toute question relative à l\'après-vente, merci de contacter la boutique.',
      sp,
    ),
    right: 44,
  ),
  G1Line(
    1274,
    (sp) => _policyText(
      'Unworn items returned in their original packaging can be exchanged or credited within '
      'thirty (30) days of purchase on presentation of this ticket at the boutique of purchase. '
      'Store credit is valid for six (6) months. No refunds.',
      sp,
    ),
    right: 44,
  ),
  G1Line(
    1528,
    (sp) => _policyText(
      'Please keep this ticket for any after-sales service. Personalized items and special '
      'orders cannot be returned or exchanged.',
      sp,
    ),
    right: 44,
  ),
];

/// Space above each [g1Layout] line in dots, from tools/calibrate_g1 (see docs):
/// target cap top − (bottom of the previous line + the font's cap offset).
const g1Before = <int>[
  8,
  0,
  0,
  0,
  9,
  0,
  7,
  1,
  0,
  0,
  0,
  18,
  16,
  10,
  16,
  2,
  14,
  13,
  34,
  17,
  8,
  15,
  20,
  14,
  12,
  13,
  39,
  10,
  0,
  12,
  73,
  138,
  144, //
];

ColumnsBlock _hdrRow(List<String> t, TextFormat f, BlockSpacing sp) => ColumnsBlock(
  cells: [
    for (final (i, x) in t.indexed) ColumnCell(text: x, flex: const [11, 10, 9, 8, 8, 12][i]),
  ],
  format: f,
  gap: 0,
  spacing: sp,
);

ColumnsBlock _vatRow(List<String> t, BlockSpacing sp) => ColumnsBlock(
  cells: [
    ColumnCell(text: t[0], flex: 6),
    ColumnCell(text: t[1], align: HAlign.right, flex: 6),
    ColumnCell(text: t[2], align: HAlign.right, flex: 5),
    ColumnCell(text: t[3], align: HAlign.right, flex: 8),
  ],
  format: _body,
  gap: 0,
  spacing: sp,
);

TextBlock _policyText(String t, BlockSpacing sp) => TextBlock(text: t, format: _policy, spacing: sp);
