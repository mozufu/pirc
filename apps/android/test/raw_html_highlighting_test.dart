import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'live_test.dart' show theme;

List<Map<String, Object>> segments(Iterable<InlineSpan> spans) {
  final result = <Map<String, Object>>[];
  void visit(InlineSpan span, TextStyle inherited) {
    final style = inherited.merge(span.style);
    if (span is! TextSpan) return;
    final text = span.text;
    if (text != null && text.isNotEmpty) {
      final color = style.color!;
      final next = <String, Object>{
        'text': text,
        'color':
            'rgb(${(color.r * 255).round()}, ${(color.g * 255).round()}, ${(color.b * 255).round()})',
        'italic': style.fontStyle == FontStyle.italic,
        'bold':
            (style.fontWeight ?? FontWeight.w400).value >=
            FontWeight.w600.value,
      };
      final previous = result.lastOrNull;
      if (previous != null &&
          ['color', 'italic', 'bold'].every((k) => previous[k] == next[k])) {
        previous['text'] = '${previous['text']}$text';
      } else {
        result.add(next);
      }
    }
    for (final child in span.children ?? <InlineSpan>[]) {
      visit(child, style);
    }
  }

  for (final span in spans) {
    visit(span, const TextStyle());
  }
  return result;
}

void main() {
  for (final brightness in Brightness.values) {
    final reference = obj(
      jsonDecode(
        File(
          '../../fixtures/mobile-parity/syntax-highlighting-${brightness.name}-expected.json',
        ).readAsStringSync(),
      ),
    );
    for (final row in rows(reference['cases'])) {
      testWidgets(
        'authored HTML highlight spans match web ${row['id']} ${brightness.name}',
        (t) async {
          await t.pumpWidget(
            MaterialApp(
              theme: theme.build(brightness),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: NativeMarkdown(
                    source:
                        '<pre><code class="hljs">${row['standalone']}</code></pre>',
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          final spans = t
              .widgetList<RichText>(
                find.descendant(
                  of: find.byType(NativeMarkdown),
                  matching: find.byType(RichText),
                ),
              )
              .map((w) => w.text);
          final actual = segments(spans);
          expect(actual.map((s) => s['text']).join(), row['text']);
          expect(actual, row['rawSegments']);
          expect(t.takeException(), isNull);
        },
      );
    }
  }
}
