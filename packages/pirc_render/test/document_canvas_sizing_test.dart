import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_canvas_sizing.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../apps/android/tool/parity/fixtures/document-canvas-sizing-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  final seen = <String>{};
  for (final row in fixture['cases'] as List) {
    final mode = row['mode'] as String;
    if (!seen.add(mode)) continue;
    test('Canvas sizing agrees with Chromium checkpoints: $mode', () {
      for (final checkpoint in row['result']['checkpoints'] as List) {
        final state = checkpoint['synchronous'];
        final actual = nativeCanvasCssUsedSize(
          cssWidth: state['axes']['width'],
          cssHeight: state['axes']['height'],
          parentWidth: (row['parentSize']['width'] as num).toDouble(),
          parentHeight: (row['parentSize']['height'] as num).toDouble(),
          intrinsicWidth: (state['bitmap']['width'] as num).toDouble(),
          intrinsicHeight: (state['bitmap']['height'] as num).toDouble(),
        );
        expect(actual, isNotNull);
        double expected(String key) => double.parse(
          (state['style'][key] as String).replaceFirst('px', ''),
        );
        // Chromium quantizes layout to 1/64 px; Flutter uses unrounded doubles.
        final tolerance = mode == 'fractional_ratio' ? .02 : 0.0;
        expect(
          actual!.width,
          closeTo(expected('width'), tolerance),
          reason: checkpoint['name'],
        );
        expect(
          actual.height,
          closeTo(expected('height'), tolerance),
          reason: checkpoint['name'],
        );
      }
    });
  }
}
