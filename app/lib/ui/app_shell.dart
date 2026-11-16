import 'package:flutter/material.dart';

import 'photo_page.dart';
import 'printer_controller.dart';
import 'receipt/receipt_page.dart';

/// Top level: Photo and Receipt tabs sharing one [PrinterController], with
/// the progress bar and status line below/above both.
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.initialImage});

  final String? initialImage;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _printer = PrinterController();
  bool _ready = false;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _printer.loadPrefs();
    if (!mounted) return;
    setState(() => _ready = true);
    // Discovery never opens a browser chooser (that needs a click: "Add
    // printer" buttons), so scanning on start is safe on the web too.
    await _printer.startBridgeIfEnabled();
    await _printer.scan();
    _printer.startHotplug();
  }

  @override
  void dispose() {
    _printer.dispose();
    super.dispose();
  }

  static const _destinations = [
    (Icons.photo_outlined, Icons.photo, 'Photo'),
    (Icons.receipt_long_outlined, Icons.receipt_long, 'Receipt'),
  ];

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final wide = MediaQuery.sizeOf(context).width > 820;
    final pages = IndexedStack(index: _tab, children: [
      PhotoPage(printer: _printer, initialImage: widget.initialImage),
      ReceiptPage(printer: _printer),
    ]);
    final body = Column(children: [
      ListenableBuilder(
        listenable: _printer,
        builder: (context, _) => _printer.progress == null
            ? const SizedBox.shrink()
            : LinearProgressIndicator(value: _printer.progress),
      ),
      Expanded(child: pages),
      ListenableBuilder(listenable: _printer, builder: (context, _) => _statusBar(context)),
    ]);
    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: _tab,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              for (final (icon, sel, label) in _destinations)
                NavigationRailDestination(icon: Icon(icon), selectedIcon: Icon(sel), label: Text(label)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ]),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        height: 64,
        destinations: [
          for (final (icon, sel, label) in _destinations)
            NavigationDestination(icon: Icon(icon), selectedIcon: Icon(sel), label: label),
        ],
      ),
    );
  }

  Widget _statusBar(BuildContext context) {
    final s = _printer.status;
    if (s == null) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: SafeArea(
        top: false,
        child: ListTile(
          dense: true,
          // Live region: screen readers announce progress/errors (also what
          // tools/web_e2e.mjs reads in the browser).
          title: Semantics(liveRegion: true, label: 'Status: $s', excludeSemantics: true, child: Text(s)),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Dismiss',
            onPressed: () => _printer.setStatus(null),
          ),
        ),
      ),
    );
  }
}
