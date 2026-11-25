@TestOn('vm')
library;

import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_client/src/transport/io_transport.dart';
import 'package:test/test.dart';

void main() {
  // Android, macOS and tests resolve `dart.library.io`, not `js_interop`.
  test('native platforms get the dart:io adapter', () {
    final transport = createTransport(
      TransportConfig(baseUri: Uri.parse('https://pirc.example')),
    );
    expect(transport, isA<IoTransport>());
    transport.close();
  });
}
