import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Subresource Integrity (`integrity="sha384-…"`) for script and stylesheet
/// requests of a document. The old app checked it in Kotlin; the scripts
/// channel does not, and the runtime only passes the metadata on, so it is
/// checked here before the bytes reach the isolate.
///
/// Returns true when [bytes] match [metadata]. Metadata with no known hash
/// passes, as in browsers. A response the document may not read (`opaque`)
/// never passes a non-empty check.
bool documentIntegrityMatches(
  String? metadata,
  Uint8List bytes, {
  required String responseType,
}) {
  final expected = _parse(metadata ?? '');
  if (expected.isEmpty) return true;
  if (responseType != 'cors') return false;
  final strongest = expected
      .map((hash) => hash.$1)
      .reduce((a, b) => _strength[a]! >= _strength[b]! ? a : b);
  final actual = base64.encode(switch (strongest) {
    'sha512' => sha512.convert(bytes).bytes,
    'sha384' => sha384.convert(bytes).bytes,
    _ => sha256.convert(bytes).bytes,
  });
  return expected.any(
    (hash) => hash.$1 == strongest && _sameBase64(hash.$2, actual),
  );
}

const _strength = {'sha256': 1, 'sha384': 2, 'sha512': 3};

List<(String, String)> _parse(String metadata) => [
  for (final token in metadata.split(RegExp(r'[\t\n\f\r ]+')))
    if (token.indexOf('-') case final dash when dash > 0)
      if (_strength.containsKey(token.substring(0, dash).toLowerCase()))
        (
          token.substring(0, dash).toLowerCase(),
          token.substring(dash + 1).split('?').first,
        ),
];

/// base64 and base64url spell the same digest (SRI § 3.3.5).
bool _sameBase64(String a, String b) {
  String normal(String value) =>
      value.replaceAll('-', '+').replaceAll('_', '/').replaceAll('=', '');
  return normal(a) == normal(b);
}
