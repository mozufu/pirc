// Run verify_document_canvas_browser.mjs first. The exact shared scripts are
// executed by Chrome and the generated JS asset, then painted by Flutter here.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_canvas.dart';

void main() {
  final reportFile = File(
    'build/parity-acceptance/document-canvas-20261015/native-snapshots.json',
  );
  final source =
      jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
  final cases = source['cases'] as List;
  final results = <Map<String, Object?>>[];
  for (final raw in cases) {
    final item = raw as Map<String, dynamic>;
    testWidgets('Chrome Canvas oracle: ${item['id']}', (t) async {
      final snapshot = NativeDocumentCanvasSnapshot.fromJson(
        Map<String, Object?>.from(item['canvas'] as Map),
      );
      final browser = item['browser'] as Map<String, dynamic>;
      final actual = await t.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        NativeDocumentCanvasPainter(
          snapshot,
        ).paint(canvas, Size(snapshot.width, snapshot.height));
        final picture = recorder.endRecording();
        final image = await picture.toImage(
          snapshot.width.toInt(),
          snapshot.height.toInt(),
        );
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          ))!;
          return data.buffer.asUint8List();
        } finally {
          image.dispose();
          picture.dispose();
        }
      });
      expect(actual, isNotNull);
      final rows = <Map<String, Object?>>[];
      final textCase = browser.containsKey('textInkBounds');
      for (final point in browser['samples'] as List) {
        final x = point['x'] as int, y = point['y'] as int;
        final offset = (y * snapshot.width.toInt() + x) * 4;
        final rgba = actual!.sublist(offset, offset + 4);
        final expected = List<int>.from(point['rgba'] as List);
        rows.add({'x': x, 'y': y, 'expected': expected, 'actual': rgba});
        if (!textCase) {
          for (var channel = 0; channel < 4; channel++) {
            expect(
              (rgba[channel] - expected[channel]).abs(),
              lessThanOrEqualTo(6),
              reason:
                  '${item['id']} ($x,$y) channel $channel: $rgba vs $expected',
            );
          }
        }
      }
      if (textCase) {
        var ink = 0;
        for (var i = 3; i < actual!.length; i += 4) {
          if (actual[i] > 0) ink++;
        }
        expect(
          ink,
          greaterThan(0),
          reason: 'Native text must paint; font glyph parity is excluded.',
        );
      }
      results.add({
        'id': item['id'],
        'samples': rows,
        'textGlyphComparison': textCase
            ? 'excluded; native ink verified'
            : 'not applicable',
      });
      File(
        'build/parity-acceptance/document-canvas-20261015/flutter-oracle.json',
      ).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'browser': source['browserOracle'],
          'runtime': source['runtime'],
          'fixture': source['fixture'],
          'rgbaTolerance': 6,
          'cases': results,
        }),
      );
    });
  }
}
