import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_math_block.dart';
import 'package:pirc_render/src/native_tex_adapter.dart';

import 'capture_fonts.dart' show loadParityFonts;
import '../../test/live_test.dart' show theme;

void main() {
  testWidgets(
    'capture native display block, baseline, and following paragraph geometry',
    (tester) async {
      await tester.runAsync(loadParityFonts);
      final fixture =
          jsonDecode(
                File(
                  '../../fixtures/mobile-parity/native-tex.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final cases = (fixture['cases'] as List)
          .cast<Map<String, dynamic>>()
          .where((item) => item['mode'] == 'display')
          .toList(growable: false);
      final bodyFontSize =
          (fixture['capture']['paragraphFontSize'] as num).toDouble();
      final mathScale =
          (fixture['capture']['mathFontScale'] as num).toDouble();
      final measurements = <Map<String, Object?>>[];
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1800);
      addTearDown(tester.view.reset);

      for (final scale in [1.0, 2.0]) {
        final widgets = <Widget>[];
        for (final item in cases) {
          final id = item['id'] as String;
          final source = item['source'] as String;
          final blockKey = ValueKey('block-$scale-$id');
          final mathKey = ValueKey('math-$scale-$id');
          final paragraphKey = ValueKey('paragraph-$scale-$id');
          widgets.add(
            SizedBox(
              key: blockKey,
              child: NativeMathDisplayBlock(
                bodyFontSize: bodyFontSize,
                mathFontSize: bodyFontSize * mathScale,
                child: SizedBox(
                  key: mathKey,
                  child: NativeMathTex(
                    source,
                    mathStyle: MathStyle.display,
                    settings: const TexParserSettings(
                      displayMode: true,
                      maxExpand: 500,
                      strict: Strict.ignore,
                    ),
                    textStyle: TextStyle(
                      fontSize: bodyFontSize * mathScale,
                      color: Colors.black,
                    ),
                    onErrorFallback: (_) => Text(
                      source,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: bodyFontSize,
                        color: Colors.red,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          widgets.add(SizedBox(height: bodyFontSize * scale * .85));
          widgets.add(
            Text(
              'Following paragraph',
              key: paragraphKey,
              style: TextStyle(
                fontSize: bodyFontSize,
                height: 1.65,
              ),
            ),
          );
        }

        await tester.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: widgets,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'scale $scale');

        final capture = <Map<String, Object?>>[];
        for (final item in cases) {
          final id = item['id'] as String;
          final blockFinder = find.byKey(ValueKey('block-$scale-$id'));
          final mathFinder = find.byKey(ValueKey('math-$scale-$id'));
          final paragraphFinder = find.byKey(
            ValueKey('paragraph-$scale-$id'),
          );
          final lineBoxFinder = find.descendant(
            of: blockFinder,
            matching: find.byType(NativeMathLineBox),
          );
          final block = tester.renderObject<RenderBox>(blockFinder);
          final lineBox = tester.renderObject<RenderNativeMathLineBox>(
            lineBoxFinder,
          );
          final formula = tester.renderObject<RenderBox>(mathFinder);
          final paragraph = tester.renderObject<RenderBox>(paragraphFinder);
          final blockTop = tester.getTopLeft(blockFinder).dy;
          final lineTop = tester.getTopLeft(lineBoxFinder).dy;
          final formulaTop = tester.getTopLeft(mathFinder).dy;
          final paragraphTop = tester.getTopLeft(paragraphFinder).dy;
          capture.add({
            'id': id,
            'nativeExpected': item['nativeExpected'],
            'blockBox': {
              'x': tester.getTopLeft(blockFinder).dx,
              'y': blockTop,
              'width': block.size.width,
              'height': block.size.height,
            },
            'lineBox': {
              'x': tester.getTopLeft(lineBoxFinder).dx,
              'y': lineTop,
              'width': lineBox.size.width,
              'height': lineBox.size.height,
              'baseline': lineBox.baseline,
              'baselineFromBlockTop': lineBox.baseline + lineTop - blockTop,
            },
            'formulaBox': {
              'x': tester.getTopLeft(mathFinder).dx,
              'y': formulaTop,
              'width': formula.size.width,
              'height': formula.size.height,
              'baseline': lineBox.childBaseline,
              'baselineFromBlockTop':
                  lineBox.childBaseline + formulaTop - blockTop,
            },
            'formulaTopFromLineBox': formulaTop - lineTop,
            'followingParagraphBox': {
              'x': tester.getTopLeft(paragraphFinder).dx,
              'y': paragraphTop,
              'width': paragraph.size.width,
              'height': paragraph.size.height,
            },
            'followingParagraphGap':
                paragraphTop - (blockTop + block.size.height),
          });
        }
        measurements.add({
          'textScale': scale,
          'bodyFontSize': bodyFontSize * scale,
          'mathFontSize': bodyFontSize * mathScale * scale,
          'cases': capture,
        });
      }

      final output =
          File('build/parity/native-tex/native-math-block-native.json')
            ..parent.createSync(recursive: true);
      output.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'renderer': 'NativeMathDisplayBlock + NativeMathTex',
          'fixture': 'fixtures/mobile-parity/native-tex.json',
          'bodyFontRule': 'Markdown body 15px, scaled by UI text scale',
          'mathFontRule': 'body font size times KaTeX 1.08em',
          'displayLineRule': 'KaTeX 1.2em line-height with baseline metrics',
          'captures': measurements,
        }),
      );
    },
  );
}
