import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The document runtime and the Canvas text engine are packaged in the app's
/// Android assets (Kotlin reads them, so Web never ships them). Their provenance
/// names the retained pre-cutover source in docs/development/historical-records.md.
void main() {
  const names = [
    'document-script-runtime.js',
    'document-script-runtime.LICENSE.txt',
    'document-script-runtime.THIRD_PARTY.txt',
    'document-script-runtime.provenance.json',
    'document-canvas-text.js',
    'document-canvas-text.wasm',
    'document-canvas-text.LICENSE.txt',
    'document-canvas-text.provenance.json',
  ];

  for (final name in names) {
    test('$name is packaged and non-empty', () {
      final file = File('android/app/src/main/assets/scripts/$name');
      expect(file.existsSync(), isTrue, reason: file.path);
      expect(file.lengthSync(), greaterThan(0), reason: file.path);
    });
  }
}
