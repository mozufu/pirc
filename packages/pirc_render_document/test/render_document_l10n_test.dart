import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/l10n/catalogs.g.dart';

/// The document runtime translates through the renderer's catalogs; every
/// string it shows needs English and Chinese text there.
void main() {
  test('every document runtime string has English and Chinese text', () {
    final literal = RegExp(
      r'''\btr\(\s*((?:r?"(?:[^"\\\n]|\\.)*"\s*|r?'(?:[^'\\\n]|\\.)*'\s*)+)[,)]''',
    );
    final missing = <String>[];
    var found = 0;
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      for (final match in literal.allMatches(file.readAsStringSync())) {
        found++;
        final key = _decode(match[1]!);
        if (!renderEnglishMessages.containsKey(key) ||
            !renderTraditionalChineseMessages.containsKey(key)) {
          missing.add('${file.path}: $key');
        }
      }
    }
    expect(found, greaterThan(100), reason: 'the scan found the strings');
    expect(missing, isEmpty);
  });
}

/// Joins adjacent Dart string literals and resolves their escapes.
String _decode(String literals) {
  final parts = RegExp(
    r"""r?"(?:[^"\\\n]|\\.)*"|r?'(?:[^'\\\n]|\\.)*'""",
  ).allMatches(literals).map((m) => m[0]!);
  final out = StringBuffer();
  for (final part in parts) {
    final raw = part.startsWith('r');
    final body = part.substring(raw ? 2 : 1, part.length - 1);
    if (raw) {
      out.write(body);
      continue;
    }
    for (var i = 0; i < body.length; i++) {
      if (body[i] == r'\' && i + 1 < body.length) {
        final next = body[++i];
        out.write(switch (next) {
          'n' => '\n',
          't' => '\t',
          'r' => '\r',
          _ => next,
        });
      } else {
        out.write(body[i]);
      }
    }
  }
  return out.toString();
}
