import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart'
    show Math, MathStyle, TexParserSettings;
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_inline_math.dart';
import 'package:pirc_render/src/native_tex_adapter.dart';

void main() {
  testWidgets('inline TeX wraps at break parts within the available width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    addTearDown(tester.view.reset);

    const parentWidth = 120.0;
    const bodyFontSize = 15.0;
    const lineHeight = 1.65;
    const textScale = 2.0;
    const expression = r'x+\mystery+y';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData.fromView(
              tester.view,
            ).copyWith(textScaler: const TextScaler.linear(textScale)),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: parentWidth,
                child: RichText(
                  text: TextSpan(
                    children: [
                      WidgetSpan(
                        alignment: PlaceholderAlignment.baseline,
                        baseline: TextBaseline.alphabetic,
                        child: NativeMathTex(
                          expression,
                          mathStyle: MathStyle.text,
                          textStyle: const TextStyle(
                            fontSize: bodyFontSize * 1.08,
                            color: Colors.black,
                          ),
                          settings: const TexParserSettings(
                            throwOnError: false,
                          ),
                          onErrorFallback: (_) => const Text('TEX_ERROR'),
                          onParsed: (context, math) => NativeInlineMath(
                            key: const ValueKey('inline-wrap'),
                            math: math as Math,
                            bodyFontSize: bodyFontSize,
                            lineHeight: lineHeight,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final inline = tester.widget<NativeInlineMath>(
      find.byKey(const ValueKey('inline-wrap')),
    );
    expect(inline.math.texBreak().parts.length, greaterThan(1));

    final inlineSize = tester.getSize(
      find.byKey(const ValueKey('inline-wrap')),
    );
    expect(inlineSize.width, lessThanOrEqualTo(parentWidth));
    expect(
      inlineSize.height,
      greaterThan(bodyFontSize * textScale * lineHeight),
    );
    final renderedMathParts = find.descendant(
      of: find.byKey(const ValueKey('inline-wrap')),
      matching: find.byType(Math),
    );
    expect(
      renderedMathParts,
      findsNWidgets(inline.math.texBreak().parts.length),
    );
    final firstPartSize = tester.getSize(renderedMathParts.first);
    expect(firstPartSize.width, lessThanOrEqualTo(parentWidth));
    expect(tester.takeException(), isNull);
  });

  testWidgets('respects TeX no-break boundaries but uses legal breaks', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 700);
    addTearDown(tester.view.reset);

    Future<({Size wrapper, Size firstPart, int partCount})> layout(
      String expression,
      String key,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 72,
                child: NativeMathTex(
                  expression,
                  mathStyle: MathStyle.text,
                  textStyle: const TextStyle(fontSize: 24, color: Colors.black),
                  settings: const TexParserSettings(throwOnError: false),
                  onErrorFallback: (_) => const Text('TEX_ERROR'),
                  onParsed: (context, math) => NativeInlineMath(
                    key: ValueKey(key),
                    math: math as Math,
                    bodyFontSize: 20,
                    lineHeight: 1.65,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final wrapperFinder = find.byKey(ValueKey(key));
      final parts = find.descendant(
        of: wrapperFinder,
        matching: find.byType(Math),
      );
      return (
        wrapper: tester.getSize(wrapperFinder),
        firstPart: tester.getSize(parts.first),
        partCount: parts.evaluate().length,
      );
    }

    final legal = await layout(r'x+\mystery+y', 'legal-break');
    final forbidden = await layout(r'x+\nobreak\mystery+y', 'no-break');

    expect(legal.partCount, greaterThan(1));
    expect(legal.firstPart.width, lessThanOrEqualTo(72));
    expect(legal.wrapper.width, lessThanOrEqualTo(72));
    expect(forbidden.partCount, lessThan(legal.partCount));
    expect(forbidden.firstPart.width, greaterThan(72));
    expect(forbidden.wrapper.width, lessThanOrEqualTo(72));
    expect(tester.takeException(), isNull);
  });

  testWidgets('split parts retain binary and scripted operator spacing', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.reset);

    Future<({double originalWidth, double wrappedWidth, double baseline})>
    measure(String expression, String key) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 1000,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    NativeMathTex(
                      expression,
                      mathStyle: MathStyle.text,
                      textStyle: const TextStyle(fontSize: 24),
                    ),
                    NativeMathTex(
                      expression,
                      mathStyle: MathStyle.text,
                      textStyle: const TextStyle(fontSize: 24),
                      onParsed: (context, math) => NativeInlineMath(
                        key: ValueKey('$key-inline'),
                        math: math as Math,
                        bodyFontSize: 24,
                        lineHeight: 1.65,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final inlineFinder = find.byKey(ValueKey('$key-inline'));
      final renderer = tester.renderObject<RenderNativeInlineMath>(
        inlineFinder,
      );
      return (
        originalWidth: tester.getSize(find.byType(Math).first).width,
        wrappedWidth: tester.getSize(inlineFinder).width,
        baseline: renderer.baseline,
      );
    }

    for (final (index, expression) in [
      r'a+b',
      r'a+b=c',
      r'x^2+y_1',
      r'a+\allowbreak b',
      r'a\allowbreak=b',
    ].indexed) {
      final sizes = await measure(expression, 'spacing-$index');
      expect(
        sizes.wrappedWidth,
        closeTo(sizes.originalWidth, 0.05),
        reason: '$expression must preserve its original TeX glue',
      );
      expect(sizes.baseline, greaterThan(0));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('an unbreakable part stays natural-sized and can paint outside', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 700);
    addTearDown(tester.view.reset);

    const parentWidth = 48.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: parentWidth,
              child: NativeMathTex(
                r'\mystery',
                mathStyle: MathStyle.text,
                textStyle: const TextStyle(fontSize: 56, color: Colors.black),
                settings: const TexParserSettings(throwOnError: false),
                onParsed: (context, math) => NativeInlineMath(
                  key: const ValueKey('inline-overflow'),
                  math: math as Math,
                  bodyFontSize: 24,
                  lineHeight: 1.65,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final parentSize = tester.getSize(
      find.byKey(const ValueKey('inline-overflow')),
    );
    final renderedPart = tester.getSize(
      find.descendant(
        of: find.byKey(const ValueKey('inline-overflow')),
        matching: find.byType(Math),
      ),
    );
    expect(parentSize.width, lessThanOrEqualTo(parentWidth));
    expect(renderedPart.width, greaterThan(parentSize.width));
    expect(tester.takeException(), isNull);
  });
}
