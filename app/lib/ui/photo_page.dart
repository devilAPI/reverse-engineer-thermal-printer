import 'dart:async';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../core/image_pipeline.dart';
import '../core/mono_bitmap.dart';
import '../core/print_job.dart';
import 'printer_controller.dart';
import 'printer_panel.dart';

/// Photo tab: pick a photo, tune dithering, print.
class PhotoPage extends StatefulWidget {
  const PhotoPage({super.key, required this.printer, this.initialImage});

  final PrinterController printer;

  /// Path of an image to open on start (desktop command line).
  final String? initialImage;

  @override
  State<PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<PhotoPage> {
  PrinterController get _printer => widget.printer;
  late PrintSettings _settings = _printer.prefs?.settings ?? const PrintSettings(dither: DitherMode.atkinson, gamma: 1.3);

  img.Image? _photo;
  String? _photoName;
  MonoBitmap? _bitmap;
  ui.Image? _preview;
  Timer? _debounce;
  int _convertSeq = 0;
  late int _width = _printer.profile.dotsPerLine;

  @override
  void initState() {
    super.initState();
    _printer.addListener(_onPrinterChanged);
    final initial = widget.initialImage;
    if (initial != null) WidgetsBinding.instance.addPostFrameCallback((_) => _openPhoto(XFile(initial)));
  }

  @override
  void dispose() {
    _printer.removeListener(_onPrinterChanged);
    _debounce?.cancel();
    super.dispose();
  }

  void _onPrinterChanged() {
    if (_printer.profile.dotsPerLine != _width) {
      _width = _printer.profile.dotsPerLine;
      _reconvert();
    }
  }

  // ---------------------------------------------------------------- photo ---

  Future<void> _pickPhoto() async {
    const group = XTypeGroup(
      label: 'Images',
      extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'tif', 'tiff'],
      mimeTypes: ['image/*'],
      uniformTypeIdentifiers: ['public.image'],
    );
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    await _openPhoto(file);
  }

  Future<void> _openPhoto(XFile file) async {
    _printer.setStatus('Decoding ${file.name}…');
    await _openBytes(await file.readAsBytes(), file.name);
  }

  Future<void> _loadFromUrl() async {
    final url = await showDialog<String>(context: context, builder: (_) => const _UrlDialog());
    final uri = Uri.tryParse(url?.trim() ?? '');
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      if (url != null && url.trim().isNotEmpty) _printer.setStatus('Not a valid http(s) URL.');
      return;
    }
    _printer.setStatus('Downloading ${uri.host}…');
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw StateError('HTTP ${res.statusCode}');
      if (res.bodyBytes.length > 50 * 1024 * 1024) throw StateError('image larger than 50 MB');
      final name = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? uri.host;
      await _openBytes(res.bodyBytes, name);
    } on Object catch (e) {
      _printer.setStatus(kIsWeb
          ? 'Download failed: $e (in the browser the site must allow cross-origin requests; the desktop/mobile app has no such limit)'
          : 'Download failed: $e');
    }
  }

  Future<void> _openBytes(Uint8List bytes, String name) async {
    try {
      final photo = await compute(decodePhoto, bytes);
      _photo = photo;
      _photoName = name;
      await _reconvert();
      _printer.setStatus(null);
    } on Object catch (e) {
      _printer.setStatus('Could not open image: $e');
    }
  }

  void _scheduleReconvert() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), _reconvert);
  }

  Future<void> _reconvert() async {
    final photo = _photo;
    if (photo == null) return;
    final seq = ++_convertSeq;
    final bmp = await compute(_convert, (photo, _printer.profile.dotsPerLine, _settings));
    if (seq != _convertSeq) return; // a newer conversion superseded this one
    final preview = await monoToUiImage(bmp);
    if (!mounted) return;
    setState(() {
      _bitmap = bmp;
      _preview?.dispose();
      _preview = preview;
    });
  }

  static MonoBitmap _convert((img.Image, int, PrintSettings) a) => convertPhoto(a.$1, a.$2, a.$3);

  Future<void> _print() async {
    final bmp = _bitmap;
    if (bmp == null) return;
    await _printer.send(buildPhotoJob(bmp, _printer.profile, _printer.job), _photoName ?? 'photo');
  }

  // ------------------------------------------------------------------- UI ---

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 820;
    final controls = _buildControls(context);
    final preview = ListenableBuilder(listenable: _printer, builder: (context, _) => _buildPreview(context));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Thermal Photo'),
        actions: [
          IconButton(onPressed: _loadFromUrl, icon: const Icon(Icons.link), tooltip: 'Load photo from URL'),
          IconButton(onPressed: _pickPhoto, icon: const Icon(Icons.add_photo_alternate_outlined), tooltip: 'Choose photo'),
        ],
      ),
      body: wide
          ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: 380, child: controls),
              const VerticalDivider(width: 1),
              Expanded(child: preview),
            ])
          : Column(children: [Expanded(flex: 5, child: preview), const Divider(height: 1), Expanded(flex: 6, child: controls)]),
      floatingActionButton: ListenableBuilder(
        listenable: _printer,
        builder: (context, _) => FloatingActionButton.extended(
          heroTag: 'print-photo',
          onPressed: !_printer.canPrint || _bitmap == null ? null : _print,
          icon: _printer.busy
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.print),
          label: const Text('Print'),
        ),
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final p = _preview;
    final bmp = _bitmap;
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.topCenter,
      child: p == null || bmp == null
          ? Center(
              child: Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center, children: [
                FilledButton.icon(
                  onPressed: _pickPhoto,
                  icon: const Icon(Icons.photo),
                  label: const Text('Choose a photo'),
                ),
                OutlinedButton.icon(
                  onPressed: _loadFromUrl,
                  icon: const Icon(Icons.link),
                  label: const Text('Load from URL'),
                ),
              ]),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                Container(
                  decoration: const BoxDecoration(boxShadow: [BoxShadow(blurRadius: 6, color: Colors.black26)]),
                  child: RawImage(image: p, width: _printer.profile.paperWidthMm * 5.0, filterQuality: FilterQuality.medium),
                ),
                const SizedBox(height: 8),
                Text(
                  '${bmp.width}×${bmp.height} dots · ${(bmp.height / 8).toStringAsFixed(0)} mm long'
                  ' · ${(bmp.data.length * _printer.job.copies / 1024).toStringAsFixed(0)} KiB',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ]),
            ),
    );
  }

  Widget _buildControls(BuildContext context) {
    final s = _settings;
    void update(PrintSettings n) {
      setState(() => _settings = n);
      _printer.prefs?.settings = n;
      _scheduleReconvert();
    }

    final t = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        Text('Printer', style: t.titleSmall),
        PrinterPanel(controller: _printer),
        const Divider(height: 32),
        Text('Image', style: t.titleSmall),
        DropdownButtonFormField<DitherMode>(
          initialValue: s.dither,
          decoration: const InputDecoration(labelText: 'Dithering'),
          items: ditherItems,
          onChanged: (d) => update(s.copyWith(dither: d)),
        ),
        LabeledSlider(label: 'Brightness', value: s.brightness, min: -0.5, max: 0.5, onChanged: (v) => update(s.copyWith(brightness: v))),
        LabeledSlider(label: 'Contrast', value: s.contrast, min: 0.3, max: 2.5, onChanged: (v) => update(s.copyWith(contrast: v))),
        LabeledSlider(label: 'Gamma', value: s.gamma, min: 0.5, max: 2.5, onChanged: (v) => update(s.copyWith(gamma: v))),
        if (s.dither == DitherMode.threshold)
          LabeledSlider(
            label: 'Threshold',
            value: s.threshold.toDouble(),
            min: 1,
            max: 254,
            onChanged: (v) => update(s.copyWith(threshold: v.round())),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Rotate 90° (landscape → full width)'),
          value: s.rotate90,
          onChanged: (v) => update(s.copyWith(rotate90: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Invert'),
          value: s.invert,
          onChanged: (v) => update(s.copyWith(invert: v)),
        ),
        TextButton(
          onPressed: () => update(const PrintSettings(dither: DitherMode.atkinson, gamma: 1.3)),
          child: const Text('Reset image settings'),
        ),
        const Divider(height: 32),
        Text('Output', style: t.titleSmall),
        OutputPanel(controller: _printer),
      ],
    );
  }
}

/// Dither mode choices (shared with the receipt editor's image block).
const ditherItems = [
  DropdownMenuItem(value: DitherMode.atkinson, child: Text('Atkinson (crisp, recommended)')),
  DropdownMenuItem(value: DitherMode.floydSteinberg, child: Text('Floyd–Steinberg (smooth)')),
  DropdownMenuItem(value: DitherMode.ordered, child: Text('Ordered / Bayer (retro)')),
  DropdownMenuItem(value: DitherMode.threshold, child: Text('Threshold (text, line art)')),
];

class _UrlDialog extends StatefulWidget {
  const _UrlDialog();

  @override
  State<_UrlDialog> createState() => _UrlDialogState();
}

class _UrlDialogState extends State<_UrlDialog> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Load photo from URL'),
        content: TextField(
          controller: _ctl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://example.com/photo.jpg'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, _ctl.text), child: const Text('Load')),
        ],
      );
}
