import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_math_fork/src/ast/nodes/style.dart';
import 'package:flutter_math_fork/src/ast/nodes/symbol.dart';
import 'package:flutter_math_fork/src/ast/syntax_tree.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/native_math_paragraph.dart';
import 'package:pirc_render/src/native_tex_adapter.dart';

import 'capture_fonts.dart' show loadParityFonts;
import '../../test/live_test.dart' show theme;

// ignore_for_file: implementation_imports

List<String> unsupportedControls(GreenNode node) {
  String text(GreenNode node) => node is SymbolNode
      ? node.symbol
      : node.children.whereType<GreenNode>().map(text).join();
  if (node is StyleNode && node.optionsDiff.color == const Color(0xffcc0000)) {
    return [text(node)];
  }
  return node.children
      .whereType<GreenNode>()
      .expand(unsupportedControls)
      .toList();
}

void main() {
  testWidgets(
    'NativeMarkdown renders the pinned TeX corpus and records 1x/2x boxes',
    (tester) async {
      await tester.runAsync(loadParityFonts);
      final fixture =
          jsonDecode(
                File(
                  '../../fixtures/mobile-parity/native-tex.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();
      final comparisonCases = cases
          .where((item) => item['comparisonSource'] is String)
          .toList(growable: false);
      final source = <String>[
        for (final item in cases)
          if (item['mode'] == 'display')
            '\$\$\n${item['source']}\n\$\$'
          else
            'Before \$${item['source']}\$ after',
        for (final item in comparisonCases)
          if ((item['comparisonMode'] ?? 'inline') == 'display')
            '\$\$\n${item['comparisonSource']}\n\$\$'
          else
            'Selected branch reference: \$${item['comparisonSource']}\$',
      ].join('\n\n');
      final measurements = <Map<String, Object?>>[];
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1800);
      addTearDown(tester.view.reset);

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

        final markdownFinder = find.byType(NativeMarkdown).first;
        final formulas = _collectFormulas(
          markdownFinder.evaluate().single,
          markdownFinder,
        );
        expect(
          formulas.length,
          cases.length + comparisonCases.length,
          reason: 'One full original Math model per case and comparison',
        );
        final caseMeasurements = <Map<String, Object?>>[];
        for (var index = 0; index < cases.length; index++) {
          final item = cases[index];
          final formula = formulas[index];
          final partRects = formula.partFinders
              .where((finder) => finder.evaluate().isNotEmpty)
              .map(tester.getRect)
              .toList(growable: false);
          final mathRect = _rectUnion(partRects);
          final wholeFormulaFallback = formula.model.parseError != null;
          final redControls = formula.model.ast == null
              ? <String>[]
              : unsupportedControls(formula.model.ast!.greenRoot);
          final presentation = wholeFormulaFallback
              ? 'whole-formula-fallback'
              : redControls.isNotEmpty
              ? 'rendered-with-unsupported-command'
              : 'math-widget';
          caseMeasurements.add({
            'id': item['id'],
            'browserExpected': item['browserExpected'],
            'nativeExpected': item['nativeExpected'],
            'sourceExpression': formula.source.expression,
            'nativePresentation': presentation,
            'unsupportedControls': redControls,
            'mathBox': {
              if (mathRect != null) 'x': mathRect.left,
              if (mathRect != null) 'y': mathRect.top,
              if (mathRect != null) 'width': mathRect.width,
              if (mathRect != null) 'height': mathRect.height,
            },
            'renderedParts': [for (final rect in partRects) _rect(rect)],
            'parseError': formula.model.parseError?.message,
            if (item['limitation'] != null) 'limitation': item['limitation'],
          });
        }
        final comparisonMeasurements = <Map<String, Object?>>[];
        for (var index = 0; index < comparisonCases.length; index++) {
          final item = comparisonCases[index];
          final formula = formulas[cases.length + index];
          final partRects = formula.partFinders
              .where((finder) => finder.evaluate().isNotEmpty)
              .map(tester.getRect)
              .toList(growable: false);
          final mathRect = _rectUnion(partRects);
          final width = formula.partFinders
              .where((finder) => finder.evaluate().isNotEmpty)
              .map((finder) => tester.getSize(finder).width)
              .fold<double>(0, (sum, value) => sum + value);
          comparisonMeasurements.add({
            'id': item['id'],
            'selectedBranchSource': item['comparisonSource'],
            'sourceExpression': formula.source.expression,
            'mathBox': {
              if (mathRect != null) 'x': mathRect.left,
              if (mathRect != null) 'y': mathRect.top,
              'width': width,
              if (mathRect != null) 'height': mathRect.height,
            },
          });
        }
        final caseById = {
          for (final item in caseMeasurements) item['id']: item,
        };
        final comparisonById = {
          for (final item in comparisonMeasurements) item['id']: item,
        };
        final selectedBranchComparisons = <Map<String, Object?>>[];
        for (final item in comparisonCases) {
          final id = item['id'] as String;
          final mixedBox = caseById[id]!['mathBox'] as Map<String, Object?>;
          final directBox =
              comparisonById[id]!['mathBox'] as Map<String, Object?>;
          final delta =
              (mixedBox['width'] as num) - (directBox['width'] as num);
          selectedBranchComparisons.add({
            'id': id,
            'selectedBranchSource': item['comparisonSource'],
            'mixedWidth': mixedBox['width'],
            'directWidth': directBox['width'],
            'widthDelta': delta,
          });
          expect(
            delta,
            closeTo(0, 0.02),
            reason: '$id selected branch spacing',
          );
        }
        measurements.add({
          'textScale': scale,
          'cases': caseMeasurements,
          'comparisons': comparisonMeasurements,
          'selectedBranchComparisons': selectedBranchComparisons,
        });
      }

      final output = File('build/parity/native-tex/native-tex-native.json')
        ..parent.createSync(recursive: true);
      output.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'renderer':
              'NativeMarkdown + NativeMathParagraph with flutter_math_fork 0.7.4',
          'fixture': 'fixtures/mobile-parity/native-tex.json',
          'captures': measurements,
        }),
      );

      final capturesByScale = {
        for (final capture in measurements)
          capture['textScale'] as double: capture,
      };
      for (final scaleCapture in measurements) {
        final byId = {
          for (final item
              in scaleCapture['cases'] as List<Map<String, Object?>>)
            item['id']: item,
        };
        for (final item in cases) {
          final id = item['id'] as String;
          final actual = byId[id]!['nativePresentation'];
          final expected = item['nativeExpected'] == 'rendered'
              ? 'math-widget'
              : item['nativeExpected'];
          expect(actual, expected, reason: id);
        }
      }

      final oneX = capturesByScale[1.0]!['cases'] as List<Map<String, Object?>>;
      final twoX = capturesByScale[2.0]!['cases'] as List<Map<String, Object?>>;
      final oneById = {for (final item in oneX) item['id']: item};
      final twoById = {for (final item in twoX) item['id']: item};
      for (final id in [
        'mathchoice-inline',
        'mathchoice-display',
        'mathchoice-script',
        'smash-top',
        'smash-bottom',
        'gather-one-row',
        'gather',
        'gather-three-rows',
        'gather-star',
        'gathered',
        'Vmatrix',
        'array-horizontal-rules',
      ]) {
        final oneBox = oneById[id]!['mathBox'] as Map<String, Object?>;
        final twoBox = twoById[id]!['mathBox'] as Map<String, Object?>;
        expect(
          twoBox['height'],
          closeTo((oneBox['height'] as num) * 2, 0.02),
          reason: '$id height should scale once at UI scale 2×',
        );
        final oneParts = (oneById[id]!['renderedParts'] as List)
            .cast<Map<String, Object?>>();
        final twoParts = (twoById[id]!['renderedParts'] as List)
            .cast<Map<String, Object?>>();
        expect(
          twoParts.length,
          oneParts.length,
          reason: '$id should retain the same painted Math parts at 2×',
        );
        for (var partIndex = 0; partIndex < oneParts.length; partIndex++) {
          for (final dimension in ['width', 'height']) {
            expect(
              twoParts[partIndex][dimension],
              closeTo((oneParts[partIndex][dimension] as num) * 2, 0.02),
              reason:
                  '$id part $partIndex $dimension should scale once at UI scale 2×',
            );
          }
        }
      }
    },
  );
}

class _SourceFormula {
  const _SourceFormula({
    required this.source,
    required this.model,
    required this.partFinders,
  });

  final NativeMathTex source;
  final Math model;
  final List<Finder> partFinders;
}

List<_SourceFormula> _collectFormulas(Element root, Finder markdownFinder) {
  final formulas = <_SourceFormula>[];
  void visit(Element element) {
    final widget = element.widget;
    if (widget is NativeMathParagraphContent) {
      final contentFinder = find.byWidget(widget);
      for (final formula in widget.formulas) {
        formulas.add(
          _SourceFormula(
            source: formula.source,
            model: formula.math,
            partFinders: [
              for (final part in formula.parts)
                find.descendant(
                  of: contentFinder,
                  matching: find.byWidgetPredicate(
                    (candidate) => identical(candidate, part),
                  ),
                ),
            ],
          ),
        );
      }
      return;
    }
    if (widget is NativeMarkdownMath) {
      final sourceFinder = find.descendant(
        of: markdownFinder,
        matching: find.byWidgetPredicate(
          (candidate) => identical(candidate, widget.math),
        ),
      );
      final resolved = widget.math.resolve(element);
      final parts = find.descendant(
        of: sourceFinder,
        matching: find.byType(Math),
      );
      formulas.add(
        _SourceFormula(
          source: widget.math,
          model: resolved.math,
          partFinders: [
            for (final child in parts.evaluate())
              find.byElementPredicate(
                (candidate) => identical(candidate, child),
              ),
          ],
        ),
      );
      return;
    }
    element.visitChildren(visit);
  }

  visit(root);
  return formulas;
}

Rect? _rectUnion(List<Rect> rects) {
  if (rects.isEmpty) return null;
  var union = rects.first;
  for (final rect in rects.skip(1)) {
    union = union.expandToInclude(rect);
  }
  return union;
}

Map<String, double> _rect(Rect rect) => {
  'x': rect.left,
  'y': rect.top,
  'width': rect.width,
  'height': rect.height,
};
