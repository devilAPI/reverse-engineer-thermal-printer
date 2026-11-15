import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/mono_bitmap.dart';
import '../core/printer_profile.dart';
import '../transport/transport.dart';
import 'printer_controller.dart';

/// Model + connection selection, test page and status buttons.
class PrinterPanel extends StatefulWidget {
  const PrinterPanel({super.key, required this.controller});

  final PrinterController controller;

  @override
  State<PrinterPanel> createState() => _PrinterPanelState();
}

class _PrinterPanelState extends State<PrinterPanel> {
  late final _hostCtl = TextEditingController(text: widget.controller.host);

  @override
  void dispose() {
    _hostCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DropdownButtonFormField<PrinterProfile>(
          key: ValueKey(c.profile),
          initialValue: c.profile,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Model'),
          items: [for (final p in PrinterProfile.all) DropdownMenuItem(value: p, child: Text(p.name))],
          onChanged: (p) {
            if (p != null) c.setProfile(p);
          },
        ),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<PrinterEndpoint>(
              key: ValueKey(c.endpoints.length),
              initialValue: c.endpoint,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Connection'),
              items: [
                for (final e in c.endpoints) DropdownMenuItem(value: e, child: Text(e.label, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: c.selectEndpoint,
            ),
          ),
          IconButton(
            onPressed: c.scanning ? null : () => c.scan(manualHost: _hostCtl.text),
            icon: c.scanning
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            tooltip: 'Scan for printers',
          ),
        ]),
        if (!kIsWeb)
          TextField(
            controller: _hostCtl,
            decoration: const InputDecoration(labelText: 'Network printer IP (optional)', hintText: '192.168.123.100'),
            onSubmitted: (v) => c.scan(manualHost: v),
          ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(
            onPressed: c.canPrint ? c.printTest : null,
            icon: const Icon(Icons.grid_on),
            label: const Text('Test page'),
          ),
          OutlinedButton.icon(
            onPressed: c.canPrint ? c.checkStatus : null,
            icon: const Icon(Icons.info_outline),
            label: const Text('Status'),
          ),
        ]),
      ]),
    );
  }
}

/// Darkness, cut and copies (JobOptions).
class OutputPanel extends StatelessWidget {
  const OutputPanel({super.key, required this.controller});

  final PrinterController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final job = c.job;
        final density = c.profile.density != DensityCommand.none;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (density)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Set print darkness'),
              subtitle: const Text('Off = printer default'),
              value: job.darkness != null,
              onChanged: (v) => c.setJob(v ? job.copyWith(darkness: 0.5) : job.copyWith(clearDarkness: true)),
            ),
          if (job.darkness != null && density)
            LabeledSlider(label: 'Darkness', value: job.darkness!, min: 0, max: 1, onChanged: (v) => c.setJob(job.copyWith(darkness: v))),
          if (c.profile.hasCutter)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Cut after printing'),
              value: job.cut,
              onChanged: (v) => c.setJob(job.copyWith(cut: v)),
            ),
          Row(children: [
            const SizedBox(width: 84, child: Text('Copies')),
            IconButton(
              onPressed: job.copies > 1 ? () => c.setJob(job.copyWith(copies: job.copies - 1)) : null,
              icon: const Icon(Icons.remove),
            ),
            Text('${job.copies}'),
            IconButton(
              onPressed: job.copies < 20 ? () => c.setJob(job.copyWith(copies: job.copies + 1)) : null,
              icon: const Icon(Icons.add),
            ),
          ]),
        ]);
      },
    );
  }
}

class LabeledSlider extends StatelessWidget {
  const LabeledSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.format,
  });

  final String label;
  final double value, min, max;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final String Function(double)? format;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      SizedBox(width: 84, child: Text(label)),
      Expanded(
        child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: onChanged),
      ),
      SizedBox(width: 44, child: Text(format?.call(value) ?? value.toStringAsFixed(2), textAlign: TextAlign.end)),
    ]);
  }
}

/// Paper-coloured preview image of a 1-bit bitmap.
Future<ui.Image> monoToUiImage(MonoBitmap bmp) {
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
