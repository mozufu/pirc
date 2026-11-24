import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/gantt_parser.dart';
import 'package:pirc_render/src/mermaid/gantt_rendering.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

const _fixturePath = '../../fixtures/mobile-parity/mermaid-gantt.json';
const _expectedPath =
    '../../fixtures/mobile-parity/mermaid-gantt-expected.json';
const _outputPath = 'build/parity/mermaid-gantt-native';

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

Map<String, Object?> _browserGeometry(Map<String, dynamic> reference) {
  final svg = _object(reference['svg']);
  final attrs = _object(svg['attrs']);
  final taskRows = _objects(svg['taskRows']);
  final axes = _object(svg['axes']);
  final ticks = _objects(axes['ticks']);
  final exclusions = _objects(svg['excludeRanges']);
  return {
    'viewBox': attrs['viewBox'],
    'svgBox': svg['box'],
    'taskBars': [
      for (final task in taskRows)
        {
          'id': task['id'],
          'label': task['label'],
          'bar': _object(task['bar'])['attrs'],
          'labelGeometry': _object(task['labelGeometry'])['attrs'],
        },
    ],
    'axisTicks': [
      for (final tick in ticks)
        {
          'transform': tick['transform'],
          'label': _object(tick['text'])['text'],
          'x': _object(tick['text'])['attrs'] is Map
              ? _object(_object(tick['text'])['attrs'])['x']
              : null,
        },
    ],
    'exclusions': [for (final range in exclusions) _object(range)['attrs']],
  };
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

void main() {
  final fixture = _object(jsonDecode(File(_fixturePath).readAsStringSync()));
  final expected = _object(jsonDecode(File(_expectedPath).readAsStringSync()));
  final fixedNow = DateTime.parse(fixture['fixedNow'] as String).toUtc();
  final cases = _objects(fixture['cases']);
  final widths = (fixture['widths'] as List).cast<int>();
  final scales = (fixture['textScales'] as List)
      .map((scale) => (scale as num).toDouble())
      .toList();

  for (final width in widths) {
    for (final brightness in Brightness.values) {
      for (final textScale in scales) {
        for (final item in cases) {
          final id = item['id'] as String;
          testWidgets(
            'native Mermaid Gantt capture $width ${brightness.name} scale$textScale $id',
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

              final source = _unfence(item['source'] as String);
              final diagram = parseNativeMermaidGantt(source, clock: fixedNow);
              final naturalLayout = layoutNativeMermaidGantt(
                diagram,
                width: width.toDouble(),
                fontFamily: 'Mermaid reference',
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
                        child: NativeMermaid(
                          source: source,
                          clock: fixedNow,
                          lineHeight: 1.65,
                        ),
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
              expect(find.byType(NativeMermaidGantt), findsOneWidget);
              expect(find.textContaining('Mermaid:'), findsNothing);
              final painters = tester
                  .widgetList<CustomPaint>(find.byType(CustomPaint))
                  .map((widget) => widget.painter)
                  .whereType<NativeGanttPainter>()
                  .toList();
              expect(painters, hasLength(1));
              final paintedLayout = painters.single.layout;
              expect(paintedLayout.tasks, hasLength(diagram.tasks.length));
              expect(paintedLayout.ticks, isNotEmpty);

              final reference = _referenceCase(
                expected,
                width,
                brightness,
                textScale,
                id,
              );
              expect(reference['status'], 'ok');
              final blockSize = tester.getSize(find.byType(NativeMermaid));
              final figureSize = tester.getSize(
                find.byType(NativeMermaidGantt),
              );
              final metric = <String, Object?>{
                'fixture': fixture['id'],
                'id': id,
                'width': width,
                'height': fixture['height'],
                'brightness': brightness.name,
                'textScale': textScale,
                'devicePixelRatio': 1,
                'clock': fixedNow.toIso8601String(),
                'mediaQueryWidth': width,
                'blockSize': {
                  'width': blockSize.width,
                  'height': blockSize.height,
                },
                'figureSize': {
                  'width': figureSize.width,
                  'height': figureSize.height,
                },
                'naturalLayout': {
                  'width': naturalLayout.size.width,
                  'height': naturalLayout.size.height,
                  'start': diagram.start.toIso8601String(),
                  'end': diagram.end.toIso8601String(),
                  'tasks': [
                    for (final task in naturalLayout.tasks)
                      {
                        'id': task.task.id,
                        'label': task.task.label,
                        'sectionIndex': task.task.sectionIndex,
                        'start': task.task.start.toIso8601String(),
                        'end': task.task.end.toIso8601String(),
                        'renderEnd': task.task.renderEnd?.toIso8601String(),
                        'statuses': task.task.statuses
                            .map((e) => e.name)
                            .toList(),
                        'bar': {
                          'x': task.bounds.left,
                          'y': task.bounds.top,
                          'width': task.bounds.width,
                          'height': task.bounds.height,
                        },
                        'labelPosition': {
                          'x': task.labelPosition.dx,
                          'y': task.labelPosition.dy,
                        },
                        'anchor': task.anchor.name,
                      },
                  ],
                  'ticks': [
                    for (final tick in naturalLayout.ticks)
                      {
                        'date': tick.date.toIso8601String(),
                        'x': tick.x,
                        'label': tick.label,
                      },
                  ],
                  'exclusions': [
                    for (final rect in naturalLayout.exclusions)
                      {
                        'x': rect.left,
                        'y': rect.top,
                        'width': rect.width,
                        'height': rect.height,
                      },
                  ],
                },
                'paintedLayout': {
                  'width': paintedLayout.size.width,
                  'height': paintedLayout.size.height,
                  'tasks': paintedLayout.tasks.length,
                  'ticks': paintedLayout.ticks.length,
                  'exclusions': paintedLayout.exclusions.length,
                  'todayMarkerEnabled':
                      paintedLayout.diagram.todayMarkerEnabled,
                  'painterClock': painters.single.clock?.toIso8601String(),
                },
                'browserReference': _browserGeometry(reference),
                'comparisonFont':
                    'Host SFNS.ttf as Mermaid reference; PingFang.ttc as generic sans-serif fallback; font metrics are macOS-host comparison data, not Android/iOS system-font oracle.',
              };
              final output = Directory(_outputPath)
                ..createSync(recursive: true);
              final stem = '$width-${brightness.name}-scale$textScale-$id';
              File('${output.path}/$stem.json').writeAsStringSync(
                const JsonEncoder.withIndent('  ').convert(metric),
              );
              await tester.runAsync(() async {
                final boundary =
                    repaintKey.currentContext!.findRenderObject()
                        as RenderRepaintBoundary;
                final image = await boundary.toImage(pixelRatio: 1);
                final data = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await File(
                  '${output.path}/$stem.png',
                ).writeAsBytes(data!.buffer.asUint8List());
                image.dispose();
              });
              await tester.pumpWidget(const SizedBox());
            },
          );
        }
      }
    }
  }
}
