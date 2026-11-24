// Capture NativeMarkdown's inline math paragraph flow from actual Flutter
// RenderParagraph and Math render boxes. Run from apps/android with:
//   flutter test tool/parity/capture_inline_math_paragraph_test.dart
// Optional filters: PIRC_INLINE_MATH_NATIVE_CASE and
// PIRC_INLINE_MATH_NATIVE_CONFIG=390-light-1.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart' show Math;
import 'package:flutter_math_fork/src/ast/nodes/style.dart';
import 'package:flutter_math_fork/src/ast/nodes/symbol.dart';
import 'package:flutter_math_fork/src/ast/syntax_tree.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/native_math_block.dart';
import 'package:pirc_render/src/native_inline_math.dart'
    show RenderNativeInlineMath;
import 'package:pirc_render/src/native_math_paragraph.dart';
import 'package:pirc_render/src/native_tex_adapter.dart';

import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart' show loadParityFonts;

const _fixturePath = '../../fixtures/mobile-parity/inline-math-paragraph.json';
const _expectedPath =
    '../../fixtures/mobile-parity/inline-math-paragraph-expected.json';
const _clipboardExpectedPath =
    '../../fixtures/mobile-parity/inline-math-clipboard-expected.json';
const _summaryPath =
    '../../fixtures/mobile-parity/inline-math-paragraph-native-summary.json';

String? _clipboardText;

void main() {
  testWidgets('capture NativeMarkdown inline math paragraph corpus', (
    tester,
  ) async {
    await tester.runAsync(loadParityFonts);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            _clipboardText = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final fixture = _object(jsonDecode(File(_fixturePath).readAsStringSync()));
    final webExpected = _object(
      jsonDecode(File(_expectedPath).readAsStringSync()),
    );
    final clipboardExpected = _object(
      jsonDecode(File(_clipboardExpectedPath).readAsStringSync()),
    );
    expect(clipboardExpected['webRevision'], fixture['webRevision']);
    final clipboardConfigurations = _objects(
      clipboardExpected['configurations'],
    );
    final expectedConfigurations = _objects(webExpected['configurations']);
    final capture = _object(fixture['capture']);
    final allCases = _objects(fixture['cases']);
    final caseFilter = Platform.environment['PIRC_INLINE_MATH_NATIVE_CASE'];
    final configFilter = Platform.environment['PIRC_INLINE_MATH_NATIVE_CONFIG'];
    final cases = caseFilter == null || caseFilter.isEmpty
        ? allCases
        : allCases.where((item) => item['id'] == caseFilter).toList();
    expect(cases, isNotEmpty, reason: 'Unknown case filter $caseFilter');

    final widths = (capture['widths'] as List).cast<num>();
    final themes = (capture['themes'] as List).cast<String>();
    final scales = (capture['textScales'] as List).cast<num>();
    final height = (capture['height'] as num).toDouble();
    final dpr = (capture['deviceScaleFactor'] as num).toDouble();
    final fontSize = (capture['paragraphFontSize'] as num).toDouble();
    final lineHeight = (capture['paragraphLineHeight'] as num).toDouble();
    final output = <Map<String, Object?>>[];
    final failures = <String>[];

    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);

    for (final widthValue in widths) {
      final width = widthValue.toDouble();
      for (final themeName in themes) {
        final brightness = themeName == 'dark'
            ? Brightness.dark
            : Brightness.light;
        final appTheme = theme
            .build(brightness)
            .copyWith(
              textTheme: theme
                  .build(brightness)
                  .textTheme
                  .apply(fontFamily: 'Arial'),
            );
        for (final scaleValue in scales) {
          final scale = scaleValue.toDouble();
          final configId = '${width.toInt()}-$themeName-${_number(scale)}';
          if (configFilter != null &&
              configFilter.isNotEmpty &&
              configFilter != configId) {
            continue;
          }
          final webConfig = expectedConfigurations.firstWhere(
            (entry) => entry['id'] == configId,
          );
          final webCases = {
            for (final entry in _objects(webConfig['cases']))
              entry['id']: entry,
          };
          final clipboardConfig = clipboardConfigurations.firstWhere(
            (entry) => entry['id'] == configId,
          );
          final clipboardCases = {
            for (final entry in _objects(clipboardConfig['cases']))
              entry['id']: entry,
          };
          tester.view.physicalSize = Size(width, height);
          final caseMeasurements = <Map<String, Object?>>[];

          for (final item in cases) {
            final id = item['id'] as String;
            final webCase = _object(webCases[id]);
            final webClipboard =
                _object(
                      _object(clipboardCases[id])['actualClipboard'],
                    )['textPlain']
                    as String;
            final boundaryKey = GlobalKey(
              debugLabel: 'inline-math-$id-$configId',
            );
            final markdownKey = ValueKey<String>(
              'inline-math-markdown-$id-$configId',
            );
            await tester.pumpWidget(
              MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme,
                home: Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: RepaintBoundary(
                      key: boundaryKey,
                      child: Scaffold(
                        body: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: SizedBox(
                              width: width - 32,
                              child: NativeMarkdown(
                                key: markdownKey,
                                source: item['source'] as String,
                                fontSize: fontSize,
                                lineHeight: lineHeight,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final layoutException = tester.takeException();
            if (layoutException != null) {
              failures.add('$configId/$id: $layoutException');
            }

            final markdownFinder = find.byKey(markdownKey);
            final rootElement = markdownFinder.evaluate().single;
            final formulas = _collectFormulas(rootElement, markdownFinder);
            final expectedCount = item['expectedMathCount'] as int;
            if (formulas.length != expectedCount) {
              failures.add(
                '$configId/$id: expected $expectedCount full formulas, '
                'found ${formulas.length}',
              );
            }
            final actualKinds = formulas
                .map((formula) => formula.kind)
                .toList();
            final expectedKinds = (item['expectedKinds'] as List)
                .cast<String>();
            if (!_sameStrings(actualKinds, expectedKinds)) {
              failures.add(
                '$configId/$id: expected kinds $expectedKinds, found $actualKinds',
              );
            }
            for (var index = 0; index < formulas.length; index++) {
              if (formulas[index].model.parseError == null &&
                  formulas[index].model.ast == null) {
                failures.add('$configId/$id formula[$index] lost its Math AST');
              }
              if (formulas[index].kind == 'whole-expression-error' &&
                  formulas[index].fallbackRedText.join().isEmpty) {
                failures.add(
                  '$configId/$id formula[$index] parseError has no visible red source text',
                );
              }
            }

            if (layoutException != null) {
              caseMeasurements.add({
                'id': id,
                'source': item['source'],
                'expectedKinds': expectedKinds,
                'actualKinds': actualKinds,
                'expectedMathCount': expectedCount,
                'actualMathCount': formulas.length,
                'rootRect': null,
                'paragraphs': const [],
                'formulas': [
                  for (final formula in formulas)
                    {
                      'expression': formula.source.expression,
                      'kind': formula.kind,
                      'parseError': formula.model.parseError?.message,
                      'astAvailable': formula.model.ast != null,
                      'actualRedText': formula.fallbackRedText,
                    },
                ],
                'nativeSelectAllClipboard': null,
                'nativeClipboardCaptured': false,
                'webSourceSelectionText': webCase['copySelectionText'],
                'webActualClipboardText': webClipboard,
                'sourceSelectionMatches': false,
                'actualClipboardMatches': false,
                'layoutException': layoutException.toString(),
                'measurementSkipped':
                    'layout failed before child geometry was safe to query',
              });
              continue;
            }

            final paragraphRecords = _paragraphRecords(tester, markdownFinder);
            _clipboardText = null;
            final regionFinder = find.byType(SelectableRegion);
            if (regionFinder.evaluate().isNotEmpty) {
              final selection = tester.state<SelectableRegionState>(
                regionFinder,
              );
              selection.selectAll(SelectionChangedCause.keyboard);
              await tester.pump();
              final copy = selection.contextMenuButtonItems.firstWhere(
                (item) => item.type == ContextMenuButtonType.copy,
              );
              copy.onPressed?.call();
              await tester.pump();
            }

            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(boundaryKey),
            );
            final configCase = <String, Object?>{
              'id': id,
              'source': item['source'],
              'expectedKinds': expectedKinds,
              'actualKinds': actualKinds,
              'expectedMathCount': expectedCount,
              'actualMathCount': formulas.length,
              'rootRect': _rect(tester.getRect(find.byKey(markdownKey))),
              'paragraphs': paragraphRecords,
              'tableCells': _tableCellRecords(tester, markdownFinder),
              'formulas': [
                for (final formula in formulas) _formulaRecord(tester, formula),
              ],
              'nativeSelectAllClipboard': _clipboardText,
              'nativeClipboardCaptured': _clipboardText != null,
              'webSourceSelectionText': webCase['copySelectionText'],
              'webActualClipboardText': webClipboard,
              'sourceSelectionMatches':
                  _clipboardText == webCase['copySelectionText'],
              'actualClipboardMatches': _clipboardText == webClipboard,
              'layoutException': layoutException?.toString(),
              'measurementErrors': layoutException == null
                  ? const <String>[]
                  : [layoutException.toString()],
            };
            if (id == 'inline-before-after') {
              final image = await tester.runAsync(() => _capturePng(boundary));
              if (image == null) {
                throw StateError('PNG capture returned no bytes for $configId');
              }
              final imageName = 'inline-math-$configId-native.png';
              File('build/parity/inline-math-paragraph-native/$imageName')
                ..parent.createSync(recursive: true)
                ..writeAsBytesSync(image);
              configCase['screenshot'] =
                  'apps/android/build/parity/inline-math-paragraph-native/$imageName';
            }
            caseMeasurements.add(configCase);
          }

          output.add({
            'id': configId,
            'viewport': {'width': width, 'height': height},
            'theme': themeName,
            'textScale': scale,
            'deviceScaleFactor': dpr,
            'paragraphTypography': {
              'fontFamily': capture['paragraphFontFamily'],
              'fontSize': fontSize,
              'lineHeight': lineHeight,
            },
            'cases': caseMeasurements,
          });
        }
      }
    }

    final complete = caseFilter == null && configFilter == null;
    final summaryFile = File(
      Platform.environment['PIRC_INLINE_MATH_NATIVE_OUTPUT'] ??
          (complete
              ? _summaryPath
              : 'build/parity/inline-math-paragraph-native/native-summary.json'),
    )..parent.createSync(recursive: true);
    final summaryJson = const JsonEncoder().convert({
      'schemaVersion': 2,
      'fixture': _fixturePath,
      'webExpected': _expectedPath,
      'webClipboardExpected': _clipboardExpectedPath,
      'webRevision': fixture['webRevision'],
      'renderer': 'NativeMarkdown + NativeMathParagraph + flutter_math_fork',
      'capture': {
        'widths': widths,
        'themes': themes,
        'textScales': scales,
        'height': height,
        'deviceScaleFactor': dpr,
        'fontLoader': 'capture_fonts.loadParityFonts; paragraph alias Arial',
        'selection':
            'Native SelectableRegion selectAll followed by actual Copy menu action and clipboard method-channel capture',
        'formulaGeometry':
            'actual Math RenderBoxes for rendered parts, plus actual RichText WidgetSpan placeholder boxes; metadata-only widths are not used',
      },
      'selection': {
        'caseFilter': caseFilter,
        'configFilter': configFilter,
        'completeMatrix': complete,
      },
      'configurations': output,
      'validationErrors': failures,
      'pixelParityAccepted': false,
    });
    summaryFile.writeAsStringSync('$summaryJson\n');
    expect(
      failures,
      isEmpty,
      reason: 'Native inline paragraph capture: ${summaryFile.path}',
    );
  });
}

List<Map<String, Object?>> _tableCellRecords(WidgetTester tester, Finder root) {
  final records = <Map<String, Object?>>[];
  final tables = find.descendant(of: root, matching: find.byType(Table));
  for (final element in tables.evaluate()) {
    final table = element.findRenderObject()! as RenderTable;
    for (var row = 0; row < table.rows; row++) {
      final cells = table.row(row).toList();
      for (var column = 0; column < cells.length; column++) {
        final cell = cells[column];
        final origin = cell.localToGlobal(Offset.zero);
        records.add({
          'row': row,
          'column': column,
          'borderBox': _rect(origin & cell.size),
        });
      }
    }
  }
  return records;
}

class _FormulaCapture {
  const _FormulaCapture({
    required this.source,
    required this.model,
    required this.display,
    required this.tags,
    required this.parts,
    required this.sourceFinder,
    required this.contentFinder,
    required this.paragraphChild,
    required this.formulaIndex,
  });

  final NativeMathTex source;
  final Math model;
  final bool display;
  final List<NativeTexEquationTag> tags;
  final List<Math> parts;
  final Finder sourceFinder;
  final Finder? contentFinder;
  final Widget? paragraphChild;
  final int formulaIndex;

  String get kind => model.parseError != null
      ? 'whole-expression-error'
      : _redAstTexts(model).isNotEmpty
      ? 'rendered-with-unsupported-command'
      : 'rendered';

  List<String> get fallbackRedText => [
    if (paragraphChild is RichText)
      ..._redRichTextWidgetTexts(paragraphChild! as RichText),
    ..._redRichTextTexts(sourceFinder),
    ..._redTextWidgetTexts(sourceFinder),
  ];
}

List<_FormulaCapture> _collectFormulas(Element root, Finder markdownFinder) {
  final result = <_FormulaCapture>[];
  void visit(Element element) {
    final widget = element.widget;
    if (widget is NativeMathParagraphContent) {
      final contentFinder = find.byWidget(widget);
      for (final formula in widget.formulas) {
        result.add(
          _FormulaCapture(
            source: formula.source,
            model: formula.math,
            display: false,
            tags: const [],
            parts: formula.parts,
            sourceFinder: contentFinder,
            contentFinder: contentFinder,
            paragraphChild: widget.child,
            formulaIndex: formula.index,
          ),
        );
      }
      return;
    }
    if (widget is NativeMarkdownMath) {
      final resolved = widget.math.resolve(element);
      final sourceFinder = find.descendant(
        of: markdownFinder,
        matching: find.byWidgetPredicate(
          (candidate) => identical(candidate, widget.math),
        ),
      );
      final actualParts = find
          .descendant(of: sourceFinder, matching: find.byType(Math))
          .evaluate()
          .map((candidate) => candidate.widget as Math)
          .toList();
      result.add(
        _FormulaCapture(
          source: widget.math,
          model: resolved.math,
          display: widget.display,
          tags: resolved.tags,
          parts: actualParts,
          sourceFinder: sourceFinder,
          contentFinder: null,
          paragraphChild: null,
          formulaIndex: 0,
        ),
      );
      return;
    }
    element.visitChildren(visit);
  }

  visit(root);
  return result;
}

Map<String, Object?> _formulaRecord(
  WidgetTester tester,
  _FormulaCapture formula,
) {
  final partRects = <Rect>[];
  for (final part in formula.parts) {
    final finder = find.descendant(
      of: formula.sourceFinder,
      matching: find.byWidgetPredicate((widget) => identical(widget, part)),
    );
    if (finder.evaluate().isNotEmpty) {
      partRects.add(tester.getRect(finder.first));
    }
  }
  final nativeParts = formula.contentFinder == null
      ? <Map<String, Object?>>[]
      : [
          for (final element
              in find
                  .descendant(
                    of: formula.contentFinder!,
                    matching: find.byType(NativeMathPart),
                  )
                  .evaluate())
            if ((element.widget as NativeMathPart).formulaIndex ==
                formula.formulaIndex)
              _nativePartRecord(tester, formula, element),
        ];
  final content = formula.contentFinder == null
      ? null
      : tester.widget<NativeMathParagraphContent>(formula.contentFinder!);
  final richTextFinder = content == null
      ? null
      : find.descendant(
          of: formula.contentFinder!,
          matching: find.byWidgetPredicate(
            (widget) => identical(widget, content.child),
          ),
        );
  final placeholderBoxes =
      richTextFinder == null || richTextFinder.evaluate().isEmpty
      ? <Map<String, Object?>>[]
      : _placeholderRecords(tester, richTextFinder.first);
  final renderedText = content?.child is RichText
      ? (content!.child as RichText).text.toPlainText(
          includePlaceholders: true,
          includeSemanticsLabels: false,
        )
      : null;
  final displayBox = find.descendant(
    of: formula.sourceFinder,
    matching: find.byType(NativeMathDisplayBlock),
  );
  final paintedPartUnion = _rectUnion(partRects);
  final fallbackRects = _sourceTextRects(
    tester,
    formula.sourceFinder,
    formula.source.expression,
  );
  return {
    'expression': formula.source.expression,
    'kind': formula.kind,
    'display': formula.display,
    'parseError': formula.model.parseError?.message,
    'astAvailable': formula.model.ast != null,
    'redAstTexts': _redAstTexts(formula.model),
    'actualRedText': formula.fallbackRedText,
    'tags': [
      for (final tag in formula.tags) {'automatic': tag.automatic},
    ],
    'paintedPartCount': partRects.length,
    'paintedPartRects': _rects(partRects),
    'paintedPartUnion': paintedPartUnion == null
        ? null
        : _rect(paintedPartUnion),
    'parts': nativeParts,
    'paragraphPlaceholderRects': placeholderBoxes,
    'paragraphTextWithPlaceholders': renderedText,
    'displayBlockRect': displayBox.evaluate().isEmpty
        ? null
        : _rect(tester.getRect(displayBox.first)),
    'richTextFallbackRects': fallbackRects,
  };
}

Map<String, Object?> _nativePartRecord(
  WidgetTester tester,
  _FormulaCapture formula,
  Element element,
) {
  final widget = element.widget as NativeMathPart;
  final elementFinder = find.byElementPredicate(
    (candidate) => identical(candidate, element),
  );
  final renderMath = _findNativeInlineMathRenderObject(element);
  final baselineY = renderMath == null
      ? null
      : renderMath.localToGlobal(Offset.zero).dy + renderMath.baseline;
  final mathRect = _mathPartRect(
    tester,
    formula.contentFinder!,
    formula.parts[widget.partIndex],
  );
  return {
    'partIndex': widget.partIndex,
    'placeholderBox': _rect(tester.getRect(elementFinder)),
    'baselineY': baselineY,
    'mathRenderBox': mathRect == null ? null : _rect(mathRect),
  };
}

RenderNativeInlineMath? _findNativeInlineMathRenderObject(Element root) {
  RenderNativeInlineMath? result;
  void visit(Element element) {
    if (result != null) return;
    if (element is RenderObjectElement &&
        element.renderObject is RenderNativeInlineMath) {
      result = element.renderObject as RenderNativeInlineMath;
      return;
    }
    element.visitChildren(visit);
  }

  visit(root);
  return result;
}

Rect? _mathPartRect(WidgetTester tester, Finder contentFinder, Math math) {
  final finder = find.descendant(
    of: contentFinder,
    matching: find.byWidgetPredicate((widget) => identical(widget, math)),
  );
  return finder.evaluate().isEmpty ? null : tester.getRect(finder.first);
}

List<Map<String, Object?>> _paragraphRecords(
  WidgetTester tester,
  Finder markdownFinder,
) {
  final records = <Map<String, Object?>>[];
  final seen = <RenderParagraph>{};
  for (final element
      in find
          .descendant(
            of: markdownFinder,
            matching: find.byWidgetPredicate((widget) => widget is RichText),
          )
          .evaluate()) {
    final paragraph = element.renderObject;
    if (paragraph is! RenderParagraph || !seen.add(paragraph)) continue;
    final widget = element.widget as RichText;
    final text = widget.text.toPlainText(
      includePlaceholders: true,
      includeSemanticsLabels: false,
    );
    final textBoxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: text.length),
    );
    records.add({
      'textWithPlaceholders': text,
      'textWithoutPlaceholders': widget.text.toPlainText(),
      'box': _rect(paragraph.localToGlobal(Offset.zero) & paragraph.size),
      'overflow': paragraph.overflow.toString(),
      'textBoxes': [
        for (final box in textBoxes)
          {
            'left': box.left,
            'top': box.top,
            'right': box.right,
            'bottom': box.bottom,
          },
      ],
      'placeholders': _placeholderRecords(
        tester,
        find.byElementPredicate((candidate) => identical(candidate, element)),
      ),
    });
  }
  return records;
}

List<Map<String, Object?>> _placeholderRecords(
  WidgetTester tester,
  Finder richTextFinder,
) {
  if (richTextFinder.evaluate().isEmpty) return const [];
  final paragraph = tester.renderObject<RenderParagraph>(richTextFinder);
  final widget = tester.widget<RichText>(richTextFinder);
  final text = widget.text.toPlainText(
    includePlaceholders: true,
    includeSemanticsLabels: false,
  );
  final result = <Map<String, Object?>>[];
  for (var offset = 0; offset < text.length; offset++) {
    if (text.codeUnitAt(offset) != 0xfffc) continue;
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: offset, extentOffset: offset + 1),
    );
    result.add({
      'offset': offset,
      'textBoxRects': [for (final box in boxes) _rect(box.toRect())],
    });
  }
  return result;
}

List<String> _redAstTexts(Math math) {
  final root = math.ast?.greenRoot;
  if (root == null) return const [];
  String text(GreenNode node) => node is SymbolNode
      ? node.symbol
      : node.children.whereType<GreenNode>().map(text).join();
  final result = <String>[];
  void visit(GreenNode node) {
    if (node is StyleNode &&
        node.optionsDiff.color == const Color(0xffcc0000)) {
      result.add(text(node));
    }
    for (final child in node.children.whereType<GreenNode>()) {
      visit(child);
    }
  }

  visit(root);
  return result;
}

List<String> _redRichTextTexts(Finder scope) {
  final result = <String>[];
  for (final element
      in find
          .descendant(
            of: scope,
            matching: find.byWidgetPredicate((widget) => widget is RichText),
          )
          .evaluate()) {
    result.addAll(_redRichTextWidgetTexts(element.widget as RichText));
  }
  return result;
}

List<String> _redRichTextWidgetTexts(RichText widget) {
  final result = <String>[];
  void visit(InlineSpan span, Color? inheritedColor) {
    if (span is! TextSpan) return;
    final color = span.style?.color ?? inheritedColor;
    if (span.text != null && color == const Color(0xffcc0000)) {
      result.add(span.text!);
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      visit(child, color);
    }
  }

  visit(widget.text, widget.text.style?.color);
  return result;
}

List<String> _redTextWidgetTexts(Finder scope) {
  final result = <String>[];
  for (final element
      in find
          .descendant(
            of: scope,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Text &&
                  widget.style?.color == const Color(0xffcc0000),
            ),
          )
          .evaluate()) {
    final widget = element.widget as Text;
    final data = widget.data;
    if (data != null) result.add(data);
  }
  return result;
}

List<Map<String, Object?>> _sourceTextRects(
  WidgetTester tester,
  Finder scope,
  String source,
) {
  final result = <Map<String, Object?>>[];
  final normalized = _collapseWhitespace(source);
  for (final element
      in find
          .descendant(
            of: scope,
            matching: find.byWidgetPredicate((widget) => widget is RichText),
          )
          .evaluate()) {
    final widget = element.widget as RichText;
    final text = widget.text.toPlainText(
      includePlaceholders: true,
      includeSemanticsLabels: false,
    );
    final start = text.indexOf(normalized);
    if (start < 0) continue;
    final paragraph = element.renderObject;
    if (paragraph is! RenderParagraph) continue;
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: start + normalized.length),
    );
    result.add({
      'text': normalized,
      'rects': [for (final box in boxes) _rect(box.toRect())],
    });
  }
  final textWidgets = find.descendant(
    of: scope,
    matching: find.byWidgetPredicate(
      (widget) => widget is Text && widget.data?.contains(source) == true,
    ),
  );
  for (final element in textWidgets.evaluate()) {
    result.add({
      'text': source,
      'widgetRect': _rect(
        tester.getRect(
          find.byElementPredicate((candidate) => identical(candidate, element)),
        ),
      ),
    });
  }
  return result;
}

Future<Uint8List> _capturePng(RenderRepaintBoundary boundary) async {
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Map<String, Object?> _object(Object? value) =>
    (value as Map).cast<String, Object?>();
List<Map<String, Object?>> _objects(Object? value) =>
    (value as List).map(_object).toList(growable: false);
bool _sameStrings(List<String> a, List<String> b) =>
    a.length == b.length &&
    List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);
String _number(double value) =>
    value == value.roundToDouble() ? value.toInt().toString() : '$value';
String _collapseWhitespace(String value) =>
    value.replaceAll(RegExp(r'[\t\n\f\r ]+'), ' ').trim();
List<double> _rect(Rect value) => [
  value.left,
  value.top,
  value.width,
  value.height,
];
List<List<double>> _rects(List<Rect> values) => [
  for (final value in values) _rect(value),
];
Rect? _rectUnion(List<Rect> rects) {
  if (rects.isEmpty) return null;
  var result = rects.first;
  for (final rect in rects.skip(1)) {
    result = result.expandToInclude(rect);
  }
  return result;
}
