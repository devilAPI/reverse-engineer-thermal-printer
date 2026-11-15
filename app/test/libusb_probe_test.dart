@TestOn('vm && linux')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:thermal_photo/transport/libusb_transport.dart';

void main() {
  test('libusb loads and enumerates without crashing', () async {
    final t = LibusbTransport();
    if (!t.isSupported) {
      markTestSkipped('libusb-1.0 not installed');
      return;
    }
    final eps = await t.discover();
    // ignore: avoid_print
    print('libusb candidates: $eps');
  });
}
