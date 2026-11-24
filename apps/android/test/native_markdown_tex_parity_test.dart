import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/native_math_paragraph.dart';
import 'package:flutter_math_fork/flutter_math.dart' show Math;

import 'live_test.dart' show theme;

void main() {
  testWidgets(
    'NativeMarkdown renders mathchoice branches with matching boundaries and scales once',
    (tester) async {
      final source = [
        r'Inline mixed boundary: $a\mathchoice{=}{+}{\sum}{x}b$ compared with $a+b$.',
        r'Script branch: $x^{a\mathchoice{=}{+}{\sum}{x}b}$ compared with $x^{a\sum b}$.',
        r'Explicit style: $\displaystyle a\mathchoice{=}{+}{\sum}{x}b$ compared with $\displaystyle a=b$.',
      ].join('\n\n');
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1800);
      addTearDown(tester.view.reset);

      final boxesByScale = <double, List<Size>>{};
      for (final scale in [1.0, 2.0]) {
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
                      child: NativeMarkdown(source: source),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'scale $scale');

        final formulaEntries = <_FormulaEntry>[
          for (final (contentIndex, content)
              in tester
                  .widgetList<NativeMathParagraphContent>(
                    find.byType(NativeMathParagraphContent),
                  )
                  .indexed)
            for (final formula in content.formulas)
              _FormulaEntry(
                contentFinder: find
                    .byType(NativeMathParagraphContent)
                    .at(contentIndex),
                formula: formula,
              ),
        ];
        expect(formulaEntries, hasLength(6));
        final boxes = [
          for (final entry in formulaEntries)
            _paintedFormulaSize(tester, entry),
        ];
        boxesByScale[scale] = boxes;
        final textFallbacks = tester
            .widgetList<Text>(find.byType(Text))
            .where((widget) => widget.data?.contains(r'\mathchoice') ?? false);
        expect(textFallbacks, isEmpty, reason: 'scale $scale');
        for (final (mixedIndex, literalIndex) in [(0, 1), (2, 3), (4, 5)]) {
          expect(
            boxes[mixedIndex].width,
            closeTo(boxes[literalIndex].width, 0.02),
            reason:
                'selected branch pair $mixedIndex/$literalIndex, scale $scale',
          );
        }
      }

      final one = boxesByScale[1.0]!;
      final two = boxesByScale[2.0]!;
      for (var index = 0; index < one.length; index++) {
        expect(
          two[index].width,
          closeTo(one[index].width * 2, 0.03),
          reason: 'math widget $index scales once',
        );
      }
    },
  );
}

class _FormulaEntry {
  const _FormulaEntry({required this.contentFinder, required this.formula});

  final Finder contentFinder;
  final NativeParagraphMathFormula formula;
}

Size _paintedFormulaSize(WidgetTester tester, _FormulaEntry entry) {
  final sizes = <Size>[];
  for (final part in entry.formula.parts) {
    final finder = find.descendant(
      of: entry.contentFinder,
      matching: find.byWidgetPredicate((widget) => identical(widget, part)),
    );
    expect(
      finder,
      findsOneWidget,
      reason:
          '${entry.formula.source.expression} part must be an actual painted Math widget',
    );
    expect(part, isA<Math>());
    sizes.add(tester.getSize(finder));
  }
  expect(sizes, isNotEmpty, reason: entry.formula.source.expression);
  return Size(
    sizes.fold<double>(0, (sum, size) => sum + size.width),
    sizes.map((size) => size.height).reduce((a, b) => a > b ? a : b),
  );
}
