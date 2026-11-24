import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import 'package:pirc_render/src/mermaid/xy_parser.dart';
import 'package:pirc_render/src/mermaid/xy_rendering.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

const _fixturePath = '../../fixtures/mobile-parity/mermaid-xy.json';
const _expectedPath = '../../fixtures/mobile-parity/mermaid-xy-expected.json';
const _outputPath = 'build/parity/mermaid-xy-native';

Map<String, dynamic> _map(Object? value) =>
    (value as Map).cast<String, dynamic>();

List<Map<String, dynamic>> _maps(Object? value) =>
    (value as List).map(_map).toList();

double _num(Object? value) =>
    value is num ? value.toDouble() : double.parse(value as String);

double _cssNum(Object? value) =>
    double.parse((value as String).replaceFirst(RegExp(r'px$'), ''));

Color _hexColor(Object? value) {
  final hex = (value as String).replaceFirst('#', '');
  return Color(int.parse('ff$hex', radix: 16));
}

String _unfence(String source) => source
    .replaceFirst(RegExp(r'^~~~mermaid\s*'), '')
    .replaceFirst(RegExp(r'^```mermaid\s*'), '')
    .replaceFirst(RegExp(r'\s*(?:~~~|```)\s*$'), '');

Map<String, dynamic> _referenceCase(
  Map<String, dynamic> expected,
  int width,
  Brightness brightness,
  double textScale,
  String id,
) {
  final themes = _map(expected['themes']);
  final themeData = _map(themes[brightness.name]);
  final widthRow = _maps(
    themeData['widths'],
  ).singleWhere((row) => row['width'] == width);
  final scaleRow = _maps(
    widthRow['scales'],
  ).singleWhere((row) => _num(row['textScale']) == textScale);
  return _maps(scaleRow['cases']).singleWhere((row) => row['id'] == id);
}

Future<void> _loadComparisonFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    await loadParityFonts();
    final pingFang =
        Directory('/System/Library/AssetsV2/com_apple_MobileAsset_Font7')
            .listSync(recursive: true)
            .whereType<File>()
            .firstWhere((file) => file.path.endsWith('/PingFang.ttc'));
    await (FontLoader(
      'sans-serif',
    )..addFont(pingFang.readAsBytes().then(ByteData.sublistView))).load();
    await (FontLoader('Mermaid reference')..addFont(
          File(
            '/System/Library/Fonts/SFNS.ttf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });
}

ThemeData _comparisonTheme(Brightness brightness) {
  final base = theme.build(brightness);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'Mermaid reference'),
  );
}

Rect _globalRect(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return box.localToGlobal(Offset.zero) & box.size;
}

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

double _max(double current, double next) => math.max(current, next);

List<Map<String, Object?>> _barComparisons(
  NativeMermaidXYChartLayout layout,
  Map<String, dynamic> shared,
) {
  final shapes = _maps(shared['shapes']);
  final deltas = <Map<String, Object?>>[];
  for (var seriesIndex = 0; seriesIndex < layout.series.length; seriesIndex++) {
    final expectedBars = shapes.where((shape) {
      final groupPath = (shape['groupPath'] as List).cast<String>();
      return shape['tag'] == 'rect' &&
          groupPath.contains('bar-plot-$seriesIndex');
    }).toList();
    final actualBars = layout.series[seriesIndex].bars;
    expect(
      actualBars,
      hasLength(expectedBars.length),
      reason: 'bar plot $seriesIndex',
    );
    for (var i = 0; i < actualBars.length; i++) {
      final attrs = _map(expectedBars[i]['attrs']);
      final actual = actualBars[i].rect;
      final diff = <String, double>{
        'x': actual.left - _num(attrs['x']),
        'y': actual.top - _num(attrs['y']),
        'width': actual.width - _num(attrs['width']),
        'height': actual.height - _num(attrs['height']),
      };
      deltas.add({
        'series': seriesIndex,
        'index': i,
        'actual': _rect(actual),
        'browser': {
          'x': _num(attrs['x']),
          'y': _num(attrs['y']),
          'width': _num(attrs['width']),
          'height': _num(attrs['height']),
        },
        'delta': diff,
      });
    }
  }
  return deltas;
}

List<Map<String, Object?>> _lineComparisons(
  NativeMermaidXYChartLayout layout,
  Map<String, dynamic> shared,
) {
  final shapes = _maps(shared['shapes']);
  final deltas = <Map<String, Object?>>[];
  for (var seriesIndex = 0; seriesIndex < layout.series.length; seriesIndex++) {
    final lineShape = shapes.where((shape) {
      final groupPath = (shape['groupPath'] as List).cast<String>();
      return shape['tag'] == 'path' &&
          groupPath.contains('line-plot-$seriesIndex');
    }).firstOrNull;
    if (lineShape == null) continue;
    final path = _map(lineShape['attrs'])['d'] as String;
    final coordinates = RegExp(
      r'-?\d+(?:\.\d+)?(?:e[-+]?\d+)?',
      caseSensitive: false,
    ).allMatches(path).map((match) => double.parse(match[0]!)).toList();
    final points = layout.series[seriesIndex].points;
    expect(coordinates, hasLength(points.length * 2));
    for (var i = 0; i < points.length; i++) {
      final actual = points[i];
      final browser = Offset(coordinates[i * 2], coordinates[i * 2 + 1]);
      deltas.add({
        'series': seriesIndex,
        'index': i,
        'actual': {'x': actual.dx, 'y': actual.dy},
        'browser': {'x': browser.dx, 'y': browser.dy},
        'delta': {'x': actual.dx - browser.dx, 'y': actual.dy - browser.dy},
      });
    }
  }
  return deltas;
}

List<Map<String, Object?>> _dataLabelComparisons(
  NativeMermaidXYChartLayout layout,
  Map<String, dynamic> shared,
) {
  final texts = _maps(shared['texts']);
  final expected = texts.where((text) {
    final groupPath = (text['groupPath'] as List).cast<String>();
    return groupPath.contains('bar-plot-0');
  }).toList();
  final actual = layout.series
      .expand((series) => series.labels)
      .where((label) => label.role == 'data-label')
      .toList();
  expect(actual, hasLength(expected.length), reason: 'bar data labels');

  final comparisons = <Map<String, Object?>>[];
  for (var index = 0; index < actual.length; index++) {
    final attrs = _map(expected[index]['attrs']);
    final label = actual[index];
    final delta = <String, double>{
      'x': label.position.dx - _num(attrs['x']),
      'y': label.position.dy - _num(attrs['y']),
      'fontSize': label.fontSize - _cssNum(attrs['font-size']),
    };
    final browserAnchor = attrs['text-anchor'];
    final anchorMatches = label.anchor.name == browserAnchor;
    final browserBaseline = attrs['dominant-baseline'];
    final baselineMatches = switch (browserBaseline) {
      'middle' => label.baseline == NativeMermaidXYTextBaseline.middle,
      'auto' => label.baseline == NativeMermaidXYTextBaseline.alphabetic,
      _ => false,
    };
    final browserColor = _hexColor(attrs['fill']);
    final colorMatches = label.color.toARGB32() == browserColor.toARGB32();
    expect(
      label.text,
      expected[index]['text'],
      reason: 'bar data label $index',
    );
    expect(anchorMatches, isTrue, reason: 'bar data label $index anchor');
    expect(baselineMatches, isTrue, reason: 'bar data label $index baseline');
    expect(colorMatches, isTrue, reason: 'bar data label $index color');
    comparisons.add({
      'text': label.text,
      'actual': {
        'x': label.position.dx,
        'y': label.position.dy,
        'fontSize': label.fontSize,
        'anchor': label.anchor.name,
        'baseline': label.baseline.name,
        'color': '#${label.color.toARGB32().toRadixString(16).substring(2)}',
      },
      'browser': {
        'x': _num(attrs['x']),
        'y': _num(attrs['y']),
        'fontSize': _cssNum(attrs['font-size']),
        'anchor': browserAnchor,
        'baseline': browserBaseline,
        'color': attrs['fill'],
      },
      'delta': delta,
      'colorMatches': colorMatches,
    });
  }
  return comparisons;
}

void main() {
  final fixture = _map(jsonDecode(File(_fixturePath).readAsStringSync()));
  final expected = _map(jsonDecode(File(_expectedPath).readAsStringSync()));
  final cases = _maps(fixture['cases']);
  final widths = (fixture['widths'] as List).cast<int>();
  final scales = (fixture['textScales'] as List)
      .map((value) => _num(value))
      .toList();
  final rows = <Map<String, Object?>>[];

  tearDownAll(() {
    final output = Directory(_outputPath)..createSync(recursive: true);
    double maxDeltaFor(String kind) => rows
        .where((row) => row['status'] == 'ok')
        .map((row) => _num(_map(row['residuals'])[kind]))
        .fold(0.0, _max);
    File('${output.path}/summary.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'fixture': fixture['id'],
        'reference': expected['reference'],
        'statesCaptured': rows.length,
        'statesExpected': widths.length * 2 * scales.length * cases.length,
        'maximumAbsoluteSvgUserUnitDeltas': {
          'bars': maxDeltaFor('maxBarDelta'),
          'lines': maxDeltaFor('maxLineDelta'),
          'dataLabels': maxDeltaFor('maxDataLabelDelta'),
          'blockBox': maxDeltaFor('maxBlockBoxDelta'),
          'chartCanvas': maxDeltaFor('maxChartBoxDelta'),
        },
        'comparisonFont':
            'Host SFNS.ttf as Mermaid reference and PingFang TTC fallback; macOS host font comparison, not Android/iOS system-font proof.',
        'captures': rows,
      }),
    );
  });

  for (final width in widths) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      for (final textScale in scales) {
        for (final item in cases) {
          final id = item['id'] as String;
          testWidgets(
            'native XY capture $width ${brightness.name} scale$textScale $id',
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

              final source = item['source'] as String;
              final chartSource = _unfence(source);
              final reference = _referenceCase(
                expected,
                width,
                brightness,
                textScale,
                id,
              );
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
                        child: NativeMarkdown(source: source),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull, reason: id);
              expect(find.byType(NativeMermaid), findsOneWidget);

              final browserStatus = reference['status'] as String;
              final expectedStatus = item['expectedStatus'] == 'error'
                  ? 'error'
                  : 'ok';
              expect(browserStatus, expectedStatus, reason: id);
              final isValid = browserStatus == 'ok';
              final chartFinder = find.byType(NativeMermaidXYChart);
              expect(chartFinder, isValid ? findsOneWidget : findsNothing);
              expect(
                find.textContaining('Mermaid:'),
                isValid ? findsNothing : findsOneWidget,
              );

              final blockRect = _globalRect(tester, find.byType(NativeMermaid));
              final canvasBox = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(repaintKey),
              );
              final globalCanvas =
                  canvasBox.localToGlobal(Offset.zero) & canvasBox.size;
              final metric = <String, Object?>{
                'case': id,
                'viewportWidth': width,
                'brightness': brightness.name,
                'textScale': textScale,
                'devicePixelRatio': 1,
                'status': isValid ? 'ok' : 'error',
                'globalCanvas': _rect(globalCanvas),
                'nativeBlock': _rect(blockRect),
                'browserBlock': _map(_map(reference['html'])['block'])['box'],
                'browserSvg': isValid ? _map(reference['svg'])['box'] : null,
                'blockBoxDelta': isValid
                    ? _rectDelta(
                        blockRect,
                        _map(_map(reference['html'])['block'])['box'],
                      )
                    : null,
                'nativeChart': null,
                'geometry': null,
                'residuals': {
                  'maxBarDelta': 0.0,
                  'maxLineDelta': 0.0,
                  'maxDataLabelDelta': 0.0,
                  'maxBlockBoxDelta': 0.0,
                  'maxChartBoxDelta': 0.0,
                },
                'nativeError': null,
                'expectedError': reference['errorText'],
              };
              if (isValid) {
                final chartRect = _globalRect(tester, chartFinder);
                final paintFinder = find.byKey(
                  const ValueKey('native-mermaid-xy-chart-paint'),
                );
                expect(paintFinder, findsOneWidget);
                final paintRect = _globalRect(tester, paintFinder);
                final painterSize = tester.getSize(paintFinder);
                final browserSvgBox = _map(reference['svg'])['box'];
                final browserBox = _map(browserSvgBox);
                final geometryId = _map(reference['svg'])['geometryId'];
                final shared = _map(
                  _map(expected['geometryCatalog'])[geometryId],
                )['shared'];
                final diagram = parseNativeMermaidXYChart(chartSource);
                final layout = layoutNativeMermaidXYChart(
                  diagram,
                  width: painterSize.width,
                  dark: brightness == Brightness.dark,
                  fontFamily: 'Mermaid reference',
                  measurementViewportWidth: width.toDouble(),
                );
                final barDeltas = _barComparisons(layout, _map(shared));
                final lineDeltas = _lineComparisons(layout, _map(shared));
                final dataLabelDeltas = _dataLabelComparisons(
                  layout,
                  _map(shared),
                );
                final maxBarDelta = barDeltas
                    .expand((entry) => _map(entry['delta']).values)
                    .map(_num)
                    .map((value) => value.abs())
                    .fold(0.0, _max);
                final maxLineDelta = lineDeltas
                    .expand((entry) => _map(entry['delta']).values)
                    .map(_num)
                    .map((value) => value.abs())
                    .fold(0.0, _max);
                final maxDataLabelDelta = dataLabelDeltas
                    .expand((entry) => _map(entry['delta']).values)
                    .map(_num)
                    .map((value) => value.abs())
                    .fold(0.0, _max);
                final blockBoxDelta = _rectDelta(
                  blockRect,
                  _map(_map(reference['html'])['block'])['box'],
                );
                final chartBoxDelta = _rectDelta(paintRect, browserBox);
                metric['nativeChart'] = {
                  'block': _rect(chartRect),
                  'canvas': _rect(paintRect),
                  'paintSize': {
                    'width': painterSize.width,
                    'height': painterSize.height,
                  },
                  'viewBox': {
                    'width': layout.viewBoxSize.width,
                    'height': layout.viewBoxSize.height,
                  },
                  'scale': layout.scale,
                  'measurementViewportWidth': width,
                  'plotBounds': _rect(layout.plotBounds),
                  'xAxis': {
                    'bounds': _rect(layout.xAxis.bounds),
                    'ticks': layout.xAxis.tickLabels,
                    'positions': layout.xAxis.tickPositions,
                  },
                  'yAxis': {
                    'bounds': _rect(layout.yAxis.bounds),
                    'ticks': layout.yAxis.tickLabels,
                    'positions': layout.yAxis.tickPositions,
                  },
                  'bars': barDeltas,
                  'linePoints': lineDeltas,
                  'dataLabels': dataLabelDeltas,
                  'series': [
                    for (final series in layout.series)
                      {
                        'type': series.series.type.name,
                        'title': series.series.title,
                        'color': series.color.toARGB32(),
                        'points': [
                          for (final point in series.points)
                            {'x': point.dx, 'y': point.dy},
                        ],
                      },
                  ],
                  'legend': [
                    for (final legend in layout.legend)
                      {
                        'label': legend.label.text,
                        'marker': _rect(legend.marker),
                        'labelPosition': {
                          'x': legend.label.position.dx,
                          'y': legend.label.position.dy,
                        },
                      },
                  ],
                };
                metric['geometry'] = {
                  'viewBox': _map(_map(shared)['attrs'])['viewBox'],
                  'browserGeometryId': geometryId,
                  'maxBarDelta': maxBarDelta,
                  'maxLineDelta': maxLineDelta,
                  'maxDataLabelDelta': maxDataLabelDelta,
                  'barDetails': barDeltas,
                  'lineDetails': lineDeltas,
                };
                final blockMaxDelta = blockBoxDelta.values
                    .map((value) => value.abs())
                    .fold(0.0, _max);
                final chartMaxDelta = chartBoxDelta.values
                    .map((value) => value.abs())
                    .fold(0.0, _max);
                metric['residuals'] = {
                  'maxBarDelta': maxBarDelta,
                  'maxLineDelta': maxLineDelta,
                  'maxDataLabelDelta': maxDataLabelDelta,
                  'maxBlockBoxDelta': blockMaxDelta,
                  'maxChartBoxDelta': chartMaxDelta,
                };
                expect(maxBarDelta, lessThanOrEqualTo(3), reason: id);
                expect(maxLineDelta, lessThanOrEqualTo(3), reason: id);
                expect(
                  maxDataLabelDelta,
                  lessThanOrEqualTo(3),
                  reason: '$id data labels',
                );
                for (final component in ['x', 'y', 'width']) {
                  expect(
                    chartBoxDelta[component]!.abs(),
                    lessThanOrEqualTo(.05),
                    reason: '$id canvas $component',
                  );
                }
              } else {
                metric['nativeError'] = tester
                    .widgetList<Text>(find.byType(Text))
                    .map((widget) => widget.data)
                    .whereType<String>()
                    .where((text) => text.startsWith('Mermaid:'))
                    .join('\n');
              }

              final output = Directory(_outputPath)
                ..createSync(recursive: true);
              final stem = '$width-${brightness.name}-scale$textScale-$id';
              File('${output.path}/$stem.json').writeAsStringSync(
                const JsonEncoder.withIndent('  ').convert(metric),
              );
              await tester.runAsync(() async {
                final boundary = canvasBox;
                final image = await boundary.toImage(pixelRatio: 1);
                final data = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await File(
                  '${output.path}/$stem.png',
                ).writeAsBytes(data!.buffer.asUint8List());
                image.dispose();
              });
              rows.add(metric);
              await tester.pumpWidget(const SizedBox());
            },
          );
        }
      }
    }
  }
}
