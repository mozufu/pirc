import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import 'package:pirc_render/src/mermaid/quadrant_parser.dart';
import 'package:pirc_render/src/mermaid/quadrant_rendering.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

const _fixturePath = '../../fixtures/mobile-parity/mermaid-quadrant-xy.json';
const _expectedPath =
    '../../fixtures/mobile-parity/mermaid-quadrant-xy-expected.json';
const _outputPath = 'build/parity/mermaid-quadrant-native';
const _geometryTolerance = .002;

Map<String, dynamic> _object(Object? value) =>
    (value as Map).cast<String, dynamic>();

List<Map<String, dynamic>> _objects(Object? value) =>
    (value as List).map(_object).toList();

String _unfence(String source) => source
    .replaceFirst(RegExp(r'^```mermaid\s*'), '')
    .replaceFirst(RegExp(r'\s*```$'), '');

Map<String, dynamic> _referenceCase(
  Map<String, dynamic> expected,
  int width,
  Brightness brightness,
  double textScale,
  String id,
) {
  final themes = _object(expected['themes']);
  final theme = _object(themes[brightness.name]);
  final widths = _objects(theme['widths']);
  final widthRow = widths.singleWhere((row) => row['width'] == width);
  final scales = _objects(widthRow['scales']);
  final scaleRow = scales.singleWhere((row) => row['textScale'] == textScale);
  return _objects(scaleRow['cases']).singleWhere((row) => row['id'] == id);
}

Map<String, dynamic> _geometry(
  Map<String, dynamic> expected,
  Map<String, dynamic> reference,
) {
  final svg = _object(reference['svg']);
  final geometryId = svg['geometryId'] as String;
  return _object(
    _object(expected['geometryCatalog'])[geometryId],
  ).cast<String, dynamic>();
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

double _num(Object? value) =>
    value is num ? value.toDouble() : double.parse(value as String);

String _hex(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

Color _browserColor(Object? value) {
  final source = value as String;
  final hex = RegExp(r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$').firstMatch(source);
  if (hex != null) {
    var digits = hex[1]!;
    if (digits.length == 3) {
      digits = digits.split('').map((digit) => '$digit$digit').join();
    }
    return Color(0xff000000 | int.parse(digits, radix: 16));
  }
  final rgb = RegExp(r'^rgb\((\d+),\s*(\d+),\s*(\d+)\)$').firstMatch(source);
  if (rgb != null) {
    return Color.fromARGB(
      255,
      int.parse(rgb[1]!),
      int.parse(rgb[2]!),
      int.parse(rgb[3]!),
    );
  }
  throw FormatException('Unexpected browser computed color: $source');
}

NativeMermaidQuadrantText _textGeometry(Map<String, dynamic> map) {
  final attrs = _object(map['attrs']);
  final transform = attrs['transform'] as String;
  final match = RegExp(
    r'translate\(([-\d.eE]+),\s*([-\d.eE]+)\)\s*rotate\(([-\d.eE]+)\)',
  ).firstMatch(transform)!;
  return NativeMermaidQuadrantText(
    text: map['text'] as String,
    position: Offset(double.parse(match[1]!), double.parse(match[2]!)),
    fontSize: double.parse(attrs['font-size'] as String),
    color: _browserColor(_object(map['computed'])['fill']),
    rotation: double.parse(match[3]!) * math.pi / 180,
    centered: attrs['text-anchor'] != 'start',
    middleBaseline: attrs['dominant-baseline'] == 'middle',
  );
}

List<NativeMermaidQuadrantText> _nativeTexts(
  NativeMermaidQuadrantLayout layout,
) => [
  if (layout.title != null) layout.title!,
  ...layout.quadrantLabels.whereType<NativeMermaidQuadrantText>(),
  ...layout.axisLabels,
  for (final point in layout.points) point.label,
];

Map<String, Object?> _compareLayout(
  NativeMermaidQuadrantLayout layout,
  Map<String, dynamic> shared,
) {
  final shapes = _objects(shared['shapes']);
  final rects = shapes.where((shape) => shape['tag'] == 'rect').toList();
  final lines = shapes.where((shape) => shape['tag'] == 'line').toList();
  final circles = shapes.where((shape) => shape['tag'] == 'circle').toList();
  expect(rects, hasLength(4));
  expect(lines, hasLength(6));
  expect(circles, hasLength(layout.points.length));

  var maxQuadrantDelta = 0.0;
  for (var i = 0; i < rects.length; i++) {
    final attrs = _object(rects[i]['attrs']);
    final rect = layout.quadrants[i];
    final deltas = [
      (rect.left - _num(attrs['x'])).abs(),
      (rect.top - _num(attrs['y'])).abs(),
      (rect.width - _num(attrs['width'])).abs(),
      (rect.height - _num(attrs['height'])).abs(),
    ];
    maxQuadrantDelta = math.max(maxQuadrantDelta, deltas.reduce(math.max));
    expect(deltas.every((delta) => delta <= _geometryTolerance), isTrue);
    expect(
      layout.quadrantFills[i],
      _browserColor(_object(rects[i]['computed'])['fill']),
    );
  }

  var maxBorderDelta = 0.0;
  for (var i = 0; i < lines.length; i++) {
    final attrs = _object(lines[i]['attrs']);
    final computed = _object(lines[i]['computed']);
    final line = layout.borders[i];
    final deltas = [
      (line.start.dx - _num(attrs['x1'])).abs(),
      (line.start.dy - _num(attrs['y1'])).abs(),
      (line.end.dx - _num(attrs['x2'])).abs(),
      (line.end.dy - _num(attrs['y2'])).abs(),
      (line.width -
              double.parse(
                (computed['strokeWidth'] as String).replaceFirst('px', ''),
              ))
          .abs(),
    ];
    maxBorderDelta = math.max(maxBorderDelta, deltas.reduce(math.max));
    expect(deltas.every((delta) => delta <= _geometryTolerance), isTrue);
    expect(line.color, _browserColor(computed['stroke']));
  }

  var maxPointDelta = 0.0;
  for (var i = 0; i < circles.length; i++) {
    final attrs = _object(circles[i]['attrs']);
    final computed = _object(circles[i]['computed']);
    final point = layout.points[i];
    final expectedStrokeWidth = double.parse(
      (computed['strokeWidth'] as String).replaceFirst('px', ''),
    );
    final deltas = [
      (point.center.dx - _num(attrs['cx'])).abs(),
      (point.center.dy - _num(attrs['cy'])).abs(),
      (point.radius - _num(attrs['r'])).abs(),
      (point.strokeWidth - expectedStrokeWidth).abs(),
    ];
    maxPointDelta = math.max(maxPointDelta, deltas.reduce(math.max));
    expect(deltas.every((delta) => delta <= _geometryTolerance), isTrue);
    expect(
      point.fill,
      _browserColor(computed['fill']),
      reason: point.point.label,
    );
    if (computed['stroke'] == 'none') {
      expect(point.strokeWidth, 0, reason: point.point.label);
    } else {
      expect(point.stroke, _browserColor(computed['stroke']));
    }
  }

  final actualTexts = _nativeTexts(layout);
  final browserTexts = _objects(shared['texts']);
  expect(actualTexts, hasLength(browserTexts.length));
  var maxTextPositionDelta = 0.0;
  final textMetrics = <Map<String, Object?>>[];
  for (final browser in browserTexts) {
    final expectedText = _textGeometry(browser);
    final actual = actualTexts.singleWhere(
      (text) => text.text == expectedText.text,
    );
    final positionDelta = math.max(
      (actual.position.dx - expectedText.position.dx).abs(),
      (actual.position.dy - expectedText.position.dy).abs(),
    );
    final angleDelta = (actual.rotation - expectedText.rotation).abs();
    maxTextPositionDelta = math.max(maxTextPositionDelta, positionDelta);
    expect(
      positionDelta,
      lessThanOrEqualTo(_geometryTolerance),
      reason: actual.text,
    );
    expect(
      angleDelta,
      lessThanOrEqualTo(_geometryTolerance),
      reason: actual.text,
    );
    expect(actual.fontSize, expectedText.fontSize, reason: actual.text);
    expect(actual.color, expectedText.color, reason: actual.text);

    final painter = TextPainter(
      text: TextSpan(
        text: actual.text,
        style: TextStyle(
          fontFamily: layout.fontFamily,
          fontSize: actual.fontSize,
          fontWeight: FontWeight.w400,
          height: 1,
          letterSpacing: 0,
          fontVariations: [ui.FontVariation('opsz', actual.fontSize)],
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: 1,
    )..layout();
    final browserBox = _object(browser['bbox']);
    final browserAdvance = _num(browser['computedTextLength']);
    textMetrics.add({
      'text': actual.text,
      'browserComputedTextLength': browserAdvance,
      'nativeTextPainterAdvanceWidth': painter.width,
      'advanceWidthDelta': painter.width - browserAdvance,
      'browserGlyphBox': {
        'width': browserBox['width'],
        'height': browserBox['height'],
      },
      'nativeTextPainterBox': {
        'width': painter.width,
        'height': painter.height,
      },
      'widthDelta': painter.width - _num(browserBox['width']),
      'heightDelta': painter.height - _num(browserBox['height']),
      'positionDelta': positionDelta,
    });
    painter.dispose();
  }

  final maxTextWidthDelta = textMetrics
      .map((row) => (row['advanceWidthDelta'] as double).abs())
      .fold(0.0, math.max);
  final maxTextGlyphBoxWidthDelta = textMetrics
      .map((row) => (row['widthDelta'] as double).abs())
      .fold(0.0, math.max);
  final maxTextHeightDelta = textMetrics
      .map((row) => (row['heightDelta'] as double).abs())
      .fold(0.0, math.max);
  final attrs = _object(shared['attrs']);
  final viewBox = attrs['viewBox'] as String;
  expect(
    viewBox,
    '0 0 ${layout.viewBoxSize.width.toInt()} ${layout.viewBoxSize.height.toInt()}',
  );
  return {
    'viewBox': viewBox,
    'quadrants': {'count': rects.length, 'maxGeometryDelta': maxQuadrantDelta},
    'borders': {'count': lines.length, 'maxGeometryDelta': maxBorderDelta},
    'points': {
      'count': circles.length,
      'maxGeometryDelta': maxPointDelta,
      'details': [
        for (final point in layout.points)
          {
            'label': point.point.label,
            'x': point.center.dx,
            'y': point.center.dy,
            'radius': point.radius,
            'fill': _hex(point.fill),
            'stroke': point.strokeWidth == 0 ? 'none' : _hex(point.stroke),
            'strokeWidth': point.strokeWidth,
            'text': {
              'x': point.label.position.dx,
              'y': point.label.position.dy,
              'fontSize': point.label.fontSize,
            },
          },
      ],
    },
    'texts': {
      'count': browserTexts.length,
      'maxPositionDelta': maxTextPositionDelta,
      'maxTextPainterAdvanceWidthDelta': maxTextWidthDelta,
      'maxTextPainterGlyphBoxWidthDelta': maxTextGlyphBoxWidthDelta,
      'maxTextPainterHeightDelta': maxTextHeightDelta,
      'details': textMetrics,
    },
  };
}

Map<String, Object?> _box(Rect box) => {
  'x': box.left,
  'y': box.top,
  'width': box.width,
  'height': box.height,
};

Map<String, Object?> _boxDelta(Rect actual, Map<String, dynamic> expected) => {
  'x': actual.left - _num(expected['x']),
  'y': actual.top - _num(expected['y']),
  'width': actual.width - _num(expected['width']),
  'height': actual.height - _num(expected['height']),
};

void main() {
  final fixture = _object(jsonDecode(File(_fixturePath).readAsStringSync()));
  final expected = _object(jsonDecode(File(_expectedPath).readAsStringSync()));
  final cases = _objects(
    fixture['cases'],
  ).where((item) => (item['id'] as String).startsWith('quadrant-')).toList();
  final widths = (fixture['widths'] as List).cast<int>();
  final scales = (fixture['textScales'] as List)
      .map((value) => (value as num).toDouble())
      .toList();
  final rows = <Map<String, Object?>>[];

  tearDownAll(() {
    expect(rows, hasLength(84));
    final output = Directory(_outputPath)..createSync(recursive: true);
    final validRows = rows.where((row) => row['status'] == 'ok').toList();
    double maxAbsoluteBoxDelta(String field, String component) => validRows
        .map(
          (row) => ((_object(row[field])[component] as num).toDouble()).abs(),
        )
        .fold(0.0, math.max);
    double maxGeometryDelta(String field) => validRows
        .map(
          (row) => _num(
            _object(row['geometryComparison'])[field] is Map
                ? _object(
                    _object(row['geometryComparison'])[field],
                  )['maxGeometryDelta']
                : 0,
          ),
        )
        .fold(0.0, math.max);
    double maxTextMetric(String field) => validRows
        .map(
          (row) =>
              _num(_object(_object(row['geometryComparison'])['texts'])[field]),
        )
        .fold(0.0, math.max);
    File('${output.path}/summary.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'fixture': fixture['id'],
        'oracle': expected['reference'],
        'statesCaptured': rows.length,
        'statesExpected': 84,
        'aggregateResiduals': {
          'browserSvgGlobalBoxMaxAbsDelta': {
            for (final component in ['x', 'y', 'width', 'height'])
              component: maxAbsoluteBoxDelta('svgGlobalBoxDelta', component),
          },
          'browserHtmlBlockMaxAbsDelta': {
            for (final component in ['x', 'y', 'width', 'height'])
              component: maxAbsoluteBoxDelta('blockBoxDelta', component),
          },
          'maxShapeGeometryDeltaInSvgUnits': {
            'quadrants': maxGeometryDelta('quadrants'),
            'borders': maxGeometryDelta('borders'),
            'points': maxGeometryDelta('points'),
          },
          'maxTextAnchorPositionDeltaInSvgUnits': maxTextMetric(
            'maxPositionDelta',
          ),
          'maxTextPainterAdvanceVsBrowserComputedTextLengthDelta':
              maxTextMetric('maxTextPainterAdvanceWidthDelta'),
          'maxTextPainterVsBrowserSvgGlyphBoxDelta': {
            'width': maxTextMetric('maxTextPainterGlyphBoxWidthDelta'),
            'height': maxTextMetric('maxTextPainterHeightDelta'),
          },
        },
        'comparisons': rows,
        'comparisonFont':
            'Host SFNS.ttf as Mermaid reference; PingFang.ttc as generic sans-serif fallback; this is macOS host font data, not Android/iOS system-font oracle.',
      }),
    );
  });

  for (final width in widths) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      for (final textScale in scales) {
        for (final item in cases) {
          final id = item['id'] as String;
          testWidgets(
            'quadrant Flutter capture $width ${brightness.name} scale$textScale $id',
            (tester) async {
              await _loadComparisonFonts(tester);
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(
                width.toDouble(),
                (fixture['height'] as num).toDouble(),
              );
              tester.platformDispatcher.textScaleFactorTestValue = textScale;
              addTearDown(tester.view.reset);
              addTearDown(
                tester.platformDispatcher.clearTextScaleFactorTestValue,
              );

              final markdown = item['source'] as String;
              final source = _unfence(markdown);
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
                        child: NativeMarkdown(source: markdown),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 50)),
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              expect(find.byType(NativeMermaid), findsOneWidget);

              final isValid = reference['status'] == 'ok';
              expect(
                reference['status'],
                item['expectedStatus'] == 'error' ? 'error' : 'ok',
              );
              final chartFinder = find.byType(NativeMermaidQuadrant);
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
                'fixture': fixture['id'],
                'case': id,
                'width': width,
                'brightness': brightness.name,
                'textScale': textScale,
                'devicePixelRatio': 1,
                'status': isValid ? 'ok' : 'error',
                'globalCanvas': _box(globalCanvas),
                'nativeBlock': _box(blockRect),
                'blockBoxDelta': isValid
                    ? _boxDelta(
                        blockRect,
                        _object(_object(reference['html'])['block'])['box'],
                      )
                    : null,
                'browserHtml': reference['html'],
                'nativeFigureWidget': null,
                'nativeSvg': null,
                'browserSvg': isValid ? _object(reference['svg'])['box'] : null,
                'svgGlobalBoxDelta': null,
                'browserGeometryId': isValid
                    ? _object(reference['svg'])['geometryId']
                    : null,
                'geometryComparison': null,
                'nativeError': null,
                'expectedError': reference['errorText'],
                'comparisonFont':
                    'Host SFNS.ttf as Mermaid reference; PingFang.ttc as generic sans-serif fallback; platform font rendering may differ from Android/iOS.',
              };
              if (isValid) {
                final figureRect = _globalRect(tester, chartFinder);
                final paintFinder = find.descendant(
                  of: chartFinder,
                  matching: find.byType(CustomPaint),
                );
                expect(paintFinder, findsOneWidget);
                final painterSize = tester.getSize(paintFinder);
                final svgGlobalRect = _globalRect(tester, paintFinder);
                final browserSvgBox = _object(reference['svg'])['box'];
                final svgBoxDelta = _boxDelta(svgGlobalRect, browserSvgBox);
                for (final component in ['x', 'y', 'width', 'height']) {
                  expect(
                    (_object(svgBoxDelta)[component] as double).abs(),
                    lessThanOrEqualTo(.02),
                    reason:
                        'Native SVG global $component must match the browser SVG box.',
                  );
                }
                final chart = parseNativeMermaidQuadrant(source);
                final layout = layoutNativeMermaidQuadrant(
                  chart,
                  width: painterSize.width,
                  dark: brightness == Brightness.dark,
                  fontFamily: 'Mermaid reference',
                );
                final expectedShared = _object(
                  _geometry(expected, reference)['shared'],
                );
                final geometryComparison = _compareLayout(
                  layout,
                  expectedShared,
                );
                metric['nativeFigureWidget'] = _box(figureRect);
                metric['svgGlobalBoxDelta'] = svgBoxDelta;
                metric['nativeSvg'] = {
                  'globalBox': _box(svgGlobalRect),
                  'size': {
                    'width': painterSize.width,
                    'height': painterSize.height,
                  },
                  'viewBoxSize': {
                    'width': layout.viewBoxSize.width,
                    'height': layout.viewBoxSize.height,
                  },
                  'scale': layout.scale,
                  'quadrants': [
                    for (var i = 0; i < layout.quadrants.length; i++)
                      {
                        'rect': _box(layout.quadrants[i]),
                        'fill': _hex(layout.quadrantFills[i]),
                        'label': layout.quadrantLabels[i]?.text,
                        'labelPosition': layout.quadrantLabels[i] == null
                            ? null
                            : {
                                'x': layout.quadrantLabels[i]!.position.dx,
                                'y': layout.quadrantLabels[i]!.position.dy,
                              },
                      },
                  ],
                  'points': geometryComparison['points'],
                  'texts': geometryComparison['texts'],
                  'strokes': [
                    for (final line in layout.borders)
                      {
                        'x1': line.start.dx,
                        'y1': line.start.dy,
                        'x2': line.end.dx,
                        'y2': line.end.dy,
                        'color': _hex(line.color),
                        'width': line.width,
                      },
                  ],
                };
                metric['geometryComparison'] = geometryComparison;
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
                final image = await canvasBox.toImage(pixelRatio: 1);
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
