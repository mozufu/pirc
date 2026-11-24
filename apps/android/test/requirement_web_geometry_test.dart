import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:pirc_render/src/mermaid/requirement_parser.dart';
import 'package:pirc_render/src/mermaid/requirement_rendering.dart';
import '../tool/parity/capture_fonts.dart' show loadParityFonts;

void main() {
  testWidgets(
    'requirement content and styles match Chrome; geometry differences recorded',
    (t) async {
      await t.runAsync(loadParityFonts);
      final fixture =
          jsonDecode(
                File(
                  '../../fixtures/mobile-parity/mermaid-requirement-web-expected.json',
                ).readAsStringSync(),
              )
              as Map;
      Color rgb(String value) {
        final parts = RegExp(
          r'\d+',
        ).allMatches(value).map((m) => int.parse(m[0]!)).toList();
        return Color.fromARGB(255, parts[0], parts[1], parts[2]);
      }

      final reports = <Map<String, dynamic>>[];
      for (final group in (fixture['captures'] as Map).entries) {
        for (final raw in group.value as List) {
          final actual = layoutNativeMermaidRequirement(
            parseNativeMermaidRequirement(raw['sourceExpected']),
            fontFamily: 'Arial',
            dark: group.key.toString().startsWith('dark'),
          );
          final svg = raw['svg'] as Map;
          final differences = <Map<String, dynamic>>[];
          for (final web in svg['nodes'] as List) {
            final id = web['graphNode']['name'];
            final node = actual.nodes.singleWhere((n) => n.node.name == id);
            expect(
              node.fields.map((f) => f.label.text).toList(),
              (web['fields'] as List).map((f) => f['text']).toList(),
              reason: '${raw['id']} $id fields',
            );
            final paths = web['outerShape']['paintedPaths'] as List;
            final fill = paths.firstWhere(
              (p) => p['computed']['fill'] != 'none',
            );
            final border = paths.firstWhere(
              (p) => p['computed']['stroke'] != 'none',
            );
            expect(
              node.style.fill,
              rgb(fill['computed']['fill']),
              reason: '$id fill',
            );
            expect(
              node.style.stroke,
              rgb(border['computed']['stroke']),
              reason: '$id outline',
            );
            expect(
              node.style.ink,
              rgb(web['fields'][0]['content']['computed']['color']),
              reason: '$id text',
            );
            final position = RegExp(
              r'translate\(([-\d.]+),\s*([-\d.]+)\)',
            ).firstMatch(web['transform']);
            expect(position, isNotNull);
            final box = web['bbox'] as Map;
            final wanted = [
              double.parse(position![1]!) + (box['x'] as num),
              double.parse(position[2]!) + (box['y'] as num),
              (box['width'] as num).toDouble(),
              (box['height'] as num).toDouble(),
            ];
            final got = [
              node.bounds.left,
              node.bounds.top,
              node.bounds.width,
              node.bounds.height,
            ];
            for (var i = 0; i < 4; i++) {
              final delta = (got[i] - wanted[i]).abs();
              if (delta > 4) {
                differences.add({
                  'node': id,
                  'field': ['x', 'y', 'width', 'height'][i],
                  'delta': delta,
                  'web': wanted[i],
                  'native': got[i],
                });
              }
            }
            for (var i = 0; i < node.fields.length; i++) {
              final webField = (web['fields'] as List)[i];
              final offset = RegExp(
                r'translate\(([-\d.]+),\s*([-\d.]+)\)',
              ).firstMatch(webField['transform'])!;
              final relativeY = double.parse(offset[2]!) - (box['y'] as num);
              final nativeY =
                  node.fieldBounds(node.fields[i]).top - node.bounds.top;
              if ((relativeY - nativeY).abs() > 2) {
                differences.add({
                  'node': id,
                  'field': 'label-$i-y',
                  'delta': (relativeY - nativeY).abs(),
                });
              }
            }
          }
          for (var i = 0; i < actual.nodes.length; i++) {
            for (var j = i + 1; j < actual.nodes.length; j++) {
              expect(
                actual.nodes[i].bounds.overlaps(actual.nodes[j].bounds),
                isFalse,
                reason: '${raw['id']} overlapping nodes',
              );
            }
          }
          final expected = (svg['attrs']['viewBox'] as String)
              .split(' ')
              .map(double.parse)
              .toList();
          reports.add({
            'id': raw['id'],
            'configuration': group.key,
            'nativeSize': [actual.size.width, actual.size.height],
            'webSize': expected.skip(2).toList(),
            'differences': differences,
          });
        }
      }
      Directory('build/parity').createSync(recursive: true);
      File('build/parity/requirement-geometry-report.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({'captures': reports}),
      );
      expect(reports, hasLength(8));
    },
  );
}
