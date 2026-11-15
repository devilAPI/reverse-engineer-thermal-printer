import 'dart:convert';
import 'dart:typed_data';

import '../core/image_pipeline.dart';

/// Receipt document model: an ordered list of blocks, (de)serialisable to
/// JSON. Pure Dart, immutable — every edit produces a new object, which makes
/// undo/redo a simple list of snapshots. See docs/RECEIPT_EDITOR.md.

/// Current JSON format version. Bump when the format changes incompatibly
/// and keep [Receipt.fromJson] able to read the older versions.
const receiptFormatVersion = 1;
const receiptFormatTag = 'thermal_photo.receipt';

/// Horizontal alignment of a block (or a column cell) on the paper.
enum HAlign { left, center, right }

/// Bundled fonts (assets/fonts, DejaVu). Bundled rather than system fonts so
/// the raster is identical on every platform.
enum ReceiptFont {
  sans('ReceiptSans', 'Sans'),
  mono('ReceiptMono', 'Mono');

  const ReceiptFont(this.family, this.label);
  final String family;
  final String label;
}

enum SeparatorStyle { solid, dashed, dotted, double, blank }

enum QrEcc { low, medium, quartile, high }

enum BarcodeSymbology {
  code128('Code 128'),
  ean13('EAN-13'),
  ean8('EAN-8'),
  upcA('UPC-A'),
  code39('Code 39');

  const BarcodeSymbology(this.label);
  final String label;
}

T _enum<T extends Enum>(List<T> values, Object? name, T fallback) => values.asNameMap()[name] ?? fallback;

double _d(Object? v, double fallback) => v is num ? v.toDouble() : fallback;
int _i(Object? v, int fallback) => v is num ? v.round() : fallback;
bool _b(Object? v, [bool fallback = false]) => v is bool ? v : fallback;
String _s(Object? v, [String fallback = '']) => v is String ? v : fallback;

int _idSeq = 0;

/// Process-unique block id (keys for the reorderable list; not serialised).
String newBlockId() => 'b${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_idSeq++).toRadixString(36)}';

/// Character formatting shared by text and column blocks.
class TextFormat {
  const TextFormat({
    this.font = ReceiptFont.sans,
    this.size = 24,
    this.bold = false,
    this.underline = false,
    this.scaleX = 1,
    this.scaleY = 1,
    this.stretch = 1,
    this.letterSpacing = 0,
    this.lineHeight,
  });

  final ReceiptFont font;

  /// Font size in printer dots (8 dots = 1 mm at 203 dpi).
  final double size;
  final bool bold;
  final bool underline;

  /// Stretch factors 1..4, like the printer's ESC ! double width/height.
  final int scaleX;
  final int scaleY;

  /// Free horizontal stretch 0.5..2 on top of [scaleX] — narrow (condensed)
  /// or wide lettering, like the printer's own Font B vs Font A.
  final double stretch;

  /// Extra space between characters in dots (negative = tighter), -5..40.
  final double letterSpacing;

  /// Line pitch in dots (baseline to baseline, after [scaleY]); null = the
  /// font's natural line height. Rendered in whole dots (rounded). Receipt
  /// printers default to 30 dots.
  final double? lineHeight;

  TextFormat copyWith({
    ReceiptFont? font,
    double? size,
    bool? bold,
    bool? underline,
    int? scaleX,
    int? scaleY,
    double? stretch,
    double? letterSpacing,
    double? lineHeight,
    bool clearLineHeight = false,
  }) => TextFormat(
    font: font ?? this.font,
    size: size ?? this.size,
    bold: bold ?? this.bold,
    underline: underline ?? this.underline,
    scaleX: scaleX ?? this.scaleX,
    scaleY: scaleY ?? this.scaleY,
    stretch: stretch ?? this.stretch,
    letterSpacing: letterSpacing ?? this.letterSpacing,
    lineHeight: clearLineHeight ? null : (lineHeight ?? this.lineHeight),
  );

  Map<String, Object?> toJson() => {
    'font': font.name,
    'size': size,
    'bold': bold,
    'underline': underline,
    'scaleX': scaleX,
    'scaleY': scaleY,
    if (stretch != 1) 'stretch': stretch,
    if (letterSpacing != 0) 'letterSpacing': letterSpacing,
    if (lineHeight != null) 'lineHeight': lineHeight,
  };

  factory TextFormat.fromJson(Map<String, Object?> j, [TextFormat d = const TextFormat()]) => TextFormat(
    font: _enum(ReceiptFont.values, j['font'], d.font),
    size: _d(j['size'], d.size).clamp(6, 400),
    bold: _b(j['bold'], d.bold),
    underline: _b(j['underline'], d.underline),
    scaleX: _i(j['scaleX'], d.scaleX).clamp(1, 4),
    scaleY: _i(j['scaleY'], d.scaleY).clamp(1, 4),
    stretch: _d(j['stretch'], d.stretch).clamp(0.5, 2),
    letterSpacing: _d(j['letterSpacing'], d.letterSpacing).clamp(-5, 40),
    lineHeight: j['lineHeight'] is num ? _d(j['lineHeight'], 30).clamp(4, 400) : d.lineHeight,
  );

  @override
  bool operator ==(Object other) =>
      other is TextFormat &&
      other.font == font &&
      other.size == size &&
      other.bold == bold &&
      other.underline == underline &&
      other.scaleX == scaleX &&
      other.scaleY == scaleY &&
      other.stretch == stretch &&
      other.letterSpacing == letterSpacing &&
      other.lineHeight == lineHeight;

  @override
  int get hashCode => Object.hash(font, size, bold, underline, scaleX, scaleY, stretch, letterSpacing, lineHeight);
}

/// Space around a block, in printer dots (8 dots = 1 mm): blank paper
/// before/after it and indents from the receipt margins.
class BlockSpacing {
  const BlockSpacing({this.before = 0, this.after = 0, this.left = 0, this.right = 0});

  static const zero = BlockSpacing();

  final int before;
  final int after;
  final int left;
  final int right;

  bool get isZero => before == 0 && after == 0 && left == 0 && right == 0;

  BlockSpacing copyWith({int? before, int? after, int? left, int? right}) => BlockSpacing(
    before: before ?? this.before,
    after: after ?? this.after,
    left: left ?? this.left,
    right: right ?? this.right,
  );

  Map<String, Object?> toJson() => {
    if (before != 0) 'spaceBefore': before,
    if (after != 0) 'spaceAfter': after,
    if (left != 0) 'indentLeft': left,
    if (right != 0) 'indentRight': right,
  };

  /// All four keys, zeros included (used to overwrite existing values).
  Map<String, Object?> _all(BlockSpacing s) => {
    'spaceBefore': s.before,
    'spaceAfter': s.after,
    'indentLeft': s.left,
    'indentRight': s.right,
  };

  factory BlockSpacing.fromJson(Map<String, Object?> j) => BlockSpacing(
    before: _i(j['spaceBefore'], 0).clamp(0, 800),
    after: _i(j['spaceAfter'], 0).clamp(0, 800),
    left: _i(j['indentLeft'], 0).clamp(0, 600),
    right: _i(j['indentRight'], 0).clamp(0, 600),
  );

  @override
  bool operator ==(Object other) =>
      other is BlockSpacing &&
      other.before == before &&
      other.after == after &&
      other.left == left &&
      other.right == right;

  @override
  int get hashCode => Object.hash(before, after, left, right);
}

/// Base class of all blocks. [id] identifies a block within an editing
/// session; it is regenerated on load and not part of the JSON.
sealed class ReceiptBlock {
  ReceiptBlock({String? id, this.spacing = BlockSpacing.zero}) : id = id ?? newBlockId();

  final String id;

  /// Space before/after and indents, common to every block type.
  final BlockSpacing spacing;

  /// JSON `type` discriminator.
  String get type;

  Map<String, Object?> toJson() => {'type': type, ..._fields(), ...spacing.toJson()};
  Map<String, Object?> _fields();

  /// Same content, fresh id (duplicate).
  ReceiptBlock duplicate() => ReceiptBlock.fromJson(toJson())!;

  /// Same block (same id) with different [spacing].
  ReceiptBlock withSpacing(BlockSpacing s) =>
      ReceiptBlock.fromJson({...toJson(), ...BlockSpacing.zero._all(s)}, id: id)!;

  /// Null for unknown block types (newer app version) — the caller skips them.
  static ReceiptBlock? fromJson(Map<String, Object?> j, {String? id}) => switch (j['type']) {
    'text' => TextBlock.fromJson(j, id: id),
    'columns' => ColumnsBlock.fromJson(j, id: id),
    'separator' => SeparatorBlock.fromJson(j, id: id),
    'image' => ImageBlock.fromJson(j, id: id),
    'qr' => QrBlock.fromJson(j, id: id),
    'barcode' => BarcodeBlock.fromJson(j, id: id),
    'feed' => FeedBlock.fromJson(j, id: id),
    'cut' => CutBlock(id: id, spacing: BlockSpacing.fromJson(j)),
    _ => null,
  };
}

class TextBlock extends ReceiptBlock {
  TextBlock({
    super.id,
    super.spacing,
    this.text = '',
    this.align = HAlign.left,
    this.format = const TextFormat(),
    this.invert = false,
  });

  /// Multi-line text; may contain placeholder tokens like `{date}`.
  final String text;
  final HAlign align;
  final TextFormat format;

  /// White text on a black bar.
  final bool invert;

  @override
  String get type => 'text';

  TextBlock copyWith({String? text, HAlign? align, TextFormat? format, bool? invert}) => TextBlock(
    id: id,
    spacing: spacing,
    text: text ?? this.text,
    align: align ?? this.align,
    format: format ?? this.format,
    invert: invert ?? this.invert,
  );

  @override
  Map<String, Object?> _fields() => {'text': text, 'align': align.name, ...format.toJson(), 'invert': invert};

  factory TextBlock.fromJson(Map<String, Object?> j, {String? id}) => TextBlock(
    id: id,
    spacing: BlockSpacing.fromJson(j),
    text: _s(j['text']),
    align: _enum(HAlign.values, j['align'], HAlign.left),
    format: TextFormat.fromJson(j),
    invert: _b(j['invert']),
  );
}

/// One cell of a [ColumnsBlock].
class ColumnCell {
  const ColumnCell({this.text = '', this.align = HAlign.left, this.flex = 1});

  final String text;
  final HAlign align;

  /// Relative width (like Flutter's Expanded.flex), 1..12.
  final int flex;

  ColumnCell copyWith({String? text, HAlign? align, int? flex}) =>
      ColumnCell(text: text ?? this.text, align: align ?? this.align, flex: flex ?? this.flex);

  Map<String, Object?> toJson() => {'text': text, 'align': align.name, 'flex': flex};

  factory ColumnCell.fromJson(Map<String, Object?> j) => ColumnCell(
    text: _s(j['text']),
    align: _enum(HAlign.values, j['align'], HAlign.left),
    flex: _i(j['flex'], 1).clamp(1, 12),
  );
}

/// A row of 2–3 cells, e.g. `item ........ price`.
class ColumnsBlock extends ReceiptBlock {
  ColumnsBlock({
    super.id,
    super.spacing,
    this.cells = const [ColumnCell(flex: 3), ColumnCell(align: HAlign.right)],
    this.format = const TextFormat(),
    this.fill = false,
    this.gap,
  }) : assert(cells.length >= 2 && cells.length <= maxCells);

  /// Tables like a ticket header (6 fields) or a VAT line (4) need more than 3.
  static const maxCells = 6;

  final List<ColumnCell> cells;
  final TextFormat format;

  /// Dot leader between neighbouring cells (single-line cells only).
  final bool fill;

  /// Space between cells in dots; null = automatic (8, or 4 for >3 cells).
  final int? gap;

  @override
  String get type => 'columns';

  ColumnsBlock copyWith({List<ColumnCell>? cells, TextFormat? format, bool? fill, int? gap, bool autoGap = false}) =>
      ColumnsBlock(
        id: id,
        spacing: spacing,
        cells: cells ?? this.cells,
        format: format ?? this.format,
        fill: fill ?? this.fill,
        gap: autoGap ? null : (gap ?? this.gap),
      );

  @override
  Map<String, Object?> _fields() => {
    'cells': [for (final c in cells) c.toJson()],
    'fill': fill,
    if (gap != null) 'gap': gap,
    ...format.toJson(),
  };

  factory ColumnsBlock.fromJson(Map<String, Object?> j, {String? id}) {
    var cells = [
      for (final c in (j['cells'] as List? ?? const []))
        if (c is Map) ColumnCell.fromJson(c.cast<String, Object?>()),
    ];
    if (cells.length > ColumnsBlock.maxCells) cells = cells.sublist(0, ColumnsBlock.maxCells);
    while (cells.length < 2) {
      cells.add(const ColumnCell());
    }
    return ColumnsBlock(
      id: id,
      spacing: BlockSpacing.fromJson(j),
      cells: cells,
      format: TextFormat.fromJson(j),
      fill: _b(j['fill']),
      gap: j['gap'] is num ? _i(j['gap'], 8).clamp(0, 200) : null,
    );
  }
}

class SeparatorBlock extends ReceiptBlock {
  SeparatorBlock({
    super.id,
    super.spacing,
    this.style = SeparatorStyle.dashed,
    this.thickness = 2,
    this.height = 16,
    this.dash,
    this.gap,
  });

  final SeparatorStyle style;

  /// Line thickness in dots, 1..8.
  final int thickness;

  /// Total block height in dots (the line is centred vertically).
  final int height;

  /// Dash / dot length and the gap between them in dots (dashed and dotted
  /// styles); null = automatic from the thickness.
  final int? dash;
  final int? gap;

  @override
  String get type => 'separator';

  SeparatorBlock copyWith({
    SeparatorStyle? style,
    int? thickness,
    int? height,
    int? dash,
    int? gap,
    bool autoPattern = false,
  }) => SeparatorBlock(
    id: id,
    spacing: spacing,
    style: style ?? this.style,
    thickness: thickness ?? this.thickness,
    height: height ?? this.height,
    dash: autoPattern ? null : (dash ?? this.dash),
    gap: autoPattern ? null : (gap ?? this.gap),
  );

  @override
  Map<String, Object?> _fields() => {
    'style': style.name,
    'thickness': thickness,
    'height': height,
    if (dash != null) 'dash': dash,
    if (gap != null) 'gap': gap,
  };

  factory SeparatorBlock.fromJson(Map<String, Object?> j, {String? id}) => SeparatorBlock(
    id: id,
    spacing: BlockSpacing.fromJson(j),
    style: _enum(SeparatorStyle.values, j['style'], SeparatorStyle.dashed),
    thickness: _i(j['thickness'], 2).clamp(1, 8),
    height: _i(j['height'], 16).clamp(1, 800),
    dash: j['dash'] is num ? _i(j['dash'], 6).clamp(1, 200) : null,
    gap: j['gap'] is num ? _i(j['gap'], 4).clamp(1, 200) : null,
  );
}

/// Picture, dithered with the same pipeline as the photo tab.
class ImageBlock extends ReceiptBlock {
  ImageBlock({
    super.id,
    super.spacing,
    this.bytes,
    this.name = '',
    this.widthPercent = 100,
    this.align = HAlign.center,
    this.settings = const PrintSettings(dither: DitherMode.atkinson, gamma: 1.3),
  });

  /// Encoded image (PNG/JPEG...), base64 in JSON. Null = not chosen yet.
  final Uint8List? bytes;
  final String name;

  /// Width as a percentage of the printable width, 5..100.
  final int widthPercent;
  final HAlign align;
  final PrintSettings settings;

  @override
  String get type => 'image';

  ImageBlock copyWith({Uint8List? bytes, String? name, int? widthPercent, HAlign? align, PrintSettings? settings}) =>
      ImageBlock(
        id: id,
        spacing: spacing,
        bytes: bytes ?? this.bytes,
        name: name ?? this.name,
        widthPercent: widthPercent ?? this.widthPercent,
        align: align ?? this.align,
        settings: settings ?? this.settings,
      );

  @override
  Map<String, Object?> _fields() => {
    'name': name,
    'width': widthPercent,
    'align': align.name,
    'dither': settings.dither.name,
    'brightness': settings.brightness,
    'contrast': settings.contrast,
    'gamma': settings.gamma,
    'threshold': settings.threshold,
    'invert': settings.invert,
    'rotate90': settings.rotate90,
    'data': bytes == null ? null : base64Encode(bytes!),
  };

  factory ImageBlock.fromJson(Map<String, Object?> j, {String? id}) {
    final data = j['data'];
    return ImageBlock(
      id: id,
      spacing: BlockSpacing.fromJson(j),
      bytes: data is String && data.isNotEmpty ? base64Decode(data) : null,
      name: _s(j['name']),
      widthPercent: _i(j['width'], 100).clamp(5, 100),
      align: _enum(HAlign.values, j['align'], HAlign.center),
      settings: PrintSettings(
        dither: _enum(DitherMode.values, j['dither'], DitherMode.atkinson),
        brightness: _d(j['brightness'], 0).clamp(-1, 1),
        contrast: _d(j['contrast'], 1).clamp(0, 3),
        gamma: _d(j['gamma'], 1.3).clamp(0.1, 5),
        threshold: _i(j['threshold'], 128).clamp(1, 254),
        invert: _b(j['invert']),
        rotate90: _b(j['rotate90']),
      ),
    );
  }
}

class QrBlock extends ReceiptBlock {
  QrBlock({
    super.id,
    super.spacing,
    this.data = 'https://example.com',
    this.moduleSize = 6,
    this.ecc = QrEcc.medium,
    this.align = HAlign.center,
  });

  final String data;

  /// Dots per QR module, 1..20 (shrunk automatically if it does not fit).
  final int moduleSize;
  final QrEcc ecc;
  final HAlign align;

  @override
  String get type => 'qr';

  QrBlock copyWith({String? data, int? moduleSize, QrEcc? ecc, HAlign? align}) => QrBlock(
    id: id,
    spacing: spacing,
    data: data ?? this.data,
    moduleSize: moduleSize ?? this.moduleSize,
    ecc: ecc ?? this.ecc,
    align: align ?? this.align,
  );

  @override
  Map<String, Object?> _fields() => {'data': data, 'module': moduleSize, 'ecc': ecc.name, 'align': align.name};

  factory QrBlock.fromJson(Map<String, Object?> j, {String? id}) => QrBlock(
    id: id,
    spacing: BlockSpacing.fromJson(j),
    data: _s(j['data']),
    moduleSize: _i(j['module'], 6).clamp(1, 20),
    ecc: _enum(QrEcc.values, j['ecc'], QrEcc.medium),
    align: _enum(HAlign.values, j['align'], HAlign.center),
  );
}

class BarcodeBlock extends ReceiptBlock {
  BarcodeBlock({
    super.id,
    super.spacing,
    this.symbology = BarcodeSymbology.code128,
    this.data = '12345678',
    this.moduleWidth = 2,
    this.height = 80,
    this.showText = true,
    this.align = HAlign.center,
  });

  final BarcodeSymbology symbology;
  final String data;

  /// Dots per narrow bar, 1..6.
  final int moduleWidth;

  /// Bar height in dots.
  final int height;

  /// Human-readable text below the bars.
  final bool showText;
  final HAlign align;

  @override
  String get type => 'barcode';

  BarcodeBlock copyWith({
    BarcodeSymbology? symbology,
    String? data,
    int? moduleWidth,
    int? height,
    bool? showText,
    HAlign? align,
  }) => BarcodeBlock(
    id: id,
    spacing: spacing,
    symbology: symbology ?? this.symbology,
    data: data ?? this.data,
    moduleWidth: moduleWidth ?? this.moduleWidth,
    height: height ?? this.height,
    showText: showText ?? this.showText,
    align: align ?? this.align,
  );

  @override
  Map<String, Object?> _fields() => {
    'symbology': symbology.name,
    'data': data,
    'module': moduleWidth,
    'height': height,
    'text': showText,
    'align': align.name,
  };

  factory BarcodeBlock.fromJson(Map<String, Object?> j, {String? id}) => BarcodeBlock(
    id: id,
    spacing: BlockSpacing.fromJson(j),
    symbology: _enum(BarcodeSymbology.values, j['symbology'], BarcodeSymbology.code128),
    data: _s(j['data']),
    moduleWidth: _i(j['module'], 2).clamp(1, 6),
    height: _i(j['height'], 80).clamp(8, 800),
    showText: _b(j['text'], true),
    align: _enum(HAlign.values, j['align'], HAlign.center),
  );
}

/// Blank paper of [mm] millimetres.
class FeedBlock extends ReceiptBlock {
  FeedBlock({super.id, super.spacing, this.mm = 5});

  final double mm;

  @override
  String get type => 'feed';

  FeedBlock copyWith({double? mm}) => FeedBlock(id: id, spacing: spacing, mm: mm ?? this.mm);

  @override
  Map<String, Object?> _fields() => {'mm': mm};

  factory FeedBlock.fromJson(Map<String, Object?> j, {String? id}) =>
      FeedBlock(id: id, spacing: BlockSpacing.fromJson(j), mm: _d(j['mm'], 5).clamp(0, 200));
}

/// Paper cut (cutter printers); a tear-off feed on printers without cutter.
class CutBlock extends ReceiptBlock {
  CutBlock({super.id, super.spacing});

  @override
  String get type => 'cut';

  @override
  Map<String, Object?> _fields() => const {};
}

class Receipt {
  Receipt({
    this.name = 'Untitled',
    this.blocks = const [],
    this.counter = 1,
    this.marginLeft = 0,
    this.marginRight = 0,
  });

  final String name;
  final List<ReceiptBlock> blocks;

  /// Receipt-wide left/right margins in dots, inside the printable width.
  final int marginLeft;
  final int marginRight;

  /// Value of the `{n}` token for the next printed copy.
  final int counter;

  Receipt copyWith({String? name, List<ReceiptBlock>? blocks, int? counter, int? marginLeft, int? marginRight}) =>
      Receipt(
        name: name ?? this.name,
        blocks: blocks ?? this.blocks,
        counter: counter ?? this.counter,
        marginLeft: marginLeft ?? this.marginLeft,
        marginRight: marginRight ?? this.marginRight,
      );

  Map<String, Object?> toJson() => {
    'format': receiptFormatTag,
    'version': receiptFormatVersion,
    'name': name,
    'counter': counter,
    if (marginLeft != 0) 'marginLeft': marginLeft,
    if (marginRight != 0) 'marginRight': marginRight,
    'blocks': [for (final b in blocks) b.toJson()],
  };

  String encode({bool pretty = false}) =>
      pretty ? const JsonEncoder.withIndent('  ').convert(toJson()) : jsonEncode(toJson());

  /// Throws [FormatException] if [j] is not a receipt.
  factory Receipt.fromJson(Map<String, Object?> j) {
    final fmt = j['format'];
    if (fmt != null && fmt != receiptFormatTag) throw FormatException('Not a receipt file (format "$fmt")');
    if (j['blocks'] is! List) throw const FormatException('Not a receipt file (no "blocks" list)');
    // Files from a newer version (j['version'] > receiptFormatVersion) are
    // read best-effort: unknown fields are ignored, unknown block types skipped.
    return Receipt(
      name: _s(j['name'], 'Untitled'),
      counter: _i(j['counter'], 1),
      marginLeft: _i(j['marginLeft'], 0).clamp(0, 400),
      marginRight: _i(j['marginRight'], 0).clamp(0, 400),
      blocks: [
        for (final b in j['blocks'] as List)
          if (b is Map) ?ReceiptBlock.fromJson(b.cast<String, Object?>()),
      ],
    );
  }

  static Receipt decode(String json) {
    final j = jsonDecode(json);
    if (j is! Map) throw const FormatException('Not a receipt file');
    return Receipt.fromJson(j.cast<String, Object?>());
  }
}
