import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/quadrant_parser.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/mermaid-quadrant-xy.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final cases = fixture['cases'] as List<dynamic>;
  final labeledSource =
      (cases.first as Map<String, dynamic>)['source'] as String;

  group('parseNativeMermaidQuadrant', () {
    test(
      'parses pinned labels, class styles, inline styles, and init sizes',
      () {
        final chart = parseNativeMermaidQuadrant(labeledSource);

        expect(chart.title, 'Product priorities');
        expect(
          (chart.xAxisLeftText, chart.xAxisRightText),
          ('Low reach', 'High reach'),
        );
        expect(
          (chart.yAxisBottomText, chart.yAxisTopText),
          ('Low effort', 'High effort'),
        );
        expect(chart.quadrants, ['Scale', 'Maintain', 'Defer', 'Explore']);
        expect(chart.config.chartWidth, 470);
        expect(chart.config.chartHeight, 340);
        expect(chart.config.pointRadius, 7);
        expect(chart.points, hasLength(5));

        final market = chart.points.first;
        expect(market.label, 'Market, east');
        expect(market.className, 'featured');
        expect((market.x, market.y), (.82, .82));
        expect(chart.classes['featured']?.color, '#123456');
        expect(chart.classes['featured']?.radius, 8);

        final inline = chart.points.last;
        expect(inline.style.radius, 9);
        expect(inline.style.color, '#c1121f');
        expect(inline.style.strokeColor, '#111827');
        expect(inline.style.strokeWidth, '3px');
      },
    );

    test('supports ordinary point labels and an unlabelled chart', () {
      final chart = parseNativeMermaidQuadrant('''
quadrantChart
"Point, one": [0, 1]
''');
      expect(chart.points.single.label, 'Point, one');
      expect(chart.points.single.x, 0);
      expect(chart.points.single.y, 1);
      expect(chart.quadrants, ['', '', '', '']);
      expect(chart.title, isNull);
    });

    test('preserves Mermaid arrow text for a single-ended axis label', () {
      final chart = parseNativeMermaidQuadrant('''
quadrantChart
x-axis Low -->
y-axis Efficient -->
''');
      expect(chart.xAxisLeftText, 'Low ⟶ ');
      expect(chart.yAxisBottomText, 'Efficient ⟶ ');
      expect(chart.semanticsLabel, contains('X axis: Low ⟶ '));
    });

    test(
      'rejects coordinates outside Mermaid lexer range and unsupported styles',
      () {
        expect(
          () => parseNativeMermaidQuadrant('quadrantChart\nOut: [1.1, 0.5]'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('Lexical error'),
            ),
          ),
        );
        expect(
          () => parseNativeMermaidQuadrant(
            'quadrantChart\nA: [0.2, 0.7] opacity: 0.5',
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('Unsupported quadrant style'),
            ),
          ),
        );
      },
    );

    test('rejects unknown init options rather than losing them', () {
      expect(
        () => parseNativeMermaidQuadrant('''
%%{init: {"quadrantChart":{"chartWidth":470,"unknown":1}}}%%
quadrantChart
'''),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Unsupported quadrantChart option'),
          ),
        ),
      );
    });
  });
}
