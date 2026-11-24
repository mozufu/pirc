import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/state_diagram.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/mermaid-uml.json',
            ).readAsStringSync(),
          )
          as Map;
  final references =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/mermaid-uml-expected.json',
            ).readAsStringSync(),
          )
          as Map;
  final referenceCases =
      (((references['themes'] as Map)['light'] as Map)['widths'] as List)
              .first['cases']
          as List;
  final cases = (fixture['cases'] as List).cast<Map>().where(
    (item) =>
        item['kind'] == 'state' && item['id'] != 'state-invalid-transition',
  );
  String source(Map item) => (item['source'] as String)
      .split('\n')
      .skip(1)
      .toList()
      .sublist(0, (item['source'] as String).split('\n').length - 2)
      .join('\n');

  for (final item in cases) {
    testWidgets(
      "native compound state layout preserves visible geometry ${item['id']}",
      (tester) async {
        final graph = parseNativeMermaidStateDiagram(source(item));
        final layout = layoutNativeMermaidStateDiagram(
          graph,
          fontFamily: 'Ahem',
        );
        if (const {
          'state-start-end',
          'state-multiple-descriptions',
          'state-composite-nested',
          'state-parallel-regions',
        }.contains(item['id'])) {
          final reference =
              referenceCases.firstWhere((entry) => entry['id'] == item['id'])
                  as Map;
          final viewBox = (reference['svg']['viewBox'] as String)
              .split(' ')
              .map(double.parse)
              .toList();
          // These diagrams' vertical ranks have fixed line counts. Their
          // natural height must follow the captured production SVG even when
          // the test's Ahem glyph widths differ from the browser's font.
          expect(
            layout.size.height,
            closeTo(viewBox[3], .01),
            reason: 'pinned web compound/rank height',
          );
        }
        final canvas = (Offset.zero & layout.size).inflate(.01);
        expect(
          layout.size.width.isFinite && layout.size.height.isFinite,
          isTrue,
        );
        final boxes = {
          for (final node in layout.nodes) node.node.id: node.bounds,
        };
        for (final node in layout.nodes) {
          expect(
            canvas.contains(node.bounds.topLeft),
            isTrue,
            reason: node.node.id,
          );
          expect(
            canvas.contains(node.bounds.bottomRight),
            isTrue,
            reason: node.node.id,
          );
          final parent = node.node.parentId;
          if (parent != null) {
            expect(
              boxes[parent]!.inflate(.01).contains(node.bounds.topLeft),
              isTrue,
              reason: node.node.id,
            );
            expect(
              boxes[parent]!.inflate(.01).contains(node.bounds.bottomRight),
              isTrue,
              reason: node.node.id,
            );
          }
        }
        for (final edge in layout.edges) {
          final bounds = edge.path.getBounds();
          expect(canvas.contains(bounds.topLeft), isTrue, reason: edge.edge.id);
          expect(
            canvas.contains(bounds.bottomRight),
            isTrue,
            reason: edge.edge.id,
          );
        }
        for (final width in [390.0, 768.0]) {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 900);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: NativeMermaidStateDiagram(source: source(item)),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final widget = find.byType(NativeMermaidStateDiagram);
          expect(tester.getSize(widget).width, lessThanOrEqualTo(width));
          expect(tester.getSize(widget).height, greaterThan(0));
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        tester.view.reset();
      },
    );
  }
  test('opposite transitions use separate paths and self loops fit', () {
    final graph = parseNativeMermaidStateDiagram(
      'stateDiagram-v2\nA --> B : forward\nB --> A : reverse\nA --> A : retry',
    );
    final layout = layoutNativeMermaidStateDiagram(graph, fontFamily: 'Ahem');
    final forward = layout.edges.firstWhere((e) => e.edge.label == 'forward');
    final reverse = layout.edges.firstWhere((e) => e.edge.label == 'reverse');
    expect(forward.labelCenter, isNot(reverse.labelCenter));
    final self = layout.edges.firstWhere((e) => e.edge.label == 'retry');
    final canvas = (Offset.zero & layout.size).inflate(.01);
    expect(canvas.contains(self.path.getBounds().bottomRight), isTrue);
  });
  test('nested transitions inherit the enclosing region direction', () {
    final model = parseNativeMermaidStateDiagram('''
stateDiagram-v2
state Outer {
  direction LR
  state Inner {
    A --> B
  }
}
''');
    final layout = layoutNativeMermaidStateDiagram(model, fontFamily: 'Ahem');
    final boxes = {for (final item in layout.nodes) item.node.id: item.bounds};
    final edge = layout.edges.single;
    final metric = edge.path.computeMetrics().single;
    final start = metric.getTangentForOffset(0)!;
    final end = metric.getTangentForOffset(metric.length)!;
    expect(boxes['A']!.right, lessThan(boxes['B']!.left));
    expect(start.position.dx, closeTo(boxes['A']!.right, .01));
    expect(end.position.dx, closeTo(boxes['B']!.left, .01));
    expect(start.vector.dy, closeTo(0, .01));
    expect(start.vector.dx, greaterThan(0));
  });
}
