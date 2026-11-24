// ignore_for_file: implementation_imports

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_math_fork/flutter_math.dart'
    show Math, MathStyle, TexParserSettings;
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_inline_math.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/native_math_paragraph.dart';
import 'package:pirc_render/src/native_tex_adapter.dart';

import 'live_test.dart' show theme;

void main() {
  testWidgets('joins prose and legal math parts in one paragraph run', (
    tester,
  ) async {
    await _pumpParagraph(
      tester,
      width: 520,
      children: [
        const Text('Lead text '),
        _mathMarker(r'x+\unknown+y'),
        const Text(' trailing text'),
      ],
    );

    final content = tester.widget<NativeMathParagraphContent>(
      find.byType(NativeMathParagraphContent),
    );
    expect(content.formulas, hasLength(1));
    final formula = content.formulas.single;
    expect(formula.index, 0);
    expect(formula.source.expression, r'x+\unknown+y');
    expect(formula.parts.length, greaterThan(1));
    expect(
      formula.parts.length,
      find
          .descendant(
            of: find.byType(NativeMathParagraphContent),
            matching: find.byType(NativeMathPart),
          )
          .evaluate()
          .length,
    );
    expect(
      find.descendant(
        of: find.byType(NativeMathParagraphContent),
        matching: find.byType(Math),
      ),
      findsNWidgets(formula.parts.length),
      reason: 'the full source model is metadata, not an extra painted Math',
    );

    final paragraph = _contentParagraph(tester, 0);
    final leadingText = paragraph.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: 4),
    );
    final plainText = paragraph.text.toPlainText(
      includePlaceholders: true,
      includeSemanticsLabels: false,
    );
    final placeholders = [
      for (var index = 0; index < plainText.length; index++)
        if (plainText.codeUnitAt(index) == 0xfffc)
          ...paragraph.getBoxesForSelection(
            TextSelection(baseOffset: index, extentOffset: index + 1),
          ),
    ];
    expect(placeholders, hasLength(formula.parts.length));
    final placeholderOverlap =
        math.min(placeholders.first.bottom, leadingText.first.bottom) -
        math.max(placeholders.first.top, leadingText.first.top);
    expect(placeholderOverlap, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps no-break slices together and preserves a plus width', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 700,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NativeMathTex(
                    'a+b',
                    mathStyle: MathStyle.text,
                    textStyle: const TextStyle(
                      fontSize: 25.92,
                      color: Colors.black,
                    ),
                  ),
                  NativeMathParagraph(children: [_mathMarker('a+b')]),
                  NativeMathParagraph(
                    children: [_mathMarker(r'x+\nobreak\unknown+y')],
                  ),
                  NativeMathParagraph(children: [_mathMarker(r'x+\unknown+y')]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final whole = tester.renderObject<RenderBox>(find.byType(Math).first);
    final plusContent = tester.widget<NativeMathParagraphContent>(
      find.byType(NativeMathParagraphContent).at(0),
    );
    final plusParts = _mathPartBoxes(tester, 0);
    expect(
      plusParts.fold<double>(0, (sum, box) => sum + box.size.width),
      closeTo(whole.size.width, .05),
      reason: 'legal placeholder boundaries must retain TeX binary glue',
    );

    final noBreak = tester.widget<NativeMathParagraphContent>(
      find.byType(NativeMathParagraphContent).at(1),
    );
    final legal = tester.widget<NativeMathParagraphContent>(
      find.byType(NativeMathParagraphContent).at(2),
    );
    expect(plusContent.formulas.single.parts, hasLength(plusParts.length));
    expect(
      noBreak.formulas.single.parts.length,
      lessThan(legal.formulas.single.parts.length),
      reason: 'penalty >= 10000 must merge pieces into one WidgetSpan',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('scales prose and resolved Math once at 2x', (tester) async {
    Future<({double mathWidth, double textHeight})> capture(
      double scale,
    ) async {
      await _pumpParagraph(
        tester,
        width: 700,
        scale: scale,
        children: [const Text('Body '), _mathMarker('a+b')],
      );
      final parts = _mathPartBoxes(tester, 0);
      final paragraph = _contentParagraph(tester, 0);
      final textBoxes = paragraph.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 4),
      );
      return (
        mathWidth: parts.fold<double>(0, (sum, box) => sum + box.size.width),
        textHeight: textBoxes.first.bottom - textBoxes.first.top,
      );
    }

    final one = await capture(1);
    final two = await capture(2);
    expect(two.mathWidth, closeTo(one.mathWidth * 2, .05));
    expect(two.textHeight, closeTo(one.textHeight * 2, .1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tall inline fractions expand the line box', (tester) async {
    await _pumpParagraph(
      tester,
      width: 400,
      children: [
        const Text('ratio '),
        _mathMarker(r'\dfrac{\dfrac{a+b}{c+d}}{\dfrac{e+f}{g+h}}'),
        const Text(' follows'),
      ],
    );

    final part = _mathPartBoxes(tester, 0).single;
    final paragraph = _contentParagraph(tester, 0);
    expect(part.size.height, greaterThan(24 * 1.65));
    expect(paragraph.size.height, greaterThan(24 * 1.65));
    expect(paragraph.size.height, greaterThanOrEqualTo(part.size.height - .5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps opaque inline widgets in the paragraph flow', (
    tester,
  ) async {
    const opaqueKey = ValueKey('opaque-inline');
    var tapped = false;
    await _pumpParagraph(
      tester,
      width: 280,
      children: [
        const Text('before '),
        _mathMarker('x+y'),
        GestureDetector(
          key: opaqueKey,
          onTap: () => tapped = true,
          child: const SizedBox(
            width: 18,
            height: 14,
            child: ColoredBox(color: Colors.blue),
          ),
        ),
        const Text(' after'),
      ],
    );

    final content = tester.widget<NativeMathParagraphContent>(
      find.byType(NativeMathParagraphContent),
    );
    final paragraph = content.child as RichText;
    expect(
      paragraph.text.toPlainText(
        includePlaceholders: true,
        includeSemanticsLabels: false,
      ),
      contains('\uFFFC'),
    );
    expect(
      find.descendant(
        of: find.byType(NativeMathParagraphContent),
        matching: find.byKey(opaqueKey),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(opaqueKey));
    expect(tapped, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unbreakable Math keeps natural width in a narrow paragraph', (
    tester,
  ) async {
    await _pumpParagraph(
      tester,
      width: 80,
      children: [
        const Text('lead '),
        _mathMarker(r'\text{MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM}'),
      ],
    );

    final part = find.byType(NativeMathInlinePart);
    final naturalMath = find.descendant(of: part, matching: find.byType(Math));
    expect(part, findsOneWidget);
    expect(naturalMath, findsOneWidget);
    expect(tester.getSize(part).width, lessThanOrEqualTo(80));
    expect(tester.getSize(naturalMath).width, greaterThan(80));
    final richText = _contentParagraph(tester, 0);
    expect(richText.size.width, lessThanOrEqualTo(80));
    expect(richText.overflow, TextOverflow.visible);
    expect(
      tester.getRect(naturalMath).right,
      greaterThan(
        tester.getRect(find.byWidget(_paragraphContent(tester, 0).child)).right,
      ),
      reason: 'the unbreakable TeX part paints at natural width past its box',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('math keeps a force-strut Markdown paragraph in one run', (
    tester,
  ) async {
    await _pumpParagraph(
      tester,
      width: 340,
      children: [
        Text.rich(
          const TextSpan(text: 'before '),
          style: const TextStyle(fontSize: 24, color: Colors.black),
          strutStyle: const StrutStyle(
            fontSize: 24,
            height: 1.65,
            forceStrutHeight: true,
          ),
        ),
        _mathMarker(r'\dfrac{\dfrac{a}{b}}{\dfrac{c}{d}}'),
        Text.rich(
          const TextSpan(text: ' after'),
          style: const TextStyle(fontSize: 24, color: Colors.black),
          strutStyle: const StrutStyle(
            fontSize: 24,
            height: 1.65,
            forceStrutHeight: true,
          ),
        ),
      ],
    );

    expect(find.byType(NativeMathParagraphContent), findsOneWidget);
    final paragraph = _contentParagraph(tester, 0);
    final part = _mathPartBoxes(tester, 0).single;
    expect(part.size.height, greaterThan(24 * 1.65));
    expect(paragraph.size.height, greaterThan(24 * 1.65));
    expect(paragraph.size.height, greaterThanOrEqualTo(part.size.height - .5));
    expect(paragraph.text.toPlainText(), contains('before '));
    expect(paragraph.text.toPlainText(), contains(' after'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'inline math survives native table dry-baseline probes at 1x/2x',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 900);
      addTearDown(tester.view.reset);
      const source =
          '| Left cell | Right cell |\n'
          '| --- | --- |\n'
          r'| before $a+b$ after | second $c+d$ end |';

      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: NativeMarkdown(
                    source: source,
                    fontSize: 15,
                    lineHeight: 1.65,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final formulas = tester
            .widgetList<NativeMathParagraphContent>(
              find.byType(NativeMathParagraphContent),
            )
            .expand((content) => content.formulas)
            .toList(growable: false);
        expect(formulas, hasLength(2));
        expect(formulas.map((formula) => formula.source.expression), [
          'a+b',
          'c+d',
        ]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets(
    'actual NativeMarkdown keeps 49.5px line advance at 2x around inline math',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: const NativeMarkdown(
                  source: r'Before $a+b$ after the formula.',
                  fontSize: 15,
                  lineHeight: 1.65,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final paragraph = _contentParagraph(tester, 0);
      final plainText = paragraph.text.toPlainText(
        includePlaceholders: true,
        includeSemanticsLabels: false,
      );
      final firstWord = plainText.indexOf('Before');
      final lastWord = plainText.indexOf('formula.');
      expect(firstWord, isNonNegative);
      expect(lastWord, isNonNegative);
      final firstLine = paragraph
          .getBoxesForSelection(
            TextSelection(baseOffset: firstWord, extentOffset: firstWord + 6),
          )
          .single
          .toRect();
      final secondLine = paragraph
          .getBoxesForSelection(
            TextSelection(baseOffset: lastWord, extentOffset: lastWord + 8),
          )
          .single
          .toRect();
      // The browser reference advances exactly 49.5px; Flutter's bundled
      // Ahem test font rounds this same line step to 50px.
      expect(secondLine.top - firstLine.top, closeTo(49.5, 0.6));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'NativeMarkdown drops empty allowbreak placeholders without inflating lines',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 900);
      addTearDown(tester.view.reset);
      const source =
          r'A long expression $x_1+\allowbreak x_2+\allowbreak x_3+\allowbreak x_4+\allowbreak x_5+\allowbreak x_6+\allowbreak x_7+\allowbreak x_8+\allowbreak x_9+\allowbreak x_{10}+\allowbreak x_{11}+\allowbreak x_{12}$ continues after the math.';
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: const NativeMarkdown(
                  source: source,
                  fontSize: 15,
                  lineHeight: 1.65,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final content = tester.widget<NativeMathParagraphContent>(
        find.byType(NativeMathParagraphContent),
      );
      final formula = content.formulas.single;
      expect(formula.source.expression, contains(r'\allowbreak'));
      expect(formula.parts, hasLength(12));

      final parts = find.byType(NativeMathPart);
      expect(parts, findsNWidgets(12));
      for (var index = 0; index < 12; index++) {
        final renderedMath = find.descendant(
          of: parts.at(index),
          matching: find.byType(Math),
        );
        expect(renderedMath, findsOneWidget);
        final size = tester.getSize(renderedMath);
        expect(size.width, greaterThan(0), reason: 'part $index has width');
        expect(size.height, greaterThan(0), reason: 'part $index has height');
      }

      final paragraph = _contentParagraph(tester, 0);
      final plainText = paragraph.text.toPlainText(
        includePlaceholders: true,
        includeSemanticsLabels: false,
      );
      final prosePrefixEnd =
          plainText.indexOf(' expression') + ' expression'.length;
      final proseBoxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: prosePrefixEnd),
      );
      expect(proseBoxes, hasLength(2));
      expect(
        proseBoxes.last.top - proseBoxes.first.top,
        closeTo(49.5, 0.6),
        reason: 'prose line height remains one 2x body line advance',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retains height-bearing Math beside an allowbreak', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: const NativeMarkdown(
              source: r'Before $x+\rule{0pt}{2em}\allowbreak y$ after.',
              fontSize: 15,
              lineHeight: 1.65,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final content = tester.widget<NativeMathParagraphContent>(
      find.byType(NativeMathParagraphContent),
    );
    final formula = content.formulas.single;
    expect(formula.source.expression, contains(r'\rule'));
    expect(formula.source.expression, contains(r'\allowbreak'));
    final renderedMaths = find.descendant(
      of: find.byType(NativeMathParagraphContent),
      matching: find.byType(Math),
    );
    final heights = [
      for (var index = 0; index < renderedMaths.evaluate().length; index++)
        tester.getSize(renderedMaths.at(index)).height,
    ];
    expect(heights, isNotEmpty);
    expect(heights.any((height) => height > 49.5), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retains CJK text and link recognizers across math', (
    tester,
  ) async {
    var tapped = false;
    final recognizer = TapGestureRecognizer()..onTap = () => tapped = true;
    addTearDown(recognizer.dispose);
    await _pumpParagraph(
      tester,
      width: 500,
      children: [
        Text.rich(
          TextSpan(
            style: const TextStyle(fontSize: 22, color: Colors.black),
            children: [
              TextSpan(text: 'Open', recognizer: recognizer),
              const TextSpan(text: ' 中文 '),
            ],
          ),
        ),
        _mathMarker('x+y'),
      ],
    );

    final paragraph = _contentParagraph(tester, 0);
    final box = paragraph
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 4),
        )
        .first;
    await tester.tapAt(box.toRect().center);
    expect(tapped, isTrue);
    expect(paragraph.text.toPlainText(), contains('中文'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders malformed inline source as red prose text', (
    tester,
  ) async {
    const malformed = r'\frac{a';
    await _pumpParagraph(
      tester,
      width: 500,
      children: [
        const Text('before '),
        _mathMarker(malformed),
        const Text(' after'),
      ],
    );

    final content = tester.widget<NativeMathParagraphContent>(
      find.byType(NativeMathParagraphContent),
    );
    expect(content.formulas, hasLength(1));
    expect(content.formulas.single.math.parseError, isNotNull);
    expect(content.formulas.single.parts, isEmpty);
    expect(
      find.descendant(
        of: find.byType(NativeMathParagraphContent),
        matching: find.byType(NativeMathPart),
      ),
      findsNothing,
    );
    final paragraph = _contentParagraph(tester, 0);
    expect(paragraph.text.toPlainText(), contains(r'\frac{a'));
    expect(_containsRedText(paragraph.text), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses marker body style when the paragraph starts with math', (
    tester,
  ) async {
    final marker = _mathMarker(
      'x+y',
      bodyFontSize: 28,
      bodyStyle: const TextStyle(
        fontFamily: 'HeadingFace',
        fontSize: 28,
        fontWeight: FontWeight.w600,
        color: Colors.purple,
      ),
    );
    await _pumpParagraph(tester, width: 400, children: [marker]);

    final paragraph = _contentParagraph(tester, 0);
    expect(paragraph.text.style?.fontFamily, 'HeadingFace');
    expect(paragraph.text.style?.fontSize, 28);
    expect(paragraph.text.style?.fontWeight, FontWeight.w600);
    expect(paragraph.text.style?.color, Colors.purple);
    expect(tester.takeException(), isNull);
  });

  testWidgets('display markers stay mounted between prose runs', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NativeMathParagraph(
            children: [
              const Text('before display'),
              _mathMarker('x=y', display: true),
              const Text('after display'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Column), findsOneWidget);
    expect(find.byType(NativeMarkdownMath), findsOneWidget);
    expect(find.byType(NativeMathTex), findsOneWidget);
    final contents = tester.widgetList<NativeMathParagraphContent>(
      find.byType(NativeMathParagraphContent),
    );
    expect(contents, hasLength(2));
    expect(contents.first.formulas, isEmpty);
    expect(contents.last.formulas, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

List<RenderBox> _mathPartBoxes(WidgetTester tester, int contentIndex) {
  final content = find.byType(NativeMathParagraphContent).at(contentIndex);
  final mathParts = find.descendant(of: content, matching: find.byType(Math));
  return [
    for (final element in mathParts.evaluate())
      element.renderObject! as RenderBox,
  ];
}

RenderParagraph _contentParagraph(WidgetTester tester, int index) {
  final content = tester.widget<NativeMathParagraphContent>(
    find.byType(NativeMathParagraphContent).at(index),
  );
  return tester.renderObject<RenderParagraph>(find.byWidget(content.child));
}

Future<void> _pumpParagraph(
  WidgetTester tester, {
  required double width,
  required List<Widget> children,
  double scale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData.fromView(
            tester.view,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: NativeMathParagraph(children: children),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

NativeMarkdownMath _mathMarker(
  String expression, {
  bool display = false,
  double bodyFontSize = 24,
  double lineHeight = 1.65,
  TextStyle? bodyStyle,
}) {
  final baseStyle =
      bodyStyle ??
      TextStyle(
        fontSize: bodyFontSize,
        height: lineHeight,
        color: Colors.black,
      );
  return NativeMarkdownMath(
    math: NativeMathTex(
      expression,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: baseStyle.copyWith(fontSize: bodyFontSize * 1.08),
      settings: const TexParserSettings(throwOnError: false),
      onErrorFallback: (_) => const Text('unexpected fallback'),
    ),
    bodyFontSize: bodyFontSize,
    lineHeight: lineHeight,
    display: display,
    bodyStyle: baseStyle,
  );
}

NativeMathParagraphContent _paragraphContent(WidgetTester tester, int index) =>
    tester.widget<NativeMathParagraphContent>(
      find.byType(NativeMathParagraphContent).at(index),
    );

bool _containsRedText(InlineSpan span) {
  if (span is! TextSpan) return false;
  if (span.style?.color == const Color(0xffcc0000)) return true;
  return span.children?.any(_containsRedText) ?? false;
}
