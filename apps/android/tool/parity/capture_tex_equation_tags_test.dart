// Capture the actual NativeMarkdown TeX equation-tag tree. Run from
// apps/android with:
//   flutter test tool/parity/capture_tex_equation_tags_test.dart
// A filtered run writes to build/ unless PIRC_TEX_TAG_CAPTURE_OUTPUT is set.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_math_fork/src/ast/nodes/symbol.dart';
import 'package:flutter_math_fork/src/ast/syntax_tree.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/native_math_block.dart';
import 'package:pirc_render/src/native_math_error.dart';
import 'package:pirc_render/src/native_math_tags.dart';
import 'package:pirc_render/src/native_math_paragraph.dart';
import 'package:pirc_render/src/native_tex_adapter.dart';

import 'capture_fonts.dart' show loadParityFonts;
import '../../test/live_test.dart' show theme;

// ignore_for_file: implementation_imports

const _fixturePath = '../../fixtures/mobile-parity/tex-equation-tags.json';
const _defaultSummaryPath =
    '../../fixtures/mobile-parity/tex-equation-tags-native-summary.json';
const _buildOutputPath =
    'build/parity/tex-equation-tags-native/native-measurements.json';

void main() {
  testWidgets('capture NativeMarkdown equation tags and document numbering', (
    tester,
  ) async {
    await tester.runAsync(loadParityFonts);

    final fixture = _object(jsonDecode(File(_fixturePath).readAsStringSync()));
    final capture = _object(fixture['capture']);
    final allCases = _objects(fixture['cases']);
    final caseFilter = Platform.environment['PIRC_TEX_TAG_CASE'];
    final configFilter = Platform.environment['PIRC_TEX_TAG_CONFIG'];
    final cases = caseFilter == null || caseFilter.isEmpty
        ? allCases
        : allCases.where((item) => item['id'] == caseFilter).toList();
    expect(cases, isNotEmpty, reason: 'No matching TeX tag case: $caseFilter');

    final widths = (capture['widths'] as List).cast<num>();
    final themes = (capture['themes'] as List).cast<String>();
    final textScales = (capture['textScales'] as List).cast<num>();
    final height = (capture['height'] as num).toDouble();
    final deviceScale = (capture['deviceScaleFactor'] as num).toDouble();
    final outputDir = Directory('build/parity/tex-equation-tags-native')
      ..createSync(recursive: true);
    final configurations = <Map<String, Object?>>[];
    final measurementErrors = <String>[];
    var stageCount = 0;

    tester.view.devicePixelRatio = deviceScale;
    addTearDown(tester.view.reset);

    for (final widthValue in widths) {
      final width = widthValue.toDouble();
      for (final themeName in themes) {
        final brightness = themeName == 'dark'
            ? Brightness.dark
            : Brightness.light;
        for (final scaleValue in textScales) {
          final textScale = scaleValue.toDouble();
          final configId = '${width.toInt()}-$themeName-${_num(textScale)}';
          if (configFilter != null &&
              configFilter.isNotEmpty &&
              configFilter != configId) {
            continue;
          }

          tester.view.physicalSize = Size(width, height);
          final appTheme = theme
              .build(brightness)
              .copyWith(
                textTheme: theme
                    .build(brightness)
                    .textTheme
                    .apply(fontFamily: 'Arial'),
              );
          final capturedCases = <Map<String, Object?>>[];

          for (final item in cases) {
            final id = item['id'] as String;
            final boundaryKey = GlobalKey(debugLabel: 'tex-tags-$id-$configId');
            final markdownKey = ValueKey<String>('tex-tags-$id-$configId');
            final stageSources = <(String, String)>[
              ('initial', item['source'] as String),
              for (final (index, source)
                  in (item['rerenderSources'] as List).cast<String>().indexed)
                ('rerender-${index + 1}', source),
            ];
            final stages = <Map<String, Object?>>[];

            for (final (stageId, source) in stageSources) {
              await tester.pumpWidget(
                _captureApp(
                  width: width,
                  height: height,
                  textScale: textScale,
                  themeData: appTheme,
                  boundaryKey: boundaryKey,
                  markdownKey: markdownKey,
                  source: source,
                  fontSize: (capture['paragraphFontSize'] as num).toDouble(),
                  lineHeight: (capture['paragraphLineHeight'] as num)
                      .toDouble(),
                ),
              );
              await tester.pumpAndSettle();

              final exception = tester.takeException();
              final stageErrors = <String>[];
              if (exception != null) {
                stageErrors.add('Flutter layout/build exception: $exception');
              }

              final boundaryFinder = find.byKey(boundaryKey);
              final markdownFinder = find.byKey(markdownKey);
              final texElements = _collectNativeFormulas(
                markdownFinder.evaluate().single,
                markdownFinder,
              );
              final formulas = <Map<String, Object?>>[];
              for (var index = 0; index < texElements.length; index++) {
                formulas.add(
                  _captureFormula(
                    tester,
                    texElements[index],
                    index,
                    stageErrors,
                  ),
                );
              }

              if (formulas.isEmpty) {
                stageErrors.add('No full source formula models found');
              }
              final viewportBox = _rectFor(tester, boundaryFinder);
              final markdownBox = _rectFor(tester, markdownFinder);
              final screenshotBytes = await _capturePng(tester, boundaryKey);
              final screenshotName =
                  'tex-tags-$id-${width.toInt()}-$themeName-scale${_num(textScale)}-$stageId-native.png';
              File(
                '${outputDir.path}/$screenshotName',
              ).writeAsBytesSync(screenshotBytes);

              final stage = <String, Object?>{
                'stageId': stageId,
                'source': source,
                'viewportBox': viewportBox,
                'markdownBox': markdownBox,
                'bodyColor': _color(appTheme.scaffoldBackgroundColor),
                'formulaCount': formulas.length,
                'formulas': formulas,
                'layoutExceptions': stageErrors,
                'screenshot':
                    'apps/android/build/parity/tex-equation-tags-native/$screenshotName',
              };
              stages.add(stage);
              stageCount++;
              measurementErrors.addAll(
                stageErrors.map((error) => '$configId/$id/$stageId: $error'),
              );
            }

            capturedCases.add({'id': id, 'stages': stages});
          }

          configurations.add({
            'id': configId,
            'viewport': {'width': width, 'height': height},
            'theme': themeName,
            'textScale': textScale,
            'deviceScaleFactor': deviceScale,
            'fontLoader': 'capture_fonts.loadParityFonts; body alias Arial',
            'cases': capturedCases,
          });
        }
      }
    }

    final filtered = caseFilter != null || configFilter != null;
    final outputPath = File(
      Platform.environment['PIRC_TEX_TAG_CAPTURE_OUTPUT'] ??
          (filtered ? _buildOutputPath : _defaultSummaryPath),
    )..parent.createSync(recursive: true);
    outputPath.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': 1,
        'fixture': _fixturePath,
        'webExpected':
            '../../fixtures/mobile-parity/tex-equation-tags-expected.json',
        'webRevision': fixture['webRevision'],
        'renderer': 'NativeMarkdown + NativeMathTex + flutter_math_fork',
        'capture': {
          'widths': widths,
          'height': height,
          'themes': themes,
          'textScales': textScales,
          'deviceScaleFactor': deviceScale,
          'paragraphFontFamily': capture['paragraphFontFamily'],
          'paragraphFontSize': capture['paragraphFontSize'],
          'paragraphLineHeight': capture['paragraphLineHeight'],
          'fontLoader': 'capture_fonts.loadParityFonts; body alias Arial',
          'formulaEvidence':
              'NativeMathTex, Math.parseError, parseNativeTex tag metadata, NativeTaggedMath.tags Math AST/RichText and real render boxes',
        },
        'selection': {
          'caseFilter': caseFilter,
          'configFilter': configFilter,
          'completeMatrix': !filtered,
        },
        'stageCount': stageCount,
        'configurations': configurations,
        'measurementErrors': measurementErrors,
        'visualParityAccepted': false,
      }),
    );

    // Structural capture failures fail the test after the partial evidence is
    // written. Browser/native differences are left to the comparator summary.
    expect(
      measurementErrors,
      isEmpty,
      reason: 'Native TeX tag capture errors: ${outputPath.path}',
    );
  });
}

Widget _captureApp({
  required double width,
  required double height,
  required double textScale,
  required ThemeData themeData,
  required GlobalKey boundaryKey,
  required Key markdownKey,
  required String source,
  required double fontSize,
  required double lineHeight,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: themeData,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
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
                  source: source,
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
);

class _NativeFormula {
  const _NativeFormula({
    required this.source,
    required this.model,
    required this.scopeFinder,
    required this.partFinders,
    required this.contentFinder,
    required this.formulaIndex,
  });

  final NativeMathTex source;
  final Math model;
  final Finder scopeFinder;
  final List<Element> partFinders;
  final Finder? contentFinder;
  final int formulaIndex;
}

List<_NativeFormula> _collectNativeFormulas(
  Element root,
  Finder markdownFinder,
) {
  final formulas = <_NativeFormula>[];
  void visit(Element element) {
    final widget = element.widget;
    if (widget is NativeMathParagraphContent) {
      final contentFinder = find.byWidget(widget);
      for (final formula in widget.formulas) {
        final parts = <Element>[];
        for (final part in formula.parts) {
          final finder = find.descendant(
            of: contentFinder,
            matching: find.byWidgetPredicate(
              (candidate) => identical(candidate, part),
            ),
          );
          if (finder.evaluate().isNotEmpty) parts.add(finder.evaluate().single);
        }
        formulas.add(
          _NativeFormula(
            source: formula.source,
            model: formula.math,
            scopeFinder: contentFinder,
            partFinders: parts,
            contentFinder: contentFinder,
            formulaIndex: formula.index,
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
      final parts = find
          .descendant(of: sourceFinder, matching: find.byType(Math))
          .evaluate()
          .toList(growable: false);
      formulas.add(
        _NativeFormula(
          source: widget.math,
          model: resolved.math,
          scopeFinder: sourceFinder,
          partFinders: parts,
          contentFinder: null,
          formulaIndex: 0,
        ),
      );
      return;
    }
    element.visitChildren(visit);
  }

  visit(root);
  return formulas;
}

Map<String, Object?> _captureFormula(
  WidgetTester tester,
  _NativeFormula formula,
  int index,
  List<String> errors,
) {
  final source = formula.source;
  final sourceFinder = formula.scopeFinder;
  final mathElements = formula.partFinders;
  final taggedElements = find
      .descendant(of: sourceFinder, matching: find.byType(NativeTaggedMath))
      .evaluate()
      .toList(growable: false);

  final taggedWidgets = taggedElements
      .map((element) => element.widget as NativeTaggedMath)
      .toList(growable: false);
  final originalMath = formula.model;
  if (originalMath.parseError == null && originalMath.ast == null) {
    errors.add(
      'Formula $index (${source.expression}) lost its complete Math AST',
    );
  }

  NativeTexParseResult? parsed;
  Map<String, Object?>? parserError;
  try {
    parsed = parseNativeTex(source.expression, settings: source.settings);
  } on ParseException catch (error) {
    parserError = _parseError(error);
  } on Object catch (error) {
    parserError = {'type': error.runtimeType.toString(), 'message': '$error'};
  }

  final displayFinder = find.descendant(
    of: sourceFinder,
    matching: find.byType(NativeMathDisplayBlock),
  );
  final inlineFinder = formula.contentFinder == null
      ? find.descendant(of: sourceFinder, matching: find.byType(NativeMathPart))
      : find.descendant(
          of: sourceFinder,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is NativeMathPart &&
                widget.formulaIndex == formula.formulaIndex,
          ),
        );
  final errorFinder = find.descendant(
    of: sourceFinder,
    matching: find.byType(NativeMathErrorText),
  );
  final taggedFinder = find.descendant(
    of: sourceFinder,
    matching: find.byType(NativeTaggedMath),
  );
  final bodyWidget = taggedWidgets.isNotEmpty
      ? taggedWidgets.first.math
      : mathElements.isNotEmpty
      ? mathElements.first.widget
      : null;
  final bodyMathFinder = bodyWidget == null
      ? null
      : find.descendant(
          of: sourceFinder,
          matching: find.byWidgetPredicate(
            (widget) => identical(widget, bodyWidget),
          ),
        );

  final nativeTags = <Map<String, Object?>>[];
  var tagOrdinal = 0;
  for (final tagged in taggedWidgets) {
    final taggedFinderForWidget = find.descendant(
      of: sourceFinder,
      matching: find.byWidgetPredicate((widget) => identical(widget, tagged)),
    );
    final bodyFinder = find.descendant(
      of: taggedFinderForWidget,
      matching: find.byWidgetPredicate(
        (widget) => identical(widget, tagged.math),
      ),
    );
    RenderBox? bodyBox;
    if (bodyFinder.evaluate().isNotEmpty) {
      final renderObject = tester.renderObject<RenderObject>(bodyFinder);
      if (renderObject is RenderBox) bodyBox = renderObject;
    }

    for (var localIndex = 0; localIndex < tagged.tags.length; localIndex++) {
      final tag = tagged.tags[localIndex];
      final tagMath = tag.math;
      final tagFinder = find.descendant(
        of: taggedFinderForWidget,
        matching: find.byWidgetPredicate(
          (widget) => identical(widget, tagMath),
        ),
      );
      final actualMath = tagMath is Math ? tagMath : null;
      final richTextRuns = _richTextRuns(tester, tagFinder);
      final parsedTag = parsed != null && tagOrdinal < parsed.tags.length
          ? parsed.tags[tagOrdinal]
          : null;
      if (tagFinder.evaluate().isEmpty) {
        errors.add('Native equation tag $tagOrdinal has no mounted widget');
      }
      final tagBox = tagFinder.evaluate().isEmpty
          ? null
          : _rectFor(tester, tagFinder);
      final anchor = tag.anchor;
      final anchorBox = anchor?.renderBox;

      nativeTags.add({
        'index': tagOrdinal,
        'localIndex': localIndex,
        'automatic': parsedTag?.automatic,
        'astAvailable': actualMath?.ast != null,
        'astRootType': actualMath?.ast?.greenRoot.runtimeType.toString(),
        'astSymbols': _astSymbols(actualMath?.ast),
        'astSymbolText': _astSymbols(actualMath?.ast).join(),
        'richTextRuns': richTextRuns,
        'box': tagBox,
        'baseline': _baselineFor(tester, tagFinder),
        'textColor': _color(actualMath?.textStyle?.color),
        'optionsColor': _color(actualMath?.options?.color),
        'optionsFontSize': actualMath?.options?.fontSize,
        'anchor': anchor == null
            ? null
            : {
                'box': anchorBox == null ? null : _rectOfBox(anchorBox),
                'baselineOffsetWithinBody': bodyBox == null
                    ? null
                    : anchor.baselineOffsetWithin(bodyBox),
              },
      });
      tagOrdinal++;
    }
  }

  final mathError = originalMath.parseError;
  final actualKind = mathError == null
      ? 'rendered'
      : 'whole-expression-parse-error';
  final errorWidgets = [
    for (final element in errorFinder.evaluate())
      if (element.widget case final NativeMathErrorText widget)
        {
          'source': widget.source,
          'bodyFontSize': widget.bodyFontSize,
          'lineHeight': widget.lineHeight,
          'block': widget.block,
          'fontFamily': widget.fontFamily,
          'box': _rectFor(
            tester,
            find.byWidgetPredicate((candidate) => identical(candidate, widget)),
          ),
        },
  ];

  final widgets = <String, Object?>{};
  if (displayFinder.evaluate().isNotEmpty) {
    widgets['displayBlockBox'] = _rectFor(tester, displayFinder.first);
  }
  if (inlineFinder.evaluate().isNotEmpty) {
    widgets['inlineBox'] = _rectFor(tester, inlineFinder.first);
  }
  if (taggedFinder.evaluate().isNotEmpty) {
    widgets['taggedMathBox'] = _rectFor(tester, taggedFinder.first);
    widgets['taggedMathBaseline'] = _baselineFor(tester, taggedFinder.first);
  }
  if (bodyMathFinder != null && bodyMathFinder.evaluate().isNotEmpty) {
    widgets['bodyMathBox'] = _rectFor(tester, bodyMathFinder);
    widgets['bodyMathBaseline'] = _baselineFor(tester, bodyMathFinder);
  }
  if (errorFinder.evaluate().isNotEmpty) {
    widgets['errorBox'] = _rectFor(tester, errorFinder.first);
  }

  final nativeTagCount = taggedWidgets.fold<int>(
    0,
    (sum, tagged) => sum + tagged.tags.length,
  );
  if (parsed != null && nativeTagCount != parsed.tags.length) {
    errors.add(
      'Formula ${source.expression} parser reported ${parsed.tags.length} tags, '
      'but mounted NativeTaggedMath contains $nativeTagCount',
    );
  }
  final bodyRichTextRuns = bodyMathFinder == null
      ? const <Map<String, Object?>>[]
      : _richTextRuns(tester, bodyMathFinder);

  return {
    'index': index,
    'expression': source.expression,
    'mathStyle': source.mathStyle.name,
    'displayMode': source.settings.displayMode,
    'kind': actualKind,
    'parseError': _parseError(mathError),
    'reparseError': parserError,
    'astAvailable': originalMath.ast != null,
    'astRootType': originalMath.ast?.greenRoot.runtimeType.toString(),
    'automaticNumberCount': parsed?.automaticNumberCount,
    'parsedTagMetadata': parsed == null
        ? const <Object?>[]
        : [
            for (final (tagIndex, tag) in parsed.tags.indexed)
              {
                'index': tagIndex,
                'automatic': tag.automatic,
                'anchorAvailable': tag.anchor != null,
                'contentAstSymbols': _astSymbols(
                  tag.content == null
                      ? null
                      : SyntaxTree(greenRoot: tag.content!),
                ),
              },
          ],
    'tags': nativeTags,
    'tagCount': nativeTagCount,
    'tagMathCount': taggedWidgets.fold<int>(
      0,
      (sum, tagged) => sum + tagged.tags.length,
    ),
    'renderedMathPartCount': mathElements.length,
    'bodyMathRichTextRuns': bodyRichTextRuns,
    'bodyMathRichTextUnion': _rectUnion(
      bodyRichTextRuns.map((run) => run['box']).whereType<Map>().map(_toRect),
    ),
    'layout': widgets,
    'errorWidgets': errorWidgets,
    'bodyMathColor': _color(originalMath.textStyle?.color),
    'bodyOptionsColor': _color(originalMath.options?.color),
    'bodyOptionsFontSize': originalMath.options?.fontSize,
  };
}

List<String> _astSymbols(SyntaxTree? ast) {
  if (ast == null) return const [];
  final result = <String>[];
  void visit(GreenNode node) {
    if (node is SymbolNode) {
      result.add(node.symbol);
      return;
    }
    for (final child in node.children.whereType<GreenNode>()) {
      visit(child);
    }
  }

  visit(ast.greenRoot);
  return result;
}

List<Map<String, Object?>> _richTextRuns(WidgetTester tester, Finder root) => [
  for (final element
      in find.descendant(of: root, matching: find.byType(RichText)).evaluate())
    if (element.widget case final RichText richText)
      {
        'text': richText.text.toPlainText(),
        'box': _rectFor(
          tester,
          find.byWidgetPredicate((widget) => identical(widget, richText)),
        ),
        'color': _color(richText.text.style?.color),
        'fontFamily': richText.text.style?.fontFamily,
        'fontSize': richText.text.style?.fontSize,
        'lineHeight': richText.text.style?.height,
        'baseline': _baselineFor(
          tester,
          find.byWidgetPredicate((widget) => identical(widget, richText)),
        ),
      },
];

Map<String, Object?>? _rectFor(WidgetTester tester, Finder finder) {
  if (finder.evaluate().isEmpty) return null;
  try {
    return _rect(tester.getRect(finder));
  } on Object {
    return null;
  }
}

Map<String, Object?> _rect(Rect rect) => {
  'left': rect.left,
  'top': rect.top,
  'width': rect.width,
  'height': rect.height,
  'right': rect.right,
  'bottom': rect.bottom,
};

Rect? _toRect(Map box) {
  final left = (box['left'] as num?)?.toDouble();
  final top = (box['top'] as num?)?.toDouble();
  final width = (box['width'] as num?)?.toDouble();
  final height = (box['height'] as num?)?.toDouble();
  if (left == null || top == null || width == null || height == null) {
    return null;
  }
  return Rect.fromLTWH(left, top, width, height);
}

Map<String, Object?>? _rectUnion(Iterable<Rect?> rects) {
  final values = rects.whereType<Rect>().toList(growable: false);
  if (values.isEmpty) return null;
  var result = values.first;
  for (final rect in values.skip(1)) {
    result = result.expandToInclude(rect);
  }
  return _rect(result);
}

Map<String, Object?> _rectOfBox(RenderBox box) => _rect(
  MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size),
);

double? _baselineFor(WidgetTester tester, Finder finder) {
  if (finder.evaluate().isEmpty) return null;
  try {
    final renderObject = tester.renderObject<RenderObject>(finder);
    return renderObject is RenderBox
        ? renderObject.getDistanceToBaseline(TextBaseline.alphabetic)
        : null;
  } on Object {
    return null;
  }
}

Map<String, Object?>? _parseError(ParseException? error) => error == null
    ? null
    : {
        'type': error.runtimeType.toString(),
        'message': error.message,
        'position': error.position,
        'token': error.token?.text,
      };

String? _color(Color? color) => color == null
    ? null
    : '#${color.toARGB32().toRadixString(16).padLeft(8, '0')}';

String _num(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();

Map<String, dynamic> _object(Object? value) =>
    (value as Map).cast<String, dynamic>();

List<Map<String, dynamic>> _objects(Object? value) =>
    (value as List).map(_object).toList(growable: false);

Future<List<int>> _capturePng(WidgetTester tester, GlobalKey key) async {
  final boundary = key.currentContext?.findRenderObject();
  if (boundary is! RenderRepaintBoundary) {
    throw StateError('Native equation-number screenshot was not laid out');
  }
  final data = await tester.runAsync<List<int>>(() async {
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
  if (data == null) throw StateError('Native screenshot returned no bytes');
  return data;
}
