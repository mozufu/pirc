// Capture NativeMarkdown's real flutter_math_fork parse/render result for the
// shared unsupported-command corpus. Run from apps/android with:
// flutter test tool/parity/capture_tex_unsupported_commands_test.dart
// Optional smoke filters: PIRC_TEX_CAPTURE_CASE=<fixture-id> and
// PIRC_TEX_CAPTURE_CONFIG=390-light-1.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_math_fork/src/ast/nodes/style.dart';
import 'package:flutter_math_fork/src/ast/nodes/symbol.dart';
import 'package:flutter_math_fork/src/ast/syntax_tree.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/native_math_block.dart';
import 'package:pirc_render/src/native_math_error.dart';
import 'package:pirc_render/src/native_inline_math.dart';
import 'package:pirc_render/src/native_math_paragraph.dart';
import 'package:pirc_render/src/native_tex_adapter.dart';

import 'capture_fonts.dart' show loadParityFonts;
import '../../test/live_test.dart' show theme;

// ignore_for_file: implementation_imports

const _errorColor = Color(0xffcc0000);

void main() {
  testWidgets('capture NativeMarkdown TeX unsupported-command cases', (
    tester,
  ) async {
    await tester.runAsync(loadParityFonts);

    final fixture =
        jsonDecode(
              File(
                '../../fixtures/mobile-parity/tex-unsupported-commands.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final capture = fixture['capture'] as Map<String, dynamic>;
    final allCases = (fixture['cases'] as List).cast<Map<String, dynamic>>();
    final caseFilter = Platform.environment['PIRC_TEX_CAPTURE_CASE'];
    final configFilter = Platform.environment['PIRC_TEX_CAPTURE_CONFIG'];
    final captureFlutterErrorDiagnostics =
        Platform.environment['PIRC_TEX_CAPTURE_FLUTTER_ERRORS'] == '1';
    final captureUnsplitProbe =
        Platform.environment['PIRC_TEX_CAPTURE_UNSPLIT_MATH'] == '1';
    final cases = caseFilter == null || caseFilter.isEmpty
        ? allCases
        : allCases.where((item) => item['id'] == caseFilter).toList();
    expect(cases, isNotEmpty, reason: 'No matching fixture case: $caseFilter');

    final widths = (capture['widths'] as List).cast<num>();
    final themes = (capture['themes'] as List).cast<String>();
    final textScales = (capture['textScales'] as List).cast<num>();
    final height = (capture['height'] as num).toDouble();
    final deviceScaleFactor = (capture['deviceScaleFactor'] as num).toDouble();
    final paragraphFontSize = (capture['paragraphFontSize'] as num).toDouble();
    final paragraphLineHeight = (capture['paragraphLineHeight'] as num)
        .toDouble();
    final outputDir = Directory('build/parity/tex-unsupported-commands')
      ..createSync(recursive: true);
    final configurations = <Map<String, Object?>>[];
    final validationErrors = <String>[];
    var captureCount = 0;

    tester.view.devicePixelRatio = deviceScaleFactor;
    addTearDown(tester.view.reset);

    for (final widthValue in widths) {
      final width = widthValue.toDouble();
      for (final brightnessName in themes) {
        final brightness = brightnessName == 'dark'
            ? Brightness.dark
            : Brightness.light;
        for (final scaleValue in textScales) {
          final textScale = scaleValue.toDouble();
          final configId =
              '${width.toInt()}-$brightnessName-${_num(textScale)}';
          if (configFilter != null &&
              configFilter.isNotEmpty &&
              configId != configFilter) {
            continue;
          }

          tester.view.physicalSize = Size(width, height);
          final capturedCases = <Map<String, Object?>>[];
          for (final item in cases) {
            final id = item['id'] as String;
            final source = (item['source'] ?? item['body']) as String;
            final boundaryKey = GlobalKey(debugLabel: 'tex-$id-$configId');
            final probeKey = ValueKey('unsplit-a-plus-b-$configId-$id');
            final caseErrors = <String>[];
            final flutterErrorDiagnostics = <Map<String, Object?>>[];
            Map<String, Object?>? result;

            try {
              final previousFlutterErrorHandler = FlutterError.onError;
              if (captureFlutterErrorDiagnostics) {
                FlutterError.onError = (details) {
                  flutterErrorDiagnostics.add({
                    'details': details.toString(),
                    'exception': details.exceptionAsString(),
                    'library': details.library,
                    'context': details.context?.toString(),
                    'stack': details.stack?.toString(),
                    'observedStack': StackTrace.current.toString(),
                    'diagnosticTree': details
                        .toDiagnosticsNode(style: DiagnosticsTreeStyle.error)
                        .toStringDeep(minLevel: DiagnosticLevel.hidden),
                    'informationCollector': details.informationCollector
                        ?.call()
                        .map(
                          (node) => node.toStringDeep(
                            minLevel: DiagnosticLevel.hidden,
                          ),
                        )
                        .toList(growable: false),
                  });
                  previousFlutterErrorHandler?.call(details);
                };
              }
              try {
                final appTheme = theme.build(brightness);
                await tester.pumpWidget(
                  MaterialApp(
                    debugShowCheckedModeBanner: false,
                    theme: appTheme.copyWith(
                      textTheme: appTheme.textTheme.apply(fontFamily: 'Arial'),
                    ),
                    home: Builder(
                      builder: (context) => MediaQuery(
                        data: MediaQuery.of(
                          context,
                        ).copyWith(textScaler: TextScaler.linear(textScale)),
                        child: Scaffold(
                          body: Stack(
                            alignment: Alignment.topLeft,
                            children: [
                              SingleChildScrollView(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: RepaintBoundary(
                                    key: boundaryKey,
                                    child: SizedBox(
                                      width: width - 32,
                                      child: NativeMarkdown(
                                        source: source,
                                        fontSize: paragraphFontSize,
                                        lineHeight: paragraphLineHeight,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (captureUnsplitProbe &&
                                  configId == '390-light-1' &&
                                  id == 'unknown-control-inline')
                                Offstage(
                                  child: UnconstrainedBox(
                                    alignment: Alignment.topLeft,
                                    child: NativeMathTex(
                                      'a+b',
                                      key: probeKey,
                                      mathStyle: MathStyle.text,
                                      settings: const TexParserSettings(
                                        displayMode: false,
                                        throwOnError: false,
                                        maxExpand: 500,
                                        strict: Strict.ignore,
                                      ),
                                      textStyle: TextStyle(
                                        fontSize: paragraphFontSize * 1.08,
                                        color: Colors.black,
                                      ),
                                      onParsed: (_, math) => math,
                                    ),
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
              } finally {
                if (captureFlutterErrorDiagnostics) {
                  FlutterError.onError = previousFlutterErrorHandler;
                }
              }
              final layoutException = tester.takeException();
              if (layoutException != null) {
                caseErrors.add(
                  'Flutter layout/build exception: $layoutException',
                );
              }

              final markdownFinder = find.byKey(boundaryKey);
              final formulas = _collectCapturedFormulas(
                markdownFinder.evaluate().single,
                markdownFinder,
              );
              final targetIndex = item['targetMathIndex'] as int;
              if (targetIndex < 0 || targetIndex >= formulas.length) {
                caseErrors.add(
                  'Target source formula index $targetIndex missing; '
                  'found ${formulas.length} retained source Math models',
                );
              } else {
                final targetFormula = formulas[targetIndex];
                final targetTex = targetFormula.source;
                final targetMath = targetFormula.model;
                if (targetMath == null) {
                  caseErrors.add(
                    'Source formula ${targetTex.expression} has no original '
                    'Math model or single non-inline Math widget',
                  );
                } else {
                  final targetSourceFinder = targetFormula.sourceFinder;
                  final targetFinder = targetFormula.layoutFinder;
                  final displayFinder = find.ancestor(
                    of: targetFinder,
                    matching: find.byType(NativeMathDisplayBlock),
                  );
                  final targetRender = tester.renderObject<RenderBox>(
                    targetFinder,
                  );
                  final renderedPartRects = targetFormula.renderedPartFinders
                      .map(tester.getRect)
                      .toList(growable: false);
                  final paintedPartsRect = _rectUnion(renderedPartRects);
                  final targetRect =
                      paintedPartsRect ?? tester.getRect(targetFinder);
                  final baseline = _targetBaseline(
                    tester,
                    targetFinder,
                    targetRender,
                    targetRect,
                    isInline: targetFormula.isInline,
                  );
                  final targetAst = targetMath.ast;
                  final redAstRuns = targetAst == null
                      ? <Map<String, Object?>>[]
                      : _redAstRuns(targetAst, _errorColor);
                  final redTextRuns = _redRichTextRuns(
                    tester,
                    targetSourceFinder,
                    _errorColor,
                  );
                  final fallbackText = _fallbackText(
                    tester,
                    targetSourceFinder,
                  );
                  final errorWidgets = _nativeErrorWidgets(
                    tester,
                    targetSourceFinder,
                  );
                  final actualKind = targetMath.parseError != null
                      ? 'whole-expression-parse-error'
                      : redAstRuns.isNotEmpty
                      ? 'rendered-with-unsupported-command'
                      : 'normal-rendered';

                  if (actualKind != item['expectedKind']) {
                    caseErrors.add(
                      'expected ${item['expectedKind']}, got $actualKind '
                      '(parseError=${targetMath.parseError?.message}, '
                      'redAstRuns=${redAstRuns.map((run) => run['text']).toList()})',
                    );
                  }
                  if (item['expectedKind'] == 'whole-expression-parse-error') {
                    if (targetMath.parseError == null || targetAst != null) {
                      caseErrors.add(
                        'Structural case must retain Math.parseError and have no AST',
                      );
                    }
                    if (!errorWidgets.any(
                          (widget) => widget['source'] == targetTex.expression,
                        ) &&
                        !fallbackText.any(
                          (entry) => entry['text'] == targetTex.expression,
                        ) &&
                        !redTextRuns.any(
                          (entry) =>
                              '${entry['text']}'.contains(targetTex.expression),
                        )) {
                      caseErrors.add(
                        'Structural fallback did not render original expression '
                        '${jsonEncode(targetTex.expression)}; '
                        'errorWidgets=$errorWidgets fallback=$fallbackText',
                      );
                    }
                    for (final expectedText
                        in (item['expectedRedText'] as List).cast<String>()) {
                      if (!errorWidgets.any(
                            (entry) =>
                                '${entry['source']}'.contains(expectedText),
                          ) &&
                          !fallbackText.any(
                            (entry) =>
                                '${entry['text']}'.contains(expectedText),
                          )) {
                        caseErrors.add(
                          'Whole fallback missing original text '
                          '${jsonEncode(expectedText)}',
                        );
                      }
                      if (!redTextRuns.any(
                        (entry) => '${entry['text']}'.contains(expectedText),
                      )) {
                        caseErrors.add(
                          'Whole fallback did not paint '
                          '${jsonEncode(expectedText)} in the expected error color; '
                          'redRuns=$redTextRuns',
                        );
                      }
                    }
                  } else if (item['expectedKind'] ==
                      'rendered-with-unsupported-command') {
                    if (targetMath.parseError != null || targetAst == null) {
                      caseErrors.add(
                        'Unsupported command must remain a parsed Math AST, not '
                        'a whole-formula fallback: ${targetMath.parseError?.message}',
                      );
                    }
                    for (final expectedText
                        in (item['expectedRedText'] as List).cast<String>()) {
                      final matchingAstRun = redAstRuns.any(
                        (run) => '${run['text']}'.contains(expectedText),
                      );
                      if (!matchingAstRun) {
                        caseErrors.add(
                          'No red AST run contains ${jsonEncode(expectedText)}; '
                          'runs=${redAstRuns.map((run) => run['text']).toList()}',
                        );
                      }
                    }
                    if (!targetFormula.isInline &&
                        displayFinder.evaluate().isEmpty) {
                      caseErrors.add(
                        'Successfully parsed formula has neither a '
                        'NativeInlineMath wrapper nor a display block',
                      );
                    }
                  }

                  final expectedBefore =
                      (item['expectedBeforeAnnotations'] as List?)
                          ?.cast<String>() ??
                      const <String>[];
                  final expectedAfter =
                      (item['expectedAfterAnnotations'] as List?)
                          ?.cast<String>() ??
                      const <String>[];
                  final expectedFormulaCount =
                      expectedBefore.length + 1 + expectedAfter.length;
                  if (formulas.length != expectedFormulaCount) {
                    caseErrors.add(
                      'Source formula wrapper count differs: '
                      '${formulas.length} != $expectedFormulaCount',
                    );
                  }
                  final beforeExpressions = formulas
                      .take(targetIndex)
                      .map((formula) => formula.source.expression)
                      .toList(growable: false);
                  final afterExpressions = formulas
                      .skip(targetIndex + 1)
                      .map((formula) => formula.source.expression)
                      .toList(growable: false);
                  if (!_sameStrings(beforeExpressions, expectedBefore)) {
                    caseErrors.add(
                      'Before formulas differ: $beforeExpressions != $expectedBefore',
                    );
                  }
                  if (!_sameStrings(afterExpressions, expectedAfter)) {
                    caseErrors.add(
                      'After formulas differ: $afterExpressions != $expectedAfter',
                    );
                  }
                  for (var index = 0; index < formulas.length; index++) {
                    if (index == targetIndex) continue;
                    final neighbor = formulas[index];
                    final neighborModel = neighbor.model;
                    if (neighborModel == null ||
                        neighborModel.parseError != null ||
                        neighborModel.ast == null) {
                      caseErrors.add(
                        'Neighbor source formula[$index] failed: '
                        '${neighborModel?.parseError?.message}',
                      );
                    }
                    final neighborBox = tester.getSize(neighbor.layoutFinder);
                    if (neighborBox.width <= 0 || neighborBox.height <= 0) {
                      caseErrors.add(
                        'Neighbor formula[$index] has empty layout geometry',
                      );
                    }
                  }
                  if (targetRect.width <= 0 || targetRect.height <= 0) {
                    caseErrors.add(
                      'Target Math has empty geometry: $targetRect',
                    );
                  }

                  final displayBox = displayFinder.evaluate().isEmpty
                      ? null
                      : _rect(tester.getRect(displayFinder.first));
                  final markdownBox = markdownFinder.evaluate().isEmpty
                      ? null
                      : _rect(tester.getRect(markdownFinder.first));
                  final paragraphs = _paragraphMeasurements(tester);

                  result = {
                    'id': id,
                    'source': source,
                    'expectedKind': item['expectedKind'],
                    'actualKind': actualKind,
                    'targetMathIndex': targetIndex,
                    'sourceFormulaCount': formulas.length,
                    'renderedMathWidgetCount': find
                        .descendant(
                          of: markdownFinder,
                          matching: find.byType(Math),
                        )
                        .evaluate()
                        .length,
                    'beforeExpressions': beforeExpressions,
                    'afterExpressions': afterExpressions,
                    'target': {
                      'expression': targetTex.expression,
                      'layoutWidgetType': targetFormula.isInline
                          ? 'NativeInlineMath'
                          : 'Math',
                      'isInline': targetFormula.isInline,
                      'parseError': _parseError(targetMath.parseError),
                      'ast': _astSummary(targetAst, _errorColor),
                      'fallbackText': fallbackText,
                      'errorWidgets': errorWidgets,
                      'redAstRuns': redAstRuns,
                      'redRenderedTextRuns': redTextRuns,
                      'mathBox': _rect(targetRect),
                      'targetLayoutBox': _rect(targetRect),
                      'partsMathPaintRectUnion': paintedPartsRect == null
                          ? null
                          : _rect(paintedPartsRect),
                      'renderedParts': [
                        for (
                          var index = 0;
                          index < targetFormula.renderedParts.length;
                          index++
                        )
                          {
                            'index': index,
                            'parseError': _parseError(
                              targetFormula.renderedParts[index].parseError,
                            ),
                            'astAvailable':
                                targetFormula.renderedParts[index].ast != null,
                            'box': _rect(renderedPartRects[index]),
                          },
                      ],
                      'baseline': baseline,
                      'displayBlockBox': displayBox,
                    },
                    'neighborMath': [
                      for (var index = 0; index < formulas.length; index++)
                        if (index != targetIndex)
                          {
                            'index': index,
                            'expression': formulas[index].source.expression,
                            'parseError': _parseError(
                              formulas[index].model?.parseError,
                            ),
                            'astAvailable': formulas[index].model?.ast != null,
                            'isInline': formulas[index].isInline,
                            'renderedPartCount':
                                formulas[index].renderedParts.length,
                            'renderedParts': [
                              for (final partFinder
                                  in formulas[index].renderedPartFinders)
                                _rect(tester.getRect(partFinder)),
                            ],
                            'renderedPartWidthsSum': formulas[index]
                                .renderedPartFinders
                                .map((finder) => tester.getSize(finder).width)
                                .fold<double>(0, (sum, width) => sum + width),
                            'mathBox': _rect(
                              tester.getRect(formulas[index].layoutFinder),
                            ),
                            'partsMathPaintRectUnion': _rectUnionMap(
                              formulas[index].renderedPartFinders
                                  .map(tester.getRect)
                                  .toList(growable: false),
                            ),
                          },
                    ],
                    'markdownBox': markdownBox,
                    'paragraphBounds': paragraphs,
                    if (captureUnsplitProbe &&
                        configId == '390-light-1' &&
                        id == 'unknown-control-inline')
                      'unsplitAPlusBProbe': _probeRect(tester, probeKey),
                    'layoutException': layoutException?.toString(),
                    if (captureFlutterErrorDiagnostics)
                      'flutterErrorDiagnostics': flutterErrorDiagnostics,
                    if (captureFlutterErrorDiagnostics)
                      'renderLineDiagnostics': _renderLineDiagnostics(
                        tester,
                        find.byKey(boundaryKey),
                      ),
                  };
                }
              }

              final image = await _capturePng(tester, boundaryKey);
              final imageName =
                  'tex-unsupported-$id-${width.toInt()}-$brightnessName-scale${_num(textScale)}-native.png';
              File('${outputDir.path}/$imageName').writeAsBytesSync(image);
              result ??= {
                'id': id,
                'source': source,
                'expectedKind': item['expectedKind'],
                'actualKind': 'capture-failed',
                'error': caseErrors.join('\n'),
                'layoutException': tester.takeException()?.toString(),
                if (captureFlutterErrorDiagnostics)
                  'flutterErrorDiagnostics': flutterErrorDiagnostics,
              };
              result['screenshot'] =
                  'apps/android/build/parity/tex-unsupported-commands/$imageName';
              result['errors'] = caseErrors;
              validationErrors.addAll(
                caseErrors.map((error) => '$configId/$id: $error'),
              );
            } catch (error, stack) {
              caseErrors.add('$error\n$stack');
              validationErrors.addAll(
                caseErrors.map((entry) => '$configId/$id: $entry'),
              );
              result ??= {
                'id': id,
                'source': source,
                'expectedKind': item['expectedKind'],
                'actualKind': 'capture-failed',
                'errors': caseErrors,
              };
            }
            capturedCases.add(result);
            captureCount++;
          }
          configurations.add({
            'id': configId,
            'viewport': {'width': width, 'height': height},
            'theme': brightnessName,
            'textScale': textScale,
            'deviceScaleFactor': deviceScaleFactor,
            'typography': {
              'paragraphFontFamily': capture['paragraphFontFamily'],
              'paragraphFontSize': paragraphFontSize,
              'paragraphLineHeight': paragraphLineHeight,
              'katexFontScale': capture['katexFontScale'],
              'fontLoader': 'capture_fonts.loadParityFonts',
            },
            'cases': capturedCases,
          });
        }
      }
    }

    final outputPath = File(
      Platform.environment['PIRC_TEX_CAPTURE_OUTPUT'] ??
          'build/parity/tex-unsupported-commands/native-measurements.json',
    )..parent.createSync(recursive: true);
    outputPath.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'fixture': '../../fixtures/mobile-parity/tex-unsupported-commands.json',
        'renderer': 'NativeMarkdown + NativeMathTex + flutter_math_fork 0.7.4',
        'capture': {
          'widths': widths,
          'height': height,
          'themes': themes,
          'textScales': textScales,
          'deviceScaleFactor': deviceScaleFactor,
          'paragraphFontFamily': capture['paragraphFontFamily'],
          'paragraphFontSize': paragraphFontSize,
          'paragraphLineHeight': paragraphLineHeight,
          'katexFontScale': capture['katexFontScale'],
        },
        'selection': {'caseFilter': caseFilter, 'configFilter': configFilter},
        'flutterErrorDiagnosticsEnabled': captureFlutterErrorDiagnostics,
        'captureCount': captureCount,
        'configurations': configurations,
        'validationErrors': validationErrors,
      }),
    );

    expect(
      validationErrors,
      isEmpty,
      reason:
          'Native TeX parity capture validation failed. Measurements: '
          '${outputPath.path}; errors: ${validationErrors.join(" | ")}',
    );
  });
}

bool _sameStrings(List<String> actual, List<String> expected) =>
    actual.length == expected.length &&
    List<bool>.generate(
      actual.length,
      (index) => actual[index] == expected[index],
    ).every((same) => same);

String _num(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();

Map<String, Object?>? _probeRect(WidgetTester tester, Key probeKey) {
  final probeSourceFinder = find.byKey(probeKey, skipOffstage: false);
  if (probeSourceFinder.evaluate().isEmpty) return null;
  final probeMathFinder = find.descendant(
    of: probeSourceFinder,
    matching: find.byType(Math, skipOffstage: false),
    skipOffstage: false,
  );
  if (probeMathFinder.evaluate().isEmpty) return null;
  return _rect(tester.getRect(probeMathFinder.first));
}

Map<String, Object?>? _parseError(ParseException? error) => error == null
    ? null
    : {
        'type': error.runtimeType.toString(),
        'message': error.message,
        'position': error.position,
        'token': error.token?.text,
      };

List<Map<String, Object?>> _redAstRuns(SyntaxTree ast, Color errorColor) {
  final runs = <Map<String, Object?>>[];

  String nodeText(GreenNode node) {
    if (node is SymbolNode) return node.symbol;
    return node.children.whereType<GreenNode>().map(nodeText).join();
  }

  void visit(GreenNode node, Color? inheritedColor) {
    final nextColor = node is StyleNode
        ? node.optionsDiff.color ?? inheritedColor
        : inheritedColor;
    if (node is StyleNode &&
        inheritedColor?.toARGB32() != errorColor.toARGB32() &&
        nextColor?.toARGB32() == errorColor.toARGB32()) {
      runs.add({
        'text': nodeText(node),
        'color': _color(nextColor!),
        'nodeType': node.runtimeType.toString(),
      });
      return;
    }
    for (final child in node.children.whereType<GreenNode>()) {
      visit(child, nextColor);
    }
  }

  visit(ast.greenRoot, null);
  return runs;
}

Map<String, Object?> _astSummary(SyntaxTree? ast, Color errorColor) {
  if (ast == null) return {'available': false};
  final nodes = <Map<String, Object?>>[];
  void visit(GreenNode node, Color? inheritedColor) {
    final color = node is StyleNode
        ? node.optionsDiff.color ?? inheritedColor
        : inheritedColor;
    nodes.add({
      'type': node.runtimeType.toString(),
      if (node is SymbolNode) 'symbol': node.symbol,
      if (node is StyleNode && node.optionsDiff.color != null)
        'styleColor': _color(node.optionsDiff.color!),
      if (color?.toARGB32() == errorColor.toARGB32()) 'underErrorColor': true,
    });
    for (final child in node.children.whereType<GreenNode>()) {
      visit(child, color);
    }
  }

  visit(ast.greenRoot, null);
  return {
    'available': true,
    'rootType': ast.greenRoot.runtimeType.toString(),
    'nodes': nodes,
  };
}

List<Map<String, Object?>> _redRichTextRuns(
  WidgetTester tester,
  Finder mathFinder,
  Color errorColor,
) {
  final result = <Map<String, Object?>>[];
  for (final widget in _richTextWidgets(tester, mathFinder)) {
    void visit(InlineSpan span, Color? inheritedColor) {
      if (span is! TextSpan) return;
      final color = span.style?.color ?? inheritedColor;
      if (span.text != null && color?.toARGB32() == errorColor.toARGB32()) {
        result.add({'text': span.text, 'color': _color(color!)});
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child, color);
      }
    }

    visit(widget.text, widget.text.style?.color);
  }
  return result;
}

List<Map<String, Object?>> _fallbackText(
  WidgetTester tester,
  Finder mathFinder,
) {
  final textFinder = find.descendant(
    of: mathFinder,
    matching: find.byWidgetPredicate(
      (widget) => widget is Text || widget is SelectableText,
    ),
  );
  final result = <Map<String, Object?>>[
    for (final element in textFinder.evaluate())
      if (_plainText(element.widget) case final String text)
        {
          'text': text,
          'type': element.widget.runtimeType.toString(),
          if (element.widget is Text)
            'color': _colorOrNull((element.widget as Text).style?.color),
        },
  ];
  for (final widget in _richTextWidgets(tester, mathFinder)) {
    result.add({
      'text': widget.text.toPlainText(),
      'type': widget.runtimeType.toString(),
      'color': _colorOrNull(widget.text.style?.color),
    });
  }
  return result;
}

/// RichText is subclassed by NativeMathParagraphContent's paragraph renderer,
/// so looking it up with find.byType(RichText) misses the actual visible
/// whole-expression error span. Read the child directly as well as descendants.
List<RichText> _richTextWidgets(WidgetTester tester, Finder mathFinder) {
  final result = <RichText>[];
  final seen = <RichText>{};
  void add(Widget? widget) {
    if (widget is RichText && seen.add(widget)) result.add(widget);
  }

  for (final element in mathFinder.evaluate()) {
    if (element.widget case final NativeMathParagraphContent content) {
      add(content.child);
    }
  }
  final descendants = find.descendant(
    of: mathFinder,
    matching: find.byWidgetPredicate((widget) => widget is RichText),
  );
  for (final element in descendants.evaluate()) {
    add(element.widget);
  }
  return result;
}

List<Map<String, Object?>> _nativeErrorWidgets(
  WidgetTester tester,
  Finder mathFinder,
) {
  final finder = find.descendant(
    of: mathFinder,
    matching: find.byType(NativeMathErrorText),
  );
  final elements = finder.evaluate().toList(growable: false);
  return [
    for (var index = 0; index < elements.length; index++)
      if (elements[index].widget case final NativeMathErrorText widget)
        {
          'source': widget.source,
          'block': widget.block,
          'bodyFontSize': widget.bodyFontSize,
          'lineHeight': widget.lineHeight,
          'fontFamily': widget.fontFamily,
          'box': _rect(tester.getRect(finder.at(index))),
        },
  ];
}

Map<String, Object?> _targetBaseline(
  WidgetTester tester,
  Finder mathFinder,
  RenderBox mathRender,
  Rect mathRect, {
  required bool isInline,
}) {
  final lineBoxFinder = find.ancestor(
    of: mathFinder,
    matching: find.byType(NativeMathLineBox),
  );
  if (lineBoxFinder.evaluate().isNotEmpty) {
    final lineBoxElement = lineBoxFinder.first;
    final render = tester.renderObject<RenderNativeMathLineBox>(lineBoxElement);
    final rect = tester.getRect(lineBoxElement);
    final baselineY = rect.top + render.baseline;
    return {
      'source': 'NativeMathLineBox.baseline',
      'globalY': baselineY,
      'offsetFromMathTop': baselineY - mathRect.top,
      'offsetFromMathBottom': mathRect.bottom - baselineY,
    };
  }

  if (isInline) {
    if (mathRender is RenderNativeInlineMath) {
      final baselineY = mathRender
          .localToGlobal(Offset(0, mathRender.baseline))
          .dy;
      return {
        'source': 'RenderNativeInlineMath.baseline',
        'globalY': baselineY,
        'offsetFromMathTop': baselineY - mathRect.top,
        'offsetFromMathBottom': mathRect.bottom - baselineY,
      };
    }
    return {
      'source': 'unavailable',
      'reason': 'NativeInlineMath render object was not found',
      'renderObjectType': mathRender.runtimeType.toString(),
      'mathBox': _rect(mathRect),
    };
  }

  final candidates = <RenderParagraph>[];
  if (mathRender is RenderParagraph) candidates.add(mathRender);
  RenderObject? ancestor = mathRender.parent;
  while (ancestor != null) {
    if (ancestor is RenderParagraph) candidates.add(ancestor);
    ancestor = ancestor.parent;
  }
  final descendants = find
      .descendant(of: mathFinder, matching: find.byType(RichText))
      .evaluate();
  for (final element in descendants) {
    final render = element.renderObject;
    if (render is RenderParagraph) candidates.add(render);
  }

  final seen = <RenderParagraph>{};
  final errors = <String>[];
  for (final paragraph in candidates) {
    if (!seen.add(paragraph)) continue;
    try {
      final offset = paragraph.getDryBaseline(
        BoxConstraints.tight(paragraph.size),
        TextBaseline.alphabetic,
      );
      if (offset == null) continue;
      final baselineY = paragraph.localToGlobal(Offset(0, offset)).dy;
      return {
        'source': 'RenderParagraph.dryBaseline',
        'globalY': baselineY,
        'offsetFromMathTop': baselineY - mathRect.top,
        'offsetFromMathBottom': mathRect.bottom - baselineY,
        'paragraphText': paragraph.text.toPlainText(),
        'paragraphBox': _rect(
          paragraph.localToGlobal(Offset.zero) & paragraph.size,
        ),
      };
    } on Object catch (error) {
      errors.add(error.toString());
    }
  }
  return {
    'source': 'unavailable',
    'errors': errors,
    'mathBox': _rect(mathRect),
  };
}

String? _plainText(Widget widget) => switch (widget) {
  Text(:final data?) => data,
  Text(:final textSpan?) => textSpan.toPlainText(),
  SelectableText(:final data) => data,
  _ => null,
};

class _CapturedFormula {
  const _CapturedFormula({
    required this.source,
    required this.sourceFinder,
    required this.isInline,
    required this.renderedParts,
    required this.renderedPartFinders,
    required this.model,
  });

  final NativeMathTex source;
  final Finder sourceFinder;
  final bool isInline;
  final List<Math> renderedParts;
  final List<Finder> renderedPartFinders;
  final Math? model;

  Finder get layoutFinder {
    if (renderedPartFinders.isNotEmpty) return renderedPartFinders.first;
    final richText = find.descendant(
      of: sourceFinder,
      matching: find.byType(RichText),
    );
    if (richText.evaluate().isNotEmpty) return richText.first;
    final text = find.descendant(of: sourceFinder, matching: find.byType(Text));
    return text.first;
  }
}

List<_CapturedFormula> _collectCapturedFormulas(
  Element root,
  Finder markdownFinder,
) {
  final formulas = <_CapturedFormula>[];
  void visit(Element element) {
    final widget = element.widget;
    if (widget is NativeMathParagraphContent) {
      final contentFinder = find.byWidget(widget);
      for (final formula in widget.formulas) {
        final partFinders = [
          for (final part in formula.parts)
            find.descendant(
              of: contentFinder,
              matching: find.byWidgetPredicate(
                (candidate) => identical(candidate, part),
              ),
            ),
        ];
        formulas.add(
          _CapturedFormula(
            source: formula.source,
            sourceFinder: contentFinder,
            isInline: true,
            renderedParts: formula.parts,
            renderedPartFinders: partFinders,
            model: formula.math,
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
      final mathElements = find
          .descendant(of: sourceFinder, matching: find.byType(Math))
          .evaluate()
          .toList(growable: false);
      formulas.add(
        _CapturedFormula(
          source: widget.math,
          sourceFinder: sourceFinder,
          isInline: !widget.display,
          renderedParts: mathElements
              .map((candidate) => candidate.widget as Math)
              .toList(growable: false),
          renderedPartFinders: [
            for (final candidate in mathElements)
              find.byElementPredicate(
                (element) => identical(element, candidate),
              ),
          ],
          model: resolved.math,
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
  var result = rects.first;
  for (final rect in rects.skip(1)) {
    result = result.expandToInclude(rect);
  }
  return result;
}

Map<String, double>? _rectUnionMap(List<Rect> rects) {
  final rect = _rectUnion(rects);
  return rect == null ? null : _rect(rect);
}

List<Map<String, Object?>> _renderLineDiagnostics(
  WidgetTester tester,
  Finder rootFinder,
) {
  final root = tester.renderObject<RenderObject>(rootFinder);
  final lines = <RenderBox>[];
  void visit(RenderObject object) {
    if (object.runtimeType.toString() == 'RenderLine' && object is RenderBox) {
      lines.add(object);
    }
    object.visitChildren(visit);
  }

  visit(root);
  return [
    for (final line in lines)
      {
        'renderLine': line.toStringDeep(minLevel: DiagnosticLevel.hidden),
        'size': {'width': line.size.width, 'height': line.size.height},
        'constraints': line.constraints.toString(),
        'creatorChain': [
          for (
            RenderObject? ancestor = line;
            ancestor != null;
            ancestor = ancestor.parent
          )
            {
              'renderObject': ancestor.toStringShort(),
              'creator': ancestor.debugCreator?.toString(),
            },
        ],
      },
  ];
}

List<Map<String, Object?>> _paragraphMeasurements(WidgetTester tester) {
  final finder = find.byType(RichText);
  final elements = finder.evaluate().toList(growable: false);
  return [
    for (var index = 0; index < elements.length; index++)
      if (elements[index].renderObject case final RenderParagraph render)
        {
          'index': index,
          'plainText': render.text.toPlainText(),
          'box': _rect(tester.getRect(finder.at(index))),
          'baselineOffset': render.getDryBaseline(
            BoxConstraints.tight(render.size),
            TextBaseline.alphabetic,
          ),
        },
  ];
}

String? _colorOrNull(Color? color) => color == null ? null : _color(color);

String _color(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0')}';

Map<String, double> _rect(Rect rect) => {
  'x': rect.left,
  'y': rect.top,
  'width': rect.width,
  'height': rect.height,
  'right': rect.right,
  'bottom': rect.bottom,
};

Future<List<int>> _capturePng(WidgetTester tester, GlobalKey key) async {
  final boundary = key.currentContext?.findRenderObject();
  if (boundary is! RenderRepaintBoundary) {
    throw StateError('NativeMarkdown RepaintBoundary was not laid out');
  }
  final png = await tester.runAsync<List<int>>(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('PNG encoding returned no bytes');
      return bytes.buffer
          .asUint8List(bytes.offsetInBytes, bytes.lengthInBytes)
          .toList(growable: false);
    } finally {
      image.dispose();
    }
  });
  if (png == null) throw StateError('PNG capture returned no data');
  return png;
}
