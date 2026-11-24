import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/l10n/catalogs.g.dart';
import 'package:pirc_render/src/render_l10n.dart';

void main() {
  tearDown(() => RenderL10n.language = 'en');

  test('the catalog translates, falls back and keeps parameters literal', () {
    expect(tr('Copy'), 'Copy');
    RenderL10n.language = 'zh-TW';
    expect(tr('Copy'), isNot('Copy'));
    expect(tr('Unknown authored text'), 'Unknown authored text');
    expect(tr('Unknown {0}', ['<b>{1}</b>']), 'Unknown <b>{1}</b>');
  });

  test('generated catalog matches the JSON sources', () {
    Map<String, String> read(String name) => Map<String, String>.from(
      jsonDecode(File('lib/src/l10n/$name.json').readAsStringSync()) as Map,
    );
    expect(renderEnglishMessages, read('en'));
    expect(renderTraditionalChineseMessages, read('zh-TW'));
  });

  test('every renderer string has English and Chinese text', () {
    final literal = RegExp(
      r'''\btr\(\s*((?:r?"(?:[^"\\\n]|\\.)*"\s*|r?'(?:[^'\\\n]|\\.)*'\s*)+)[,)]''',
    );
    final missing = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      for (final match in literal.allMatches(file.readAsStringSync())) {
        final key = _decode(match[1]!);
        if (!renderEnglishMessages.containsKey(key) ||
            !renderTraditionalChineseMessages.containsKey(key)) {
          missing.add('${file.path}: $key');
        }
      }
    }
    expect(missing, isEmpty);
    expect(
      renderTraditionalChineseMessages.keys.toSet(),
      renderEnglishMessages.keys.toSet(),
    );
    List<String> args(String value) =>
        RegExp(r'\{\d+\}').allMatches(value).map((m) => m[0]!).toList()
          ..sort();
    for (final entry in renderEnglishMessages.entries) {
      expect(args(entry.value), args(entry.key), reason: entry.key);
      expect(
        args(renderTraditionalChineseMessages[entry.key]!),
        args(entry.key),
        reason: entry.key,
      );
    }
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
