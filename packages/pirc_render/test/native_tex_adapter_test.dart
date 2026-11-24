import 'package:flutter/material.dart';
// ignore_for_file: implementation_imports

import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_math_fork/src/ast/nodes/equation_array.dart';
import 'package:flutter_math_fork/src/ast/nodes/style.dart';
import 'package:flutter_math_fork/src/ast/syntax_tree.dart';
import 'package:flutter_math_fork/src/parser/tex/parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_tex_adapter.dart';

void main() {
  setUpAll(registerNativeTexExtensions);

  group('native TeX extensions', () {
    testWidgets('mathchoice selects the branch for the current math style', (
      tester,
    ) async {
      const settings = TexParserSettings(
        displayMode: true,
        maxExpand: 500,
        strict: Strict.ignore,
      );
      final choices = [
        (MathStyle.display, 'display'),
        (MathStyle.text, 'text'),
        (MathStyle.script, 'script'),
        (MathStyle.scriptscript, 'scriptscript'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                for (final (style, key) in choices)
                  SizedBox(
                    key: ValueKey(key),
                    child: Math.tex(
                      r'\mathchoice{\rule{40pt}{5pt}}{\rule{30pt}{5pt}}{\rule{20pt}{5pt}}{\rule{10pt}{5pt}}',
                      mathStyle: style,
                      settings: settings,
                      onErrorFallback: (error) => Text(error.message),
                    ),
                  ),
                SizedBox(
                  key: const ValueKey('script-context-choice'),
                  child: Math.tex(
                    r'x^{\mathchoice{\rule{40pt}{5pt}}{\rule{30pt}{5pt}}{\rule{20pt}{5pt}}{\rule{10pt}{5pt}}}',
                    settings: settings,
                    onErrorFallback: (error) => Text(error.message),
                  ),
                ),
                SizedBox(
                  key: const ValueKey('script-context-expected'),
                  child: Math.tex(
                    r'x^{\rule{20pt}{5pt}}',
                    settings: settings,
                    onErrorFallback: (error) => Text(error.message),
                  ),
                ),
                SizedBox(
                  key: const ValueKey('scriptscript-context-choice'),
                  child: Math.tex(
                    r'x^{y^{\mathchoice{\rule{40pt}{5pt}}{\rule{30pt}{5pt}}{\rule{20pt}{5pt}}{\rule{10pt}{5pt}}}}',
                    settings: settings,
                    onErrorFallback: (error) => Text(error.message),
                  ),
                ),
                SizedBox(
                  key: const ValueKey('scriptscript-context-expected'),
                  child: Math.tex(
                    r'x^{y^{\rule{10pt}{5pt}}}',
                    settings: settings,
                    onErrorFallback: (error) => Text(error.message),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final widths = {
        for (final (_, key) in choices)
          key: tester.getSize(find.byKey(ValueKey(key))).width,
      };
      expect(widths['display'], greaterThan(widths['text']!));
      expect(widths['text'], greaterThan(widths['script']!));
      expect(widths['script'], greaterThan(widths['scriptscript']!));
      expect(
        tester.getSize(find.byKey(const ValueKey('script-context-choice'))),
        tester.getSize(find.byKey(const ValueKey('script-context-expected'))),
      );
      expect(
        tester.getSize(
          find.byKey(const ValueKey('scriptscript-context-choice')),
        ),
        tester.getSize(
          find.byKey(const ValueKey('scriptscript-context-expected')),
        ),
      );
      expect(find.textContaining('Undefined control sequence'), findsNothing);
    });

    testWidgets(
      'mathchoice rebuilds mixed atom boundaries in the selected style',
      (tester) async {
        const settings = TexParserSettings(
          displayMode: true,
          maxExpand: 500,
          strict: Strict.ignore,
        );
        const choice = r'a\mathchoice{=}{+}{\sum}{x}b';
        final examples = <(String, MathStyle, String, String)>[
          ('inline', MathStyle.text, choice, 'a+b'),
          ('display', MathStyle.display, choice, 'a=b'),
          (
            'script',
            MathStyle.text,
            r'x^{a\mathchoice{=}{+}{\sum}{x}b}',
            r'x^{a\sum b}',
          ),
          (
            'scriptscript',
            MathStyle.text,
            r'x^{y^{a\mathchoice{=}{+}{\sum}{x}b}}',
            r'x^{y^{axb}}',
          ),
          (
            'explicit-displaystyle',
            MathStyle.text,
            r'\displaystyle a\mathchoice{=}{+}{\sum}{x}b',
            r'\displaystyle a=b',
          ),
          (
            'explicit-textstyle',
            MathStyle.display,
            r'\textstyle a\mathchoice{=}{+}{\sum}{x}b',
            r'\textstyle a+b',
          ),
        ];
        Widget formula(String source, MathStyle style) => NativeMathTex(
          source,
          mathStyle: style,
          settings: settings,
          textStyle: const TextStyle(fontSize: 20, color: Colors.black),
          onErrorFallback: (error) => Text(error.message),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final (id, style, mixed, literal) in examples) ...[
                      SizedBox(
                        key: ValueKey('$id-mixed'),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: formula(mixed, style),
                        ),
                      ),
                      SizedBox(
                        key: ValueKey('$id-literal'),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: formula(literal, style),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        for (final (id, _, _, _) in examples) {
          final mixedFinder = find.descendant(
            of: find.byKey(ValueKey('$id-mixed')),
            matching: find.byType(Math),
          );
          final literalFinder = find.descendant(
            of: find.byKey(ValueKey('$id-literal')),
            matching: find.byType(Math),
          );
          final mixedRender = tester.renderObject<RenderBox>(mixedFinder);
          final literalRender = tester.renderObject<RenderBox>(literalFinder);
          expect(
            mixedRender.size.width,
            closeTo(literalRender.size.width, 0.01),
            reason: id,
          );
        }
        expect(find.text('tex error'), findsNothing);
        expect(find.textContaining('Undefined control sequence'), findsNothing);
      },
    );

    testWidgets(
      'smash parses optional top and bottom flags and resets metrics',
      (tester) async {
        const settings = TexParserSettings(
          displayMode: true,
          maxExpand: 500,
          strict: Strict.ignore,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  for (final (source, key) in [
                    (r'\frac{x}{y}', 'plain'),
                    (r'\smash{\frac{x}{y}}', 'both'),
                    (r'\smash[t]{\frac{x}{y}}', 'top'),
                    (r'\smash[b]{\frac{x}{y}}', 'bottom'),
                    (r'\smash[]{\frac{x}{y}}', 'empty'),
                    (r'\smash[q]{\frac{x}{y}}', 'invalid'),
                  ])
                    SizedBox(
                      key: ValueKey(key),
                      child: Math.tex(
                        source,
                        settings: settings,
                        onErrorFallback: (error) => Text(error.message),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final plain = tester.getSize(find.byKey(const ValueKey('plain')));
        final both = tester.getSize(find.byKey(const ValueKey('both')));
        final top = tester.getSize(find.byKey(const ValueKey('top')));
        final bottom = tester.getSize(find.byKey(const ValueKey('bottom')));
        final empty = tester.getSize(find.byKey(const ValueKey('empty')));
        final invalid = tester.getSize(find.byKey(const ValueKey('invalid')));
        expect(both.width, closeTo(plain.width, 0.01));
        expect(top.width, closeTo(plain.width, 0.01));
        expect(bottom.width, closeTo(plain.width, 0.01));
        expect(both.height, lessThan(plain.height));
        expect(empty, plain);
        expect(invalid, plain);
        expect(find.textContaining('Undefined control sequence'), findsNothing);
      },
    );

    test('gather AST carries KaTeX display style and 3pt jot spacing', () {
      for (final source in [
        r'\begin{gather}a=b\\c=d\end{gather}',
        r'\left\{\begin{gathered}a=b\\c=d\end{gathered}\right.',
      ]) {
        final root = TexParser(
          source,
          const TexParserSettings(
            displayMode: true,
            maxExpand: 500,
            strict: Strict.ignore,
          ),
        ).parse();
        final arrays = <EquationArrayNode>[];
        void visit(GreenNode node) {
          if (node is EquationArrayNode) arrays.add(node);
          for (final child in node.children) {
            if (child != null) visit(child);
          }
        }

        visit(root);
        expect(arrays, hasLength(1));
        final array = arrays.single;
        expect(array.addJot, isTrue);
        expect(array.body, hasLength(2));
        for (final row in array.body) {
          expect(row.children, hasLength(1));
          final style = row.children.single as StyleNode;
          expect(style.optionsDiff.style, MathStyle.display);
        }
      }
    });

    testWidgets('gather variants are centered display-style equation rows', (
      tester,
    ) async {
      final errors = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                for (final source in [
                  r'\begin{gather}a=b\\c=d\end{gather}',
                  r'\begin{gather*}a=b\\c=d\end{gather*}',
                  r'\left\{\begin{gathered}a=b\\c=d\end{gathered}\right.',
                ])
                  Math.tex(
                    source,
                    mathStyle: MathStyle.display,
                    settings: const TexParserSettings(
                      displayMode: true,
                      maxExpand: 500,
                      strict: Strict.ignore,
                    ),
                    onErrorFallback: (error) {
                      errors.add(error.message);
                      return const Text('tex error');
                    },
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(errors, isEmpty);
      expect(find.text('tex error'), findsNothing);
    });

    testWidgets(
      'gather applies jot only between rows and preserves explicit row gaps',
      (tester) async {
        const settings = TexParserSettings(
          displayMode: true,
          maxExpand: 500,
          strict: Strict.ignore,
        );
        final formulas = <String, String>{
          'one': r'\begin{gather}a=b\end{gather}',
          'two': r'\begin{gather}a=b\\c=d\end{gather}',
          'three': r'\begin{gather}a=b\\c=d\\e=f\end{gather}',
        };
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final entry in formulas.entries)
                      SizedBox(
                        key: ValueKey(entry.key),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: NativeMathTex(
                            entry.value,
                            mathStyle: MathStyle.display,
                            settings: settings,
                            textStyle: const TextStyle(
                              fontSize: 16.2,
                              color: Colors.black,
                            ),
                            onErrorFallback: (error) => Text(error.message),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final heights = <String, double>{};
        for (final id in formulas.keys) {
          final finder = find.descendant(
            of: find.byKey(ValueKey(id)),
            matching: find.byType(Math),
          );
          // Automatic row labels have their own Math widgets. Measure the
          // equation body, whose array metrics remain the contract here.
          expect(
            tester
                .widget<Math>(finder.first)
                .ast!
                .greenRoot
                .children
                .whereType<EquationArrayNode>(),
            hasLength(1),
          );
          heights[id] = tester.getSize(finder.first).height;
        }
        expect(
          heights['two']! - heights['one']!,
          closeTo(heights['three']! - heights['two']!, 0.02),
        );
        expect(heights['two'], closeTo(43.734375, 0.04));

        final gapRoot = TexParser(
          r'\begin{gather}a=b\\[1em]c=d\end{gather}',
          settings,
        ).parse();
        EquationArrayNode? gapArray;
        void findArray(GreenNode node) {
          if (node is EquationArrayNode) gapArray = node;
          for (final child in node.children) {
            if (child != null) findArray(child);
          }
        }

        findArray(gapRoot);
        expect(gapArray, isNotNull);
        expect(gapArray!.rowSpacings.first.toString(), '1.0em');
        expect(gapArray!.rowSpacings.last.toString(), '0.0pt');
        expect(find.textContaining('Undefined control sequence'), findsNothing);
      },
    );

    testWidgets('gather remains display-only and rejects extra columns', (
      tester,
    ) async {
      String? inlineError;
      String? columnsError;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Math.tex(
                  r'\begin{gather}a=b\end{gather}',
                  mathStyle: MathStyle.text,
                  settings: const TexParserSettings(
                    displayMode: false,
                    maxExpand: 500,
                    strict: Strict.ignore,
                  ),
                  onErrorFallback: (error) {
                    inlineError = error.message;
                    return const Text('inline rejected');
                  },
                ),
                Math.tex(
                  r'\begin{gather}a&=b\end{gather}',
                  settings: const TexParserSettings(
                    displayMode: true,
                    maxExpand: 500,
                    strict: Strict.ignore,
                  ),
                  onErrorFallback: (error) {
                    columnsError = error.message;
                    return const Text('columns rejected');
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(inlineError, contains('only in display mode'));
      expect(columnsError, contains('Too many columns'));
    });
  });
}
