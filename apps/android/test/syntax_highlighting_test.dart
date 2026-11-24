import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/code_block.dart';
import 'package:pirc_mobile/theme.dart';

import 'live_test.dart' show theme;

final _webLight =
    jsonDecode(
          File(
            '../../fixtures/mobile-parity/syntax-highlighting-light-expected.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;
final _webDark =
    jsonDecode(
          File(
            '../../fixtures/mobile-parity/syntax-highlighting-dark-expected.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

String _css(Color color) =>
    'rgb(${(color.r * 255).round()}, ${(color.g * 255).round()}, ${(color.b * 255).round()})';

List<(String, String, bool, bool)> _runs(InlineSpan root, TextStyle baseStyle) {
  final runs = <(String, String, bool, bool)>[];
  void append(String text, TextStyle style) {
    if (text.isEmpty) return;
    final next = (
      text,
      _css(style.color ?? Colors.black),
      style.fontStyle == FontStyle.italic,
      (style.fontWeight?.value ?? FontWeight.normal.value) >=
          FontWeight.w600.value,
    );
    if (runs.isNotEmpty &&
        runs.last.$2 == next.$2 &&
        runs.last.$3 == next.$3 &&
        runs.last.$4 == next.$4) {
      final previous = runs.removeLast();
      runs.add((previous.$1 + next.$1, next.$2, next.$3, next.$4));
    } else {
      runs.add(next);
    }
  }

  void visit(InlineSpan span, TextStyle inheritedStyle) {
    if (span is! TextSpan) return;
    final style = inheritedStyle.merge(span.style);
    if (span.text != null) append(span.text!, style);
    for (final child in span.children ?? const <InlineSpan>[]) {
      visit(child, style);
    }
  }

  visit(root, baseStyle);
  return runs;
}

List<(String, String, bool, bool)> _expectedRuns(
  Map<String, dynamic> testCase,
) {
  final runs = <(String, String, bool, bool)>[];
  for (final raw in testCase['segments'] as List<dynamic>) {
    final segment = raw as Map<String, dynamic>;
    final next = (
      segment['text'] as String,
      segment['color'] as String,
      segment['italic'] as bool,
      segment['bold'] as bool,
    );
    if (runs.isNotEmpty &&
        runs.last.$2 == next.$2 &&
        runs.last.$3 == next.$3 &&
        runs.last.$4 == next.$4) {
      final previous = runs.removeLast();
      runs.add((previous.$1 + next.$1, next.$2, next.$3, next.$4));
    } else {
      runs.add(next);
    }
  }
  return runs;
}

void main() {
  for (final (brightness, reference) in [
    (Brightness.light, _webLight),
    (Brightness.dark, _webDark),
  ]) {
    final colors = theme.build(brightness).extension<PircColors>()!;
    for (final raw in reference['cases'] as List<dynamic>) {
      final testCase = raw as Map<String, dynamic>;
      test('web syntax colors $brightness: ${testCase['id']}', () {
        final code = testCase['text'] as String;
        final span = highlightCode(
          code,
          testCase['language'] as String,
          colors,
        );
        expect(span.toPlainText(), code);
        final baseStyle = TextStyle(color: colors['code.text']);
        expect(
          _runs(span, baseStyle),
          _expectedRuns(testCase),
          reason:
              'Native scopes or CSS style cascade differ for ${testCase['id']}',
        );
      });
    }
  }

  test(
    'standalone limit and fenced block highlighting follow web behavior',
    () {
      final colors = theme.build(Brightness.light).extension<PircColors>()!;
      final code = '${' '.padRight(200001)}const value = 1;';
      final standalone = highlightCode(code, 'javascript', colors);
      final fenced = highlightCodeBlock(code, 'javascript', colors);
      expect(standalone.toPlainText(), code);
      expect(
        _runs(
          standalone,
          TextStyle(color: colors['code.text']),
        ).every((run) => run.$2 == _css(colors['code.text'])),
        isTrue,
      );
      expect(
        _runs(
          fenced,
          TextStyle(color: colors['code.text']),
        ).any((run) => run.$2 == _css(colors['web.hl-keyword'])),
        isTrue,
      );
    },
  );
}
