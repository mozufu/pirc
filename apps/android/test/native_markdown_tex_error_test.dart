import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/native_math_block.dart';
import 'package:pirc_render/src/native_math_error.dart';
import 'package:pirc_render/src/native_math_paragraph.dart';
import 'package:pirc_render/src/native_tex_adapter.dart';
import 'live_test.dart' show theme;

Widget host(String source, double scale) => MaterialApp(
  theme: theme.build(Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: NativeMarkdown(source: source, fontSize: 15, lineHeight: 1.65),
      ),
    ),
  ),
);

Math model(WidgetTester t, int index) {
  final inlineModels = t
      .widgetList<NativeMathParagraphContent>(
        find.byType(NativeMathParagraphContent),
      )
      .expand((content) => content.formulas)
      .map((formula) => formula.math)
      .toList(growable: false);
  if (inlineModels.length > index) {
    return inlineModels[index];
  }
  final element = find.byType(NativeMathTex).evaluate().elementAt(index);
  return (element.widget as NativeMathTex).resolve(element).math;
}

void main() {
  for (final (kind, source, display) in [
    ('inline', r'$x+\pircunknown+y$', false),
    (
      'display',
      r'$$'
          '\n'
          r'x+\pircunknown+y'
          '\n'
          r'$$',
      true,
    ),
    (
      'fenced',
      '```math\n'
          r'x+\pircunknown+y'
          '\n```',
      true,
    ),
  ]) {
    testWidgets(
      '$kind Markdown preserves math with an unknown control at 1x and 2x',
      (t) async {
        for (final scale in [1.0, 2.0]) {
          await t.pumpWidget(host(source, scale));
          await t.pumpAndSettle();
          final equation = model(t, 0);
          expect(equation.parseError, isNull);
          expect(equation.ast, isNotNull);
          expect(equation.options!.fontSize, closeTo(16.2 * scale, .001));
          expect(find.byType(NativeMathErrorText), findsNothing);
          if (!display) {
            final content = t.widget<NativeMathParagraphContent>(
              find.byType(NativeMathParagraphContent),
            );
            expect(content.formulas.single.math.ast, isNotNull);
            expect(content.formulas.single.parts, isNotEmpty);
          }
          expect(
            find.byType(NativeMathDisplayBlock),
            display ? findsOneWidget : findsNothing,
          );
          expect(t.takeException(), isNull);
        }
        await t.pumpWidget(const SizedBox());
      },
    );
  }
  for (final (kind, source, display) in [
    ('inline', r'$x+{y$', false),
    (
      'display',
      r'$$'
          '\n'
          r'x+{y'
          '\n'
          r'$$',
      true,
    ),
    (
      'fenced',
      '```tex\n'
          r'x+{y'
          '\n```',
      true,
    ),
  ]) {
    testWidgets(
      '$kind syntax error uses body text without successful display margins',
      (t) async {
        for (final scale in [1.0, 2.0]) {
          await t.pumpWidget(host(source, scale));
          await t.pumpAndSettle();
          expect(model(t, 0).parseError, isNotNull);
          expect(find.byType(NativeMathDisplayBlock), findsNothing);
          if (display) {
            final error = t.widget<NativeMathErrorText>(
              find.byType(NativeMathErrorText),
            );
            expect(error.source, r'x+{y');
            expect(error.block, isTrue);
            final fallback = t.widget<Text>(find.text(r'x+{y'));
            expect(fallback.style!.fontFamily, isNot('monospace'));
            expect(fallback.style!.fontSize, 15);
            expect(fallback.style!.height, 1.65);
            expect(fallback.style!.color, const Color(0xffcc0000));
            expect(
              MediaQuery.textScalerOf(t.element(find.text(r'x+{y'))).scale(15),
              15 * scale,
            );
          } else {
            expect(find.byType(NativeMathErrorText), findsNothing);
            final content = t.widget<NativeMathParagraphContent>(
              find.byType(NativeMathParagraphContent),
            );
            expect(content.formulas.single.math.parseError, isNotNull);
            expect(_redRichText(content.child), contains(r'x+{y'));
          }
          expect(t.takeException(), isNull);
        }
        await t.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'unknown text preserves neighboring equations and syntax errors stay isolated',
    (t) async {
      await t.pumpWidget(host(r'Before $a+b$ mid $\frac{1}$ after $c+d$.', 1));
      await t.pumpAndSettle();
      final content = t.widget<NativeMathParagraphContent>(
        find.byType(NativeMathParagraphContent),
      );
      expect(content.formulas, hasLength(3));
      expect(content.formulas.map((formula) => formula.source.expression), [
        r'a+b',
        r'\frac{1}',
        r'c+d',
      ]);
      expect(model(t, 0).parseError, isNull);
      expect(model(t, 1).parseError, isNotNull);
      expect(model(t, 2).parseError, isNull);
      expect(find.byType(NativeMathErrorText), findsNothing);
      expect(_redRichText(content.child), contains(r'\frac{1}'));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('recursive macro still reaches the pinned expansion limit', (
    t,
  ) async {
    await t.pumpWidget(
      host(r'$\newcommand{\pircLoop}{\pircLoop}\pircLoop$', 1),
    );
    await t.pumpAndSettle();
    expect(model(t, 0).parseError, isNotNull);
    final content = t.widget<NativeMathParagraphContent>(
      find.byType(NativeMathParagraphContent),
    );
    expect(_redRichText(content.child), contains(r'\newcommand'));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}

String _redRichText(Widget child) {
  if (child is! RichText) return '';
  final output = StringBuffer();
  void visit(InlineSpan span, Color? inheritedColor) {
    if (span is! TextSpan) return;
    final color = span.style?.color ?? inheritedColor;
    if (color == const Color(0xffcc0000)) output.write(span.text ?? '');
    for (final nested in span.children ?? const <InlineSpan>[]) {
      visit(nested, color);
    }
  }

  visit(child.text, null);
  return output.toString();
}
