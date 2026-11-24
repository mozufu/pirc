import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/xy_parser.dart';
import 'package:pirc_render/src/mermaid/xy_rendering.dart';

const _fixturePath = '../../fixtures/mobile-parity/mermaid-xy.json';
const _expectedPath =
    '../../fixtures/mobile-parity/mermaid-xy-test-expected.json';

Map<String, dynamic> _map(Object? value) =>
    (value as Map).cast<String, dynamic>();

List<Map<String, dynamic>> _maps(Object? value) =>
    (value as List).map(_map).toList();

String _unfence(String source) => source
    .replaceFirst(RegExp(r'^~~~mermaid\s*'), '')
    .replaceFirst(RegExp(r'^```mermaid\s*'), '')
    .replaceFirst(RegExp(r'\s*(?:~~~|```)\s*$'), '');

double _number(Object? value) =>
    value is num ? value.toDouble() : double.parse(value as String);

double _cssNumber(Object? value) =>
    double.parse((value as String).replaceFirst(RegExp(r'px$'), ''));

Map<String, dynamic> _browserCase(
  Map<String, dynamic> expected,
  String id, {
  String theme = 'light',
  int width = 390,
  double textScale = 1,
}) {
  final themeRow = _map(_map(expected['themes'])[theme]);
  final widthRow = _maps(
    themeRow['widths'],
  ).singleWhere((row) => row['width'] == width);
  final scaleRow = _maps(
    widthRow['scales'],
  ).singleWhere((row) => _number(row['textScale']) == textScale);
  return _maps(scaleRow['cases']).singleWhere((row) => row['id'] == id);
}

Map<String, dynamic> _geometry(
  Map<String, dynamic> expected,
  Map<String, dynamic> browserCase,
) {
  final svg = _map(browserCase['svg']);
  final catalog = _map(expected['geometryCatalog']);
  return _map(_map(catalog[svg['geometryId']])['shared']);
}

void _expectDataLabelsMatch(
  NativeMermaidXYChartLayout layout,
  Map<String, dynamic> geometry,
  String description,
) {
  final expected = _maps(geometry['texts']).where((text) {
    final groupPath = (text['groupPath'] as List).cast<String>();
    return groupPath.contains('bar-plot-0');
  }).toList();
  final actual = layout.series
      .expand((series) => series.labels)
      .where((label) => label.role == 'data-label')
      .toList();

  expect(actual, hasLength(expected.length), reason: description);
  for (var index = 0; index < actual.length; index++) {
    final browser = expected[index];
    final attrs = _map(browser['attrs']);
    final label = actual[index];
    expect(label.text, browser['text'], reason: '$description label $index');
    _expectClose(
      label.position.dx,
      _number(attrs['x']),
      '$description label $index x',
    );
    _expectClose(
      label.position.dy,
      _number(attrs['y']),
      '$description label $index y',
    );
    _expectClose(
      label.fontSize,
      _cssNumber(attrs['font-size']),
      '$description label $index font-size',
    );
    final browserAnchor = attrs['text-anchor'];
    expect(
      label.anchor.name,
      browserAnchor == 'middle'
          ? 'middle'
          : browserAnchor == 'end'
          ? 'end'
          : 'start',
      reason: '$description label $index anchor',
    );
  }
}

Future<void> _loadReferenceFont() async {
  final bytes = File('/System/Library/Fonts/SFNS.ttf').readAsBytes();
  await (FontLoader(
    'Mermaid reference',
  )..addFont(bytes.then(ByteData.sublistView))).load();
}

void _expectClose(double actual, double expected, String reason) {
  expect(actual, closeTo(expected, 3), reason: reason);
}

void main() {
  final fixture = _map(jsonDecode(File(_fixturePath).readAsStringSync()));
  final expected = _map(jsonDecode(File(_expectedPath).readAsStringSync()));
  final fixtureCases = _maps(fixture['cases']);

  group('native Mermaid XY chart layout', () {
    for (final id in [
      'xy-category-derived-y',
      'xy-category-labeled-series',
      'xy-numeric-explicit-negative',
      'xy-default-generated-x',
      'xy-horizontal-numeric-bars',
      'xy-horizontal-categorical',
      'xy-fixed-size-responsive',
    ]) {
      for (final viewportWidth in [390, 650, 768]) {
        test(
          'matches pinned browser geometry for $id at viewport $viewportWidth',
          () async {
            await _loadReferenceFont();
            final source = _unfence(
              fixtureCases.singleWhere((row) => row['id'] == id)['source']
                  as String,
            );
            final browser = _browserCase(expected, id, width: viewportWidth);
            final svg = _map(browser['svg']);
            final box = _map(svg['box']);
            final width = _number(box['width']);
            final layout = layoutNativeMermaidXYChart(
              parseNativeMermaidXYChart(source),
              width: width,
              dark: false,
              fontFamily: 'Mermaid reference',
              measurementViewportWidth: viewportWidth.toDouble(),
            );
            final geometry = _geometry(expected, browser);
            final shapeRows = _maps(geometry['shapes']);
            final bars = shapeRows
                .where((shape) => shape['tag'] == 'rect')
                .where((shape) {
                  final groupPath = (shape['groupPath'] as List).cast<String>();
                  return groupPath.contains('bar-plot-0');
                })
                .toList();

            _expectClose(layout.size.width, width, '$id responsive width');
            _expectClose(
              layout.size.height,
              _number(box['height']),
              '$id responsive height',
            );
            final viewBox = ((_map(geometry['attrs'])['viewBox'] as String)
                .split(' ')
                .map(double.parse)
                .toList());
            expect(layout.viewBoxSize.width, closeTo(viewBox[2], .001));
            expect(layout.viewBoxSize.height, closeTo(viewBox[3], .001));
            expect(layout.series, isNotEmpty);
            if (bars.isNotEmpty) {
              expect(
                layout.series.first.bars,
                hasLength(bars.length),
                reason: id,
              );
              for (var index = 0; index < bars.length; index++) {
                final expectedAttrs = _map(bars[index]['attrs']);
                final actual = layout.series.first.bars[index].rect;
                _expectClose(
                  actual.left,
                  _number(expectedAttrs['x']),
                  '$id bar $index x',
                );
                _expectClose(
                  actual.top,
                  _number(expectedAttrs['y']),
                  '$id bar $index y',
                );
                _expectClose(
                  actual.width,
                  _number(expectedAttrs['width']),
                  '$id bar $index width',
                );
                _expectClose(
                  actual.height,
                  _number(expectedAttrs['height']),
                  '$id bar $index height',
                );
              }
            }
          },
        );
      }
    }

    test('uses the observed base and dark palette', () async {
      await _loadReferenceFont();
      final source = _unfence(fixtureCases.first['source'] as String);
      final diagram = parseNativeMermaidXYChart(source);
      final light = layoutNativeMermaidXYChart(
        diagram,
        width: 700,
        dark: false,
      );
      final dark = layoutNativeMermaidXYChart(diagram, width: 700, dark: true);
      expect(light.background.toARGB32(), 0xffffffff);
      expect(light.series.first.color.toARGB32(), 0xfffff4dd);
      expect(dark.background.toARGB32(), 0xff333333);
      expect(dark.series.first.color.toARGB32(), 0xff3498db);
    });

    for (final id in [
      'xy-category-labeled-series',
      'xy-horizontal-numeric-bars',
    ]) {
      test('matches browser bar data-label fitting for $id', () async {
        await _loadReferenceFont();
        final source = _unfence(
          fixtureCases.singleWhere((row) => row['id'] == id)['source']
              as String,
        );
        final browser = _browserCase(expected, id);
        final box = _map(_map(browser['svg'])['box']);
        final geometry = _geometry(expected, browser);
        final layout = layoutNativeMermaidXYChart(
          parseNativeMermaidXYChart(source),
          width: _number(box['width']),
          dark: false,
          fontFamily: 'Mermaid reference',
          measurementViewportWidth: 390,
        );

        _expectDataLabelsMatch(layout, geometry, id);
      });
    }
  });
}
