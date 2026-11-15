import 'dart:async';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../core/image_pipeline.dart';
import '../core/mono_bitmap.dart';
import '../core/print_job.dart';
import '../core/printer_profile.dart';
import '../transport/transport.dart';
import '../transport/transports.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  PrinterProfile _profile = PrinterProfile.mp583;
  PrintSettings _settings = const PrintSettings(gamma: 1.3);

  img.Image? _photo;
  MonoBitmap? _bitmap;
  ui.Image? _preview;
  Timer? _debounce;

  late List<PrinterTransport> _transports = availableTransports();
  List<PrinterEndpoint> _endpoints = [];
  PrinterEndpoint? _endpoint;
  final _hostCtl = TextEditingController();

  bool _busy = false;
  double? _progress;
  String? _status;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _hostCtl.dispose();
    super.dispose();
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
    setState(() => _status = 'Decoding ${file.name}…');
    final bytes = await file.readAsBytes();
    try {
      final photo = await compute(decodePhoto, bytes);
      _photo = photo;
      await _reconvert();
      setState(() => _status = '${file.name}: ${photo.width}×${photo.height}');
    } on Object catch (e) {
      setState(() => _status = 'Could not open image: $e');
    }
  }

  void _scheduleReconvert() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), _reconvert);
  }

  Future<void> _reconvert() async {
    final photo = _photo;
    if (photo == null) return;
    final bmp = await compute(_convert, (photo, _profile.dotsPerLine, _settings));
    final preview = await _toUiImage(bmp);
    if (!mounted) return;
    setState(() {
      _bitmap = bmp;
      _preview?.dispose();
      _preview = preview;
    });
  }

  static MonoBitmap _convert((img.Image, int, PrintSettings) a) => convertPhoto(a.$1, a.$2, a.$3);

  static Future<ui.Image> _toUiImage(MonoBitmap bmp) {
    final rgba = Uint8List(bmp.width * bmp.height * 4);
    var o = 0;
    for (var y = 0; y < bmp.height; y++) {
      for (var x = 0; x < bmp.width; x++) {
        final v = bmp.getPixel(x, y) ? 20 : 250; // ink vs. paper
        rgba[o++] = v;
        rgba[o++] = v;
        rgba[o++] = v;
        rgba[o++] = 255;
      }
    }
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, bmp.width, bmp.height, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  // -------------------------------------------------------------- printer ---

  Future<void> _scan() async {
    _transports = availableTransports(
      manualHosts: _hostCtl.text.trim().isEmpty ? const [] : [_hostCtl.text.trim()],
    );
    final found = <PrinterEndpoint>[];
    for (final t in _transports) {
      try {
        found.addAll(await t.discover());
      } on Object catch (e) {
        debugPrint('discover ${t.name} failed: $e');
      }
    }
    if (!mounted) return;
    setState(() {
      _endpoints = found;
      if (!found.contains(_endpoint)) _endpoint = found.isEmpty ? null : found.first;
    });
  }

  Future<void> _print() async {
    final bmp = _bitmap;
    final ep = _endpoint;
    if (bmp == null || ep == null) return;
    final transport = _transports.firstWhere((t) => t.name == ep.transport);
    setState(() {
      _busy = true;
      _progress = 0;
      _status = 'Connecting to ${ep.label}…';
    });
    PrinterConnection? conn;
    try {
      final job = buildPhotoJob(bmp, _profile);
      conn = await transport.open(ep);
      setState(() => _status = 'Sending ${job.length} bytes…');
      await sendChunked(
        conn,
        job,
        chunkSize: _profile.chunkSize,
        delay: _profile.chunkDelay,
        onProgress: (p) => setState(() => _progress = p),
      );
      setState(() => _status = 'Printed.');
    } on Object catch (e) {
      setState(() => _status = 'Print failed: $e');
    } finally {
      await conn?.close();
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  // ------------------------------------------------------------------- UI ---

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 800;
    final controls = _buildControls(context);
    final preview = _buildPreview(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Thermal Photo')),
      body: wide
          ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: 360, child: controls),
              const VerticalDivider(width: 1),
              Expanded(child: preview),
            ])
          : Column(children: [Expanded(child: preview), const Divider(height: 1), Expanded(child: controls)]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy || _bitmap == null || _endpoint == null ? null : _print,
        icon: const Icon(Icons.print),
        label: const Text('Print'),
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final p = _preview;
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.topCenter,
      child: p == null
          ? Center(
              child: FilledButton.icon(
                onPressed: _pickPhoto,
                icon: const Icon(Icons.photo),
                label: const Text('Choose a photo'),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Container(
                decoration: const BoxDecoration(boxShadow: [BoxShadow(blurRadius: 6, color: Colors.black26)]),
                // Show at physical width (dots / 8 per mm), scaled for screen.
                child: RawImage(image: p, width: _profile.paperWidthMm * 5.0, filterQuality: FilterQuality.none),
              ),
            ),
    );
  }

  Widget _buildControls(BuildContext context) {
    final s = _settings;
    void update(PrintSettings n) {
      setState(() => _settings = n);
      _scheduleReconvert();
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        if (_progress != null) LinearProgressIndicator(value: _progress),
        if (_status != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_status!)),
        OutlinedButton.icon(onPressed: _pickPhoto, icon: const Icon(Icons.photo_library), label: const Text('Choose photo')),
        const SizedBox(height: 16),
        DropdownButtonFormField<PrinterProfile>(
          initialValue: _profile,
          decoration: const InputDecoration(labelText: 'Printer model'),
          items: [for (final p in PrinterProfile.all) DropdownMenuItem(value: p, child: Text(p.name))],
          onChanged: (p) {
            if (p == null) return;
            setState(() => _profile = p);
            _reconvert();
          },
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<PrinterEndpoint>(
              initialValue: _endpoint,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Connection'),
              items: [for (final e in _endpoints) DropdownMenuItem(value: e, child: Text(e.label, overflow: TextOverflow.ellipsis))],
              onChanged: (e) => setState(() => _endpoint = e),
            ),
          ),
          IconButton(onPressed: _scan, icon: const Icon(Icons.refresh), tooltip: 'Scan'),
        ]),
        TextField(
          controller: _hostCtl,
          decoration: const InputDecoration(labelText: 'Network printer IP (optional)', hintText: '192.168.1.87'),
          onSubmitted: (_) => _scan(),
        ),
        const Divider(height: 32),
        DropdownButtonFormField<DitherMode>(
          initialValue: s.dither,
          decoration: const InputDecoration(labelText: 'Dithering'),
          items: const [
            DropdownMenuItem(value: DitherMode.floydSteinberg, child: Text('Floyd–Steinberg')),
            DropdownMenuItem(value: DitherMode.atkinson, child: Text('Atkinson')),
            DropdownMenuItem(value: DitherMode.ordered, child: Text('Ordered (Bayer)')),
            DropdownMenuItem(value: DitherMode.threshold, child: Text('Threshold (line art)')),
          ],
          onChanged: (d) => update(s.copyWith(dither: d)),
        ),
        _slider('Brightness', s.brightness, -0.5, 0.5, (v) => update(s.copyWith(brightness: v))),
        _slider('Contrast', s.contrast, 0.3, 2.5, (v) => update(s.copyWith(contrast: v))),
        _slider('Gamma', s.gamma, 0.5, 2.5, (v) => update(s.copyWith(gamma: v))),
        if (s.dither == DitherMode.threshold)
          _slider('Threshold', s.threshold.toDouble(), 1, 254, (v) => update(s.copyWith(threshold: v.round()))),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Rotate 90°'),
          value: s.rotate90,
          onChanged: (v) => update(s.copyWith(rotate90: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Invert'),
          value: s.invert,
          onChanged: (v) => update(s.copyWith(invert: v)),
        ),
      ],
    );
  }

  Widget _slider(String label, double value, double min, double max, ValueChanged<double> onChanged) {
    return Row(children: [
      SizedBox(width: 84, child: Text(label)),
      Expanded(child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged)),
      SizedBox(width: 40, child: Text(value.toStringAsFixed(2), textAlign: TextAlign.end)),
    ]);
  }
}
