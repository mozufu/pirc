import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

const _fixturePath = '../../fixtures/mobile-parity/mermaid-svg-scale.json';
const _expectedPath =
    '../../fixtures/mobile-parity/mermaid-svg-scale-expected.json';
const _outputPath = 'build/parity/mermaid-svg-scale-native';

Map<String, dynamic> _object(Object? value) =>
    (value as Map).cast<String, dynamic>();

List<Map<String, dynamic>> _objects(Object? value) =>
    (value as List).map(_object).toList();

String _unfence(String source) {
  final fence = String.fromCharCode(96) * 3;
  return source
      .replaceFirst(
        RegExp(
          '^${RegExp.escape(fence)}'
          r'mermaid\s*',
        ),
        '',
      )
      .replaceFirst(RegExp(r'\s*' + RegExp.escape(fence) + r'$'), '');
}

Map<String, dynamic> _referenceCase(
  Map<String, dynamic> expected,
  int width,
  Brightness brightness,
  double textScale,
  String id,
) {
  final themes = _object(expected['themes']);
  final theme = _object(themes[brightness.name]);
  final widths = _objects(theme['widths']);
  final widthRow = widths.singleWhere((row) => row['width'] == width);
  final scales = _objects(widthRow['scales']);
  final scaleRow = scales.singleWhere((row) => row['textScale'] == textScale);
  return _objects(scaleRow['cases']).singleWhere((row) => row['id'] == id);
}

Map<String, Object?> _rect(Rect rect) => {
  'left': rect.left,
  'top': rect.top,
  'right': rect.right,
  'bottom': rect.bottom,
  'width': rect.width,
  'height': rect.height,
};

Map<String, Object?> _rectDelta(Rect native, Map<String, dynamic> web) => {
  'left': native.left - (web['x'] as num).toDouble(),
  'top': native.top - (web['y'] as num).toDouble(),
  'width': native.width - (web['width'] as num).toDouble(),
  'height': native.height - (web['height'] as num).toDouble(),
};

String _captureKey(
  int width,
  Brightness brightness,
  String id,
  double textScale,
) => '$width:${brightness.name}:$id:$textScale';

Future<void> _loadComparisonFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    await loadParityFonts();
    // Chrome's generic sans-serif resolves to the host PingFang collection in
    // these captures. FontLoader uses the collection's first face; it cannot
    // select PingFang TC by name, so this is only an explicit host comparison
    // alias and is not a bundled production font.
    final pingFang =
        Directory('/System/Library/AssetsV2/com_apple_MobileAsset_Font7')
            .listSync(recursive: true)
            .whereType<File>()
            .firstWhere((file) => file.path.endsWith('/PingFang.ttc'));
    await (FontLoader(
      'sans-serif',
    )..addFont(pingFang.readAsBytes().then(ByteData.sublistView))).load();
    await (FontLoader('Mermaid reference')..addFont(
          File(
            '/System/Library/Fonts/SFNS.ttf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });
}

ThemeData _comparisonTheme(Brightness brightness) {
  final base = theme.build(brightness);
  return base.copyWith(textTheme: base.textTheme.apply(fontFamily: 'Arial'));
}

void main() {
  final fixture = _object(jsonDecode(File(_fixturePath).readAsStringSync()));
  final expected = _object(jsonDecode(File(_expectedPath).readAsStringSync()));
  final cases = _objects(fixture['cases']);
  final widths = (fixture['widths'] as List).cast<int>();
  final scales = (fixture['textScales'] as List)
      .map((scale) => (scale as num).toDouble())
      .toList();
  final height = (fixture['height'] as num).toDouble();

  testWidgets('capture native Mermaid SVG text-scale matrix', (tester) async {
    await _loadComparisonFonts(tester);
    Directory(_outputPath).createSync(recursive: true);

    final captures = <Map<String, dynamic>>[];
    final rectsByScalePair = <String, Map<double, Rect>>{};

    for (final width in widths) {
      for (final brightness in Brightness.values) {
        for (final textScale in scales) {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width.toDouble(), height);
          tester.platformDispatcher.textScaleFactorTestValue = textScale;

          for (final item in cases) {
            final id = item['id'] as String;
            final source = _unfence(item['source'] as String);
            final reference = _referenceCase(
              expected,
              width,
              brightness,
              textScale,
              id,
            );
            expect(reference['status'], 'ok', reason: id);

            final repaintKey = GlobalKey();
            await tester.pumpWidget(
              RepaintBoundary(
                key: repaintKey,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: _comparisonTheme(brightness),
                  home: Scaffold(
                    body: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: DefaultTextStyle(
                        style: const TextStyle(fontFamily: 'Mermaid reference'),
                        child: NativeMermaid(source: source, lineHeight: 1.65),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await tester.pump(const Duration(milliseconds: 20));
            await tester.pumpAndSettle();

            expect(tester.takeException(), isNull, reason: id);
            expect(find.byType(NativeMermaid), findsOneWidget);
            expect(
              find.byKey(const ValueKey('native-mermaid-block')),
              findsOneWidget,
            );
            final customPaintFinder = find.byType(CustomPaint);
            expect(customPaintFinder, findsOneWidget, reason: id);
            final painter = tester.widget<CustomPaint>(customPaintFinder);
            expect(painter.painter, isNotNull, reason: id);

            final blockRect = tester.getRect(
              find.byKey(const ValueKey('native-mermaid-block')),
            );
            final canvasRect = tester.getRect(customPaintFinder);
            final pairKey = _captureKey(width, brightness, id, 0);
            rectsByScalePair.putIfAbsent(pairKey, () => {})[textScale] =
                canvasRect;

            final webBlock = _object(reference['block']);
            final webFigure = _object(reference['figure']);
            final webSvg = _object(reference['svg']);
            final webBlockBox = _object(webBlock['box']);
            final webFigureBox = _object(webFigure['box']);
            final webSvgBox = _object(webSvg['box']);
            final webSvgAttrs = _object(webSvg['attrs']);

            final metric = <String, dynamic>{
              'id': id,
              'kind': item['kind'],
              'width': width,
              'height': height,
              'brightness': brightness.name,
              'textScale': textScale,
              'devicePixelRatio': 1,
              'native': {
                'nativeMermaidBlockRect': _rect(blockRect),
                'customPaintCanvasRect': _rect(canvasRect),
                'customPaintSize': {
                  'width': canvasRect.width,
                  'height': canvasRect.height,
                },
                'painterType': painter.painter.runtimeType.toString(),
                'fontAliases': {
                  'bodyTheme':
                      'Arial (host Supplemental Arial via capture_fonts.dart)',
                  'mermaidDefaultTextStyle':
                      'Mermaid reference (host SFNS.ttf)',
                  'genericSansSerif':
                      'PingFang.ttc first face (host-only comparison alias)',
                },
              },
              'chrome': {
                'blockRect': webBlockBox,
                'figureRect': webFigureBox,
                'svgRect': webSvgBox,
                'svgViewBox': webSvgAttrs['viewBox'],
                'svgWorldBox': webSvg['worldBox'],
                'blockFontSize': webBlock['fontSize'],
                'blockLineHeight': webBlock['lineHeight'],
              },
              'nativeCanvasMinusChromeSvg': _rectDelta(canvasRect, webSvgBox),
              'nativeBlockMinusChromeBlock': _rectDelta(blockRect, webBlockBox),
              'visualParityAccepted': false,
              'notes': [
                'Native CustomPaint canvas bounds are compared with the browser SVG client box; dimensions are recorded without asserting absolute pixel parity.',
                'Host SFNS and Arial are comparison fonts only. They are not bundled app assets.',
              ],
            };

            final filename =
                '$id-$width-${brightness.name}-scale$textScale.png';
            await tester.runAsync(() async {
              final boundary =
                  repaintKey.currentContext!.findRenderObject()
                      as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 1);
              try {
                final data = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                if (data == null) {
                  throw StateError('PNG encoding returned no bytes for $id');
                }
                final output = File('$_outputPath/$filename');
                await output.writeAsBytes(
                  data.buffer.asUint8List(),
                  flush: true,
                );
                metric['png'] = output.path;
              } finally {
                image.dispose();
              }
            });
            captures.add(metric);

            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          }
        }
      }
    }

    final scaleComparisons = <Map<String, dynamic>>[];
    for (final width in widths) {
      for (final brightness in Brightness.values) {
        for (final item in cases) {
          final id = item['id'] as String;
          final pairKey = _captureKey(width, brightness, id, 0);
          final pair = rectsByScalePair[pairKey]!;
          final scale1 = pair[1]!;
          final scale2 = pair[2]!;
          final sameGeometry =
              (scale1.left - scale2.left).abs() < 0.001 &&
              (scale1.top - scale2.top).abs() < 0.001 &&
              (scale1.width - scale2.width).abs() < 0.001 &&
              (scale1.height - scale2.height).abs() < 0.001;
          expect(
            sameGeometry,
            isTrue,
            reason:
                'Native Mermaid paint geometry changed with text scaling: $pairKey',
          );
          scaleComparisons.add({
            'id': id,
            'width': width,
            'brightness': brightness.name,
            'scale1CanvasRect': _rect(scale1),
            'scale2CanvasRect': _rect(scale2),
            'nativePaintGeometryUnchanged': sameGeometry,
            'blockHeightsMayChangeWithHtmlTextScale': true,
          });
        }
      }
    }

    final output = <String, dynamic>{
      'fixture': fixture['id'],
      'reference': fixture['webRevision'],
      'mermaidVersion': fixture['mermaidVersion'],
      'matrix': {
        'widths': widths,
        'themes': (fixture['themes'] as List).cast<String>(),
        'textScales': scales,
        'height': height,
        'devicePixelRatio': 1,
      },
      'fontComparisonPolicy': {
        'uiBody':
            'Arial host alias loaded from /System/Library/Fonts/Supplemental',
        'mermaidText':
            'SFNS.ttf loaded as Mermaid reference, matching the existing Gantt capture setup',
        'genericSansSerif':
            'PingFang.ttc loaded as sans-serif; FontLoader selects the collection first face, not a named TC face',
        'productionFontsBundled': false,
      },
      'visualParityAccepted': false,
      'nativePaintGeometryInvariantAcrossTextScales': true,
      'scaleComparisons': scaleComparisons,
      'captures': captures,
    };
    File(
      '$_outputPath/metrics.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(output));
    debugPrint(
      'Captured ${captures.length} native Mermaid SVG scale cases to $_outputPath',
    );
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  });
}
