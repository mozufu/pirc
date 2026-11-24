import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/xy_model.dart';
import 'package:pirc_render/src/mermaid/xy_parser.dart';

const _fixturePath = '../../fixtures/mobile-parity/mermaid-xy.json';

String _unfence(String source) => source
    .replaceFirst(RegExp(r'^~~~mermaid\s*'), '')
    .replaceFirst(RegExp(r'^```mermaid\s*'), '')
    .replaceFirst(RegExp(r'\s*(?:~~~|```)\s*$'), '');

void main() {
  group('native Mermaid XY chart parser', () {
    test(
      'parses every supported real-browser case and retains source semantics',
      () {
        final fixture =
            jsonDecode(File(_fixturePath).readAsStringSync()) as Map;
        final cases = fixture['cases'] as List;
        for (final item in cases.cast<Map>()) {
          final id = item['id'] as String;
          final source = _unfence(item['source'] as String);
          if (item['expectedStatus'] == 'error') {
            expect(
              () => parseNativeMermaidXYChart(source),
              throwsFormatException,
              reason: id,
            );
            continue;
          }
          final diagram = parseNativeMermaidXYChart(source);
          expect(diagram.series, isNotEmpty, reason: id);
          expect(diagram.semanticsLabel, contains('XY chart'), reason: id);
          if (id.startsWith('xy-horizontal')) {
            expect(diagram.config.orientation, Axis.horizontal, reason: id);
          }
        }
      },
    );

    test('maps category data, point labels, and inferred domains', () {
      final diagram = parseNativeMermaidXYChart('''
xychart-beta
title "Weekly, signals"
x-axis "Day" [Mon, Tue, Wed, Thu]
y-axis "Index" 0 --> 100
bar "Visits" [20 "twenty", 35, 53, 72]
line "Retention" [15 "low", 49 "rising", 57 "peak", 84 "high"]
''');
      expect(diagram.title, 'Weekly, signals');
      expect(diagram.xAxis.type, NativeMermaidXYAxisType.band);
      expect(diagram.xAxis.categories, ['Mon', 'Tue', 'Wed', 'Thu']);
      expect(diagram.yAxis.min, 0);
      expect(diagram.yAxis.max, 100);
      expect(diagram.series.first.values, [20, 35, 53, 72]);
      expect(diagram.series.first.pointLabels, isEmpty);
      expect(diagram.series.last.pointLabels, [
        'low',
        'rising',
        'peak',
        'high',
      ]);
    });

    test(
      'derives numeric sample coordinates and value extent when axes omit ranges',
      () {
        final diagram = parseNativeMermaidXYChart('''
xychart-beta
title "Default domains"
line [4, 8, 2, 12, 9]
''');
        expect(diagram.xAxis.type, NativeMermaidXYAxisType.linear);
        expect(diagram.xAxis.min, 1);
        expect(diagram.xAxis.max, 5);
        expect(diagram.yAxis.min, 2);
        expect(diagram.yAxis.max, 12);
      },
    );

    test('keeps Mermaid dimensions and axis rotation from init directives', () {
      final diagram = parseNativeMermaidXYChart('''
%%{init: {"xyChart": {"width": 520, "height": 340, "xAxis": {"labelRotation": -35}}}}%%
xychart-beta
x-axis "Elapsed time" 0 --> 8
y-axis "Requests per minute" 0 --> 80
bar "Requests" [12, 22, 31]
''');
      expect(diagram.config.width, 520);
      expect(diagram.config.height, 340);
      expect(diagram.config.xAxis.labelRotation, -35);
    });

    test(
      'rejects malformed data, unsupported statements, and missing plots',
      () {
        for (final source in [
          'xychart-beta\nbar "bad" [5, nope, 9]',
          'xychart-beta\nline [1, 2]\nclick A href "x"',
          'xychart-beta\nx-axis [A, B]\nbar [1]',
          'xychart-beta\nx-axis 0 --> 1\nbar [1, 2,]',
          'xychart-beta\ny-axis "Value" 0 --> NaN\nbar [1]',
          'xychart-beta\ntitle "No plot"',
        ]) {
          expect(
            () => parseNativeMermaidXYChart(source),
            throwsFormatException,
            reason: source,
          );
        }
      },
    );
  });
}
