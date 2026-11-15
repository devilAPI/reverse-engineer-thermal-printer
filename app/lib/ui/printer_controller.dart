import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/print_job.dart';
import '../core/printer_profile.dart';
import '../core/status.dart';
import '../core/test_page.dart';
import '../transport/transport.dart';
import '../transport/transports.dart';
import 'prefs.dart';

/// Printer selection and the send path, shared by the Photo and Receipt
/// tabs: model (profile), connection (endpoint), job options (darkness, cut,
/// copies), progress and the status line.
class PrinterController extends ChangeNotifier {
  Prefs? prefs;
  PrinterProfile profile = PrinterProfile.mp583;
  JobOptions job = const JobOptions();

  List<PrinterTransport> _transports = availableTransports();
  List<PrinterEndpoint> endpoints = [];
  PrinterEndpoint? endpoint;
  String host = '';
  bool scanning = false;

  bool busy = false;
  double? progress;
  String? status;

  bool get canPrint => !busy && endpoint != null;

  /// Load persisted choices. Never throws (prefs may be unavailable).
  Future<void> loadPrefs() async {
    try {
      final p = await Prefs.load();
      prefs = p;
      profile = PrinterProfile.byId(p.profileId);
      job = p.job;
      host = p.host;
    } on Object catch (e) {
      debugPrint('prefs unavailable: $e');
    }
    notifyListeners();
  }

  void setStatus(String? s) {
    status = s;
    notifyListeners();
  }

  void setProfile(PrinterProfile p) {
    if (p == profile) return;
    profile = p;
    prefs?.profileId = p.id;
    notifyListeners();
  }

  void setJob(JobOptions j) {
    job = j;
    prefs?.job = j;
    notifyListeners();
  }

  void selectEndpoint(PrinterEndpoint? e) {
    endpoint = e;
    if (e != null) {
      prefs?.endpointId = _key(e);
      _autoProfile(e);
    }
    notifyListeners();
  }

  Future<void> scan({String? manualHost}) async {
    if (manualHost != null) {
      host = manualHost.trim();
      prefs?.host = host;
    }
    _transports = availableTransports(manualHosts: host.isEmpty ? const [] : [host]);
    scanning = true;
    notifyListeners();
    final found = <PrinterEndpoint>[];
    for (final t in _transports) {
      try {
        found.addAll(await t.discover());
      } on Object catch (e) {
        debugPrint('discover ${t.name} failed: $e');
      }
    }
    scanning = false;
    _applyEndpoints(found);
    if (found.isEmpty) status = 'No printer found. Plug it in / switch it on, then refresh.';
    notifyListeners();
  }

  /// Transports whose discovery is instant and local (USB/device nodes):
  /// polled every few seconds so plug/unplug shows up without Refresh.
  static const _cheap = {'libusb', 'device', 'usbprint', 'usb', 'dump'};
  Timer? _hotplug;

  void startHotplug() {
    _hotplug ??= Timer.periodic(const Duration(seconds: 3), (_) => _quickRefresh());
  }

  @override
  void dispose() {
    _hotplug?.cancel();
    super.dispose();
  }

  Future<void> _quickRefresh() async {
    if (busy || scanning) return;
    final fresh = <PrinterEndpoint>[];
    for (final t in _transports.where((t) => _cheap.contains(t.name))) {
      try {
        fresh.addAll(await t.discover());
      } on Object {
        // ignore; the full scan reports errors
      }
    }
    if (busy || scanning) return;
    final merged = [...fresh, ...endpoints.where((e) => !_cheap.contains(e.transport))];
    if (merged.length == endpoints.length && merged.toSet().containsAll(endpoints)) return;
    _applyEndpoints(merged);
    notifyListeners();
  }

  /// Update the list without ever silently switching to a different printer:
  /// keep the current/remembered choice if present; if it vanished, select
  /// nothing and say so. (Bug seen on hardware: after a replug the USB entry
  /// changed id and printing silently went to the Bluetooth printer.)
  void _applyEndpoints(List<PrinterEndpoint> found) {
    final remembered = prefs?.endpointId;
    final current = endpoint;
    PrinterEndpoint? next;
    if (current != null) {
      next = found.where((e) => e == current).firstOrNull;
      if (next == null) status = '"${current.label}" is no longer available.';
    } else {
      next = found.where((e) => _key(e) == remembered).firstOrNull ?? (remembered == null ? found.firstOrNull : null);
    }
    endpoints = found;
    endpoint = next;
    if (next != null && current == null && remembered == null) _autoProfile(next);
  }

  /// Switch the model to match a newly chosen connection (USB ID / BT name).
  void _autoProfile(PrinterEndpoint e) {
    final g = PrinterProfile.guess(label: e.label, vid: e.usbVendorId, pid: e.usbProductId);
    if (g == null || g == profile) return;
    profile = g;
    status = 'Detected ${g.name} from "${e.label}".';
    prefs?.profileId = g.id;
    notifyListeners();
  }

  static String _key(PrinterEndpoint e) => '${e.transport}|${e.id}';

  PrinterTransport _transportFor(PrinterEndpoint ep) => _transports.firstWhere((t) => t.name == ep.transport);

  /// Send a finished ESC/POS [job] to the selected printer. Returns whether
  /// all bytes were written.
  Future<bool> send(Uint8List job, String what) async {
    final ep = endpoint;
    if (ep == null || busy) return false;
    busy = true;
    progress = 0;
    status = 'Connecting to ${ep.label}…';
    notifyListeners();
    PrinterConnection? conn;
    var ok = false;
    try {
      conn = await _transportFor(ep).open(ep);
      setStatus('Sending $what (${(job.length / 1024).toStringAsFixed(1)} KiB)…');
      final sw = Stopwatch()..start();
      await sendChunked(
        conn,
        job,
        chunkSize: profile.chunkSize,
        delay: profile.chunkDelay,
        onProgress: (p) {
          progress = p;
          notifyListeners();
        },
      );
      ok = true;
      var msg = 'Sent $what in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s.';
      if (conn is PrinterStatusReader) {
        final r = conn as PrinterStatusReader;
        final st = await queryStatus(conn.write, r.read);
        msg += ' Printer: $st.';
      }
      status = msg;
    } on Object catch (e) {
      status = 'Failed: $e';
    } finally {
      await conn?.close();
      busy = false;
      progress = null;
      notifyListeners();
    }
    return ok;
  }

  Future<void> printTest() => send(buildTestPage(profile), 'test page');

  Future<void> checkStatus() async {
    final ep = endpoint;
    if (ep == null) return;
    setStatus('Querying status…');
    PrinterConnection? conn;
    try {
      conn = await _transportFor(ep).open(ep);
      if (conn is! PrinterStatusReader) {
        setStatus('This connection cannot read status (write-only).');
        return;
      }
      final st = await queryStatus(conn.write, (conn as PrinterStatusReader).read);
      setStatus('Printer: $st');
    } on Object catch (e) {
      setStatus('Status failed: $e');
    } finally {
      await conn?.close();
    }
  }
}
