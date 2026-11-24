import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/er_diagram.dart';
import 'package:pirc_render/src/mermaid/er_rendering.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/mermaid-er.json',
            ).readAsStringSync(),
          )
          as Map;
  final expected =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/mermaid-er-expected.json',
            ).readAsStringSync(),
          )
          as Map;
  final references = (expected['themes']['light']['widths'][0]['cases'] as List)
      .cast<Map>();
  for (final entry in (fixture['cases'] as List).cast<Map>()) {
    final reference = references.firstWhere((r) => r['id'] == entry['id']);
    if (reference['status'] != 'ok' ||
        entry['id'] == 'er-direction-lr-and-roles') {
      continue;
    }
    test('ER natural height matches pinned SVG: ${entry['id']}', () {
      final source = (entry['source'] as String)
          .replaceFirst('```mermaid\n', '')
          .replaceFirst(RegExp(r'\n```$'), '');
      final data = parseNativeMermaidErDiagram(source);
      final layout = layoutNativeMermaidErDiagram(data);
      final height = double.parse(
        (reference['svg']['viewBox'] as String).split(' ').last,
      );
      expect(layout.size.height, closeTo(height, .001));
      for (final entity in layout.entities) {
        expect(entity.bounds.width.isFinite, isTrue);
        expect(entity.bounds.height, greaterThan(0));
        for (final other in layout.entities) {
          if (entity == other) continue;
          expect(entity.bounds.overlaps(other.bounds), isFalse);
        }
      }
    });
  }
}
