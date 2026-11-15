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
