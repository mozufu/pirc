import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/flowchart.dart';

const _fixturePath =
    '../../fixtures/mobile-parity/mermaid-flowchart-styles.json';
const _expectedPath =
    '../../fixtures/mobile-parity/mermaid-flowchart-styles-expected.json';

Map<String, dynamic> _object(Object? value) =>
    (value as Map).cast<String, dynamic>();

List<Map<String, dynamic>> _objects(Object? value) =>
    (value as List).map(_object).toList();

String _unfence(String source) => source
    .replaceFirst(RegExp(r'^```mermaid\s*'), '')
    .replaceFirst(RegExp(r'\s*```$'), '');

int _rgb(Object? value) {
  final source = value as String;
  final match = RegExp(
    r'^rgb\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)$',
  ).firstMatch(source);
  if (match == null) throw FormatException('Unexpected browser color: $source');
  return (int.parse(match[1]!) << 16) |
      (int.parse(match[2]!) << 8) |
      int.parse(match[3]!);
}

int _color(Color value) => value.toARGB32() & 0x00ffffff;

double _cssPx(Object? value) =>
    double.parse((value as String).replaceFirst(RegExp(r'px$'), ''));

void main() {
  final fixture = _object(jsonDecode(File(_fixturePath).readAsStringSync()));
  final expected = _object(jsonDecode(File(_expectedPath).readAsStringSync()));
  for (final item in _objects(fixture['cases'])) {
    final id = item['id'] as String;
    final graph = parseNativeMermaidFlowchart(
      _unfence(item['source'] as String),
    );
    for (final colorScheme in ['light', 'dark']) {
      test('$id resolves class styles like browser $colorScheme output', () {
        final parsed = _object(
          _object(_object(expected['parsedCases'])[id])[colorScheme],
        );
        final apiData = _object(_object(parsed['api'])['data']);
        final webNodes = _objects(apiData['nodes']);
        final themeData = _object(_object(expected['themes'])[colorScheme]);
        final widthRow = _objects(
          themeData['widths'],
        ).singleWhere((row) => row['width'] == 390);
        final scaleRow = _objects(
          widthRow['scales'],
        ).singleWhere((row) => (row['textScale'] as num) == 1);
        final webCase = _objects(
          scaleRow['cases'],
        ).singleWhere((row) => row['id'] == id);
        final svg = _object(webCase['svg']);
        final geometryId = svg['geometryId'] as String;
        final shared = _object(
          _object(_object(expected['geometryCatalog'])[geometryId])['shared'],
        );
        final shapes = _objects(shared['shapes']).where((shape) {
          final path = (shape['groupPath'] as List).cast<String>();
          return path.contains('nodes') &&
              shape['class'] == 'basic label-container';
        }).toList();
        final labels = _objects(shared['foreignTexts']);

        expect(webNodes, hasLength(graph.nodes.length));
        expect(shapes, hasLength(graph.nodes.length));
        expect(labels, hasLength(graph.nodes.length));
        for (var index = 0; index < graph.nodes.length; index++) {
          final node = graph.nodes[index];
          final browserNode = webNodes.singleWhere(
            (row) => row['id'] == node.id,
          );
          final shapeStyle = _object(shapes[index]['computed']);
          final label = labels.singleWhere((row) => row['text'] == node.label);
          final labelStyle = _object(label['computed']);
          final nodeGroup = (shapes[index]['groupPath'] as List)
              .cast<String>()
              .last;

          expect(browserNode['label'], node.label, reason: '$id/${node.id}');
          expect(
            nodeGroup,
            'node ${(browserNode['cssClasses'] as String).trim()}',
            reason: '$id/${node.id} class assignment',
          );
          expect(node.style.fill, isNotNull);
          expect(node.style.stroke, isNotNull);
          expect(node.style.color, isNotNull);
          expect(node.style.strokeWidth, isNotNull);
          expect(_color(node.style.fill!), _rgb(shapeStyle['fill']));
          expect(_color(node.style.stroke!), _rgb(shapeStyle['stroke']));
          expect(node.style.strokeWidth, _cssPx(shapeStyle['strokeWidth']));
          expect(_color(node.style.color!), _rgb(labelStyle['color']));
        }
      });
    }
  }
}
