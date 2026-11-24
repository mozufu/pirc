import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/classic_palette.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import 'package:pirc_render/src/mermaid/timeline_rendering.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';
import 'mermaid_font_tracking.dart';

const _fixturePath = '../../fixtures/mobile-parity/mermaid-timeline.json';
const _expectedPath =
    '../../fixtures/mobile-parity/mermaid-timeline-expected.json';
const _fullOutputPath = 'build/parity/mermaid-timeline-native';
const _baselineOutputPath = 'build/parity/mermaid-timeline-native-baseline';
const _referenceRevision = 'bd3d90981271e1f93cf3d1d1a5bbf9b61136b74c';
const _svgFontSize = 13.0;
const _fontPath = '/System/Library/Fonts/SFNS.ttf';
final _baselineOnly = Platform.environment['TIMELINE_BASELINE_ONLY'] == '1';
final _outputPath = _baselineOnly ? _baselineOutputPath : _fullOutputPath;

SfntFontXHeightSample? _sfnsXHeightSample;
int? _sfnsUnitsPerEm;
double? _sfns13LetterSpacing;
double? _sfnsTitleSize;
double? _sfnsTitleLetterSpacing;
Map<String, Object?>? _fontMetadata;

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

Rect _globalRect(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return Rect.fromPoints(
    box.localToGlobal(Offset.zero),
    box.localToGlobal(Offset(box.size.width, box.size.height)),
  );
}

Rect _globalBox(RenderBox box, Rect local) => Rect.fromPoints(
  box.localToGlobal(local.topLeft),
  box.localToGlobal(local.bottomRight),
);

String _color(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

Color _brightness(Color color, bool enabled) => !enabled
    ? color
    : Color.fromARGB(
        (color.a * 255).round(),
        (color.r * 255 * 1.2).round().clamp(0, 255),
        (color.g * 255 * 1.2).round().clamp(0, 255),
        (color.b * 255 * 1.2).round().clamp(0, 255),
      );

Map<String, dynamic> _referenceCase(
  Map<String, dynamic> expected,
  int width,
  Brightness brightness,
  double textScale,
  String id,
) {
  final themeRow = _map(_map(expected['themes'])[brightness.name]);
  final widthRow = _maps(
    themeRow['widths'],
  ).singleWhere((row) => row['width'] == width);
  final scaleRow = _maps(
    widthRow['scales'],
  ).singleWhere((row) => _num(row['textScale']) == textScale);
  return _maps(scaleRow['cases']).singleWhere((row) => row['id'] == id);
}

Map<String, dynamic> _sharedGeometry(
  Map<String, dynamic> expected,
  Map<String, dynamic> reference,
) {
  final geometryId = _map(reference['svg'])['geometryId'] as String;
  return _map(_map(_map(expected['geometryCatalog'])[geometryId])['shared']);
}

Future<void> _loadComparisonFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    await loadParityFonts();
    final sfnsBytes = await File(_fontPath).readAsBytes();
    final metrics = SfntFontTracking.parse(sfnsBytes);
    final xHeightSample = metrics.sampleXHeightAt({'opsz': 17});
    if (xHeightSample.variedUnits <= 0) {
      throw StateError('$_fontPath has no usable variable OS/2.sxHeight');
    }
    _sfnsXHeightSample = xHeightSample;
    _sfnsUnitsPerEm = metrics.unitsPerEm;
    _sfns13LetterSpacing = metrics.letterSpacing(_svgFontSize);
    final svgXHeight =
        xHeightSample.variedUnits / metrics.unitsPerEm * _svgFontSize;
    _sfnsTitleSize = svgXHeight * 4;
    _sfnsTitleLetterSpacing = metrics.letterSpacing(_sfnsTitleSize!);
    _fontMetadata = {
      'source': _fontPath,
      'loadedAlias': 'Mermaid reference',
      'unitsPerEm': metrics.unitsPerEm,
      'os2XHeightAtSourceOpsz17': xHeightSample.toJson(
        unitsPerEm: metrics.unitsPerEm,
        pxSize: _svgFontSize,
      ),
      'variationAxes': metrics.axes
          .map(
            (axis) => {
              'tag': axis.tag,
              'minimum': axis.minimum,
              'default': axis.defaultValue,
              'maximum': axis.maximum,
            },
          )
          .toList(),
      'normalTrack13Px': metrics.adjustmentAt(_svgFontSize),
      'svgTextSizePx': _svgFontSize,
      'svgLetterSpacingPx': _sfns13LetterSpacing,
      'titleSizeFormula':
          'MVAR xhgt-adjusted OS/2.sxHeight at opsz 17 / head.unitsPerEm * 13px * 4ex',
      'timelineLabelFontVariation': {
        'opsz': 13,
        'activeClampedAxis': 'opsz=17',
      },
      'timelineTitleFontVariation': {'opsz': _sfnsTitleSize},
      'titleSizePxFromHostFont': _sfnsTitleSize,
      'titleLetterSpacingPxFromHostTrack': _sfnsTitleLetterSpacing,
      'fontWeight':
          'Mermaid node text is 400; title uses synthetic/loaded 700.',
      'limitations':
          'Host SFNS.ttf comparison alias only. Chrome reports the platform face .SFNS-Regular; the app does not bundle this font. Chrome computed title 4ex is captured separately and is not fed into the native renderer.',
    };
    await (FontLoader(
      'Mermaid reference',
    )..addFont(Future.value(ByteData.sublistView(sfnsBytes)))).load();
  });
}

ThemeData _comparisonTheme(Brightness brightness) {
  final base = theme.build(brightness);
  final extensions = base.extensions.values
      .where((extension) => extension is! NativeTimelineTypography)
      .toList();
  extensions.add(
    NativeTimelineTypography(
      fontFamily: 'Mermaid reference',
      letterSpacing: _sfns13LetterSpacing!,
      titleFontSize: _sfnsTitleSize!,
      titleLetterSpacing: _sfnsTitleLetterSpacing!,
      svgXHeight:
          _sfnsXHeightSample!.variedUnits / _sfnsUnitsPerEm! * _svgFontSize,
    ),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'Arial'),
    extensions: extensions,
  );
}

List<Map<String, Object?>> _layoutTextEntries(NativeTimelineLayout layout) {
  final result = <Map<String, Object?>>[];
  for (var nodeIndex = 0; nodeIndex < layout.nodes.length; nodeIndex++) {
    final node = layout.nodes[nodeIndex];
    for (final line in node.geometry.lines) {
      if (line.paintText.isEmpty) continue;
      result.add({
        'role': 'node-line',
        'nodeIndex': nodeIndex,
        'nodeKind': node.kind,
        'lineIndex': line.index,
        'rawText': line.rawText,
        'paintText': line.paintText,
        'advanceWidth': line.width,
        'baseline': line.baseline,
        'dy': line.dy,
        'modelFontCellBounds': _rect(line.glyphBounds),
      });
    }
  }
  if (layout.title case final title?) {
    result.add({
      'role': 'title',
      'text': title.text,
      'layoutBounds': _rect(title.bounds),
      'style': {
        'fontFamily': title.style.fontFamily,
        'fontSize': title.style.fontSize,
        'fontWeight': title.style.fontWeight?.value,
        'letterSpacing': title.style.letterSpacing,
        'height': title.style.height,
        'color': title.style.color == null ? null : _color(title.style.color!),
      },
    });
  }
  return result;
}

Map<String, Object?> _renderedTextWidget(
  WidgetTester tester,
  Finder finder,
  Text widget,
) {
  final paragraphFinder = find.descendant(
    of: finder,
    matching: find.byType(RichText),
  );
  final paragraph = tester.renderObject<RenderParagraph>(paragraphFinder);
  final value =
      widget.data ??
      widget.textSpan?.toPlainText(includeSemanticsLabels: false) ??
      '';
  final boxes = value.isEmpty
      ? const <TextBox>[]
      : paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: value.length),
        );
  final metricsPainter = TextPainter(
    text: paragraph.text,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    maxLines: paragraph.maxLines,
    locale: paragraph.locale,
    strutStyle: paragraph.strutStyle,
    textWidthBasis: paragraph.textWidthBasis,
    textHeightBehavior: paragraph.textHeightBehavior,
    textAlign: paragraph.textAlign,
  )..layout(maxWidth: paragraph.constraints.maxWidth);
  final lineMetrics = metricsPainter.computeLineMetrics();
  final style = widget.style;
  final result = {
    'text': value,
    'widgetRect': _rect(
      Rect.fromPoints(
        paragraph.localToGlobal(Offset.zero),
        paragraph.localToGlobal(
          Offset(paragraph.size.width, paragraph.size.height),
        ),
      ),
    ),
    'style': {
      'fontFamily': style?.fontFamily,
      'fontSize': style?.fontSize,
      'letterSpacing': style?.letterSpacing,
      'height': style?.height,
      'fontWeight': style?.fontWeight?.value,
      'color': style?.color == null ? null : _color(style!.color!),
      'textScaler': widget.textScaler.toString(),
    },
    'lineMetrics': lineMetrics
        .map(
          (metric) => {
            'baseline': metric.baseline,
            'ascent': metric.ascent,
            'descent': metric.descent,
            'unscaledAscent': metric.unscaledAscent,
            'height': metric.height,
            'width': metric.width,
            'left': metric.left,
            'lineNumber': metric.lineNumber,
          },
        )
        .toList(),
    'selectionBoxes': boxes
        .map((box) => _rect(_globalBox(paragraph, box.toRect())))
        .toList(),
  };
  metricsPainter.dispose();
  return result;
}

Map<String, Object?> _timelineNodeRecord(
  NativeTimelinePlacedNode node,
  NativeTimelineLayout layout,
  int index,
) {
  final geometry = node.geometry;
  final baseFill = mermaidClassicSectionColor(node.colorIndex, layout.dark);
  final paintFill = _brightness(baseFill, node.event);
  final baseText = layout.textStyle.color ?? Colors.black;
  final paintText = _brightness(baseText, node.event);
  return {
    'index': index,
    'kind': node.kind,
    'ordinal': node.ordinal,
    'description': node.description,
    'position': {'x': node.position.dx, 'y': node.position.dy},
    'bounds': _rect(node.bounds),
    'geometry': {
      'width': geometry.width,
      'height': geometry.height,
      'virtualHeight': geometry.virtualHeight,
      'localBounds': _rect(geometry.localBounds),
      'textFontCellUnionPreTransform': _rect(geometry.textBounds),
      'textFontCellBoundsInNode': _rect(geometry.textBoundsInNode),
      'textTransform': {
        'x': geometry.textTransform.dx,
        'y': geometry.textTransform.dy,
      },
      'backgroundPathBounds': _rect(geometry.backgroundPath.getBounds()),
      'backgroundPathContours': geometry.backgroundPath
          .computeMetrics()
          .map(
            (metric) => {'length': metric.length, 'isClosed': metric.isClosed},
          )
          .toList(),
      'bottomRuleBounds': geometry.bottomRulePath == null
          ? null
          : _rect(geometry.bottomRulePath!.getBounds()),
      'lines': geometry.lines
          .map(
            (line) => {
              'index': line.index,
              'rawText': line.rawText,
              'paintText': line.paintText,
              'dy': line.dy,
              'advanceWidth': line.width,
              'baseline': line.baseline,
              'fontCellBounds': _rect(line.glyphBounds),
            },
          )
          .toList(),
    },
    'colorIndex': node.colorIndex,
    'event': node.event,
    'paintColors': {
      'paletteBeforeEventBrightness': _color(baseFill),
      'actualBackgroundDrawColorAfterEventBrightness': _color(paintFill),
      'labelBeforeEventBrightness': _color(baseText),
      'actualLabelDrawColorAfterEventBrightness': _color(paintText),
      'eventBrightnessApplied': node.event,
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = _map(jsonDecode(File(_fixturePath).readAsStringSync()));
  final expected = _map(jsonDecode(File(_expectedPath).readAsStringSync()));
  final cases = _maps(fixture['cases']);
  final allWidths = (fixture['widths'] as List).cast<int>();
  final allScales = (fixture['textScales'] as List).map(_num).toList();
  final fullStateCount =
      allWidths.length *
      (fixture['themes'] as List).length *
      allScales.length *
      cases.length;
  final widths = _baselineOnly ? [390] : allWidths;
  final themes = _baselineOnly
      ? ['light']
      : (fixture['themes'] as List).cast<String>();
  final scales = _baselineOnly ? [1.0] : allScales;
  final expectedStateCount =
      widths.length * themes.length * scales.length * cases.length;
  final rows = <Map<String, Object?>>[];

  if (fixture['webRevision'] != _referenceRevision ||
      expected['reference'] != _referenceRevision) {
    throw StateError(
      'Timeline Web reference SHA is not pinned to $_referenceRevision',
    );
  }
  if (fixture['mermaidVersion'] != '11.17.2' ||
      expected['mermaidVersion'] != '11.17.2') {
    throw StateError('Timeline fixture must use Mermaid 11.17.2');
  }
  if (jsonEncode(fixture['widths']) != '[390,650,651,768,860,861,1024]' ||
      jsonEncode(fixture['themes']) != '["light","dark"]' ||
      jsonEncode(fixture['textScales']) != '[1,2]' ||
      cases.isEmpty) {
    throw StateError('Timeline fixture matrix/cases changed unexpectedly');
  }

  tearDownAll(() {
    final output = Directory(_outputPath)..createSync(recursive: true);
    final statusCounts = <String, int>{};
    for (final row in rows) {
      final status = row['status'] as String;
      statusCounts[status] = (statusCounts[status] ?? 0) + 1;
    }
    final allStatusesMatch = rows.every((row) => row['statusMatches'] == true);
    final complete = rows.length == expectedStateCount && allStatusesMatch;
    File('${output.path}/summary.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'fixture': fixture['id'],
        'reference': expected['reference'],
        'requiredReference': _referenceRevision,
        'captureMode': _baselineOnly ? '390-light-scale1-baseline' : 'full',
        'captureComplete': complete,
        'captureCompleteForRequestedMode': rows.length == expectedStateCount,
        'statusParityComplete': allStatusesMatch,
        'statesCaptured': rows.length,
        'statesExpectedForMode': expectedStateCount,
        'fullMatrixStatesExpected': fullStateCount,
        'statusCounts': statusCounts,
        'bodyFixture': fixture['body'],
        'fontMetadata': _fontMetadata,
        'hostXHeightSample': _sfnsXHeightSample?.toJson(
          unitsPerEm: _sfnsUnitsPerEm!,
          pxSize: _svgFontSize,
        ),
        'titleExMetricCaveat': {
          'hostFontFormulaPx': _sfnsTitleSize,
          'chromeComputed4exPx': 27.3711,
          'note':
              'Chrome value is copied only into this source-diagnostic note from pinned SVG computed style; the native title size uses the host SFNS OS/2.sxHeight formula.',
        },
        'comparisonFont':
            'Comparison-only macOS SFNS.ttf alias for Mermaid SVG labels; Arial for Markdown body. No host fonts are bundled in the app.',
        'bodyLineHeight': 1.65,
        'devicePixelRatio': 1,
        'captures': rows,
      }),
    );
  });

  for (final width in widths) {
    for (final brightnessName in themes) {
      final brightness = brightnessName == 'dark'
          ? Brightness.dark
          : Brightness.light;
      for (final textScale in scales) {
        testWidgets(
          'native timeline capture $width $brightnessName scale$textScale',
          (tester) async {
            await _loadComparisonFonts(tester);
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(
              width.toDouble(),
              _num(fixture['height']),
            );
            tester.platformDispatcher.textScaleFactorTestValue = textScale;
            addTearDown(tester.view.reset);
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );

            final output = Directory(_outputPath)..createSync(recursive: true);
            for (final item in cases) {
              final id = item['id'] as String;
              final reference = _referenceCase(
                expected,
                width,
                brightness,
                textScale,
                id,
              );
              final expectedStatus = item['expectedStatus'] == 'error'
                  ? 'error'
                  : 'ok';
              expect(
                reference['status'],
                expectedStatus,
                reason:
                    'Web reference status for $id/$width/$brightnessName/$textScale',
              );

              final source = item['source'] as String;
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
                        child: KeyedSubtree(
                          key: ValueKey(id),
                          child: NativeMarkdown(
                            source: source,
                            fontSize: 15,
                            lineHeight: 1.65,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull, reason: id);
              final blockFinder = find.byType(NativeMermaid);
              expect(blockFinder, findsOneWidget, reason: id);

              final timelineFinder = find.byType(NativeMermaidTimeline);
              final isNativeValid = timelineFinder.evaluate().isNotEmpty;
              final nativeError = tester
                  .widgetList<Text>(
                    find.descendant(
                      of: blockFinder,
                      matching: find.byType(Text),
                    ),
                  )
                  .map((widget) => widget.data)
                  .whereType<String>()
                  .where((text) => text.startsWith('Mermaid:'))
                  .firstOrNull;
              final nativeStatus = isNativeValid
                  ? 'ok'
                  : nativeError != null
                  ? 'error'
                  : 'missing';
              final statusMatches =
                  nativeStatus == expectedStatus &&
                  nativeStatus == reference['status'];

              final rootBoundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(repaintKey),
              );
              final rootBox = _globalRect(tester, find.byKey(repaintKey));
              final blockBox = _globalRect(tester, blockFinder);
              NativeTimelineLayout? layout;
              Rect? figureBox;
              Rect? figureLineBox;
              Rect? painterBox;
              List<Map<String, Object?>> textWidgets = [];
              List<Map<String, Object?>> nodes = [];
              List<Map<String, Object?>> connectors = [];
              Map<String, Object?>? title;
              Map<String, Object?>? nativeTextStyle;
              Map<String, Object?>? nativeViewBox;
              double? nativeScale;
              String? geometryId;
              Map<String, Object?>? webGeometryReference;

              if (isNativeValid) {
                final paintFinder = find.byWidgetPredicate(
                  (widget) =>
                      widget is CustomPaint &&
                      widget.painter is NativeTimelinePainter,
                  description: 'NativeTimelinePainter CustomPaint',
                );
                expect(paintFinder, findsOneWidget, reason: id);
                final painter =
                    tester.widget<CustomPaint>(paintFinder).painter!
                        as NativeTimelinePainter;
                layout = painter.layout;
                figureBox = _globalRect(tester, timelineFinder);
                final figureLineBoxFinder = find.ancestor(
                  of: timelineFinder,
                  matching: find.byWidgetPredicate(
                    (widget) =>
                        widget is Column &&
                        widget.mainAxisSize == MainAxisSize.min &&
                        widget.children.length == 2 &&
                        widget.children.last is SizedBox,
                    description: 'Mermaid SVG inline figure line box',
                  ),
                );
                expect(figureLineBoxFinder, findsOneWidget, reason: id);
                figureLineBox = _globalRect(tester, figureLineBoxFinder);
                painterBox = _globalRect(tester, paintFinder);
                geometryId = _map(reference['svg'])['geometryId'] as String;
                final shared = _sharedGeometry(expected, reference);
                webGeometryReference = {
                  'geometryId': geometryId,
                  'nodeCount': _maps(shared['timelineNodes']).length,
                  'viewBox': _map(shared['attrs'])['viewBox'],
                  'svgBox': _map(_map(reference['svg'])['box']),
                  'figureBox': _map(_map(reference['html'])['figure'])['box'],
                  'blockBox': _map(_map(reference['html'])['block'])['box'],
                  'sourceNodeGeometry': 'expected.geometryCatalog[geometryId]',
                };
                nodes = [
                  for (var index = 0; index < layout.nodes.length; index++)
                    _timelineNodeRecord(layout.nodes[index], layout, index),
                ];
                connectors = [
                  for (var index = 0; index < layout.connectors.length; index++)
                    {
                      'index': index,
                      'start': {
                        'x': layout.connectors[index].start.dx,
                        'y': layout.connectors[index].start.dy,
                      },
                      'end': {
                        'x': layout.connectors[index].end.dx,
                        'y': layout.connectors[index].end.dy,
                      },
                      'width': layout.connectors[index].width,
                      'dashed': layout.connectors[index].dashed,
                      'arrow': layout.connectors[index].arrow,
                    },
                ];
                final entries = _layoutTextEntries(layout);
                final textFinder = find.descendant(
                  of: timelineFinder,
                  matching: find.byType(Text),
                );
                final actualTextWidgets = tester
                    .widgetList<Text>(textFinder)
                    .toList();
                expect(
                  actualTextWidgets,
                  hasLength(entries.length),
                  reason: '$id rendered Text widget count',
                );
                textWidgets = [
                  for (var index = 0; index < entries.length; index++)
                    () {
                      final rendered = _renderedTextWidget(
                        tester,
                        textFinder.at(index),
                        actualTextWidgets[index],
                      );
                      final lineMetrics = _maps(rendered['lineMetrics']);
                      expect(
                        lineMetrics,
                        hasLength(1),
                        reason:
                            '$id SVG text must remain one actual Flutter text line: ${entries[index]['text'] ?? entries[index]['paintText']}',
                      );
                      return {
                        ...entries[index],
                        'rendered': {
                          ...rendered,
                          'singleLineNoRewrap': lineMetrics.length == 1,
                        },
                      };
                    }(),
                ];
                nativeTextStyle = {
                  'fontFamily': layout.textStyle.fontFamily,
                  'fontSize': layout.textStyle.fontSize,
                  'letterSpacing': layout.textStyle.letterSpacing,
                  'height': layout.textStyle.height,
                  'color': layout.textStyle.color == null
                      ? null
                      : _color(layout.textStyle.color!),
                  'fontWeight': layout.textStyle.fontWeight?.value,
                };
                nativeViewBox = _rect(layout.viewBox);
                nativeScale = layout.scale;
                if (layout.title case final nativeTitle?) {
                  final titleEntry = textWidgets.lastWhere(
                    (entry) => entry['role'] == 'title',
                  );
                  title = {
                    'text': nativeTitle.text,
                    'position': {
                      'x': nativeTitle.position.dx,
                      'y': nativeTitle.position.dy,
                    },
                    'bounds': _rect(nativeTitle.bounds),
                    'style': {
                      'fontFamily': nativeTitle.style.fontFamily,
                      'fontSize': nativeTitle.style.fontSize,
                      'letterSpacing': nativeTitle.style.letterSpacing,
                      'height': nativeTitle.style.height,
                      'fontWeight': nativeTitle.style.fontWeight?.value,
                      'color': nativeTitle.style.color == null
                          ? null
                          : _color(nativeTitle.style.color!),
                    },
                    'renderedWidget': titleEntry['rendered'],
                  };
                }
              }

              final metric = <String, Object?>{
                'case': id,
                'viewport': {'width': width, 'height': _num(fixture['height'])},
                'brightness': brightnessName,
                'textScale': textScale,
                'devicePixelRatio': 1,
                'bodyFixture': fixture['body'],
                'status': nativeStatus,
                'expectedStatus': expectedStatus,
                'webStatus': reference['status'],
                'statusMatches': statusMatches,
                'webError': reference['errorText'],
                'nativeError': nativeError,
                'rootBox': _rect(rootBox),
                'nativeBlockBox': _rect(blockBox),
                'nativeFigureBox': figureBox == null ? null : _rect(figureBox),
                'nativePainterBox': painterBox == null
                    ? null
                    : _rect(painterBox),
                'web': webGeometryReference,
                'native': layout == null
                    ? null
                    : {
                        'geometryId': geometryId,
                        'direction': layout.diagram.direction,
                        'titleText': layout.diagram.title,
                        'accessibleTitle': layout.diagram.accessibleTitle,
                        'accessibleDescription':
                            layout.diagram.accessibleDescription,
                        'sectionNames': layout.diagram.sections
                            .map((section) => section.name)
                            .toList(),
                        'taskCount': layout.diagram.tasks.length,
                        'eventCount': layout.diagram.tasks.fold<int>(
                          0,
                          (count, task) => count + task.events.length,
                        ),
                        'viewBox': nativeViewBox,
                        'size': {
                          'width': layout.size.width,
                          'height': layout.size.height,
                        },
                        'scale': nativeScale,
                        'textStyle': nativeTextStyle,
                        'figureBox': _rect(figureBox!),
                        'figureLineBox': _rect(figureLineBox!),
                        'painterBox': _rect(painterBox!),
                        'title': title,
                        'nodes': nodes,
                        'connectors': connectors,
                        'renderedTextWidgets': textWidgets,
                      },
              };
              rows.add(metric);

              final stem = '$id-$width-$brightnessName-scale$textScale';
              await tester.runAsync(() async {
                final image = await rootBoundary.toImage(pixelRatio: 1);
                final data = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                if (data == null) {
                  image.dispose();
                  throw StateError('PNG encoding returned null for $stem');
                }
                await File(
                  '${output.path}/$stem.png',
                ).writeAsBytes(data.buffer.asUint8List());
                image.dispose();
              });
              metric['screenshot'] = '${output.path}/$stem.png';

              expect(
                nativeStatus,
                expectedStatus,
                reason:
                    '$id native/Web status mismatch at $width/$brightnessName/$textScale: $nativeError',
              );
              expect(statusMatches, isTrue, reason: '$id status gate');
              if (isNativeValid) {
                expect(layout, isNotNull, reason: '$id missing native layout');
                expect(
                  geometryId,
                  isNotEmpty,
                  reason: '$id missing Web geometry reference',
                );
                expect(
                  nodes,
                  hasLength(
                    _maps(
                      _sharedGeometry(expected, reference)['timelineNodes'],
                    ).length,
                  ),
                  reason: '$id native/Web node count',
                );
              }
              await tester.pumpWidget(const SizedBox());
            }
          },
        );
      }
    }
  }
}
