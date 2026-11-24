import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_math_block.dart';
import 'package:pirc_render/src/native_tex_adapter.dart';

Widget _display(String source, {Key? mathKey}) {
  return NativeMathDisplayBlock(
    bodyFontSize: 15,
    mathFontSize: 16.2,
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
        textStyle: const TextStyle(fontSize: 16.2, color: Colors.black),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'short displays get the CSS line box, margin, and fixed padding',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 600);
      addTearDown(tester.view.reset);

      for (final scale in [1.0, 2.0]) {
        final blockKey = ValueKey('block-$scale');
        final mathKey = ValueKey('math-$scale');
        final paragraphKey = ValueKey('paragraph-$scale');
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: SizedBox(
                    width: 360,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          key: blockKey,
                          child: _display(
                            r'\rule{40pt}{5pt}',
                            mathKey: mathKey,
                          ),
                        ),
                        SizedBox(height: 15 * scale * .85),
                        Text(
                          'Following paragraph',
                          key: paragraphKey,
                          style: const TextStyle(fontSize: 15, height: 1.65),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'scale=$scale');

        final block = tester.renderObject<RenderBox>(find.byKey(blockKey));
        final lineBox = tester.renderObject<RenderBox>(
          find.byType(NativeMathLineBox),
        );
        final formula = tester.renderObject<RenderBox>(find.byKey(mathKey));
        final lineRender = lineBox as RenderNativeMathLineBox;
        final childBaseline = lineRender.childBaseline;
        final scaledBody = 15 * scale;
        final scaledMath = 16.2 * scale;
        final expectedLineHeight = math.max(
          formula.size.height,
          scaledMath * 1.2,
        );
        expect(
          lineBox.size.height,
          closeTo(expectedLineHeight, .02),
          reason: 'minimum 1.2em line box at scale=$scale',
        );
        expect(
          block.size.height,
          closeTo(expectedLineHeight + 4 + scaledBody * .6, .02),
          reason: '2px padding and .3em display margins at scale=$scale',
        );
        expect(
          lineRender.baseline,
          closeTo(scaledMath * .9, .02),
          reason: 'normal CSS line baseline at scale=$scale',
        );

        final mathTop = tester.getTopLeft(find.byKey(mathKey)).dy;
        final lineTop = tester.getTopLeft(find.byType(NativeMathLineBox)).dy;
        expect(
          mathTop - lineTop,
          closeTo(scaledMath * .9 - childBaseline, .02),
          reason: 'formula baseline remains aligned at scale=$scale',
        );
        final paragraphTop = tester.getTopLeft(find.byKey(paragraphKey)).dy;
        expect(
          paragraphTop -
              (tester.getTopLeft(find.byKey(blockKey)).dy + block.size.height),
          closeTo(scaledBody * .85, .02),
          reason: 'following paragraph uses the CSS block margin',
        );
      }
    },
  );

  testWidgets('tall formulas and gather rows expand around their baseline', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 900);
    addTearDown(tester.view.reset);

    for (final source in [
      r'\frac{x}{y}',
      r'\begin{gather}a=b\\c=d\\e=f\end{gather}',
      r'\smash[t]{\frac{x}{y}}',
    ]) {
      final mathKey = ValueKey(source);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              child: _display(source, mathKey: mathKey),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: source);

      final lineBox = tester.renderObject<RenderBox>(
        find.byType(NativeMathLineBox),
      );
      final formula = tester.renderObject<RenderBox>(find.byKey(mathKey));
      final formulaTop = tester.getTopLeft(find.byKey(mathKey)).dy;
      final lineTop = tester.getTopLeft(find.byType(NativeMathLineBox)).dy;
      final formulaBottom = formulaTop + formula.size.height;
      final lineBottom = lineTop + lineBox.size.height;
      expect(formulaTop, greaterThanOrEqualTo(lineTop - .01), reason: source);
      expect(
        formulaBottom,
        lessThanOrEqualTo(lineBottom + .01),
        reason: source,
      );
      expect(
        lineBox.size.height,
        greaterThanOrEqualTo(formula.size.height - .01),
        reason: source,
      );
    }
  });

  testWidgets(
    'intrinsic height reserves room for a tall baseline and minimum descent',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(240, 160);
      addTearDown(tester.view.reset);

      final intrinsicKey = GlobalKey();
      final lineBoxKey = GlobalKey();
      final childKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 100,
                child: IntrinsicHeight(
                  key: intrinsicKey,
                  child: NativeMathLineBox(
                    key: lineBoxKey,
                    minAscent: 20,
                    minDescent: 5,
                    child: Baseline(
                      baseline: 30,
                      baselineType: TextBaseline.alphabetic,
                      child: SizedBox(key: childKey, width: 30, height: 30),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final intrinsic = tester.renderObject<RenderBox>(
        find.byKey(intrinsicKey),
      );
      final lineBox = tester.renderObject<RenderNativeMathLineBox>(
        find.byKey(lineBoxKey),
      );
      final child = tester.renderObject<RenderBox>(find.byKey(childKey));
      expect(intrinsic.size.height, closeTo(35, .01));
      expect(lineBox.size.height, closeTo(35, .01));
      expect(lineBox.baseline, closeTo(30, .01));

      final lineBoxTop = tester.getTopLeft(find.byKey(lineBoxKey)).dy;
      final childTop = tester.getTopLeft(find.byKey(childKey)).dy;
      expect(childTop - lineBoxTop, closeTo(0, .01));
      expect(
        childTop + child.size.height,
        lessThanOrEqualTo(lineBoxTop + lineBox.size.height + .01),
      );
    },
  );

  testWidgets('wide formulas scroll horizontally without changing block size', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 500);
    addTearDown(tester.view.reset);

    final blockKey = GlobalKey();
    final mathKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            key: blockKey,
            width: 300,
            child: _display(r'\rule{120em}{.5em}', mathKey: mathKey),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final block = tester.renderObject<RenderBox>(find.byKey(blockKey));
    final formula = tester.renderObject<RenderBox>(find.byKey(mathKey));
    expect(block.size.width, 300);
    expect(formula.size.width, greaterThan(block.size.width));

    final scrollableFinder = find.descendant(
      of: find.byKey(blockKey),
      matching: find.byType(Scrollable),
    );
    final scrollable = tester.state<ScrollableState>(scrollableFinder);
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
  });
}
