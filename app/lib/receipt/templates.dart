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
  BuiltInTemplate('G1', 'Boutique sales slip: logo, brand, ticket header, item, payment, VAT, return policy', g1Receipt),
];

Receipt shopReceipt() {
  const mono = TextFormat(font: ReceiptFont.mono, size: 22);
  ColumnsBlock item(String name, String price) => ColumnsBlock(
        cells: [ColumnCell(text: name, flex: 3), ColumnCell(text: price, align: HAlign.right)],
        format: mono,
        fill: true,
      );
  return Receipt(name: 'Shop receipt', blocks: [
    TextBlock(text: 'CORNER CAFÉ', align: HAlign.center, format: const TextFormat(size: 30, bold: true, scaleX: 1, scaleY: 2)),
    TextBlock(text: 'Hauptstraße 12 · 10115 Berlin\nTel. 030 1234567', align: HAlign.center, format: const TextFormat(size: 20)),
    SeparatorBlock(style: SeparatorStyle.blank, height: 8),
    ColumnsBlock(
      cells: const [ColumnCell(text: '{date:dd.MM.yyyy}'), ColumnCell(text: 'No. {n:0000}', align: HAlign.center), ColumnCell(text: '{time}', align: HAlign.right)],
      format: const TextFormat(size: 20),
    ),
    SeparatorBlock(style: SeparatorStyle.dashed),
    item('Cappuccino', '3.20'),
    item('Croissant', '2.10'),
    item('Käsekuchen', '3.90'),
    item('Orange juice 0.3 l', '3.50'),
    SeparatorBlock(style: SeparatorStyle.double, thickness: 2, height: 20),
    ColumnsBlock(
      cells: const [ColumnCell(text: 'TOTAL', flex: 2), ColumnCell(text: '€ 12.70', align: HAlign.right, flex: 2)],
      format: const TextFormat(font: ReceiptFont.mono, size: 26, bold: true, scaleY: 2),
    ),
    ColumnsBlock(
      cells: const [ColumnCell(text: 'incl. 7% VAT', flex: 2), ColumnCell(text: '0.83', align: HAlign.right)],
      format: const TextFormat(font: ReceiptFont.mono, size: 20),
    ),
    SeparatorBlock(style: SeparatorStyle.dashed),
    TextBlock(text: 'Thank you & see you soon!', align: HAlign.center, format: const TextFormat(size: 24, bold: true)),
    TextBlock(text: 'Rate your visit:', align: HAlign.center, format: const TextFormat(size: 20)),
    QrBlock(data: 'https://example.com/feedback?r={n}', moduleSize: 5),
    BarcodeBlock(data: 'R{n:000000}', height: 60, moduleWidth: 2),
    FeedBlock(mm: 3),
  ]);
}

Receipt todoNote() => Receipt(name: 'Note / to-do list', blocks: [
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
    ]);

Receipt priceLabel() => Receipt(name: 'Price label', blocks: [
      TextBlock(text: 'Organic Honey', align: HAlign.center, format: const TextFormat(size: 32, bold: true)),
      TextBlock(text: '500 g · from local beekeepers', align: HAlign.center, format: const TextFormat(size: 20)),
      SeparatorBlock(style: SeparatorStyle.solid, thickness: 2, height: 16),
      BarcodeBlock(symbology: BarcodeSymbology.ean13, data: '400638133393', moduleWidth: 3, height: 90),
      TextBlock(text: '€ 6.49', align: HAlign.center, format: const TextFormat(size: 40, bold: true, scaleX: 2, scaleY: 2)),
      FeedBlock(mm: 2),
      CutBlock(),
    ]);

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
Receipt g1Receipt() {
  const small = TextFormat(font: ReceiptFont.mono, size: 18);
  const body = TextFormat(font: ReceiptFont.mono, size: 21);
  const tiny = TextFormat(font: ReceiptFont.mono, size: 16);
  ColumnsBlock row(List<(String, HAlign)> cells, {TextFormat format = small, List<int>? flex}) => ColumnsBlock(
        cells: [
          for (var i = 0; i < cells.length; i++) ColumnCell(text: cells[i].$1, align: cells[i].$2, flex: flex?[i] ?? 1),
        ],
        format: format,
      );
  // Ticket header: 6 fields; weights sized so it fits 384 dots (58 mm) unwrapped.
  const hdr = TextFormat(font: ReceiptFont.mono, size: 15);
  const hdrFlex = [3, 4, 3, 2, 3, 2];
  const l = HAlign.left, r = HAlign.right;
  return Receipt(name: 'G1', blocks: [
    ImageBlock(bytes: placeholderLogoPng(), name: 'logo (replace me)', widthPercent: 30),
    TextBlock(text: 'BRAND', align: HAlign.center, format: const TextFormat(size: 34, bold: true, scaleX: 2)),
    TextBlock(
      text: '1 Rue Exemple\n75000 PARIS\nTEL : 01 23 45 67 89\nFR00000000000',
      align: HAlign.center,
      format: small,
    ),
    SeparatorBlock(style: SeparatorStyle.blank, height: 10),
    row([('Numero', l), ('Date', l), ('Heure', l), ('Etab', l), ('Caisse', l), ('Vd', l)], format: hdr, flex: hdrFlex),
    row([('{n:00000}', l), ('{date:dd/MM/yy}', l), ('{time}', l), ('FR1', l), ('FR1C1', l), ('ABC', l)],
        format: hdr, flex: hdrFlex),
    TextBlock(text: 'Client :      F0000001\nM. / Mme CLIENT', format: body),
    SeparatorBlock(style: SeparatorStyle.blank, height: 8),
    TextBlock(text: 'FRANCE', format: body),
    SeparatorBlock(style: SeparatorStyle.solid),
    row([('Désignation', l), ('Montant TTC', r)], format: body),
    SeparatorBlock(style: SeparatorStyle.solid),
    ColumnsBlock(
      cells: const [ColumnCell(text: '1x  PORTE-CARTES', flex: 3), ColumnCell(text: '250,00', align: HAlign.right)],
      format: body,
    ),
    TextBlock(text: '    REF0000000000', format: tiny),
    SeparatorBlock(style: SeparatorStyle.blank, height: 10),
    TextBlock(text: '***** 250,00 € *****', align: HAlign.center, format: const TextFormat(font: ReceiptFont.mono, size: 26, bold: true, scaleY: 2)),
    TextBlock(text: '1 article', align: HAlign.center, format: tiny),
    SeparatorBlock(style: SeparatorStyle.solid),
    TextBlock(text: 'Règlement', align: HAlign.center, format: body),
    SeparatorBlock(style: SeparatorStyle.solid),
    row([('Carte bancaire', l), ('250,00', r)], format: body),
    SeparatorBlock(style: SeparatorStyle.solid),
    row([('Taxe', l), ('Montant', r), ('Taux', r), ('Base HT', r)]),
    row([('TVA', l), ('41,67', r), ('20,00%', r), ('208,33', r)]),
    SeparatorBlock(style: SeparatorStyle.solid),
    SeparatorBlock(style: SeparatorStyle.blank, height: 6),
    TextBlock(
      text: '1 Rue Exemple\nVous avez été conseillé(e) par',
      align: HAlign.center,
      format: body,
    ),
    TextBlock(text: 'Prénom', align: HAlign.center, format: const TextFormat(font: ReceiptFont.mono, size: 22, bold: true)),
    SeparatorBlock(style: SeparatorStyle.blank, height: 10),
    TextBlock(
      text: 'Les articles non portés et retournés dans leur emballage d\'origine peuvent être échangés ou '
          'faire l\'objet d\'un avoir dans les trente (30) jours suivant l\'achat, sur présentation de ce '
          'ticket dans la boutique d\'achat. L\'avoir est valable six (6) mois. Aucun remboursement.',
      format: tiny,
    ),
    SeparatorBlock(style: SeparatorStyle.blank, height: 8),
    TextBlock(
      text: 'Les articles personnalisés et les commandes spéciales ne sont ni repris ni échangés. '
          'Pour toute question relative à l\'après-vente, merci de contacter la boutique.',
      format: tiny,
    ),
    SeparatorBlock(style: SeparatorStyle.dashed, height: 18),
    TextBlock(
      text: 'Unworn items returned in their original packaging can be exchanged or credited within '
          'thirty (30) days of purchase on presentation of this ticket at the boutique of purchase. '
          'Store credit is valid for six (6) months. No refunds.',
      format: tiny,
    ),
    SeparatorBlock(style: SeparatorStyle.blank, height: 8),
    TextBlock(
      text: 'Please keep this ticket for any after-sales service. Personalized items and special '
          'orders cannot be returned or exchanged.',
      format: tiny,
    ),
    FeedBlock(mm: 4),
    CutBlock(),
  ]);
}
