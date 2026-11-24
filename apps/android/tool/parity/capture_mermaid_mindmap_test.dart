import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/mindmap_rendering.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'capture_fonts.dart';
import '../../test/live_test.dart' show theme;
import 'mermaid_font_tracking.dart';

const _fixturePath = '../../fixtures/mobile-parity/mermaid-mindmap.json';
const _expectedPath =
    '../../fixtures/mobile-parity/mermaid-mindmap-expected.json';
const _fullOutputPath = 'build/parity/mermaid-mindmap-native';
const _sourceBodyLineHeight = 1.65;
final _fontDiagnosticOnly =
    Platform.environment['MINDMAP_FONT_DIAGNOSTIC'] == '1';
final _outputPath = _fontDiagnosticOnly
    ? 'build/parity/mermaid-mindmap-font-diagnostic'
    : _fullOutputPath;
double? _sfns13LetterSpacing;

Map<String, dynamic> _map(Object? value) =>
    (value as Map).cast<String, dynamic>();

List<Map<String, dynamic>> _maps(Object? value) =>
    (value as List).map(_map).toList();

double _num(Object? value) =>
    value is num ? value.toDouble() : double.parse(value as String);

Map<String, double> _rect(Rect rect) => {
  'x': rect.left,
  'y': rect.top,
  'width': rect.width,
  'height': rect.height,
};

Map<String, double> _rectDelta(Rect actual, Map<String, dynamic> expected) => {
  'x': actual.left - _num(expected['x']),
  'y': actual.top - _num(expected['y']),
  'width': actual.width - _num(expected['width']),
  'height': actual.height - _num(expected['height']),
};

Map<String, Object?> _lineBoxFontDiagnostic(BuildContext context) {
  final defaultStyle = DefaultTextStyle.of(context).style;
  final bodyStyle = Theme.of(context).textTheme.bodyMedium;
  final scaler = MediaQuery.textScalerOf(context);

  double preferredLineHeight(String? fontFamily) {
    final painter = TextPainter(
      text: TextSpan(
        text: ' ',
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: 15,
          letterSpacing: 0,
        ),
      ),
      textScaler: scaler,
      textDirection: Directionality.of(context),
    )..layout();
    final height = painter.preferredLineHeight;
    painter.dispose();
    return height;
  }

  Map<String, Object?> styleRecord(TextStyle? style) => {
    'fontFamily': style?.fontFamily,
    'fontSize': style?.fontSize,
    'height': style?.height,
    'fontWeight': style?.fontWeight?.value,
  };

  return {
    'lineBoxRuntimeType': '_MermaidSvgLineBox',
    'textScale': scaler.scale(1),
    'inheritedDefaultTextStyle': styleRecord(defaultStyle),
    'themeBodyMedium': styleRecord(bodyStyle),
    'lineBoxProbeFontSize': 15,
    'inheritedDefaultPreferredLineHeight': preferredLineHeight(
      defaultStyle.fontFamily,
    ),
    'actualLineBoxFontFamily': bodyStyle?.fontFamily,
    'actualLineBoxPreferredLineHeight': preferredLineHeight(
      bodyStyle?.fontFamily,
    ),
    'themeBodyPreferredLineHeight': preferredLineHeight(bodyStyle?.fontFamily),
  };
}

Map<String, dynamic> _referenceCase(
  Map<String, dynamic> expected,
  int width,
  String brightness,
  double textScale,
  String id,
) {
  final themeRow = _map(_map(expected['themes'])[brightness]);
  final widthRow = _maps(
    themeRow['widths'],
  ).singleWhere((row) => row['width'] == width);
  final scaleRow = _maps(
    widthRow['scales'],
  ).singleWhere((row) => _num(row['textScale']) == textScale);
  return _maps(scaleRow['cases']).singleWhere((row) => row['id'] == id);
}

Future<void> _loadComparisonFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    await loadParityFonts();
    final sfnsBytes = await File(
      '/System/Library/Fonts/SFNS.ttf',
    ).readAsBytes();
    _sfns13LetterSpacing = SfntFontTracking.parse(sfnsBytes).letterSpacing(13);
    await (FontLoader(
      'Mermaid reference',
    )..addFont(Future.value(ByteData.sublistView(sfnsBytes)))).load();
  });
}

ThemeData _comparisonTheme(Brightness brightness) {
  final base = theme.build(brightness);
  return base.copyWith(textTheme: base.textTheme.apply(fontFamily: 'Arial'));
}

ThemeData _mermaidTheme(ThemeData base) => base.copyWith(
  extensions: [
    ...base.extensions.values,
    NativeMindmapTypography(
      fontFamily: 'Mermaid reference',
      labelLetterSpacing: _sfns13LetterSpacing!,
    ),
  ],
);

Rect _globalRect(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return Rect.fromPoints(
    box.localToGlobal(Offset.zero),
    box.localToGlobal(Offset(box.size.width, box.size.height)),
  );
}

Color? _cssColor(Object? value) {
  if (value is! String) return null;
  final hex = RegExp(
    r'^#([0-9a-f]{6})$',
    caseSensitive: false,
  ).firstMatch(value);
  if (hex != null) return Color(int.parse('ff${hex[1]!}', radix: 16));
  final rgb = RegExp(r'rgba?\(([^)]+)\)').firstMatch(value);
  if (rgb == null) return null;
  final channels = rgb[1]!
      .split(',')
      .take(3)
      .map((part) => double.parse(part.trim().replaceFirst('%', '')))
      .toList();
  if (channels.length != 3) return null;
  return Color.fromARGB(
    255,
    channels[0].round().clamp(0, 255),
    channels[1].round().clamp(0, 255),
    channels[2].round().clamp(0, 255),
  );
}

String _color(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

Offset? _svgTranslate(Object? value) {
  if (value is! String) return null;
  final numbers = RegExp(
    r'-?\d+(?:\.\d+)?(?:e[-+]?\d+)?',
    caseSensitive: false,
  ).allMatches(value).map((match) => double.parse(match[0]!)).toList();
  if (numbers.length < 2) return null;
  return Offset(numbers[0], numbers[1]);
}

List<double> _pathNumbers(Object? value) => value is String
    ? RegExp(
        r'-?\d+(?:\.\d+)?(?:e[-+]?\d+)?',
        caseSensitive: false,
      ).allMatches(value).map((match) => double.parse(match[0]!)).toList()
    : const [];

Map<String, dynamic> _nodeMetrics({
  required NativeMindmapNodeLayout actual,
  required Map<String, dynamic> browser,
  required Map<String, dynamic> browserLabel,
  required Map<String, dynamic> viewportLabel,
  required Offset browserViewBoxOrigin,
  required Offset nativeViewBoxOrigin,
  required Rect? actualWidgetLabel,
  required List<Map<String, double>> actualLineMetrics,
  required Map<String, dynamic> apiNode,
}) {
  final browserCenter = _svgTranslate(browser['transform']);
  final browserBounds = _map(browser['userBBox']);
  final browserLabelBounds = _map(browserLabel['relativeBox']);
  final browserComputed = _map(browserLabel['computed']);
  final browserFill = _nodeFill(browser);
  final browserTextColor = _cssColor(browserComputed['color']);
  final centerDelta = browserCenter == null
      ? null
      : {
          'x':
              (actual.center.dx - nativeViewBoxOrigin.dx) -
              (browserCenter.dx - browserViewBoxOrigin.dx),
          'y':
              (actual.center.dy - nativeViewBoxOrigin.dy) -
              (browserCenter.dy - browserViewBoxOrigin.dy),
        };
  final nativeLabelStyle = actual.label.style;
  final webFontSize = double.tryParse(
    (browserComputed['fontSize'] as String? ?? '').replaceFirst('px', ''),
  );
  final webLineHeight = double.tryParse(
    (browserComputed['lineHeight'] as String? ?? '').replaceFirst('px', ''),
  );
  final nativeStyleLineHeight =
      nativeLabelStyle?.fontSize != null && nativeLabelStyle?.height != null
      ? nativeLabelStyle!.fontSize! * nativeLabelStyle.height!
      : null;
  final baselineStrides = <double>[
    for (var index = 1; index < actualLineMetrics.length; index++)
      actualLineMetrics[index]['baseline']! -
          actualLineMetrics[index - 1]['baseline']!,
  ];
  final baselineStrideDeltas = webLineHeight == null
      ? const <double>[]
      : baselineStrides.map((stride) => stride - webLineHeight).toList();
  final maxBaselineStrideDelta = baselineStrideDeltas.isEmpty
      ? null
      : baselineStrideDeltas.reduce((a, b) => a.abs() >= b.abs() ? a : b);
  final firstLine = actualLineMetrics.isEmpty ? null : actualLineMetrics.first;
  return {
    'id': browser['id'],
    'label': actual.node.label,
    'shape': actual.node.shape.name,
    'browserShape': apiNode['shape'],
    'center': {'x': actual.center.dx, 'y': actual.center.dy},
    'browserCenter': browserCenter == null
        ? null
        : {'x': browserCenter.dx, 'y': browserCenter.dy},
    'centerDeltaAfterViewBoxNormalization': centerDelta,
    'nativeLocalBounds': _rect(actual.localBounds),
    'browserLocalBounds': browserBounds,
    'localBoundsDelta': {
      'x': actual.localBounds.left - _num(browserBounds['x']),
      'y': actual.localBounds.top - _num(browserBounds['y']),
      'width': actual.localBounds.width - _num(browserBounds['width']),
      'height': actual.localBounds.height - _num(browserBounds['height']),
    },
    'nativeLabelSize': {
      'width': actual.labelSize.width,
      'height': actual.labelSize.height,
    },
    'browserLabelSize': {
      'width': _num(browserLabelBounds['width']),
      'height': _num(browserLabelBounds['height']),
    },
    'labelSizeDelta': {
      'width': actual.labelSize.width - _num(browserLabelBounds['width']),
      'height': actual.labelSize.height - _num(browserLabelBounds['height']),
    },
    'nativeRenderedLabelBox': actualWidgetLabel == null
        ? null
        : _rect(actualWidgetLabel),
    'browserRenderedLabelBox': viewportLabel,
    'renderedLabelBoxDelta': actualWidgetLabel == null
        ? null
        : _rectDelta(actualWidgetLabel, viewportLabel),
    'nativeFont': {
      'family': nativeLabelStyle?.fontFamily,
      'size': nativeLabelStyle?.fontSize,
      'heightMultiplier': nativeLabelStyle?.height,
      'weight': nativeLabelStyle?.fontWeight?.value,
      'color': nativeLabelStyle?.color == null
          ? null
          : _color(nativeLabelStyle!.color!),
    },
    'browserFont': {
      'family': browserComputed['fontFamily'],
      'size': webFontSize,
      'lineHeight': webLineHeight,
      'weight': browserComputed['fontWeight'],
      'color': browserComputed['color'],
    },
    'fontSizeDelta': webFontSize == null || nativeLabelStyle?.fontSize == null
        ? null
        : nativeLabelStyle!.fontSize! - webFontSize,
    'nativeLineCount': actualLineMetrics.length,
    'nativeLineMetrics': actualLineMetrics,
    'nativeRoundedLineMetricHeight': firstLine?['height'],
    'nativeAscent': firstLine?['ascent'],
    'nativeDescent': firstLine?['descent'],
    'nativeAscentPlusDescent': firstLine == null
        ? null
        : firstLine['ascent']! + firstLine['descent']!,
    'nativeAdjacentBaselineStrides': baselineStrides,
    'sourceCssLineHeightPx': webLineHeight,
    'nativeStyleLineHeightPx': nativeStyleLineHeight,
    'nativeStyleLineHeightDelta':
        webLineHeight == null || nativeStyleLineHeight == null
        ? null
        : nativeStyleLineHeight - webLineHeight,
    // Compare authored CSS line-height only with actual inter-line baselines.
    // A single-line paragraph has no baseline stride to compare.
    'lineHeightDelta': maxBaselineStrideDelta,
    'nativeFill': _color(actual.fill),
    'browserFill': browserFill == null ? null : _color(browserFill),
    'fillMatches':
        browserFill == null || actual.fill.toARGB32() == browserFill.toARGB32(),
    'nativeLabelColor': _color(actual.labelColor),
    'browserLabelColor': browserTextColor == null
        ? null
        : _color(browserTextColor),
    'labelColorMatches':
        browserTextColor == null ||
        actual.labelColor.toARGB32() == browserTextColor.toARGB32(),
  };
}

Color? _nodeFill(Map<String, dynamic> node) {
  final shapes = _maps(node['shapes']);
  for (final shape in shapes) {
    final bounds = _map(shape['userBBox']);
    if (_num(bounds['width']) <= 0 || _num(bounds['height']) <= 0) continue;
    return _cssColor(_map(shape['computed'])['fill']);
  }
  return null;
}

Map<String, double> _maxDeltas(
  Iterable<Map<String, dynamic>> rows,
  String key,
) {
  final maxes = <String, double>{};
  for (final row in rows) {
    final value = row[key];
    if (value is! Map) continue;
    for (final entry in value.entries) {
      final number = _num(entry.value).abs();
      maxes[entry.key as String] = math.max(
        maxes[entry.key as String] ?? 0,
        number,
      );
    }
  }
  return maxes;
}

void main() {
  final fixture = _map(jsonDecode(File(_fixturePath).readAsStringSync()));
  final expected = _map(jsonDecode(File(_expectedPath).readAsStringSync()));
  final sourceFixture = fixture;
  final cases = _maps(sourceFixture['cases']);
  final widths = (sourceFixture['widths'] as List).cast<int>();
  final scales = (sourceFixture['textScales'] as List).map(_num).toList();
  final captureWidths = _fontDiagnosticOnly ? [651] : widths;
  final captureBrightnesses = _fontDiagnosticOnly
      ? [Brightness.light]
      : [Brightness.light, Brightness.dark];
  final captureScales = _fontDiagnosticOnly ? [2.0] : scales;
  final captureCases = _fontDiagnosticOnly
      ? cases
            .where((item) => item['id'] == 'mindmap-uneven-indentation')
            .toList()
      : cases;
  final rows = <Map<String, Object?>>[];

  tearDownAll(() {
    final output = Directory(_outputPath)..createSync(recursive: true);
    final expectedStates =
        captureWidths.length *
        captureBrightnesses.length *
        captureScales.length *
        captureCases.length;
    final captures = rows.where((row) => row['status'] == 'ok').toList();
    final nodeRows = captures.expand(
      (row) => _maps(_map(row['native'])['nodes']),
    );
    final edgeRows = captures.expand(
      (row) => _maps(_map(row['native'])['edges']),
    );
    File('${output.path}/summary.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'fixture': sourceFixture['id'],
        'reference': expected['reference'],
        'statesCaptured': rows.length,
        'statesExpected': expectedStates,
        'captureComplete': rows.length == expectedStates,
        'expectedErrorStates':
            captureCases
                .where((item) => item['expectedStatus'] == 'error')
                .length *
            captureWidths.length *
            captureBrightnesses.length *
            captureScales.length,
        'capturedErrorStates': rows
            .where((row) => row['status'] == 'error')
            .length,
        'visualParityAccepted': false,
        'comparisonFonts': {
          'body': 'Arial from the host supplemental font directory',
          'mindmap': 'SFNS.ttf loaded as Mermaid reference on macOS',
          'sfnsNormalTrack13LetterSpacingPx': _sfns13LetterSpacing,
          'scope':
              'Host-font measurement only; these fonts are not bundled and do not prove Android or iOS system-font parity.',
        },
        'maximumAbsoluteResiduals': {
          'normalizedNodeCenter': _maxDeltas(
            nodeRows,
            'centerDeltaAfterViewBoxNormalization',
          ),
          'nodeLocalBounds': _maxDeltas(nodeRows, 'localBoundsDelta'),
          'labelSize': _maxDeltas(nodeRows, 'labelSizeDelta'),
          'renderedLabelBox': _maxDeltas(nodeRows, 'renderedLabelBoxDelta'),
          'blockBox': _maxDeltas(
            rows.map((row) => _map(row['residuals'])),
            'blockBoxDelta',
          ),
          'figureBox': _maxDeltas(
            rows.map((row) => _map(row['residuals'])),
            'figureBoxDelta',
          ),
          'edgeEndpoint': _maxDeltas(edgeRows, 'endpointDelta'),
        },
        'fontDiagnosticOnly': _fontDiagnosticOnly,
        'captures': rows,
      }),
    );
  });

  for (final width in captureWidths) {
    for (final brightness in captureBrightnesses) {
      for (final textScale in captureScales) {
        testWidgets(
          'native mindmap capture $width ${brightness.name} scale $textScale',
          (tester) async {
            await _loadComparisonFonts(tester);
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(
              width.toDouble(),
              _num(sourceFixture['height']),
            );
            tester.platformDispatcher.textScaleFactorTestValue = textScale;
            addTearDown(tester.view.reset);
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );

            for (final item in captureCases) {
              final id = item['id'] as String;
              final caseReference = _referenceCase(
                expected,
                width,
                brightness.name,
                textScale,
                id,
              );
              final browserStatus = caseReference['status'] as String;
              final expectedStatus = item['expectedStatus'] == 'error'
                  ? 'error'
                  : 'ok';
              expect(browserStatus, expectedStatus, reason: id);
              final browserBlock = _map(_map(caseReference['html'])['block']);
              final browserBlockBox = _map(browserBlock['box']);
              final repaintKey = GlobalKey();
              await tester.pumpWidget(
                RepaintBoundary(
                  key: repaintKey,
                  child: MaterialApp(
                    debugShowCheckedModeBanner: false,
                    theme: _comparisonTheme(brightness),
                    home: Scaffold(
                      body: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: DefaultTextStyle(
                          style: const TextStyle(
                            fontFamily: 'Arial',
                            fontSize: 15,
                            height: 1.65,
                          ),
                          child: Theme(
                            data: _mermaidTheme(_comparisonTheme(brightness)),
                            child: NativeMarkdown(
                              source: item['source'] as String,
                              lineHeight: _sourceBodyLineHeight,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull, reason: id);
              final blockFinder = find.byKey(
                const ValueKey('native-mermaid-block'),
              );
              expect(blockFinder, findsOneWidget, reason: id);
              expect(find.byType(NativeMermaid), findsOneWidget, reason: id);
              final blockRect = _globalRect(tester, blockFinder);
              final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(repaintKey),
              );
              final nativeMarkdown = tester.widget<NativeMarkdown>(
                find.byType(NativeMarkdown),
              );
              final nativeBuilderDefaultLineHeight = width <= 650 ? 1.65 : 1.75;
              final statusIsValid = browserStatus == 'ok';
              final mindmapFinder = find.byType(NativeMermaidMindmap);
              expect(
                mindmapFinder,
                statusIsValid ? findsOneWidget : findsNothing,
                reason: id,
              );

              final metric = <String, Object?>{
                'case': id,
                'viewport': {
                  'width': width,
                  'height': _num(sourceFixture['height']),
                  'devicePixelRatio': 1,
                },
                'brightness': brightness.name,
                'textScale': textScale,
                'nativeMindmapLetterSpacingPx': _sfns13LetterSpacing,
                'sourceBodyLineHeight': _sourceBodyLineHeight,
                'nativeBuilderLineHeight': nativeMarkdown.lineHeight,
                'nativeBuilderDefaultLineHeight':
                    nativeBuilderDefaultLineHeight,
                'status': browserStatus,
                'browserBlock': browserBlockBox,
                'nativeBlock': _rect(blockRect),
                'blockBoxDelta': _rectDelta(blockRect, browserBlockBox),
                'figureBoxDelta': null,
                'browserSvg': statusIsValid
                    ? _map(caseReference['svg'])['box']
                    : null,
                'geometryId': statusIsValid
                    ? _map(caseReference['svg'])['geometryId']
                    : null,
                'native': null,
                'residuals': {
                  'blockBoxDelta': _rectDelta(blockRect, browserBlockBox),
                  'figureBoxDelta': <String, double>{},
                  'maxCenterDelta': 0.0,
                  'maxNodeBoundsDelta': 0.0,
                  'maxLabelSizeDelta': 0.0,
                  'maxRenderedLabelDelta': 0.0,
                  'maxEdgeEndpointDelta': 0.0,
                },
                'nativeError': null,
                'expectedError': _map(
                  _map(_map(expected['parsedCases'])[id])[brightness.name],
                )['errorText'],
                'errorMatches': null,
                'screenshot': null,
              };

              if (statusIsValid) {
                final lineBoxFinder = find.byWidgetPredicate(
                  (widget) =>
                      widget.runtimeType.toString() == '_MermaidSvgLineBox',
                );
                expect(lineBoxFinder, findsOneWidget, reason: id);
                metric['lineBoxFontDiagnostic'] = _lineBoxFontDiagnostic(
                  tester.element(lineBoxFinder),
                );
                final painterFinder = find.byWidgetPredicate(
                  (widget) =>
                      widget is CustomPaint &&
                      widget.painter is NativeMindmapPainter,
                );
                expect(painterFinder, findsOneWidget, reason: id);
                final painter =
                    tester.widget<CustomPaint>(painterFinder).painter
                        as NativeMindmapPainter;
                final layout = painter.layout;
                final svg = _map(caseReference['svg']);
                final geometryId = _map(svg)['geometryId'] as String;
                final geometry = _map(
                  _map(expected['geometryCatalog'])[geometryId],
                );
                final shared = _map(geometry['shared']);
                final browserNodes = _maps(shared['nodes']);
                final browserEdges = _maps(shared['edges']);
                final apiResult = _map(
                  _map(
                    _map(_map(expected['parsedCases'])[id])[brightness.name],
                  )['api'],
                );
                final apiNodes = _maps(apiResult['nodes']);
                final apiEdges = _maps(apiResult['edges']);
                expect(
                  layout.nodes,
                  hasLength(apiNodes.length),
                  reason: '$id node count',
                );
                expect(
                  layout.edges,
                  hasLength(apiEdges.length),
                  reason: '$id edge count',
                );
                expect(
                  browserNodes,
                  hasLength(apiNodes.length),
                  reason: '$id browser node count',
                );

                final richFinder = find.descendant(
                  of: mindmapFinder,
                  matching: find.byType(RichText),
                );
                final richWidgets = tester
                    .widgetList<RichText>(richFinder)
                    .toList();
                expect(
                  richWidgets,
                  hasLength(layout.nodes.length),
                  reason: '$id rendered node labels',
                );
                final renderedLabelRects = <Rect>[];
                final renderedLineMetrics = <List<Map<String, double>>>[];
                for (var index = 0; index < richWidgets.length; index++) {
                  final paragraph = tester.renderObject<RenderParagraph>(
                    richFinder.at(index),
                  );
                  renderedLabelRects.add(
                    _globalRect(tester, richFinder.at(index)),
                  );
                  final labelPainter = TextPainter(
                    text: paragraph.text,
                    textAlign: paragraph.textAlign,
                    textDirection: paragraph.textDirection,
                    textScaler: paragraph.textScaler,
                    locale: paragraph.locale,
                    maxLines: paragraph.maxLines,
                    strutStyle: paragraph.strutStyle,
                    textWidthBasis: paragraph.textWidthBasis,
                    textHeightBehavior: paragraph.textHeightBehavior,
                  )..layout(maxWidth: paragraph.size.width);
                  final lines = labelPainter.computeLineMetrics();
                  renderedLineMetrics.add([
                    for (final line in lines)
                      {
                        'height': line.height,
                        'baseline': line.baseline,
                        'ascent': line.ascent,
                        'descent': line.descent,
                        'unscaledAscent': line.unscaledAscent,
                      },
                  ]);
                  labelPainter.dispose();
                }
                final browserViewBoxNumbers = _pathNumbers(
                  _map(shared['attrs'])['viewBox'],
                );
                expect(
                  browserViewBoxNumbers,
                  hasLength(4),
                  reason: '$id browser viewBox',
                );
                final browserOrigin = Offset(
                  browserViewBoxNumbers[0],
                  browserViewBoxNumbers[1],
                );
                final nodeMetrics = <Map<String, dynamic>>[];
                for (var index = 0; index < layout.nodes.length; index++) {
                  final browserNode = browserNodes[index];
                  final apiNode = apiNodes[index];
                  final labelRows = _maps(browserNode['htmlLabels']);
                  final browserLabel = labelRows.firstWhere(
                    (row) => row['tag'] == 'p',
                    orElse: () => labelRows.first,
                  );
                  final viewportLabel = _maps(
                    _maps(svg['labelBoxes']).singleWhere(
                      (row) => row['id'] == browserNode['id'],
                    )['labels'],
                  ).first;
                  final actualNode = layout.nodes[index];
                  expect(
                    actualNode.label.style?.letterSpacing,
                    _sfns13LetterSpacing,
                    reason: '$id tracked native label $index',
                  );
                  expect(
                    actualNode.node.label,
                    apiNode['label'],
                    reason: '$id label $index',
                  );
                  final text = richWidgets[index].text.toPlainText();
                  expect(
                    text,
                    apiNode['label'],
                    reason: '$id rendered label $index',
                  );
                  nodeMetrics.add(
                    _nodeMetrics(
                      actual: actualNode,
                      browser: browserNode,
                      browserLabel: browserLabel,
                      viewportLabel: viewportLabel,
                      browserViewBoxOrigin: browserOrigin,
                      nativeViewBoxOrigin: layout.viewBox.topLeft,
                      actualWidgetLabel: renderedLabelRects[index],
                      actualLineMetrics: renderedLineMetrics[index],
                      apiNode: apiNode,
                    ),
                  );
                }
                final edgeMetrics = <Map<String, dynamic>>[];
                for (var index = 0; index < layout.edges.length; index++) {
                  final actual = layout.edges[index];
                  final browser = browserEdges[index];
                  final path = _map(browser['attrs'])['d'] as String?;
                  final values = _pathNumbers(path);
                  final browserStart = values.length >= 2
                      ? Offset(values[0], values[1])
                      : null;
                  final browserEnd = values.length >= 2
                      ? Offset(values[values.length - 2], values.last)
                      : null;
                  final endpointDelta =
                      browserStart == null || browserEnd == null
                      ? null
                      : {
                          'startX': actual.start.dx - browserStart.dx,
                          'startY': actual.start.dy - browserStart.dy,
                          'endX': actual.end.dx - browserEnd.dx,
                          'endY': actual.end.dy - browserEnd.dy,
                        };
                  edgeMetrics.add({
                    'source': actual.source,
                    'target': actual.target,
                    'start': {'x': actual.start.dx, 'y': actual.start.dy},
                    'end': {'x': actual.end.dx, 'y': actual.end.dy},
                    'browserPath': path,
                    'browserStart': browserStart == null
                        ? null
                        : {'x': browserStart.dx, 'y': browserStart.dy},
                    'browserEnd': browserEnd == null
                        ? null
                        : {'x': browserEnd.dx, 'y': browserEnd.dy},
                    'endpointDelta': endpointDelta,
                    'nativeWidth': actual.width,
                    'nativeColor': _color(actual.color),
                    'browserComputed': _map(browser['computed']),
                  });
                }
                final figureFinder = find.descendant(
                  of: mindmapFinder,
                  matching: find.byType(FittedBox),
                );
                final figureRect = _globalRect(tester, figureFinder);
                final browserSvgBox = _map(svg['box']);
                final figureBoxDelta = _rectDelta(figureRect, browserSvgBox);
                final normalizedCenters = nodeMetrics
                    .map(
                      (row) =>
                          _map(row['centerDeltaAfterViewBoxNormalization']),
                    )
                    .toList();
                final boundsDeltas = nodeMetrics
                    .map((row) => _map(row['localBoundsDelta']))
                    .toList();
                final labelDeltas = nodeMetrics
                    .map((row) => _map(row['labelSizeDelta']))
                    .toList();
                final renderedDeltas = nodeMetrics
                    .where((row) => row['renderedLabelBoxDelta'] != null)
                    .map((row) => _map(row['renderedLabelBoxDelta']))
                    .toList();
                double maxMap(Iterable<Map<String, dynamic>> values) => values
                    .expand((value) => value.values)
                    .map((value) => _num(value).abs())
                    .fold(0.0, math.max);
                final centerMax = maxMap(normalizedCenters);
                final boundsMax = maxMap(boundsDeltas);
                final labelMax = maxMap(labelDeltas);
                final renderedMax = maxMap(renderedDeltas);
                final edgeMax = maxMap(
                  edgeMetrics
                      .where((row) => row['endpointDelta'] != null)
                      .map((row) => _map(row['endpointDelta'])),
                );
                metric['figureBoxDelta'] = figureBoxDelta;
                metric['native'] = {
                  'block': _rect(blockRect),
                  'figure': _rect(figureRect),
                  'paintBox': _rect(_globalRect(tester, painterFinder)),
                  'paintBounds': {
                    'width': tester.getSize(painterFinder).width,
                    'height': tester.getSize(painterFinder).height,
                  },
                  'viewBox': _rect(layout.viewBox),
                  'viewBoxSize': {
                    'width': layout.viewBox.width,
                    'height': layout.viewBox.height,
                  },
                  'scale': layout.scale,
                  'nodes': nodeMetrics,
                  'edges': edgeMetrics,
                };
                metric['residuals'] = {
                  'blockBoxDelta': _rectDelta(blockRect, browserBlockBox),
                  'figureBoxDelta': figureBoxDelta,
                  'maxCenterDelta': centerMax,
                  'maxNodeBoundsDelta': boundsMax,
                  'maxLabelSizeDelta': labelMax,
                  'maxRenderedLabelDelta': renderedMax,
                  'maxEdgeEndpointDelta': edgeMax,
                };
              } else {
                final error = tester
                    .widgetList<Text>(find.byType(Text))
                    .map((widget) => widget.data)
                    .whereType<String>()
                    .where((text) => text.startsWith('Mermaid:'))
                    .join('\n');
                metric['nativeError'] = error;
                metric['errorMatches'] = error == metric['expectedError'];
                expect(error, isNotEmpty, reason: '$id native error text');
              }

              final output = Directory(_outputPath)
                ..createSync(recursive: true);
              final stem = '$width-${brightness.name}-scale$textScale-$id';
              final pngPath = '${output.path}/$stem.png';
              metric['screenshot'] = pngPath;
              File('${output.path}/$stem.json').writeAsStringSync(
                const JsonEncoder.withIndent('  ').convert(metric),
              );
              await tester.runAsync(() async {
                final image = await boundary.toImage(pixelRatio: 1);
                try {
                  final data = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  await File(pngPath).writeAsBytes(data!.buffer.asUint8List());
                } finally {
                  image.dispose();
                }
              });
              rows.add(metric);
              await tester.pumpWidget(const SizedBox());
            }
          },
        );
      }
    }
  }
}
