import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/pie.dart';

String rgb(Color c) =>
    'rgb(${(c.r * 255).round()}, ${(c.g * 255).round()}, ${(c.b * 255).round()})';
void main() {
  for (final dark in [false, true]) {
    final data =
        jsonDecode(
              File(
                '../../fixtures/mobile-parity/mermaid-${dark ? 'dark' : 'light'}-expected.json',
              ).readAsStringSync(),
            )
            as Map;
    final cases = ((data['widths'] as List).first as Map)['cases'] as List;
    for (final row in cases.where(
      (dynamic c) => (c['id'] as String).startsWith('pie-'),
    )) {
      test('pie actual pinned web semantics ${row['id']} dark=$dark', () {
        if (row['status'] == 'error') {
          expect(
            () => parseNativeMermaidPie(row['source'] as String),
            throwsFormatException,
          );
          return;
        }
        final diagram = parseNativeMermaidPie(row['source'] as String);
        final painter = MermaidPiePainter(diagram, dark, 'Arial');
        final svg = row['svg'] as Map;
        final texts = svg['texts'] as List;
        final actual = [
          ...diagram.slices.map(
            (e) => '${(e.value / diagram.total * 100).round()}%',
          ),
          diagram.title,
          ...diagram.sections.entries.map(diagram.legend),
        ];
        expect(actual, texts.map((dynamic t) => t['text']).toList());
        for (final text in texts) {
          expect(
            rgb(
              text['class'] == 'slice'
                  ? painter.sliceTextColor
                  : painter.legendColor,
            ),
            text['computedFill'],
          );
        }
        final expectedFills = (svg['shapes'] as List)
            .where((dynamic s) => s['class'] == 'pieCircle')
            .map((dynamic s) => s['computedFill']);
        expect(
          diagram.slices.map(
            (e) => rgb(
              painter.palette[diagram.sections.keys.toList().indexOf(e.key) %
                  12],
            ),
          ),
          expectedFills,
        );
        // Non-text geometry is independent of host SF/Arial font availability.
        expect(painter.size.height, 450);
        expect((svg['viewBox'] as String).split(' ').last, '450');
      });
    }
  }
}
