import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/mermaid/flowchart.dart';

const _fixturePath =
    '../../fixtures/mobile-parity/mermaid-flow-parser-expected.json';

void main() {
  final fixture =
      jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;
  final cases = fixture['cases'] as List<dynamic>;

  for (final rawCase in cases) {
    final item = Map<String, dynamic>.from(rawCase as Map);
    final id = item['id'] as String;
    final source = item['source'] as String;
    final status = item['status'] as String;

    test('matches pinned Mermaid parser case $id', () {
      if (status == 'error') {
        expect(
          () => parseNativeMermaidFlowchart(source),
          throwsFormatException,
          reason: 'Pinned Mermaid rejects $id: ${item['error']}',
        );
        return;
      }

      final graph = parseNativeMermaidFlowchart(source);
      expect(graph.direction, 'LR', reason: id);

      final expectedVertices = item['vertices'] as List<dynamic>;
      final actualNodes = [...graph.nodes]
        ..sort((a, b) => a.id.compareTo(b.id));
      final sortedExpectedVertices = [...expectedVertices]
        ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));

      expect(
        actualNodes.map((node) => node.id).toList(),
        sortedExpectedVertices.map((node) => node['id'] as String).toList(),
        reason: '$id vertex IDs',
      );
      for (var i = 0; i < sortedExpectedVertices.length; i++) {
        final expected = sortedExpectedVertices[i] as Map<String, dynamic>;
        final actual = actualNodes[i];
        expect(
          actual.shape,
          _nativeShape(expected['type'] as String?),
          reason: '$id node ${actual.id} shape',
        );
        expect(
          actual.label,
          _renderedText(expected['label'] as String),
          reason: '$id node ${actual.id} rendered label',
        );
      }

      final expectedEdges = item['edges'] as List<dynamic>;
      expect(graph.edges, hasLength(expectedEdges.length), reason: '$id edges');
      for (var i = 0; i < expectedEdges.length; i++) {
        final expected = expectedEdges[i] as Map<String, dynamic>;
        final actual = graph.edges[i];
        expect(actual.from, expected['start'], reason: '$id edge $i start');
        expect(actual.to, expected['end'], reason: '$id edge $i end');
        expect(
          actual.label,
          _renderedText(expected['text'] as String),
          reason: '$id edge $i rendered text',
        );
        expect(
          actual.lineStyle,
          _nativeLineStyle(expected['stroke'] as String),
          reason: '$id edge $i line style',
        );
        final markers = _nativeMarkers(expected['type'] as String);
        expect(
          actual.startMarker,
          markers.$1,
          reason: '$id edge $i start marker',
        );
        expect(actual.endMarker, markers.$2, reason: '$id edge $i end marker');
      }
    });
  }
}

MermaidFlowNodeShape _nativeShape(String? type) => switch (type) {
  null || 'square' => MermaidFlowNodeShape.rectangle,
  'round' => MermaidFlowNodeShape.rounded,
  'circle' => MermaidFlowNodeShape.circle,
  'diamond' => MermaidFlowNodeShape.diamond,
  _ => throw StateError('Unexpected pinned Mermaid node type: $type'),
};

MermaidFlowLineStyle _nativeLineStyle(String stroke) => switch (stroke) {
  'normal' => MermaidFlowLineStyle.solid,
  'dotted' => MermaidFlowLineStyle.dotted,
  'thick' => MermaidFlowLineStyle.thick,
  _ => throw StateError('Unexpected pinned Mermaid line style: $stroke'),
};

(MermaidFlowMarker, MermaidFlowMarker) _nativeMarkers(
  String type,
) => switch (type) {
  'arrow_open' => (MermaidFlowMarker.none, MermaidFlowMarker.none),
  'arrow_point' => (MermaidFlowMarker.none, MermaidFlowMarker.arrow),
  'arrow_circle' => (MermaidFlowMarker.none, MermaidFlowMarker.circle),
  'arrow_cross' => (MermaidFlowMarker.none, MermaidFlowMarker.cross),
  'double_arrow_point' => (MermaidFlowMarker.arrow, MermaidFlowMarker.arrow),
  'double_arrow_circle' => (MermaidFlowMarker.circle, MermaidFlowMarker.circle),
  'double_arrow_cross' => (MermaidFlowMarker.cross, MermaidFlowMarker.cross),
  _ => throw StateError('Unexpected pinned Mermaid edge type: $type'),
};

String _renderedText(String source) {
  final restoredEntities = source.replaceAllMapped(RegExp(r'ﬂ°([\w#]+)¶ß'), (
    match,
  ) {
    final entityName = match[1]!;
    final reference = '&$entityName;';
    return html.parseFragment(reference).text ?? match[0]!;
  });
  return html.parseFragment(restoredEntities).text ?? '';
}
