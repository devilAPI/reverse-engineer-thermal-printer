import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../receipt/editor.dart';
import '../../receipt/encode.dart';
import '../../receipt/model.dart';
import '../../receipt/renderer.dart';
import '../../receipt/templates.dart';
import '../printer_controller.dart';
import '../printer_panel.dart';
import 'block_editors.dart';

/// Receipt tab: block list with per-block properties, live paper preview,
/// templates / saved receipts / JSON import-export, printing through the
/// shared [PrinterController].
class ReceiptPage extends StatefulWidget {
  const ReceiptPage({super.key, required this.printer});

  final PrinterController printer;

  @override
  State<ReceiptPage> createState() => _ReceiptPageState();
}

const _jsonGroup = XTypeGroup(
  label: 'Receipt (JSON)',
  extensions: ['json'],
  mimeTypes: ['application/json'],
  uniformTypeIdentifiers: ['public.json'],
);

class _ReceiptPageState extends State<ReceiptPage> {
  PrinterController get _printer => widget.printer;
  late final ReceiptEditor _editor = ReceiptEditor(_initialDoc());
  final _renderer = ReceiptRenderer();
  late List<Receipt> _library = decodeLibrary(_printer.prefs?.savedReceipts);

  RenderedReceipt? _rendered;
  List<ui.Image> _images = [];
  bool _rendering = false;
  int _renderSeq = 0;
  Timer? _renderTimer;
  Timer? _saveTimer;
  late int _width = _printer.profile.dotsPerLine;
  bool _actualSize = false;
  final _scroll = ScrollController();
  final _selectedKey = GlobalKey();

  Receipt _initialDoc() {
    final draft = _printer.prefs?.receiptDraft;
    if (draft != null) {
      try {
        return Receipt.decode(draft);
      } on Object catch (e) {
        debugPrint('receipt draft unreadable: $e');
      }
    }
    return shopReceipt();
  }

  @override
  void initState() {
    super.initState();
    _editor.addListener(_onDocChanged);
    _printer.addListener(_onPrinterChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _render());
  }

  @override
  void dispose() {
    _editor.removeListener(_onDocChanged);
    _printer.removeListener(_onPrinterChanged);
    _renderTimer?.cancel();
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      _saveDraft();
    }
    for (final i in _images) {
      i.dispose();
    }
    _editor.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onDocChanged() {
    setState(() {});
    _renderTimer?.cancel();
    _renderTimer = Timer(const Duration(milliseconds: 120), _render);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _saveDraft);
  }

  void _onPrinterChanged() {
    if (_printer.profile.dotsPerLine != _width) {
      _width = _printer.profile.dotsPerLine;
      _render();
    }
    if (mounted) setState(() {});
  }

  /// Add a block and scroll its property panel into view.
  void _add(ReceiptBlock b) {
    _editor.add(b);
    _revealSelected();
  }

  void _revealSelected([int attempt = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _selectedKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 200), alignment: 0.1);
        return;
      }
      // Not built yet (lazy list): jump near it, then try again.
      final i = _editor.doc.blocks.indexWhere((b) => b.id == _editor.selectedId);
      if (i < 0 || attempt > 3 || !_scroll.hasClients) return;
      final pos = _scroll.position;
      pos.jumpTo(pos.maxScrollExtent * i / _editor.doc.blocks.length);
      _revealSelected(attempt + 1);
    });
  }

  void _saveDraft() => _printer.prefs?.receiptDraft = _editor.doc.encode();

  Future<void> _render() async {
    final seq = ++_renderSeq;
    setState(() => _rendering = true);
    try {
      final r = await _renderer.render(_editor.doc, width: _printer.profile.dotsPerLine);
      final images = [for (final s in r.segments) await monoToUiImage(s)];
      if (!mounted || seq != _renderSeq) {
        for (final i in images) {
          i.dispose();
        }
        return;
      }
      setState(() {
        for (final i in _images) {
          i.dispose();
        }
        _images = images;
        _rendered = r;
        _rendering = false;
      });
    } on Object catch (e) {
      if (mounted && seq == _renderSeq) {
        setState(() => _rendering = false);
        _printer.setStatus('Preview failed: $e');
      }
    }
  }

  // ------------------------------------------------------------- actions ---

  Future<void> _print() async {
    final doc = _editor.doc;
    final p = _printer.profile;
    final copies = _printer.job.copies.clamp(1, 99);
    _printer.setStatus('Rendering receipt…');
    final now = DateTime.now();
    final renders = <RenderedReceipt>[
      for (var i = 0; i < copies; i++) await _renderer.render(doc, width: p.dotsPerLine, now: now, number: doc.counter + i),
    ];
    final job = buildReceiptJob(renders, p, _printer.job);
    final ok = await _printer.send(job, 'receipt');
    if (ok && receiptUsesCounter(doc)) _editor.advanceCounter(copies);
  }

  void _saveToLibrary() {
    final doc = _editor.doc;
    setState(() => _library = upsertReceipt(_library, doc));
    _printer.prefs?.savedReceipts = encodeLibrary(_library);
    _printer.setStatus('Saved "${doc.name}" (${_library.length} saved receipts).');
  }

  Future<void> _openDialog() async {
    final picked = await showDialog<Receipt>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => SimpleDialog(
          title: const Text('Open receipt'),
          children: [
            const _DialogHeader('Samples'),
            for (final t in builtInTemplates)
              ListTile(
                leading: const Icon(Icons.auto_awesome_outlined),
                title: Text(t.name),
                subtitle: Text(t.description),
                onTap: () => Navigator.pop(context, t.build()),
              ),
            const _DialogHeader('Saved on this device'),
            if (_library.isEmpty) const ListTile(enabled: false, title: Text('Nothing saved yet — use the save button.')),
            for (final r in _library)
              ListTile(
                leading: const Icon(Icons.receipt_outlined),
                title: Text(r.name),
                subtitle: Text('${r.blocks.length} blocks'),
                onTap: () => Navigator.pop(context, Receipt.decode(r.encode())),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete',
                  onPressed: () {
                    setState(() => _library = [..._library]..remove(r));
                    _printer.prefs?.savedReceipts = encodeLibrary(_library);
                    setDialog(() {});
                  },
                ),
              ),
          ],
        ),
      ),
    );
    if (picked != null) _editor.load(picked);
  }

  Future<void> _rename() async {
    final ctl = TextEditingController(text: _editor.doc.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Receipt name'),
        content: TextField(controller: ctl, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, ctl.text), child: const Text('OK')),
        ],
      ),
    );
    ctl.dispose();
    if (name != null && name.trim().isNotEmpty) _editor.rename(name.trim());
  }

  Future<void> _import() async {
    try {
      final f = await openFile(acceptedTypeGroups: [_jsonGroup]);
      if (f == null) return;
      final r = Receipt.decode(await f.readAsString());
      _editor.load(r);
      _printer.setStatus('Imported "${r.name}" (${r.blocks.length} blocks).');
    } on Object catch (e) {
      _printer.setStatus('Import failed: $e');
    }
  }

  Future<void> _export() async {
    final doc = _editor.doc;
    final name = '${doc.name.replaceAll(RegExp(r'[^\w\- ]+'), '_').trim()}.json';
    final data = Uint8List.fromList(utf8.encode(doc.encode(pretty: true)));
    try {
      final file = XFile.fromData(data, mimeType: 'application/json', name: name);
      if (kIsWeb) {
        await file.saveTo(name); // browser download
      } else {
        final loc = await getSaveLocation(suggestedName: name, acceptedTypeGroups: [_jsonGroup]);
        if (loc == null) return;
        await file.saveTo(loc.path);
      }
      _printer.setStatus('Exported "${doc.name}".');
    } on Object catch (e) {
      _printer.setStatus('Export failed: $e');
    }
  }

  // ------------------------------------------------------------------- UI ---

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 980;
    final doc = _editor.doc;
    final scaffold = Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: _rename,
          child: Text('Receipt · ${doc.name}', overflow: TextOverflow.ellipsis),
        ),
        actions: [
          IconButton(onPressed: _editor.canUndo ? _editor.undo : null, icon: const Icon(Icons.undo), tooltip: 'Undo (Ctrl+Z)'),
          IconButton(onPressed: _editor.canRedo ? _editor.redo : null, icon: const Icon(Icons.redo), tooltip: 'Redo (Ctrl+Y)'),
          IconButton(onPressed: _openDialog, icon: const Icon(Icons.folder_open_outlined), tooltip: 'Templates & saved receipts'),
          IconButton(onPressed: _saveToLibrary, icon: const Icon(Icons.save_outlined), tooltip: 'Save on this device'),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) => switch (v) {
              'new' => _editor.load(Receipt(name: 'Untitled', blocks: [TextBlock(text: 'Hello!')])),
              'rename' => _rename(),
              'import' => _import(),
              'export' => _export(),
              _ => null,
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'new', child: ListTile(leading: Icon(Icons.note_add_outlined), title: Text('New receipt'))),
              PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Rename…'))),
              PopupMenuItem(value: 'import', child: ListTile(leading: Icon(Icons.file_open_outlined), title: Text('Import JSON…'))),
              PopupMenuItem(value: 'export', child: ListTile(leading: Icon(Icons.save_alt), title: Text('Export JSON…'))),
            ],
          ),
        ],
        bottom: wide ? null : const TabBar(tabs: [Tab(text: 'Edit'), Tab(text: 'Preview')]),
      ),
      body: wide
          ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: 480, child: _buildEditPane(context)),
              const VerticalDivider(width: 1),
              Expanded(child: _buildPreview(context)),
            ])
          : TabBarView(physics: const NeverScrollableScrollPhysics(), children: [_buildEditPane(context), _buildPreview(context)]),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'print-receipt',
        onPressed: !_printer.canPrint || doc.blocks.isEmpty ? null : _print,
        icon: _printer.busy
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.print),
        label: const Text('Print receipt'),
      ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _editor.undo,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): _editor.redo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): _editor.redo,
      },
      child: DefaultTabController(length: 2, child: scaffold),
    );
  }

  Widget _buildEditPane(BuildContext context) {
    final doc = _editor.doc;
    final blocks = doc.blocks;
    final t = Theme.of(context);
    return CustomScrollView(controller: _scroll, slivers: [
      SliverToBoxAdapter(
        child: ExpansionTile(
          leading: const Icon(Icons.print_outlined),
          title: const Text('Printer'),
          subtitle: Text(
            '${_printer.profile.name} · ${_printer.endpoint?.label ?? 'no connection'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          children: [PrinterPanel(controller: _printer), OutputPanel(controller: _printer)],
        ),
      ),
      SliverToBoxAdapter(
        child: ExpansionTile(
          leading: const Icon(Icons.tune),
          title: const Text('Receipt settings'),
          subtitle: Text('Next number {n} = ${doc.counter}'),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          children: [
            SyncedTextField(label: 'Name', value: doc.name, onChanged: (v) => _editor.rename(v)),
            SyncedTextField(
              label: 'Next number for {n}',
              helper: 'Advances by one per printed copy.',
              value: '${doc.counter}',
              onChanged: (v) {
                final n = int.tryParse(v.trim());
                if (n != null) _editor.setCounter(n);
              },
            ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
          child: Row(children: [
            Text('Blocks (${blocks.length})', style: t.textTheme.titleSmall),
            const Spacer(),
            MenuAnchor(
              builder: (context, ctl, _) => FilledButton.tonalIcon(
                key: const Key('add-block'),
                onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
                icon: const Icon(Icons.add),
                label: const Text('Add block'),
              ),
              menuChildren: [
                for (final (id, icon, label, make) in blockFactories)
                  MenuItemButton(
                    key: Key('add-$id'),
                    leadingIcon: Icon(icon),
                    onPressed: () => _add(make()),
                    child: Text(label),
                  ),
              ],
            ),
          ]),
        ),
      ),
      if (blocks.isEmpty)
        const SliverToBoxAdapter(
          child: Padding(padding: EdgeInsets.all(24), child: Text('No blocks yet. Add one, or open a template.')),
        ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 96),
        sliver: SliverReorderableList(
          itemCount: blocks.length,
          onReorder: _editor.move,
          proxyDecorator: (child, _, _) => Material(elevation: 6, borderRadius: BorderRadius.circular(12), child: child),
          itemBuilder: (context, i) => _blockTile(context, blocks[i], i),
        ),
      ),
    ]);
  }

  Widget _blockTile(BuildContext context, ReceiptBlock b, int index) {
    final selected = b.id == _editor.selectedId;
    final cs = Theme.of(context).colorScheme;
    final (icon, label) = blockKind(b);
    return Card(
      key: ValueKey(b.id),
      margin: const EdgeInsets.symmetric(vertical: 3),
      color: selected ? cs.surfaceContainerHighest : null,
      shape: selected
          ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: cs.primary, width: 1.5))
          : null,
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 4, right: 4),
          leading: ReorderableDragStartListener(
            index: index,
            child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_indicator)),
          ),
          title: Row(children: [Icon(icon, size: 18), const SizedBox(width: 6), Text(label)]),
          subtitle: Text(blockSummary(b), maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => _editor.select(selected ? null : b.id),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              icon: const Icon(Icons.copy_outlined, size: 20),
              tooltip: 'Duplicate',
              onPressed: () {
                _editor.duplicate(b.id);
                _revealSelected();
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: 'Delete',
              onPressed: () => _editor.remove(b.id),
            ),
          ]),
        ),
        if (selected)
          Padding(
            key: _selectedKey,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: BlockEditor(
              key: ValueKey('editor-${b.id}'),
              block: b,
              hasCutter: _printer.profile.hasCutter,
              onChanged: _editor.update,
            ),
          ),
      ]),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final r = _rendered;
    final t = Theme.of(context);
    final profile = _printer.profile;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final displayWidth = _actualSize ? profile.dotsPerLine / dpr : profile.paperWidthMm * 5.0;
    final endCut = profile.hasCutter && (r?.endsWithCut == true || _printer.job.cut);

    Widget paper(ui.Image img) => Container(
          decoration: const BoxDecoration(boxShadow: [BoxShadow(blurRadius: 6, color: Colors.black26)]),
          child: RawImage(
            image: img,
            width: displayWidth,
            filterQuality: _actualSize ? FilterQuality.none : FilterQuality.medium,
          ),
        );

    return Container(
      color: t.colorScheme.surfaceContainerHighest,
      child: Stack(children: [
        if (r == null)
          const Center(child: CircularProgressIndicator())
        else
          SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            child: Center(
              child: Column(children: [
                if (r.segments.isEmpty)
                  const Padding(padding: EdgeInsets.all(32), child: Text('Nothing to print yet.')),
                for (var i = 0; i < _images.length; i++) ...[
                  if (i > 0) _CutMarker(width: displayWidth, cut: profile.hasCutter),
                  paper(_images[i]),
                ],
                if (r.segments.isNotEmpty) _CutMarker(width: displayWidth, cut: endCut),
                const SizedBox(height: 8),
                Text(
                  key: const Key('receipt-info'),
                  '${r.width} dots · ${(r.height / 8).toStringAsFixed(0)} mm'
                  ' · ${r.segments.length} ${r.segments.length == 1 ? 'piece' : 'pieces'}'
                  ' · ${(r.bytes / 1024).toStringAsFixed(1)} KiB',
                  style: t.textTheme.bodySmall,
                ),
                for (final w in r.warnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('⚠ $w', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
                  ),
              ]),
            ),
          ),
        Positioned(
          right: 8,
          top: 8,
          child: IconButton.filledTonal(
            onPressed: () => setState(() => _actualSize = !_actualSize),
            icon: Icon(_actualSize ? Icons.zoom_out_map : Icons.fit_screen_outlined),
            tooltip: _actualSize ? 'Paper size' : 'Actual dots (1 dot = 1 pixel)',
          ),
        ),
        if (_rendering) const Positioned(left: 0, right: 0, top: 0, child: LinearProgressIndicator(minHeight: 2)),
      ]),
    );
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge),
      );
}

/// Dashed line with scissors (cut) or a tear-off hint between slips.
class _CutMarker extends StatelessWidget {
  const _CutMarker({required this.width, required this.cut});

  final double width;
  final bool cut;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: width + 40,
      height: 28,
      child: Row(children: [
        Icon(cut ? Icons.content_cut : Icons.more_horiz, size: 16, color: color),
        const SizedBox(width: 4),
        Expanded(child: CustomPaint(size: const Size.fromHeight(1), painter: _DashPainter(color))),
        const SizedBox(width: 4),
        Text(cut ? 'cut' : 'tear', style: TextStyle(fontSize: 11, color: color)),
      ]),
    );
  }
}

class _DashPainter extends CustomPainter {
  _DashPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, size.height / 2), Offset(x + 4, size.height / 2), p);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}
