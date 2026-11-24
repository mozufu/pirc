import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/mindmap_parser.dart';
import 'package:pirc_render/src/mermaid/mindmap_rendering.dart';
import '../tool/parity/capture_fonts.dart' show loadParityFonts;

List<({String text, TextStyle style})> runs(
  TextSpan span, [
  TextStyle inherited = const TextStyle(),
]) {
  final style = inherited.merge(span.style);
  return [
    if (span.text?.isNotEmpty == true) (text: span.text!, style: style),
    for (final child in span.children ?? const <InlineSpan>[])
      if (child is TextSpan) ...runs(child, style),
  ];
}

Color rgb(String value) {
  final numbers = RegExp(
    r'\d+',
  ).allMatches(value).map((m) => int.parse(m[0]!)).toList();
  return Color.fromARGB(255, numbers[0], numbers[1], numbers[2]);
}

void main() {
  final reference =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/mermaid-mindmap-labels-expected.json',
            ).readAsStringSync(),
          )
          as Map;
  testWidgets(
    'labels and decorations retain actual pinned unified-renderer behavior',
    (tester) async {
      await tester.runAsync(loadParityFonts);
      expect(
        reference['webRevision'],
        'bd3d90981271e1f93cf3d1d1a5bbf9b61136b74c',
      );
      expect(reference['mermaidVersion'], '11.17.2');
      for (final item in reference['cases'] as List) {
        final layout = layoutNativeMermaidMindmap(
          parseNativeMermaidMindmap(item['source'] as String),
          width: 332,
          dark: false,
          fontFamily: 'Arial',
        );
        final expected = item['nodes'] as List;
        expect(layout.nodes.length, expected.length, reason: item['id']);
        for (var i = 0; i < expected.length; i++) {
          final node = layout.nodes[i], source = expected[i] as Map;
          expect(
            node.label.toPlainText(),
            source['text'],
            reason: '${item['id']} node$i',
          );
          expect(node.fill, rgb(source['shapes'][0]['fill'] as String));
          expect(node.labelSize.height % 19.5, closeTo(0, 1e-9));
          for (final leaf in source['leaves'] as List) {
            final matching = runs(
              node.label,
            ).where((run) => run.text == leaf['text']).toList();
            // A parent p can contain several literal text runs; the complete
            // string above checks that text, while leaf emphasis/styles remain.
            if (matching.isEmpty) continue;
            expect(matching.first.style.color, rgb(leaf['color'] as String));
            expect(
              matching.first.style.fontWeight?.value,
              int.parse(leaf['fontWeight'] as String),
            );
            expect(
              matching.first.style.fontStyle ?? FontStyle.normal,
              leaf['fontStyle'] == 'italic'
                  ? FontStyle.italic
                  : FontStyle.normal,
            );
          }
        }
        expect(item['iconCount'], 0);
      }
    },
  );
}
