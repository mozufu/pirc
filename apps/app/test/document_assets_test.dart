import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// The document runtime and the Canvas text engine are packaged twice until
/// M8 step 9 deletes the old app: in the old app's Flutter assets and in this
/// app's Android assets (Kotlin reads them, so Web never ships them). The two
/// copies must not drift apart.
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
    test('$name is the same in both apps', () {
      final ours = File('android/app/src/main/assets/scripts/$name');
      final old = File('../android/assets/$name');
      expect(ours.existsSync(), isTrue, reason: ours.path);
      expect(old.existsSync(), isTrue, reason: old.path);
      // Digests, not the bytes: a 7 MB byte list makes a slow and unreadable diff.
      final ourBytes = ours.readAsBytesSync();
      final oldBytes = old.readAsBytesSync();
      expect(ourBytes.length, oldBytes.length, reason: name);
      expect(
        sha256.convert(ourBytes).toString(),
        sha256.convert(oldBytes).toString(),
        reason: name,
      );
    });
  }
}
