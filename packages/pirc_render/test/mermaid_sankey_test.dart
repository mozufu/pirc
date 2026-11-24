import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/d3_sankey_layout.dart';
import 'package:pirc_render/src/mermaid/sankey_parser.dart';
import 'package:pirc_render/src/mermaid/sankey_rendering.dart';

Map<String, dynamic> _map(Object? value) =>
    (value as Map).cast<String, dynamic>();

List<Map<String, dynamic>> _maps(Object? value) =>
    (value as List).map(_map).toList();

double _number(Object? value) => (value as num).toDouble();

final _fixture = _map(
  jsonDecode(
    File('../../fixtures/mobile-parity/mermaid-sankey.json').readAsStringSync(),
  ),
);
final _cases = _maps(_fixture['cases']);

Map<String, dynamic> _case(String id) =>
    _cases.singleWhere((row) => row['id'] == id);

void _close(double actual, Object? expected, String description) {
  expect(actual, closeTo(_number(expected), 0.01), reason: description);
}

String _source(String id) => _case(id)['source'] as String;

void main() {
  group('native Mermaid Sankey source graph and D3 geometry', () {
    for (final id in [
      'weighted-branching',
      'quoted-commas-escaped-quotes-and-duplicates',
      'zero-flow-with-positive-flows',
      'unbalanced-merge-and-intermediate-layer',
      'fractional-parallel-and-branching-flows',
    ]) {
      test('matches pinned graph and node layout for $id', () {
        final sourceCase = _case(id);
        expect(sourceCase['parserStatus'], 'accepted');
        expect(sourceCase['layoutStatus'], 'ok');
        final diagram = parseNativeMermaidSankey(_source(id));
        final graph = _map(sourceCase['graph']);
        final sourceNodeIds = (graph['nodes'] as List).cast<String>();
        final sourceFlows = _maps(graph['flows']);
        expect(diagram.nodes.map((node) => node.id), sourceNodeIds);
        expect(diagram.flows, hasLength(sourceFlows.length));
        for (var index = 0; index < diagram.flows.length; index++) {
          final actual = diagram.flows[index];
          final expected = sourceFlows[index];
          expect(actual.sourceId, expected['source']);
          expect(actual.targetId, expected['target']);
          _close(actual.value, expected['value'], '$id flow $index weight');
          expect(actual.index, index);
        }

        final layout = layoutNativeMermaidSankey(diagram, dark: false);
        final expectedNodes = _maps(sourceCase['nodes']);
        final expectedFlows = _maps(sourceCase['flows']);
        expect(layout.nodes, hasLength(expectedNodes.length));
        expect(layout.flows, hasLength(expectedFlows.length));
        for (var index = 0; index < layout.nodes.length; index++) {
          final actual = layout.nodes[index];
          final expected = expectedNodes[index];
          expect(actual.node.id, expected['id']);
          _close(actual.value, expected['value'], '$id node $index value');
          _close(actual.layer.toDouble(), expected['layer'], '$id node layer');
          _close(actual.sourceBounds.left, expected['x0'], '$id node x0');
          _close(actual.sourceBounds.right, expected['x1'], '$id node x1');
          _close(actual.sourceBounds.top, expected['y0'], '$id node y0');
          _close(actual.sourceBounds.bottom, expected['y1'], '$id node y1');
        }
        for (var index = 0; index < layout.flows.length; index++) {
          final actual = layout.flows[index];
          final expected = expectedFlows[index];
          expect(actual.flow.sourceId, expected['source']);
          expect(actual.flow.targetId, expected['target']);
          _close(actual.width, expected['width'], '$id flow $index width');
          _close(actual.rawSourceY, expected['sourceY'], '$id flow $index y0');
          _close(actual.rawTargetY, expected['targetY'], '$id flow $index y1');
        }
      });
    }

    test('preserves zero links and repeated CSV rows independently', () {
      final mixed = parseNativeMermaidSankey(
        _source('zero-flow-with-positive-flows'),
      );
      expect(mixed.flows.first.value, 0);
      expect(
        layoutNativeMermaidSankey(mixed, dark: false).flows.first.width,
        0,
      );

      final duplicates = parseNativeMermaidSankey(
        _source('quoted-commas-escaped-quotes-and-duplicates'),
      );
      expect(duplicates.nodes.map((node) => node.id), [
        'Input, raw',
        'Stage "one"',
        'Output',
      ]);
      expect(duplicates.flows.map((flow) => flow.value), [4.5, 1.5, 6]);
    });

    test('rejects parser and layout cases the pinned source cannot render', () {
      expect(
        () => parseNativeMermaidSankey(_source('non-ascii-label')),
        throwsFormatException,
      );
      expect(
        () => layoutNativeMermaidSankey(
          parseNativeMermaidSankey(_source('all-zero-flow')),
          dark: false,
        ),
        throwsFormatException,
      );
      expect(
        () => layoutNativeMermaidSankey(
          parseNativeMermaidSankey(_source('cycle')),
          dark: false,
        ),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidSankey('sankey\nA,B,-1'),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidSankey('sankey\nA,B,NaN'),
        throwsFormatException,
      );
    });
  });

  group('native Mermaid Sankey Flutter canvas', () {
    for (final width in [390.0, 768.0]) {
      for (final dark in [false, true]) {
        for (final textScale in [1.0, 2.0]) {
          testWidgets(
            'fits and exposes graph semantics at $width, dark=$dark, scale=$textScale',
            (tester) async {
              final diagram = parseNativeMermaidSankey(
                _source('weighted-branching'),
              );
              await tester.pumpWidget(
                MaterialApp(
                  theme: ThemeData(
                    brightness: dark ? Brightness.dark : Brightness.light,
                  ),
                  home: MediaQuery(
                    data: MediaQueryData(
                      size: Size(width, 900),
                      textScaler: TextScaler.linear(textScale),
                    ),
                    child: Scaffold(
                      body: Align(
                        alignment: Alignment.topLeft,
                        child: SizedBox(
                          width: width,
                          child: NativeMermaidSankey(
                            diagram: diagram,
                            dark: dark,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );

              expect(tester.takeException(), isNull);
              final view = tester.getSize(find.byType(NativeMermaidSankey));
              expect(view.width, lessThanOrEqualTo(width));
              expect(view.width, greaterThan(0));
              expect(view.height, greaterThan(0));
              expect(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is CustomPaint &&
                      widget.painter is NativeMermaidSankeyPainter,
                ),
                findsOneWidget,
              );

              final semantics = tester.ensureSemantics();
              expect(find.bySemanticsLabel('Sankey diagram'), findsOneWidget);
              final semanticData = tester
                  .getSemantics(find.bySemanticsLabel('Sankey diagram'))
                  .getSemanticsData();
              expect(semanticData.value, contains('A: 8.0'));
              expect(semanticData.value, contains('B to D: 4.0'));
              semantics.dispose();
            },
          );
        }
      }
    }

    testWidgets('paints weighted links and crisp node fills on canvas', (
      tester,
    ) async {
      const width = 390.0;
      const boundaryKey = ValueKey('sankey-canvas-boundary');
      final diagram = parseNativeMermaidSankey(_source('weighted-branching'));
      final layout = layoutNativeMermaidSankey(diagram, dark: false);
      final scale = width / layout.size.width;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: boundaryKey,
                child: SizedBox(
                  width: width,
                  child: NativeMermaidSankey(diagram: diagram, dark: false),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      final samples = await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          Color pixel(Offset point) {
            final x = point.dx.floor();
            final y = point.dy.floor();
            final offset = (y * image.width + x) * 4;
            return Color.fromARGB(
              data.getUint8(offset + 3),
              data.getUint8(offset),
              data.getUint8(offset + 1),
              data.getUint8(offset + 2),
            );
          }

          final nodeCenter = layout.nodeById('A')!.bounds.center * scale;
          final link = layout.flows.firstWhere(
            (flow) => flow.flow.sourceId == 'A' && flow.flow.targetId == 'B',
          );
          final pathMetric = link.path.computeMetrics().single;
          final linkPoint =
              pathMetric.getTangentForOffset(pathMetric.length / 2)!.position *
              scale;
          return [pixel(nodeCenter), pixel(linkPoint)];
        } finally {
          image.dispose();
        }
      });
      expect(samples, isNotNull);
      expect(samples![0].toARGB32(), const Color(0xff4e79a7).toARGB32());
      expect(samples[1], isNot(const Color(0xffffffff)));
    });
  });
}
