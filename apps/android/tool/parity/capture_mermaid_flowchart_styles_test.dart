import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/flowchart.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

const _fixturePath =
    '../../fixtures/mobile-parity/mermaid-flowchart-styles.json';
const _expectedPath =
    '../../fixtures/mobile-parity/mermaid-flowchart-styles-expected.json';
const _outputPath = 'build/parity/mermaid-flowchart-styles-native';

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
  String id,
) {
  final themeData = _object(_object(expected['themes'])[brightness.name]);
  final widthRow = _objects(
    themeData['widths'],
  ).singleWhere((row) => row['width'] == width);
  final scaleRow = _objects(
    widthRow['scales'],
  ).singleWhere((row) => (row['textScale'] as num) == 1);
  return _objects(scaleRow['cases']).singleWhere((row) => row['id'] == id);
}

Map<String, dynamic> _sharedGeometry(
  Map<String, dynamic> expected,
  Map<String, dynamic> reference,
) {
  final svg = _object(reference['svg']);
  final geometryId = svg['geometryId'] as String;
  return _object(_object(expected['geometryCatalog'])[geometryId]);
}

Future<void> _loadComparisonFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    await loadParityFonts();
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

int _rgb(Object? value) {
  final source = value as String;
  final match = RegExp(
    r'^rgb\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)$',
  ).firstMatch(source);
  if (match == null) throw FormatException('Unexpected browser color: $source');
  return (int.parse(match[1]!) << 16) |
      (int.parse(match[2]!) << 8) |
      int.parse(match[3]!);
}

int _color(Color color) => color.toARGB32() & 0x00ffffff;

String _hex(int value) => '#${value.toRadixString(16).padLeft(6, '0')}';

double _cssPx(Object? value) =>
    double.parse((value as String).replaceFirst(RegExp(r'px$'), ''));

Rect _globalRect(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return MatrixUtils.transformRect(
    box.getTransformTo(null),
    Offset.zero & box.size,
  );
}

Map<String, Object?> _rect(Rect rect) => {
  'left': rect.left,
  'top': rect.top,
  'width': rect.width,
  'height': rect.height,
};

Map<String, Object?> _delta(Rect native, Map<String, dynamic> web) => {
  'left': native.left - (web['x'] as num).toDouble(),
  'top': native.top - (web['y'] as num).toDouble(),
  'width': native.width - (web['width'] as num).toDouble(),
  'height': native.height - (web['height'] as num).toDouble(),
};

List<Map<String, Object?>> _assertNodeStyles(
  MermaidFlowchartGraph graph,
  Map<String, dynamic> expected,
  Map<String, dynamic> reference,
  Brightness brightness,
) {
  final parsed = _object(
    _object(_object(expected['parsedCases'])[reference['id']])[brightness.name],
  );
  final webNodes = _objects(_object(_object(parsed['api'])['data'])['nodes']);
  final shared = _sharedGeometry(expected, reference)['shared'] as Map;
  final shapes = _objects(shared['shapes']).where((shape) {
    final path = (shape['groupPath'] as List).cast<String>();
    return path.contains('nodes') && shape['class'] == 'basic label-container';
  }).toList();
  final labels = _objects(shared['foreignTexts']);
  expect(shapes, hasLength(graph.nodes.length));
  expect(labels, hasLength(graph.nodes.length));
  expect(webNodes, hasLength(graph.nodes.length));

  final comparisons = <Map<String, Object?>>[];
  for (var index = 0; index < graph.nodes.length; index++) {
    final node = graph.nodes[index];
    final browserNode = webNodes.singleWhere((row) => row['id'] == node.id);
    final shape = shapes[index];
    final label = labels.singleWhere((row) => row['text'] == node.label);
    final shapeComputed = _object(shape['computed']);
    final labelComputed = _object(label['computed']);
    final style = node.style;

    expect(browserNode['label'], node.label, reason: '${node.id} label');
    expect(style.fill, isNotNull, reason: '${node.id} should resolve fill');
    expect(style.stroke, isNotNull, reason: '${node.id} should resolve stroke');
    expect(
      style.color,
      isNotNull,
      reason: '${node.id} should resolve label color',
    );
    expect(
      style.strokeWidth,
      isNotNull,
      reason: '${node.id} should resolve stroke width',
    );
    expect(
      _color(style.fill!),
      _rgb(shapeComputed['fill']),
      reason: '${node.id} fill vs Chrome computed shape fill',
    );
    expect(
      _color(style.stroke!),
      _rgb(shapeComputed['stroke']),
      reason: '${node.id} stroke vs Chrome computed shape stroke',
    );
    expect(
      style.strokeWidth,
      _cssPx(shapeComputed['strokeWidth']),
      reason: '${node.id} stroke width vs Chrome computed shape stroke width',
    );
    expect(
      _color(style.color!),
      _rgb(labelComputed['color']),
      reason: '${node.id} text color vs Chrome HTML label color',
    );

    final webClasses = (browserNode['cssClasses'] as String).trim();
    final nodeGroup = (shape['groupPath'] as List).cast<String>().last;
    expect(nodeGroup, 'node $webClasses', reason: '${node.id} SVG node class');
    comparisons.add({
      'id': node.id,
      'label': node.label,
      'classes': webClasses,
      'resolved': {
        'fill': _hex(_color(style.fill!)),
        'stroke': _hex(_color(style.stroke!)),
        'strokeWidth': style.strokeWidth,
        'labelColor': _hex(_color(style.color!)),
      },
      'webComputed': {
        'fill': shapeComputed['fill'],
        'stroke': shapeComputed['stroke'],
        'strokeWidth': shapeComputed['strokeWidth'],
        'labelColor': labelComputed['color'],
        'labelFontFamily': labelComputed['fontFamily'],
        'labelFontSize': labelComputed['fontSize'],
      },
      'apiCompiledStyles': browserNode['cssCompiledStyles'],
      'apiExplicitStyles': browserNode['cssStyles'],
    });
  }
  return comparisons;
}

void main() {
  final fixture = _object(jsonDecode(File(_fixturePath).readAsStringSync()));
  final expected = _object(jsonDecode(File(_expectedPath).readAsStringSync()));
  final cases = _objects(fixture['cases']);
  final widths = (fixture['widths'] as List).cast<int>();
  final height = (fixture['height'] as num).toDouble();
  final captures = <Map<String, Object?>>[];

  testWidgets('capture native flowchart styles against pinned Chrome', (
    tester,
  ) async {
    await _loadComparisonFonts(tester);
    Directory(_outputPath).createSync(recursive: true);
    final boundaryKey = GlobalKey();
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    for (final width in widths) {
      for (final brightness in Brightness.values) {
        tester.view.physicalSize = Size(width.toDouble(), height);
        for (final item in cases) {
          final id = item['id'] as String;
          final source = item['source'] as String;
          final graph = parseNativeMermaidFlowchart(_unfence(source));
          final reference = _referenceCase(expected, width, brightness, id);
          final comparisons = _assertNodeStyles(
            graph,
            expected,
            reference,
            brightness,
          );

          await tester.pumpWidget(
            RepaintBoundary(
              key: boundaryKey,
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

          expect(
            tester.takeException(),
            isNull,
            reason: '$id $width ${brightness.name}',
          );
          expect(find.byType(NativeMarkdown), findsOneWidget);
          expect(find.byType(NativeMermaid), findsOneWidget);
          expect(
            find.byType(NativeMermaidFlowchart),
            findsOneWidget,
            reason: '$id must use the native flowchart renderer',
          );
          expect(find.textContaining('Mermaid:'), findsNothing);

          final nativeFigure = _globalRect(
            tester,
            find.byKey(const ValueKey('native-mermaid-flowchart')),
          );
          final nativeBlock = _globalRect(tester, find.byType(NativeMermaid));
          final webSvg = _object(_object(reference['svg'])['box']);
          final webBlock = _object(
            _object(_object(reference['html'])['block'])['box'],
          );
          final fileName = '$id-$width-${brightness.name}.png';
          final pngPath = '$_outputPath/$fileName';
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            try {
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              if (bytes == null) throw StateError('PNG encoding returned null');
              await File(
                pngPath,
              ).writeAsBytes(bytes.buffer.asUint8List(), flush: true);
            } finally {
              image.dispose();
            }
          });

          captures.add({
            'caseId': id,
            'width': width,
            'height': height,
            'theme': brightness.name,
            'fontAlias':
                'Mermaid reference -> host /System/Library/Fonts/SFNS.ttf',
            'nativeRenderer':
                'NativeMarkdown -> NativeMermaid -> NativeMermaidFlowchart',
            'nativeFigureRect': _rect(nativeFigure),
            'nativeMermaidBlockRect': _rect(nativeBlock),
            'webSvgRect': webSvg,
            'webMarkdownBlockRect': webBlock,
            'globalBoxResidual': {
              'nativeFigureMinusWebSvg': _delta(nativeFigure, webSvg),
              'nativeMermaidBlockMinusWebBlock': _delta(nativeBlock, webBlock),
            },
            'nodeStyleComparisons': comparisons,
            'png': pngPath,
          });
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
      }
    }

    final document = {
      'fixture': fixture['id'],
      'reference': expected['reference'],
      'matrix': {
        'widths': widths,
        'themes': fixture['themes'],
        'textScales': [1],
        'deviceScaleFactor': 1,
      },
      'hostFontNote':
          'SFNS.ttf is loaded as a comparison-only alias; it is not bundled by the app.',
      'sourceSupport': {
        'covered': [
          'fill',
          'stroke',
          'color',
          'stroke-width',
          'classDef',
          'class',
          ':::',
          'style',
        ],
        'unsupported': ['font-size', 'dash variants', 'subgraphs'],
      },
      'visualParityAccepted': false,
      'captures': captures,
    };
    await tester.runAsync(() async {
      await File(
        '$_outputPath/mermaid-flowchart-styles-native.json',
      ).writeAsString(
        const JsonEncoder.withIndent('  ').convert(document),
        flush: true,
      );
    });
  });
}
