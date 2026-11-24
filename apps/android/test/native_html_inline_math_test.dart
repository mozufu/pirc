import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_math_fork/flutter_math.dart'
    show Math, MathStyle, TexParserSettings;
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_render/src/native_inline_math.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/native_math_block.dart';
import 'package:pirc_render/src/native_math_error.dart';
import 'package:pirc_render/src/native_math_paragraph.dart';
import 'package:pirc_render/src/native_math_tags.dart';
import 'package:pirc_render/src/native_tex_adapter.dart';

import 'live_test.dart' show theme;

md.Element _element(
  String tag, {
  Map<String, String> attributes = const {},
  List<md.Node> children = const [],
}) {
  final element = md.Element(tag, children);
  element.attributes.addAll(attributes);
  return element;
}

md.Element _math(String expression, {bool display = false}) => _element(
  'pirc-math',
  attributes: {if (display) 'display': 'true'},
  children: [md.Text(expression)],
);

class _MathBuilder extends fm.MarkdownElementBuilder {
  @override
  bool isBlockElement() => false;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    registerNativeTexExtensions();
    final bodyFontSize =
        parentStyle?.fontSize ?? preferredStyle?.fontSize ?? 15;
    final lineHeight = parentStyle?.height ?? 1.65;
    final display = element.attributes['display'] == 'true';
    final color = parentStyle?.color;
    return NativeMarkdownMath(
      bodyFontSize: bodyFontSize,
      lineHeight: lineHeight,
      bodyStyle: parentStyle,
      display: display,
      math: NativeMathTex(
        element.textContent,
        mathStyle: display ? MathStyle.display : MathStyle.text,
        settings: TexParserSettings(
          displayMode: display,
          throwOnError: false,
          maxExpand: 500,
        ),
        textStyle: TextStyle(fontSize: bodyFontSize * 1.08, color: color),
        onParsed: display
            ? (_, child) => NativeMathDisplayBlock(
                bodyFontSize: bodyFontSize,
                mathFontSize: bodyFontSize * 1.08,
                child: child,
              )
            : (_, child) => NativeInlineMath(
                math: child as Math,
                bodyFontSize: bodyFontSize,
                lineHeight: lineHeight,
              ),
        onErrorFallback: (_) => NativeMathErrorText(
          source: element.textContent,
          bodyFontSize: bodyFontSize,
          lineHeight: lineHeight,
          block: display,
          fontFamily: parentStyle?.fontFamily,
        ),
      ),
    );
  }
}

Widget _htmlPage(
  List<md.Node> nodes, {
  double textScale = 1,
  double width = 600,
  ValueChanged<NativeHtmlLink>? onNavigate,
}) => MaterialApp(
  theme: theme.build(Brightness.light),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: width,
            child: NativeHtmlDocument(
              nodes: nodes,
              style: const TextStyle(fontSize: 15),
              styles: fm.MarkdownStyleSheet(),
              builders: {'pirc-math': _MathBuilder()},
              onNavigate: onNavigate,
              checkboxBuilder: (checked) => NativeTaskCheckbox(
                key: ValueKey('task-checkbox-$checked'),
                checked: checked,
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

TextStyle? _styleForText(
  InlineSpan span,
  String needle, [
  TextStyle inherited = const TextStyle(),
]) {
  if (span is! TextSpan) return null;
  final effective = inherited.merge(span.style);
  if (span.text?.contains(needle) == true) return effective;
  for (final child in span.children ?? const <InlineSpan>[]) {
    final result = _styleForText(child, needle, effective);
    if (result != null) return result;
  }
  return null;
}

Finder _richTextContaining(String text) => find.byWidgetPredicate(
  (widget) => widget is RichText && widget.text.toPlainText().contains(text),
);

void main() {
  testWidgets('math-only HTML span keeps its explicit CSS line height', (
    tester,
  ) async {
    await tester.pumpWidget(
      _htmlPage([
        _element(
          'span',
          attributes: {'style': 'font-size:48px;line-height:1.65'},
          children: [_math('a+b')],
        ),
      ], textScale: 2),
    );
    await tester.pumpAndSettle();
    final markerWidgets = tester
        .widgetList<NativeMarkdownMath>(find.byType(NativeMarkdownMath))
        .toList();
    expect(markerWidgets, hasLength(1));
    final styled = markerWidgets.single;
    expect(styled.bodyFontSize, closeTo(96, .01));
    expect(styled.lineHeight, closeTo(1.65, .001));
    expect(styled.disableTextScaling, isTrue);

    final styledTexFinder = find.descendant(
      of: find.byWidget(styled),
      matching: find.byType(NativeMathTex),
    );
    final styledTex = tester.widget<NativeMathTex>(styledTexFinder);
    expect(styledTex.textStyle?.fontSize, closeTo(103.68, .02));
    final resolvedMath = styledTex
        .resolve(tester.element(styledTexFinder))
        .math;
    expect(resolvedMath.options?.fontSize, closeTo(103.68, .02));

    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      _htmlPage([
        _element(
          'span',
          attributes: {'style': 'font-size:48px;line-height:1.65'},
          children: [_math(r'x+{y')],
        ),
      ], textScale: 2),
    );
    await tester.pumpAndSettle();
    final errorTexFinder = find.byType(NativeMathTex);
    final errorTex = tester.widget<NativeMathTex>(errorTexFinder);
    final errorMath = errorTex.resolve(tester.element(errorTexFinder)).math;
    expect(errorMath.parseError, isNotNull);
    final error = errorTex.onErrorFallback(errorMath.parseError!);
    expect(error, isA<NativeMathErrorText>());
    final errorText = error as NativeMathErrorText;
    expect(errorText.bodyFontSize, closeTo(96, .01));
    expect(errorText.lineHeight, closeTo(1.65, .001));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      _htmlPage([
        _element('span', children: [_math('x+y')]),
      ], textScale: 2),
    );
    await tester.pumpAndSettle();
    final rootFallback = tester.widget<NativeMarkdownMath>(
      find.byType(NativeMarkdownMath),
    );
    expect(rootFallback.bodyFontSize, closeTo(30, .01));
    final rootTexFinder = find.descendant(
      of: find.byWidget(rootFallback),
      matching: find.byType(NativeMathTex),
    );
    final rootTex = tester.widget<NativeMathTex>(rootTexFinder);
    expect(
      rootTex.resolve(tester.element(rootTexFinder)).math.options?.fontSize,
      closeTo(32.4, .02),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('raw HTML inline math joins its styled prose RichText run', (
    tester,
  ) async {
    final span = _element(
      'span',
      attributes: {'style': 'font-size:48px;color:#800080;font-weight:bold'},
      children: [md.Text('Before '), _math('a+b'), md.Text(' after')],
    );
    await tester.pumpWidget(_htmlPage([span], textScale: 2));
    await tester.pumpAndSettle();

    expect(find.byType(NativeMathParagraphContent), findsOneWidget);
    final content = tester.widget<NativeMathParagraphContent>(
      find.byType(NativeMathParagraphContent),
    );
    expect(content.formulas, hasLength(1));
    expect(content.formulas.single.source.expression, 'a+b');
    expect(content.formulas.single.parts, isNotEmpty);
    expect(
      find.descendant(
        of: find.byType(NativeMathParagraphContent),
        matching: find.byType(NativeMathPart),
      ),
      findsNWidgets(content.formulas.single.parts.length),
    );

    final prose = tester.widget<RichText>(_richTextContaining('Before'));
    expect(prose.text.toPlainText(), contains('Before'));
    expect(prose.text.toPlainText(), contains('after'));
    final before = _styleForText(prose.text, 'Before');
    expect(before?.fontSize, closeTo(96, .01));
    expect(before?.color, const Color(0xff800080));
    expect(before?.fontWeight, FontWeight.bold);
    expect(before?.fontFamily, isNotNull);
    expect(
      content.formulas.single.source.textStyle?.fontSize,
      closeTo(103.68, .02),
    );
    expect(
      content.formulas.single.source.textStyle?.color,
      const Color(0xff800080),
    );
    expect(
      content.formulas.single.source.textStyle?.fontWeight,
      FontWeight.normal,
    );
    expect(
      content.formulas.single.source.textStyle?.fontStyle,
      FontStyle.normal,
    );
    expect(content.formulas.single.source.textStyle?.fontFamily, isNull);
    expect(
      content.formulas.single.math.options?.mathFontOptions?.fontWeight ??
          FontWeight.normal,
      FontWeight.normal,
      reason: 'KaTeX resets prose bolding on its own math font',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('HTML heading inheritance styles its inline math', (
    tester,
  ) async {
    final heading = _element(
      'h2',
      attributes: {'style': 'font-size:36px;line-height:1.2;color:#800080'},
      children: [md.Text('Before '), _math('a+b'), md.Text(' after')],
    );
    await tester.pumpWidget(_htmlPage([heading], textScale: 2));
    await tester.pumpAndSettle();

    expect(find.byType(NativeMathParagraphContent), findsOneWidget);
    final content = tester.widget<NativeMathParagraphContent>(
      find.byType(NativeMathParagraphContent),
    );
    expect(
      content.formulas.single.source.textStyle?.fontSize,
      closeTo(77.76, .02),
    );
    expect(
      content.formulas.single.source.textStyle?.color,
      const Color(0xff800080),
    );
    final prose = tester.widget<RichText>(_richTextContaining('Before'));
    final before = _styleForText(prose.text, 'Before');
    expect(before?.fontSize, closeTo(72, .01));
    expect(before?.height, closeTo(1.2, .001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('math inside a raw HTML link remains tappable', (tester) async {
    NativeHtmlLink? tapped;
    var tapCount = 0;
    final link = _element(
      'a',
      attributes: {'href': '/math-link'},
      children: [_math('a+b'), md.Text(' linked')],
    );
    final span = _element(
      'span',
      children: [md.Text('Before '), link, md.Text(' after')],
    );
    await tester.pumpWidget(
      _htmlPage(
        [span],
        onNavigate: (value) {
          tapped = value;
          tapCount++;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NativeMathParagraphContent), findsOneWidget);
    final part = find.byType(NativeMathPart).first;
    await tester.tap(part, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(tapped?.href, '/math-link');
    expect(tapCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a control placeholder stays beside breakable HTML math', (
    tester,
  ) async {
    final span = _element(
      'span',
      children: [
        md.Text('Before '),
        _math('a+b'),
        md.Text(' '),
        _element(
          'input',
          attributes: {'type': 'checkbox', 'checked': '', 'name': 'task'},
        ),
        md.Text(' after'),
      ],
    );
    await tester.pumpWidget(_htmlPage([span]));
    await tester.pumpAndSettle();

    expect(find.byType(NativeMathParagraphContent), findsOneWidget);
    expect(find.byType(NativeTaskCheckbox), findsOneWidget);
    final content = tester.widget<NativeMathParagraphContent>(
      find.byType(NativeMathParagraphContent),
    );
    expect(content.formulas.single.parts, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tagged display math keeps resolved HTML size at 2x', (
    tester,
  ) async {
    final span = _element(
      'span',
      attributes: {'style': 'font-size:48px;color:#800080'},
      children: [
        md.Text('Before '),
        _math('x+y\\tag{A}', display: true),
        md.Text(' after'),
      ],
    );
    await tester.pumpWidget(_htmlPage([span], textScale: 2));
    await tester.pumpAndSettle();

    expect(find.byType(NativeMathDisplayBlock), findsOneWidget);
    expect(find.byType(NativeTaggedMath), findsOneWidget);
    final block = tester.widget<NativeMathDisplayBlock>(
      find.byType(NativeMathDisplayBlock),
    );
    expect(block.bodyFontSize, closeTo(96, .01));
    expect(block.mathFontSize, closeTo(103.68, .02));
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline parse errors remain prose and preserve inherited size', (
    tester,
  ) async {
    final span = _element(
      'span',
      attributes: {'style': 'font-size:48px;color:#800080'},
      children: [md.Text('Before '), _math('x+{y'), md.Text(' after')],
    );
    await tester.pumpWidget(_htmlPage([span], textScale: 2));
    await tester.pumpAndSettle();

    expect(find.byType(NativeMathParagraphContent), findsOneWidget);
    final content = tester.widget<NativeMathParagraphContent>(
      find.byType(NativeMathParagraphContent),
    );
    expect(content.formulas.single.math.parseError, isNotNull);
    expect(find.byType(NativeMathPart), findsNothing);
    final prose = tester.widget<RichText>(_richTextContaining('Before'));
    expect(prose.text.toPlainText(), contains('x+{y'));
    final red = _styleForText(prose.text, 'x+{y');
    expect(red?.fontSize, closeTo(96, .01));
    expect(red?.color, const Color(0xffcc0000));
    expect(tester.takeException(), isNull);
  });

  testWidgets('display parse error does not rescale its HTML font twice', (
    tester,
  ) async {
    final span = _element(
      'span',
      attributes: {'style': 'font-size:48px;color:#800080;line-height:1.65'},
      children: [
        md.Text('Before '),
        _math('x+{y', display: true),
        md.Text(' after'),
      ],
    );
    await tester.pumpWidget(_htmlPage([span], textScale: 2));
    await tester.pumpAndSettle();

    expect(find.byType(NativeMathDisplayBlock), findsNothing);
    expect(find.byType(NativeMathErrorText), findsOneWidget);
    final error = tester.widget<NativeMathErrorText>(
      find.byType(NativeMathErrorText),
    );
    expect(error.bodyFontSize, closeTo(96, .01));
    final surrounding = tester.widget<RichText>(_richTextContaining('Before'));
    final surroundingStyle = _styleForText(surrounding.text, 'Before');
    expect(surroundingStyle?.height, closeTo(1.65, .001));
    expect(error.lineHeight, closeTo(surroundingStyle!.height!, .001));
    final text = tester.widget<Text>(
      find.descendant(
        of: find.byType(NativeMathErrorText),
        matching: find.byType(Text),
      ),
    );
    expect(text.style?.fontSize, closeTo(96, .01));
    expect(text.style?.color, const Color(0xffcc0000));
    expect(tester.takeException(), isNull);
  });
}
