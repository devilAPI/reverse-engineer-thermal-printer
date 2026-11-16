import 'transport.dart';
import 'transports_stub.dart'
    if (dart.library.io) 'transports_io.dart'
    if (dart.library.js_interop) 'transports_web.dart' as impl;

/// All transports usable on the running platform.
List<PrinterTransport> availableTransports({List<String> manualHosts = const []}) =>
    impl.platformTransports(manualHosts: manualHosts).where((t) => t.isSupported).toList();

/// Platform/browser limits worth showing to the user, or null.
String? platformNote() => impl.platformNote();
