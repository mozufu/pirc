import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/mindmap_cose.dart';

void main() {
  group('layoutNativeMindmapCoseBilkent', () {
    test('matches the pinned Mermaid CoSE tree centers and orientation', () {
      final fixture = _readMermaidExpected();
      final api =
          fixture['parsedCases']['mindmap-basic-tree']['light']['api']
              as Map<String, dynamic>;
      final geometry =
          fixture['geometryCatalog']['mindmap-basic-tree-light']['shared']['nodes']
              as List<dynamic>;
      final byDomId = <String, Map<String, dynamic>>{
        for (final row in geometry.cast<Map<String, dynamic>>())
          row['id'] as String: row,
      };
      final nodes = (api['nodes'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final nodeIndex = <String, int>{
        for (var i = 0; i < nodes.length; i++) nodes[i]['id'] as String: i,
      };
      final sizes = nodes.map((node) {
        final box =
            byDomId[node['domId'] as String]!['userBBox']
                as Map<String, dynamic>;
        return Size(
          (box['width'] as num).toDouble(),
          (box['height'] as num).toDouble(),
        );
      }).toList();
      final edges = (api['edges'] as List<dynamic>).map((raw) {
        final edge = raw as Map<String, dynamic>;
        return (
          source: nodeIndex[edge['start'] as String]!,
          target: nodeIndex[edge['end'] as String]!,
        );
      }).toList();
      final expected = geometry
          .cast<Map<String, dynamic>>()
          .map((row) => _parseTranslate(row['transform'] as String))
          .toList();

      final actual = layoutNativeMindmapCoseBilkent(
        nodeSizes: sizes,
        edges: edges,
      );

      expect(actual, hasLength(expected.length));
      for (var i = 0; i < actual.length; i++) {
        expect(
          (actual[i] - expected[i]).distance,
          lessThan(0.01),
          reason:
              'node ${nodes[i]['id']} changed its CoSE position/orientation',
        );
      }
    });

    test(
      'matches every captured tree and viewport-specific source geometry',
      () {
        final fixture = _readMermaidExpected();
        final catalog = fixture['geometryCatalog'] as Map<String, dynamic>;
        var maximum = 0.0;
        for (final entry in catalog.entries) {
          final row = entry.value as Map<String, dynamic>;
          final api =
              fixture['parsedCases'][row['caseId']][row['theme']]['api']
                  as Map<String, dynamic>;
          final geometry = row['shared']['nodes'] as List;
          final byId = {for (final node in geometry) node['id']: node};
          final nodes = api['nodes'] as List;
          final index = {
            for (var i = 0; i < nodes.length; i++) nodes[i]['id']: i,
          };
          final actual = layoutNativeMindmapCoseBilkent(
            nodeSizes: [
              for (final node in nodes)
                Size(
                  (byId[node['domId']]['userBBox']['width'] as num).toDouble(),
                  (byId[node['domId']]['userBBox']['height'] as num).toDouble(),
                ),
            ],
            edges: [
              for (final edge in api['edges'] as List)
                (source: index[edge['start']]!, target: index[edge['end']]!),
            ],
          );
          for (var i = 0; i < nodes.length; i++) {
            final expected = _parseTranslate(
              byId[nodes[i]['domId']]['transform'] as String,
            );
            final delta = (actual[i] - expected).distance;
            if (delta > maximum) maximum = delta;
          }
        }
        // This measures algorithm equality with source node sizes, separately
        // from the native host fonts and actual widget layout capture.
        expect(maximum, lessThan(.01));
      },
    );

    test('is deterministic for the same ordered tree input', () {
      final sizes = <Size>[
        const Size(72, 72),
        const Size(96.21875, 29.5),
        const Size(89.296875, 29.5),
        const Size(75.8125, 29.5),
        const Size(70.234375, 29.5),
        const Size(99.46875, 29.5),
        const Size(82.90625, 29.5),
        const Size(66.78125, 29.5),
      ];
      final edges = <({int source, int target})>[
        (source: 0, target: 1),
        (source: 1, target: 2),
        (source: 1, target: 3),
        (source: 0, target: 4),
        (source: 4, target: 5),
        (source: 4, target: 6),
        (source: 0, target: 7),
      ];

      final first = layoutNativeMindmapCoseBilkent(
        nodeSizes: sizes,
        edges: edges,
      );
      final second = layoutNativeMindmapCoseBilkent(
        nodeSizes: sizes,
        edges: edges,
      );

      expect(second, first);
    });

    test('rejects non-tree and invalid-size input explicitly', () {
      expect(
        () => layoutNativeMindmapCoseBilkent(
          nodeSizes: const <Size>[Size(20, 20), Size(20, 20), Size(20, 20)],
          edges: const <({int source, int target})>[
            (source: 0, target: 1),
            (source: 1, target: 2),
            (source: 2, target: 0),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => layoutNativeMindmapCoseBilkent(
          nodeSizes: const <Size>[Size(20, 20), Size(20, 20)],
          edges: const <({int source, int target})>[],
        ),
        throwsArgumentError,
      );
      expect(
        () => layoutNativeMindmapCoseBilkent(
          nodeSizes: const <Size>[Size(0, 20)],
          edges: const <({int source, int target})>[],
        ),
        throwsArgumentError,
      );
    });
  });
}

Map<String, dynamic> _readMermaidExpected() {
  final file = File(
    '../../fixtures/mobile-parity/mermaid-mindmap-expected.json',
  );
  if (!file.existsSync()) {
    throw StateError(
      'Missing pinned Mermaid mindmap expected fixture: ${file.path}',
    );
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

Offset _parseTranslate(String value) {
  final match = RegExp(
    r'^translate\(\s*([+-]?[0-9.eE-]+)\s*,\s*([+-]?[0-9.eE-]+)\s*\)$',
  ).firstMatch(value);
  if (match == null) {
    throw FormatException('Invalid node transform: $value');
  }
  return Offset(double.parse(match.group(1)!), double.parse(match.group(2)!));
}
