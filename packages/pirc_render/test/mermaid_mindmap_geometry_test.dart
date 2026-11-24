import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/mindmap_parser.dart';
import 'package:pirc_render/src/mermaid/mindmap_rendering.dart';

void main() {
  test('source-sized shapes retain pinned local geometry', () {
    final fixture =
        jsonDecode(
              File(
                '../../fixtures/mobile-parity/mermaid-mindmap.json',
              ).readAsStringSync(),
            )
            as Map;
    final expected =
        jsonDecode(
              File(
                '../../fixtures/mobile-parity/mermaid-mindmap-expected.json',
              ).readAsStringSync(),
            )
            as Map;
    final input =
        (fixture['cases'] as List).firstWhere(
              (item) => item['id'] == 'mindmap-six-shapes',
            )
            as Map;
    final source = (input['source'] as String)
        .replaceFirst('~~~mermaid\n', '')
        .replaceFirst('\n~~~', '');
    final diagram = parseNativeMermaidMindmap(source);
    final nodes =
        expected['geometryCatalog']['mindmap-six-shapes-light']['shared']['nodes']
            as List;
    for (var i = 0; i < diagram.nodes.length; i++) {
      final row = nodes[i] as Map;
      final labelBox =
          ((row['htmlLabels'] as List).firstWhere((item) => item['tag'] == 'p')
                  as Map)['relativeBox']
              as Map;
      final size = Size(
        (labelBox['width'] as num).toDouble(),
        (labelBox['height'] as num).toDouble(),
      );
      final bounds = nativeMindmapNodeShape(
        diagram.nodes[i].shape,
        size,
      ).bounds;
      final box = row['userBBox'] as Map;
      for (final field in [
        ('x', bounds.left),
        ('y', bounds.top),
        ('width', bounds.width),
        ('height', bounds.height),
      ]) {
        expect(
          field.$2,
          closeTo((box[field.$1] as num).toDouble(), .02),
          reason: '${row['label']} ${field.$1}',
        );
      }
    }
  });
}
