import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/native_math_block.dart';

import 'capture_fonts.dart' show loadParityFonts;
import '../../test/live_test.dart' show theme;

void main() {
  testWidgets(
    'capture NativeMarkdown display block against pinned Chrome geometry',
    (tester) async {
      await tester.runAsync(loadParityFonts);
      final fixture =
          jsonDecode(
                File(
                  '../../fixtures/mobile-parity/native-tex.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final browser =
          jsonDecode(
                File(
                  'build/parity/native-tex-web/native-tex-web.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final formula = (fixture['cases'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((item) => item['id'] == 'mathchoice-display');
      final source = '\$\$\n${formula['source']}\n\$\$\n\nFollowing paragraph';
      final browserCaptures = (browser['captures'] as List)
          .cast<Map<String, dynamic>>();

      tester.view.devicePixelRatio =
          (fixture['capture']['deviceScaleFactor'] as num).toDouble();
      tester.view.physicalSize = Size(
        (fixture['capture']['width'] as num).toDouble(),
        (fixture['capture']['height'] as num).toDouble(),
      );
      addTearDown(tester.view.reset);

      final measurements = <Map<String, Object?>>[];
      for (final scale
          in (fixture['capture']['textScales'] as List).cast<num>().map(
            (value) => value.toDouble(),
          )) {
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
                      child: SizedBox(
                        width:
                            (fixture['capture']['width'] as num).toDouble() -
                            32,
                        child: NativeMarkdown(
                          source: source,
                          fontSize:
                              (fixture['capture']['paragraphFontSize'] as num)
                                  .toDouble(),
                          lineHeight: 1.65,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'scale=$scale');

        final blockFinder = find.byType(NativeMathDisplayBlock);
        final lineBoxFinder = find.byType(NativeMathLineBox);
        final paragraphFinder = find.text('Following paragraph');
        expect(blockFinder, findsOneWidget);
        expect(paragraphFinder, findsOneWidget);
        final block = tester.getRect(blockFinder);
        final lineBox = tester.getRect(lineBoxFinder);
        final paragraph = tester.getRect(paragraphFinder);
        final gap = paragraph.top - block.bottom;
        final nativeTextYFromBlockTop = paragraph.top - block.top;
        final webScale = browserCaptures.singleWhere(
          (capture) => (capture['textScale'] as num).toDouble() == scale,
        );
        final webCase = (webScale['cases'] as List)
            .cast<Map<String, dynamic>>()
            .singleWhere((item) => item['id'] == formula['id']);
        final webBlock = webCase['mathBlockBox'] as Map<String, dynamic>;
        final webLineBox = webCase['displayBox'] as Map<String, dynamic>;
        final webParagraph =
            webCase['followingParagraphBox'] as Map<String, dynamic>;
        final webTextYFromBlockTop =
            (webParagraph['y'] as num).toDouble() -
            (webBlock['y'] as num).toDouble();
        final webGap =
            (webParagraph['y'] as num).toDouble() -
            ((webBlock['y'] as num).toDouble() +
                (webBlock['height'] as num).toDouble());

        expect(
          block.width,
          closeTo((webBlock['width'] as num).toDouble(), .02),
        );
        expect(
          block.height,
          closeTo((webBlock['height'] as num).toDouble(), .02),
        );
        expect(
          lineBox.height,
          closeTo((webLineBox['height'] as num).toDouble(), .02),
        );
        expect(gap, closeTo(webGap, .02));
        expect(nativeTextYFromBlockTop, closeTo(webTextYFromBlockTop, .02));
        measurements.add({
          'textScale': scale,
          'native': {
            'mathBlockBox': _box(block),
            'displayLineBox': _box(lineBox),
            'followingTextBox': _box(paragraph),
            'followingTextYFromBlockTop': nativeTextYFromBlockTop,
            'followingTextGap': gap,
          },
          'chrome154': {
            'mathBlockBox': webBlock,
            'displayLineBox': webLineBox,
            'followingParagraphBox': webParagraph,
            'followingParagraphYFromBlockTop': webTextYFromBlockTop,
            'followingParagraphGap': webGap,
          },
          'deltas': {
            'mathBlockWidth':
                block.width - (webBlock['width'] as num).toDouble(),
            'mathBlockHeight':
                block.height - (webBlock['height'] as num).toDouble(),
            'displayLineHeight':
                lineBox.height - (webLineBox['height'] as num).toDouble(),
            'followingTextYFromBlockTop':
                nativeTextYFromBlockTop - webTextYFromBlockTop,
            'followingTextGap': gap - webGap,
          },
        });
      }

      File('build/parity/native-tex/native-markdown-math-display-native.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'renderer': 'NativeMarkdown > NativeMathDisplayBlock',
            'fixture': 'fixtures/mobile-parity/native-tex.json',
            'browserReference':
                'build/parity/native-tex-web/native-tex-web.json (Chrome 154)',
            'captures': measurements,
          }),
        );
    },
  );
}

Map<String, double> _box(Rect rect) => {
  'x': rect.left,
  'y': rect.top,
  'width': rect.width,
  'height': rect.height,
};
