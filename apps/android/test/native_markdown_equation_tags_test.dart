import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_math_fork/src/ast/nodes/symbol.dart';
import 'package:flutter_math_fork/src/ast/syntax_tree.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_equation_numbers.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/native_math_tags.dart';
import 'package:pirc_render/src/native_math_paragraph.dart';
import 'live_test.dart' show theme;
// ignore_for_file: implementation_imports

String text(GreenNode node) => node is SymbolNode
    ? node.symbol
    : node.children.whereType<GreenNode>().map(text).join();
List<String> tags(WidgetTester t) => [
  for (final widget in t.widgetList<NativeTaggedMath>(
    find.byType(NativeTaggedMath),
  ))
    for (final tag in widget.tags) text((tag.math as Math).ast!.greenRoot),
];
Widget host(Widget child, {double scale = 1}) => MaterialApp(
  theme: theme.build(Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);
String block(String source) => '\$\$\n$source\n\$\$';

void main() {
  testWidgets(
    'real Markdown tags and row numbers remain separate from the body',
    (t) async {
      t.view.physicalSize = const Size(390, 1200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      for (final scale in [1.0, 2.0]) {
        await t.pumpWidget(
          host(
            NativeMarkdown(
              source: [
                block(r'x+y\tag{A}'),
                block(r'\begin{gather}a=b\\c=d\end{gather}'),
                block(
                  r'\begin{align}a&=b\tag*{M}\\c&=d\notag\\e&=f\end{align}',
                ),
                block(r'\begin{equation}z=3\end{equation}'),
                block(r'\begin{gather}p=q\tag{A}\\r=s\tag*{B}\end{gather}'),
              ].join('\n\n'),
              fontSize: 15,
              lineHeight: 1.65,
            ),
            scale: scale,
          ),
        );
        await t.pumpAndSettle();
        expect(tags(t), ['(A)', '(1)', '(2)', 'M', '(3)', '(4)', '(A)', 'B']);
        expect(
          t
              .widgetList<NativeMathParagraphContent>(
                find.byType(NativeMathParagraphContent),
              )
              .expand((content) => content.formulas)
              .any((formula) => formula.math.parseError != null),
          isFalse,
        );
        expect(t.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'numbering continues across Markdown siblings and resets on replacement',
    (t) async {
      Future<void> show(List<String> sources) async {
        await t.pumpWidget(
          host(
            NativeEquationNumberDocument(
              child: Column(
                children: [
                  for (var i = 0; i < sources.length; i++)
                    NativeMarkdown(key: ValueKey(i), source: sources[i]),
                ],
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
      }

      await show([
        block(r'\begin{equation}x=1\end{equation}'),
        block(r'\begin{equation}y=2\end{equation}'),
      ]);
      expect(tags(t), ['(1)', '(2)']);
      await show([block(r'\begin{equation}z=3\end{equation}')]);
      expect(tags(t), ['(1)']);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('stable streaming chunks and completion preserve counter order', (
    t,
  ) async {
    final first = block(r'\begin{equation}x=1\end{equation}');
    final source =
        '$first\n\nProse.\n\n${block(r'\begin{equation}y=2\end{equation}')}';
    await t.pumpWidget(host(NativeMarkdown(source: first, streaming: true)));
    await t.pumpAndSettle();
    expect(tags(t), ['(1)']);
    await t.pumpWidget(host(NativeMarkdown(source: source, streaming: true)));
    await t.pump(const Duration(milliseconds: 100));
    await t.pumpAndSettle();
    expect(tags(t), ['(1)', '(2)']);
    await t.pumpWidget(host(NativeMarkdown(source: source, streaming: false)));
    await t.pumpAndSettle();
    expect(tags(t), ['(1)', '(2)']);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'ordinary inline tag errors but inline double-dollar uses display tags',
    (t) async {
      await t.pumpWidget(
        host(const NativeMarkdown(source: r'Before $x+y\tag{I}$ after.')),
      );
      await t.pumpAndSettle();
      final formulas = [
        for (final content in t.widgetList<NativeMathParagraphContent>(
          find.byType(NativeMathParagraphContent),
        ))
          ...content.formulas,
      ];
      expect(formulas, hasLength(1));
      expect(
        formulas.single.math.parseError?.message,
        contains(r'\tag works only in display equations'),
      );
      bool hasRedError(InlineSpan span, [TextStyle? parent]) {
        if (span is! TextSpan) return false;
        final style = parent?.merge(span.style) ?? span.style;
        if (span.text == r'x+y\tag{I}' &&
            style?.color == const Color(0xffcc0000)) {
          return true;
        }
        return span.children?.any((child) => hasRedError(child, style)) ??
            false;
      }

      expect(
        t
            .widgetList<RichText>(
              find.byWidgetPredicate((widget) => widget is RichText),
            )
            .any((text) => hasRedError(text.text)),
        isTrue,
      );
      expect(tags(t), isEmpty);
      await t.pumpWidget(
        host(const NativeMarkdown(source: r'Before $$x+y\tag{D}$$ after.')),
      );
      await t.pumpAndSettle();
      expect(tags(t), ['(D)']);
      expect(t.takeException(), isNull);
    },
  );
}
