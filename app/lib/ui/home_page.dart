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
import '../core/status.dart';
import '../core/test_page.dart';
import '../transport/transport.dart';
import '../transport/transports.dart';
import 'prefs.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.initialImage});

  /// Path of an image to open on start (desktop command line).
  final String? initialImage;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Prefs? _prefs;
  PrinterProfile _profile = PrinterProfile.mp583;
  PrintSettings _settings = const PrintSettings(dither: DitherMode.atkinson, gamma: 1.3);
  JobOptions _job = const JobOptions();

  img.Image? _photo;
  String? _photoName;
  MonoBitmap? _bitmap;
  ui.Image? _preview;
  Timer? _debounce;
  int _convertSeq = 0;

  List<PrinterTransport> _transports = availableTransports();
  List<PrinterEndpoint> _endpoints = [];
  PrinterEndpoint? _endpoint;
  final _hostCtl = TextEditingController();
  bool _scanning = false;

  bool _busy = false;
  double? _progress;
  String? _status;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final p = await Prefs.load();
      setState(() {
        _prefs = p;
        _profile = PrinterProfile.byId(p.profileId);
        _settings = p.settings;
        _job = p.job;
        _hostCtl.text = p.host;
      });
    } on Object catch (e) {
      debugPrint('prefs unavailable: $e');
    }
    final initial = widget.initialImage;
    if (initial != null) await _openPhoto(XFile(initial));
    // Web Bluetooth needs a user gesture to scan; don't auto-scan there.
    if (!kIsWeb) await _scan();
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
    await _openPhoto(file);
  }

  Future<void> _openPhoto(XFile file) async {
    setState(() => _status = 'Decoding ${file.name}…');
    final bytes = await file.readAsBytes();
    try {
      final photo = await compute(decodePhoto, bytes);
      _photo = photo;
      _photoName = file.name;
      await _reconvert();
      setState(() => _status = null);
    } on Object catch (e) {
      setState(() => _status = 'Could not open image: $e');
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
    final bmp = await compute(_convert, (photo, _profile.dotsPerLine, _settings));
    if (seq != _convertSeq) return; // a newer conversion superseded this one
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
        final v = bmp.getPixel(x, y) ? 30 : 248; // ink vs. paper
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
    final host = _hostCtl.text.trim();
    _prefs?.host = host;
    _transports = availableTransports(manualHosts: host.isEmpty ? const [] : [host]);
    setState(() => _scanning = true);
    final found = <PrinterEndpoint>[];
    for (final t in _transports) {
      try {
        found.addAll(await t.discover());
      } on Object catch (e) {
        debugPrint('discover ${t.name} failed: $e');
      }
    }
    if (!mounted) return;
    final remembered = _prefs?.endpointId;
    setState(() {
      _scanning = false;
      _endpoints = found;
      _endpoint = found.where((e) => _key(e) == remembered).firstOrNull ??
          found.where((e) => _key(e) == (_endpoint == null ? null : _key(_endpoint!))).firstOrNull ??
          found.firstOrNull;
      if (found.isEmpty) _status = 'No printer found. Plug it in / switch it on, then refresh.';
    });
  }

  static String _key(PrinterEndpoint e) => '${e.transport}|${e.id}';

  PrinterTransport _transportFor(PrinterEndpoint ep) => _transports.firstWhere((t) => t.name == ep.transport);

  Future<void> _send(Uint8List job, String what) async {
    final ep = _endpoint;
    if (ep == null) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _status = 'Connecting to ${ep.label}…';
    });
    PrinterConnection? conn;
    try {
      conn = await _transportFor(ep).open(ep);
      setState(() => _status = 'Sending $what (${(job.length / 1024).toStringAsFixed(1)} KiB)…');
      final sw = Stopwatch()..start();
      await sendChunked(
        conn,
        job,
        chunkSize: _profile.chunkSize,
        delay: _profile.chunkDelay,
        onProgress: (p) => setState(() => _progress = p),
      );
      var msg = 'Sent $what in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s.';
      if (conn is PrinterStatusReader) {
        final r = conn as PrinterStatusReader;
        final st = await queryStatus(conn.write, r.read);
        msg += ' Printer: $st.';
      }
      setState(() => _status = msg);
    } on Object catch (e) {
      setState(() => _status = 'Failed: $e');
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

  Future<void> _print() async {
    final bmp = _bitmap;
    if (bmp == null) return;
    await _send(buildPhotoJob(bmp, _profile, _job), _photoName ?? 'photo');
  }

  Future<void> _printTest() => _send(buildTestPage(_profile), 'test page');

  Future<void> _checkStatus() async {
    final ep = _endpoint;
    if (ep == null) return;
    setState(() => _status = 'Querying status…');
    PrinterConnection? conn;
    try {
      conn = await _transportFor(ep).open(ep);
      if (conn is! PrinterStatusReader) {
        setState(() => _status = 'This connection cannot read status (write-only).');
        return;
      }
      final st = await queryStatus(conn.write, (conn as PrinterStatusReader).read);
      setState(() => _status = 'Printer: $st');
    } on Object catch (e) {
      setState(() => _status = 'Status failed: $e');
    } finally {
      await conn?.close();
    }
  }

  // ------------------------------------------------------------------- UI ---

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 820;
    final controls = _buildControls(context);
    final preview = _buildPreview(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Thermal Photo'),
        actions: [
          IconButton(onPressed: _pickPhoto, icon: const Icon(Icons.add_photo_alternate_outlined), tooltip: 'Choose photo'),
        ],
      ),
      body: Column(children: [
        if (_progress != null) LinearProgressIndicator(value: _progress),
        Expanded(
          child: wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SizedBox(width: 380, child: controls),
                  const VerticalDivider(width: 1),
                  Expanded(child: preview),
                ])
              : Column(children: [Expanded(flex: 5, child: preview), const Divider(height: 1), Expanded(flex: 6, child: controls)]),
        ),
      ]),
      bottomNavigationBar: _status == null
          ? null
          : Material(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: SafeArea(
                child: ListTile(
                  dense: true,
                  title: Text(_status!),
                  trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _status = null)),
                ),
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy || _bitmap == null || _endpoint == null ? null : _print,
        icon: _busy ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.print),
        label: const Text('Print'),
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
              child: FilledButton.icon(
                onPressed: _pickPhoto,
                icon: const Icon(Icons.photo),
                label: const Text('Choose a photo'),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                Container(
                  decoration: const BoxDecoration(boxShadow: [BoxShadow(blurRadius: 6, color: Colors.black26)]),
                  child: RawImage(image: p, width: _profile.paperWidthMm * 5.0, filterQuality: FilterQuality.medium),
                ),
                const SizedBox(height: 8),
                Text(
                  '${bmp.width}×${bmp.height} dots · ${(bmp.height / 8).toStringAsFixed(0)} mm long'
                  ' · ${(bmp.data.length * _job.copies / 1024).toStringAsFixed(0)} KiB',
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
      _prefs?.settings = n;
      _scheduleReconvert();
    }

    void updateJob(JobOptions j) {
      setState(() => _job = j);
      _prefs?.job = j;
    }

    final t = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        Text('Printer', style: t.titleSmall),
        DropdownButtonFormField<PrinterProfile>(
          initialValue: _profile,
          decoration: const InputDecoration(labelText: 'Model'),
          items: [for (final p in PrinterProfile.all) DropdownMenuItem(value: p, child: Text(p.name))],
          onChanged: (p) {
            if (p == null) return;
            setState(() => _profile = p);
            _prefs?.profileId = p.id;
            _reconvert();
          },
        ),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<PrinterEndpoint>(
              key: ValueKey(_endpoints.length),
              initialValue: _endpoint,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Connection'),
              items: [
                for (final e in _endpoints) DropdownMenuItem(value: e, child: Text(e.label, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (e) {
                setState(() => _endpoint = e);
                if (e != null) _prefs?.endpointId = _key(e);
              },
            ),
          ),
          IconButton(
            onPressed: _scanning ? null : _scan,
            icon: _scanning
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            tooltip: 'Scan for printers',
          ),
        ]),
        if (!kIsWeb)
          TextField(
            controller: _hostCtl,
            decoration: const InputDecoration(labelText: 'Network printer IP (optional)', hintText: '192.168.123.100'),
            onSubmitted: (_) => _scan(),
          ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(
            onPressed: _busy || _endpoint == null ? null : _printTest,
            icon: const Icon(Icons.grid_on),
            label: const Text('Test page'),
          ),
          OutlinedButton.icon(
            onPressed: _busy || _endpoint == null ? null : _checkStatus,
            icon: const Icon(Icons.info_outline),
            label: const Text('Status'),
          ),
        ]),
        const Divider(height: 32),
        Text('Image', style: t.titleSmall),
        DropdownButtonFormField<DitherMode>(
          initialValue: s.dither,
          decoration: const InputDecoration(labelText: 'Dithering'),
          items: const [
            DropdownMenuItem(value: DitherMode.atkinson, child: Text('Atkinson (crisp, recommended)')),
            DropdownMenuItem(value: DitherMode.floydSteinberg, child: Text('Floyd–Steinberg (smooth)')),
            DropdownMenuItem(value: DitherMode.ordered, child: Text('Ordered / Bayer (retro)')),
            DropdownMenuItem(value: DitherMode.threshold, child: Text('Threshold (text, line art)')),
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
        if (_profile.density != DensityCommand.none)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Set print darkness'),
            subtitle: const Text('Off = printer default'),
            value: _job.darkness != null,
            onChanged: (v) => updateJob(v ? _job.copyWith(darkness: 0.5) : _job.copyWith(clearDarkness: true)),
          ),
        if (_job.darkness != null && _profile.density != DensityCommand.none)
          _slider('Darkness', _job.darkness!, 0, 1, (v) => updateJob(_job.copyWith(darkness: v))),
        if (_profile.hasCutter)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Cut after printing'),
            value: _job.cut,
            onChanged: (v) => updateJob(_job.copyWith(cut: v)),
          ),
        Row(children: [
          const SizedBox(width: 84, child: Text('Copies')),
          IconButton(
            onPressed: _job.copies > 1 ? () => updateJob(_job.copyWith(copies: _job.copies - 1)) : null,
            icon: const Icon(Icons.remove),
          ),
          Text('${_job.copies}'),
          IconButton(
            onPressed: _job.copies < 20 ? () => updateJob(_job.copyWith(copies: _job.copies + 1)) : null,
            icon: const Icon(Icons.add),
          ),
        ]),
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
