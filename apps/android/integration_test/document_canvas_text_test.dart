import 'dart:ui' as ui;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/document_canvas.dart';

class _ProbeGateway extends Gateway {
  int? fontBytes;
  int? heapBytes;
  int? fontCount;

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    dynamic result;
    try {
      result = await super.call(method, args);
    } catch (error) {
      if (method == 'documentScriptCanvasTextResources') {
        debugPrintSynchronously('PIRC_NATIVE_CANVAS_FONT_ERROR $error');
      }
      rethrow;
    }
    if (method == 'documentScriptCanvasTextResources') {
      fontBytes = obj(result)['fontBytes'] as int?;
    } else if (method == 'documentScriptEvaluate' &&
        (args['source'] as String).startsWith('__pircInitializeCanvasText(')) {
      final prepared = obj(jsonDecode(obj(result)['value'] as String));
      heapBytes = prepared['heapBytes'] as int?;
      fontCount = prepared['fontCount'] as int?;
    }
    return result;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Canvas advances and ink use matched native Skia fonts synchronously', (
    tester,
  ) async {
    final rows = [
      {'font': '16px Arial', 'family': 'Arial', 'text': 'Hello AV fi'},
      {
        'font': 'bold 16px Arial',
        'family': 'Arial',
        'text': 'Hello AV fi',
        'bold': true,
      },
      {
        'font': 'italic 16px Arial',
        'family': 'Arial',
        'text': 'Hello AV fi',
        'italic': true,
      },
      {
        'font': 'italic bold 16px Arial',
        'family': 'Arial',
        'text': 'Hello AV fi',
        'bold': true,
        'italic': true,
      },
      {'font': '16px serif', 'family': 'serif', 'text': 'Hello AV fi'},
      {'font': '16px monospace', 'family': 'monospace', 'text': 'Hello AV fi'},
      {'font': '16px Arial', 'family': 'Arial', 'text': 'Hello  '},
      {'font': '16px Arial', 'family': 'Arial', 'text': '中文繁體測試'},
      {
        'font': 'bold 16px Arial',
        'family': 'Arial',
        'text': '中文繁體測試',
        'bold': true,
      },
      {
        'font': 'italic 16px Arial',
        'family': 'Arial',
        'text': '中文繁體測試',
        'italic': true,
      },
      {'font': '16px serif', 'family': 'serif', 'text': '中文繁體測試'},
      {'font': '16px monospace', 'family': 'monospace', 'text': '中文繁體測試'},
      {'font': '16px Arial', 'family': 'Arial', 'text': '\tHello\n世界'},
      {'font': '16px Arial', 'family': 'Arial', 'text': ''},
      {'font': '16px Arial', 'family': 'Arial', 'text': 'office A\u0301 To'},
      {'font': '16px Arial', 'family': 'Arial', 'text': '中文🙂'},
      {
        'font': '16.5px Arial',
        'family': 'Arial',
        'text': 'AV To',
        'size': 16.5,
      },
      {
        'font': '16px Arial',
        'family': 'Arial',
        'text': 'AV fi',
        'direction': 'rtl',
      },
      {
        'font': '16px Arial',
        'family': 'Arial',
        'text': 'AV',
        'baseline': 'top',
      },
      {
        'font': '16px Arial',
        'family': 'Arial',
        'text': 'AV',
        'baseline': 'middle',
      },
      {
        'font': '16px Arial',
        'family': 'Arial',
        'text': 'AV',
        'baseline': 'bottom',
      },
    ];
    const width = 512, lineHeight = 48, rasterScale = 4;
    final height = rows.length * lineHeight + 64;
    final source =
        '''<!doctype html><html><body><canvas id="c" width="$width" height="$height"></canvas><pre id="probe">WAIT</pre><script>
var rows=${jsonEncode(rows)},ctx=document.getElementById('c').getContext('2d'),results=[],started=Date.now();
for(var i=0;i<rows.length;i++){var row=rows[i];try{
ctx.font=row.font;ctx.direction=row.direction||'ltr';ctx.textAlign='left';ctx.textBaseline=row.baseline||'alphabetic';
var before=ctx.font,metrics=ctx.measureText(row.text);
results.push({font:ctx.font,width:metrics.width,type:metrics instanceof TextMetrics,unchanged:ctx.font===before,
left:metrics.actualBoundingBoxLeft,right:metrics.actualBoundingBoxRight,ascent:metrics.actualBoundingBoxAscent,descent:metrics.actualBoundingBoxDescent});
ctx.fillText(row.text,40,i*$lineHeight+32,undefined);
}catch(e){results.push({error:e.name+': '+e.message})}}
document.getElementById('probe').textContent=JSON.stringify({results:results,measureMs:Date.now()-started,heapBytes:__pircInkProbeEngine?__pircInkProbeEngine.heapBytes:null});
ctx.font='16px Arial';ctx.fillStyle='#ff0000';ctx.fillRect(0,${rows.length * lineHeight},ctx.measureText('中文繁體測試').width,8);
</script></body></html>''';
    final gateway = _ProbeGateway();
    // Capture the private engine only in this synthetic test document. The
    // shipped runtime hides it; this measures live WASM growth after ink reads.
    final scripts = NativeDocumentScripts(
      gateway,
      loadRuntime: () async =>
          'globalThis.__pircInkProbeEngine=globalThis.__pircNativeCanvasText;\n${await rootBundle.loadString('assets/document-script-runtime.js')}',
    );
    final startup = Stopwatch()..start();
    try {
      await scripts.start(
        source: source,
        url: 'https://example.test/native-canvas-text',
      );
      startup.stop();
      debugPrintSynchronously(
        'PIRC_NATIVE_CANVAS_TEXT_RESOURCES ${jsonEncode({'startupMs': startup.elapsedMilliseconds, 'fontBytes': gateway.fontBytes, 'heapBytes': gateway.heapBytes, 'fontCount': gateway.fontCount})}',
      );
      expect(scripts.ready, isTrue, reason: '${scripts.diagnostics}');
      expect(scripts.diagnostics, isEmpty);
      final raw = html
          .parse(scripts.content!.text)
          .getElementById('probe')!
          .text;
      debugPrintSynchronously('PIRC_NATIVE_CANVAS_TEXT $raw');
      final probe = jsonDecode(raw) as Map;
      debugPrintSynchronously(
        'PIRC_NATIVE_CANVAS_INK_RESOURCES ${jsonEncode({'measureMs': probe['measureMs'], 'heapBytesAfterInk': probe['heapBytes']})}',
      );
      final actual = probe['results'] as List;
      expect(actual, hasLength(rows.length));
      for (var i = 0; i < rows.length; i++) {
        final row = rows[i], entry = actual[i] as Map;
        expect(
          entry,
          isNot(contains('error')),
          reason: 'row $i ${scripts.diagnostics}',
        );
        final text = (row['text'] as String).replaceAll(
          RegExp(r'[\t\n\f\r]'),
          ' ',
        );
        final painter = TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              fontFamily: row['family'] as String,
              fontSize: (row['size'] as num?)?.toDouble() ?? 16,
              fontWeight: row['bold'] == true
                  ? FontWeight.w700
                  : FontWeight.w400,
              fontStyle: row['italic'] == true
                  ? FontStyle.italic
                  : FontStyle.normal,
              height: 1,
            ),
          ),
          textDirection: row['direction'] == 'rtl'
              ? TextDirection.rtl
              : TextDirection.ltr,
          textScaler: TextScaler.noScaling,
          maxLines: 1,
        )..layout();
        debugPrintSynchronously(
          'PIRC_NATIVE_CANVAS_TEXT_COMPARE ${jsonEncode({'row': i, 'runtime': entry['width'], 'flutter': painter.width})}',
        );
        expect(
          entry['width'],
          closeTo(painter.width, .02),
          reason: 'Same actual font and style for row $i',
        );
        expect(entry['type'], true);
        expect(entry['unchanged'], true);
        painter.dispose();
      }
      final snapshot = scripts.canvases.values.single;
      expect(
        snapshot.commands.where((command) => command.op == 'fillText'),
        hasLength(rows.length),
      );
      expect(snapshot.commands.last.op, 'fillRect');
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(rasterScale.toDouble());
      NativeDocumentCanvasPainter(
        snapshot,
      ).paint(canvas, Size(snapshot.width, snapshot.height));
      final picture = recorder.endRecording();
      final image = await tester.runAsync(
        () => picture.toImage(width * rasterScale, height * rasterScale),
      );
      try {
        final data = (await tester.runAsync(
          () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
        ))!;
        final bytes = data.buffer.asUint8List();
        List<int> pixel(int x, int y) => bytes.sublist(
          (y * width * rasterScale + x) * 4,
          (y * width * rasterScale + x) * 4 + 4,
        );
        expect(
          pixel(94 * rasterScale, (rows.length * lineHeight + 4) * rasterScale),
          [255, 0, 0, 255],
        );
        expect(
          pixel(99 * rasterScale, (rows.length * lineHeight + 4) * rasterScale),
          [0, 0, 0, 0],
        );
        for (var i = 0; i < rows.length; i++) {
          final entry = actual[i] as Map;
          int? left, top, right, bottom;
          for (
            var y = i * lineHeight * rasterScale;
            y < (i + 1) * lineHeight * rasterScale;
            y++
          ) {
            for (var x = 0; x < width * rasterScale; x++) {
              if (bytes[(y * width * rasterScale + x) * 4 + 3] == 0) continue;
              left = left == null || x < left ? x : left;
              right = right == null || x + 1 > right ? x + 1 : right;
              top = top == null || y < top ? y : top;
              bottom = bottom == null || y + 1 > bottom ? y + 1 : bottom;
            }
          }
          if ((rows[i]['text'] as String).trim().isEmpty) {
            expect(left, isNull, reason: 'Empty text row $i must not paint');
            continue;
          }
          expect(left, isNotNull, reason: 'Native text row $i must paint');
          // Compare real native raster ink with independently measured Skia
          // outlines at 4x resolution to avoid low-resolution hinting shifts.
          // Raster coverage rounds outward and can add one AA pixel.
          final expected = [
            40 - (entry['left'] as num),
            i * lineHeight + 32 - (entry['ascent'] as num),
            40 + (entry['right'] as num),
            i * lineHeight + 32 + (entry['descent'] as num),
          ];
          final painted = [
            left,
            top,
            right,
            bottom,
          ].map((value) => value! / rasterScale).toList();
          debugPrintSynchronously(
            'PIRC_NATIVE_CANVAS_INK_COMPARE ${jsonEncode({'row': i, 'outline': expected, 'raster': painted})}',
          );
          for (var edge = 0; edge < 4; edge++) {
            expect(
              painted[edge],
              closeTo(expected[edge], 1.1),
              reason: 'Real native ink row $i edge $edge',
            );
          }
        }
      } finally {
        image?.dispose();
        picture.dispose();
      }
    } finally {
      scripts.dispose();
      await scripts.closed;
    }
  });
}
