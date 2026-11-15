import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/image_pipeline.dart';
import '../../receipt/image_prep.dart';
import '../../receipt/model.dart';
import '../photo_page.dart' show ditherItems;
import '../printer_panel.dart' show LabeledSlider;

/// Called with the edited block and the property name (for undo coalescing).
typedef BlockChanged = void Function(ReceiptBlock block, String field);

/// Icon and type label of a block.
(IconData, String) blockKind(ReceiptBlock b) => switch (b) {
  TextBlock() => (Icons.notes, 'Text'),
  ColumnsBlock() => (Icons.view_column_outlined, 'Columns'),
  SeparatorBlock() => (Icons.horizontal_rule, 'Separator'),
  ImageBlock() => (Icons.image_outlined, 'Image'),
  QrBlock() => (Icons.qr_code_2, 'QR code'),
  BarcodeBlock() => (Icons.view_week_outlined, 'Barcode'),
  FeedBlock() => (Icons.vertical_align_bottom, 'Feed'),
  CutBlock() => (Icons.content_cut, 'Cut'),
};

/// One-line description shown in the block list.
String blockSummary(ReceiptBlock b) {
  String first(String s) {
    final l = s.split('\n').first.trim();
    return l.isEmpty ? '(empty)' : l;
  }

  return switch (b) {
    TextBlock() => first(b.text),
    ColumnsBlock() => b.cells.map((c) => c.text.isEmpty ? '·' : first(c.text)).join('  |  '),
    SeparatorBlock() => '${b.style.name}, ${b.height} dots',
    ImageBlock() =>
      b.bytes == null ? 'no picture chosen' : '${b.name.isEmpty ? 'picture' : b.name}, ${b.widthPercent}%',
    QrBlock() => first(b.data),
    BarcodeBlock() => '${b.symbology.label}: ${b.data}',
    FeedBlock() => '${b.mm.toStringAsFixed(b.mm == b.mm.roundToDouble() ? 0 : 1)} mm',
    CutBlock() => 'cut / tear off here',
  };
}

/// Fresh block of each kind, for the "Add block" menu.
final blockFactories = <(String, IconData, String, ReceiptBlock Function())>[
  ('text', Icons.notes, 'Text', () => TextBlock(text: 'Text')),
  (
    'columns',
    Icons.view_column_outlined,
    'Columns',
    () => ColumnsBlock(
      cells: const [
        ColumnCell(text: 'Item', flex: 3),
        ColumnCell(text: '0.00', align: HAlign.right),
      ],
      format: const TextFormat(font: ReceiptFont.mono, size: 22),
      fill: true,
    ),
  ),
  ('separator', Icons.horizontal_rule, 'Separator', () => SeparatorBlock()),
  ('image', Icons.image_outlined, 'Image', () => ImageBlock()),
  ('qr', Icons.qr_code_2, 'QR code', () => QrBlock()),
  ('barcode', Icons.view_week_outlined, 'Barcode', () => BarcodeBlock()),
  ('feed', Icons.vertical_align_bottom, 'Feed', () => FeedBlock()),
  ('cut', Icons.content_cut, 'Cut', () => CutBlock()),
];

const tokenHelp = 'Tokens: {date} {time} {datetime} {date:dd.MM.yy} {n} {n:0000}';

/// Property panel for [block].
class BlockEditor extends StatelessWidget {
  const BlockEditor({super.key, required this.block, required this.onChanged, required this.hasCutter});

  final ReceiptBlock block;
  final BlockChanged onChanged;
  final bool hasCutter;

  @override
  Widget build(BuildContext context) {
    final b = block;
    final children = switch (b) {
      TextBlock() => _text(b),
      ColumnsBlock() => _columns(b),
      SeparatorBlock() => _separator(b),
      ImageBlock() => [_ImageEditor(block: b, onChanged: onChanged)],
      QrBlock() => _qr(b),
      BarcodeBlock() => _barcode(b),
      FeedBlock() => [
        LabeledSlider(
          label: 'Length',
          value: b.mm,
          min: 0,
          max: 100,
          divisions: 200,
          format: (v) => '${v.toStringAsFixed(1)} mm',
          onChanged: (v) => onChanged(b.copyWith(mm: (v * 2).round() / 2), 'mm'),
        ),
      ],
      CutBlock() => [
        Text(
          hasCutter
              ? 'The paper is cut here (GS V B). Everything below starts a new slip.'
              : 'This printer has no cutter: paper is fed here so it can be torn off.',
        ),
      ],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 6), child: c),
        if (b is! CutBlock)
          SpacingEditor(spacing: b.spacing, onChanged: (sp, field) => onChanged(b.withSpacing(sp), field)),
      ],
    );
  }

  List<Widget> _text(TextBlock b) => [
    SyncedTextField(
      fieldKey: const Key('block-text'),
      label: 'Text',
      helper: tokenHelp,
      value: b.text,
      maxLines: 8,
      onChanged: (v) => onChanged(b.copyWith(text: v), 'text'),
    ),
    AlignPicker(
      value: b.align,
      onChanged: (a) => onChanged(b.copyWith(align: a), 'align'),
    ),
    TextFormatEditor(
      format: b.format,
      onChanged: (f, field) => onChanged(b.copyWith(format: f), field),
    ),
    _check('White on black', b.invert, (v) => onChanged(b.copyWith(invert: v), 'invert')),
  ];

  List<Widget> _columns(ColumnsBlock b) {
    void setCell(int i, ColumnCell c, String field) =>
        onChanged(b.copyWith(cells: [...b.cells]..[i] = c), 'cell$i.$field');
    return [
      Row(
        children: [
          const Text('Columns'),
          const SizedBox(width: 12),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [for (var n = 2; n <= ColumnsBlock.maxCells; n++) ButtonSegment(value: n, label: Text('$n'))],
            selected: {b.cells.length},
            onSelectionChanged: (s) {
              final n = s.first;
              // Keep first and last cell (e.g. item … price); add/remove middle ones.
              final middle = b.cells.sublist(1, b.cells.length - 1);
              while (middle.length < n - 2) {
                middle.add(const ColumnCell(text: '', align: HAlign.center));
              }
              final cells = [b.cells.first, ...middle.take(n - 2), b.cells.last];
              onChanged(b.copyWith(cells: cells), 'count');
            },
          ),
        ],
      ),
      for (var i = 0; i < b.cells.length; i++)
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: SyncedTextField(
                fieldKey: Key('block-cell-$i'),
                label: 'Column ${i + 1}',
                value: b.cells[i].text,
                onChanged: (v) => setCell(i, b.cells[i].copyWith(text: v), 'text'),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 64,
              child: DropdownButtonFormField<int>(
                key: ValueKey('flex$i:${b.cells[i].flex}'),
                initialValue: b.cells[i].flex.clamp(1, 6),
                decoration: const InputDecoration(labelText: 'Width'),
                items: [for (var f = 1; f <= 6; f++) DropdownMenuItem(value: f, child: Text('$f'))],
                onChanged: (f) => setCell(i, b.cells[i].copyWith(flex: f), 'flex'),
              ),
            ),
            AlignPicker(
              compact: true,
              value: b.cells[i].align,
              onChanged: (a) => setCell(i, b.cells[i].copyWith(align: a), 'align'),
            ),
          ],
        ),
      const Text(tokenHelp, style: TextStyle(fontSize: 12)),
      _check('Dot leaders between columns', b.fill, (v) => onChanged(b.copyWith(fill: v), 'fill')),
      OptionalDots(
        label: 'Column gap',
        value: b.gap,
        auto: b.cells.length > 3 ? 4 : 8,
        min: 0,
        max: 120,
        onChanged: (v) => onChanged(v == null ? b.copyWith(autoGap: true) : b.copyWith(gap: v), 'gap'),
      ),
      TextFormatEditor(
        format: b.format,
        onChanged: (f, field) => onChanged(b.copyWith(format: f), field),
      ),
    ];
  }

  List<Widget> _separator(SeparatorBlock b) => [
    DropdownButtonFormField<SeparatorStyle>(
      key: ValueKey(b.style),
      initialValue: b.style,
      decoration: const InputDecoration(labelText: 'Style'),
      items: [
        for (final s in SeparatorStyle.values)
          DropdownMenuItem(value: s, child: Text(s == SeparatorStyle.blank ? 'blank space' : s.name)),
      ],
      onChanged: (s) => onChanged(b.copyWith(style: s), 'style'),
    ),
    if (b.style != SeparatorStyle.blank)
      LabeledSlider(
        label: 'Thickness',
        value: b.thickness.toDouble(),
        min: 1,
        max: 8,
        divisions: 7,
        format: (v) => '${v.round()}',
        onChanged: (v) => onChanged(b.copyWith(thickness: v.round()), 'thickness'),
      ),
    DotsField(
      label: 'Height',
      value: b.height,
      min: 1,
      max: 800,
      onChanged: (v) => onChanged(b.copyWith(height: v), 'height'),
    ),
    if (b.style == SeparatorStyle.dashed || b.style == SeparatorStyle.dotted) ...[
      OptionalDots(
        label: b.style == SeparatorStyle.dotted ? 'Dot length' : 'Dash length',
        value: b.dash,
        auto: b.style == SeparatorStyle.dotted ? b.thickness : 6 + b.thickness * 3,
        min: 1,
        max: 200,
        onChanged: (v) => onChanged(v == null ? b.copyWith(autoPattern: true) : b.copyWith(dash: v), 'dash'),
      ),
      OptionalDots(
        label: 'Gap length',
        value: b.gap,
        auto: b.style == SeparatorStyle.dotted ? b.thickness * 2 + 1 : 4 + b.thickness * 2,
        min: 1,
        max: 200,
        onChanged: (v) => onChanged(v == null ? b.copyWith(autoPattern: true) : b.copyWith(gap: v), 'gap'),
      ),
    ],
  ];

  List<Widget> _qr(QrBlock b) => [
    SyncedTextField(
      fieldKey: const Key('block-qr'),
      label: 'Data (URL, text…)',
      helper: tokenHelp,
      value: b.data,
      maxLines: 4,
      onChanged: (v) => onChanged(b.copyWith(data: v), 'data'),
    ),
    LabeledSlider(
      label: 'Module',
      value: b.moduleSize.toDouble(),
      min: 1,
      max: 20,
      divisions: 19,
      format: (v) => '${v.round()} dt',
      onChanged: (v) => onChanged(b.copyWith(moduleSize: v.round()), 'module'),
    ),
    DropdownButtonFormField<QrEcc>(
      key: ValueKey(b.ecc),
      initialValue: b.ecc,
      decoration: const InputDecoration(labelText: 'Error correction'),
      items: const [
        DropdownMenuItem(value: QrEcc.low, child: Text('L — 7 %')),
        DropdownMenuItem(value: QrEcc.medium, child: Text('M — 15 %')),
        DropdownMenuItem(value: QrEcc.quartile, child: Text('Q — 25 %')),
        DropdownMenuItem(value: QrEcc.high, child: Text('H — 30 %')),
      ],
      onChanged: (e) => onChanged(b.copyWith(ecc: e), 'ecc'),
    ),
    AlignPicker(
      value: b.align,
      onChanged: (a) => onChanged(b.copyWith(align: a), 'align'),
    ),
  ];

  List<Widget> _barcode(BarcodeBlock b) => [
    DropdownButtonFormField<BarcodeSymbology>(
      key: ValueKey(b.symbology),
      initialValue: b.symbology,
      decoration: const InputDecoration(labelText: 'Type'),
      items: [for (final s in BarcodeSymbology.values) DropdownMenuItem(value: s, child: Text(s.label))],
      onChanged: (s) => onChanged(b.copyWith(symbology: s), 'symbology'),
    ),
    SyncedTextField(
      fieldKey: const Key('block-barcode'),
      label: 'Data',
      helper: switch (b.symbology) {
        BarcodeSymbology.ean13 => '12 digits (check digit added) or 13',
        BarcodeSymbology.ean8 => '7 digits (check digit added) or 8',
        BarcodeSymbology.upcA => '11 digits (check digit added) or 12',
        BarcodeSymbology.code39 => 'A–Z 0–9 - . space \$ / + %',
        BarcodeSymbology.code128 => 'ASCII text; {n} for a running number',
      },
      value: b.data,
      onChanged: (v) => onChanged(b.copyWith(data: v), 'data'),
    ),
    LabeledSlider(
      label: 'Bar width',
      value: b.moduleWidth.toDouble(),
      min: 1,
      max: 6,
      divisions: 5,
      format: (v) => '${v.round()} dt',
      onChanged: (v) => onChanged(b.copyWith(moduleWidth: v.round()), 'module'),
    ),
    LabeledSlider(
      label: 'Height',
      value: b.height.toDouble(),
      min: 16,
      max: 300,
      divisions: 284,
      format: (v) => '${v.round()}',
      onChanged: (v) => onChanged(b.copyWith(height: v.round()), 'height'),
    ),
    _check('Human-readable text', b.showText, (v) => onChanged(b.copyWith(showText: v), 'text')),
    AlignPicker(
      value: b.align,
      onChanged: (a) => onChanged(b.copyWith(align: a), 'align'),
    ),
  ];
}

Widget _check(String label, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
  contentPadding: EdgeInsets.zero,
  dense: true,
  title: Text(label),
  value: value,
  onChanged: onChanged,
);

/// Font, size, bold/underline and stretch.
class TextFormatEditor extends StatelessWidget {
  const TextFormatEditor({super.key, required this.format, required this.onChanged});

  final TextFormat format;
  final void Function(TextFormat f, String field) onChanged;

  @override
  Widget build(BuildContext context) {
    final f = format;
    Widget scale(String label, int value, ValueChanged<int> set) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        const SizedBox(width: 6),
        DropdownButton<int>(
          value: value,
          items: [for (var i = 1; i <= 4; i++) DropdownMenuItem(value: i, child: Text('×$i'))],
          onChanged: (v) => set(v ?? 1),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<ReceiptFont>(
              showSelectedIcon: false,
              segments: [for (final r in ReceiptFont.values) ButtonSegment(value: r, label: Text(r.label))],
              selected: {f.font},
              onSelectionChanged: (s) => onChanged(f.copyWith(font: s.first), 'font'),
            ),
            FilterChip(
              label: const Text('B', style: TextStyle(fontWeight: FontWeight.bold)),
              tooltip: 'Bold',
              selected: f.bold,
              onSelected: (v) => onChanged(f.copyWith(bold: v), 'bold'),
            ),
            FilterChip(
              label: const Text('U', style: TextStyle(decoration: TextDecoration.underline)),
              tooltip: 'Underline',
              selected: f.underline,
              onSelected: (v) => onChanged(f.copyWith(underline: v), 'underline'),
            ),
            scale('Wide', f.scaleX, (v) => onChanged(f.copyWith(scaleX: v), 'scaleX')),
            scale('Tall', f.scaleY, (v) => onChanged(f.copyWith(scaleY: v), 'scaleY')),
          ],
        ),
        LabeledSlider(
          label: 'Size',
          value: f.size,
          min: 12,
          max: 96,
          divisions: 84,
          format: (v) => '${v.round()} dt',
          onChanged: (v) => onChanged(f.copyWith(size: v.roundToDouble()), 'size'),
        ),
        LabeledSlider(
          label: 'Stretch',
          value: f.stretch,
          min: 0.5,
          max: 2,
          divisions: 30,
          format: (v) => '${(v * 100).round()}%',
          onChanged: (v) => onChanged(f.copyWith(stretch: (v * 20).round() / 20), 'stretch'),
        ),
        DotsField(
          label: 'Letter spacing',
          value: f.letterSpacing.round(),
          min: -5,
          max: 40,
          onChanged: (v) => onChanged(f.copyWith(letterSpacing: v.toDouble()), 'letterSpacing'),
        ),
        OptionalDots(
          label: 'Line pitch',
          value: f.lineHeight?.round(),
          auto: (f.size * 1.17 * f.scaleY).round(),
          min: 4,
          max: 400,
          onChanged: (v) => onChanged(
            v == null ? f.copyWith(clearLineHeight: true) : f.copyWith(lineHeight: v.toDouble()),
            'lineHeight',
          ),
        ),
      ],
    );
  }
}

/// Space before/after and left/right indents of any block, in dots.
class SpacingEditor extends StatelessWidget {
  const SpacingEditor({super.key, required this.spacing, required this.onChanged});

  final BlockSpacing spacing;
  final void Function(BlockSpacing s, String field) onChanged;

  @override
  Widget build(BuildContext context) {
    final sp = spacing;
    return ExpansionTile(
      key: const PageStorageKey('spacing'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      leading: const Icon(Icons.format_line_spacing),
      title: const Text('Spacing'),
      subtitle: Text(
        sp.isZero ? 'none' : '↑${sp.before}  ↓${sp.after}  ←${sp.left}  →${sp.right} dots',
        style: const TextStyle(fontSize: 12),
      ),
      initiallyExpanded: !sp.isZero,
      children: [
        DotsField(
          label: 'Space above',
          value: sp.before,
          min: 0,
          max: 800,
          onChanged: (v) => onChanged(sp.copyWith(before: v), 'spaceBefore'),
        ),
        DotsField(
          label: 'Space below',
          value: sp.after,
          min: 0,
          max: 800,
          onChanged: (v) => onChanged(sp.copyWith(after: v), 'spaceAfter'),
        ),
        DotsField(
          label: 'Indent left',
          value: sp.left,
          min: 0,
          max: 600,
          onChanged: (v) => onChanged(sp.copyWith(left: v), 'indentLeft'),
        ),
        DotsField(
          label: 'Indent right',
          value: sp.right,
          min: 0,
          max: 600,
          onChanged: (v) => onChanged(sp.copyWith(right: v), 'indentRight'),
        ),
      ],
    );
  }
}

/// Exact integer value in printer dots: −/+ buttons and a number field,
/// with the millimetre equivalent (8 dots = 1 mm at 203 dpi).
class DotsField extends StatefulWidget {
  const DotsField({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value, min, max;
  final ValueChanged<int> onChanged;

  @override
  State<DotsField> createState() => _DotsFieldState();
}

class _DotsFieldState extends State<DotsField> {
  late final _ctl = TextEditingController(text: '${widget.value}');

  @override
  void didUpdateWidget(DotsField old) {
    super.didUpdateWidget(old);
    if ('${widget.value}' != _ctl.text && int.tryParse(_ctl.text) != widget.value) _ctl.text = '${widget.value}';
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _set(int v) {
    v = v.clamp(widget.min, widget.max);
    _ctl.text = '$v';
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final mm = widget.value / 8;
    return Row(
      children: [
        SizedBox(width: 108, child: Text(widget.label)),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove),
          onPressed: widget.value > widget.min ? () => _set(widget.value - 1) : null,
        ),
        SizedBox(
          width: 64,
          child: TextField(
            controller: _ctl,
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            decoration: const InputDecoration(isDense: true, suffixText: 'dt'),
            onChanged: (t) {
              final v = int.tryParse(t.trim());
              if (v != null && v >= widget.min && v <= widget.max) widget.onChanged(v);
            },
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add),
          onPressed: widget.value < widget.max ? () => _set(widget.value + 1) : null,
        ),
        Text(
          '${mm.toStringAsFixed(mm == mm.roundToDouble() ? 0 : 2)} mm',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// [DotsField] that can also be "auto" (null).
class OptionalDots extends StatelessWidget {
  const OptionalDots({
    super.key,
    required this.label,
    required this.value,
    required this.auto,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int? value;

  /// Value used while automatic (shown, and the starting point when switching to manual).
  final int auto;
  final int min, max;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final v = value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(v == null ? '$label: automatic (≈$auto dots)' : '$label: manual'),
          value: v != null,
          onChanged: (on) => onChanged(on == true ? auto.clamp(min, max) : null),
        ),
        if (v != null) DotsField(label: label, value: v, min: min, max: max, onChanged: onChanged),
      ],
    );
  }
}

class AlignPicker extends StatelessWidget {
  const AlignPicker({super.key, required this.value, required this.onChanged, this.compact = false});

  final HAlign value;
  final ValueChanged<HAlign> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final picker = SegmentedButton<HAlign>(
      showSelectedIcon: false,
      style: compact ? const ButtonStyle(visualDensity: VisualDensity.compact) : null,
      segments: const [
        ButtonSegment(value: HAlign.left, icon: Icon(Icons.format_align_left), tooltip: 'Left'),
        ButtonSegment(value: HAlign.center, icon: Icon(Icons.format_align_center), tooltip: 'Center'),
        ButtonSegment(value: HAlign.right, icon: Icon(Icons.format_align_right), tooltip: 'Right'),
      ],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
    );
    if (compact) return Padding(padding: const EdgeInsets.only(left: 8), child: picker);
    return Align(alignment: Alignment.centerLeft, child: picker);
  }
}

/// TextField that follows external changes of [value] (undo/redo) without
/// losing the cursor while typing.
class SyncedTextField extends StatefulWidget {
  const SyncedTextField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.helper,
    this.maxLines = 1,
    this.fieldKey,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String? label;
  final String? helper;
  final int maxLines;
  final Key? fieldKey;

  @override
  State<SyncedTextField> createState() => _SyncedTextFieldState();
}

class _SyncedTextFieldState extends State<SyncedTextField> {
  late final _ctl = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(SyncedTextField old) {
    super.didUpdateWidget(old);
    if (widget.value != _ctl.text) {
      _ctl.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    key: widget.fieldKey,
    controller: _ctl,
    minLines: 1,
    maxLines: widget.maxLines,
    keyboardType: widget.maxLines > 1 ? TextInputType.multiline : TextInputType.text,
    decoration: InputDecoration(labelText: widget.label, helperText: widget.helper, helperMaxLines: 2),
    onChanged: widget.onChanged,
  );
}

class _ImageEditor extends StatefulWidget {
  const _ImageEditor({required this.block, required this.onChanged});

  final ImageBlock block;
  final BlockChanged onChanged;

  @override
  State<_ImageEditor> createState() => _ImageEditorState();
}

class _ImageEditorState extends State<_ImageEditor> {
  bool _loading = false;
  String? _error;

  Future<void> _pick() async {
    const group = XTypeGroup(
      label: 'Images',
      extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'tif', 'tiff'],
      mimeTypes: ['image/*'],
      uniformTypeIdentifiers: ['public.image'],
    );
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bytes = await compute(prepareImageBytes, await file.readAsBytes());
      widget.onChanged(widget.block.copyWith(bytes: bytes, name: file.name), 'bytes');
    } on Object catch (e) {
      _error = 'Could not open image: $e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.block;
    final s = b.settings;
    void set(PrintSettings n, String field) => widget.onChanged(b.copyWith(settings: n), field);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: _loading ? null : _pick,
              icon: _loading
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.folder_open),
              label: Text(b.bytes == null ? 'Choose picture' : 'Replace picture'),
            ),
            const SizedBox(width: 12),
            if (b.bytes != null)
              Expanded(
                child: Text(
                  '${b.name} · ${(b.bytes!.length / 1024).toStringAsFixed(0)} KiB',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        LabeledSlider(
          label: 'Width',
          value: b.widthPercent.toDouble(),
          min: 5,
          max: 100,
          divisions: 19,
          format: (v) => '${v.round()} %',
          onChanged: (v) => widget.onChanged(b.copyWith(widthPercent: v.round()), 'width'),
        ),
        AlignPicker(
          value: b.align,
          onChanged: (a) => widget.onChanged(b.copyWith(align: a), 'align'),
        ),
        DropdownButtonFormField<DitherMode>(
          key: ValueKey(s.dither),
          initialValue: s.dither,
          decoration: const InputDecoration(labelText: 'Dithering'),
          items: ditherItems,
          onChanged: (d) => set(s.copyWith(dither: d), 'dither'),
        ),
        LabeledSlider(
          label: 'Brightness',
          value: s.brightness,
          min: -0.5,
          max: 0.5,
          onChanged: (v) => set(s.copyWith(brightness: v), 'brightness'),
        ),
        LabeledSlider(
          label: 'Contrast',
          value: s.contrast,
          min: 0.3,
          max: 2.5,
          onChanged: (v) => set(s.copyWith(contrast: v), 'contrast'),
        ),
        LabeledSlider(
          label: 'Gamma',
          value: s.gamma,
          min: 0.5,
          max: 2.5,
          onChanged: (v) => set(s.copyWith(gamma: v), 'gamma'),
        ),
        if (s.dither == DitherMode.threshold)
          LabeledSlider(
            label: 'Threshold',
            value: s.threshold.toDouble(),
            min: 1,
            max: 254,
            onChanged: (v) => set(s.copyWith(threshold: v.round()), 'threshold'),
          ),
        _check('Rotate 90°', s.rotate90, (v) => set(s.copyWith(rotate90: v), 'rotate')),
        _check('Invert', s.invert, (v) => set(s.copyWith(invert: v), 'invert')),
      ],
    );
  }
}
