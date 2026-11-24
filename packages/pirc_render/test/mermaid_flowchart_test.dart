import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/flowchart.dart';

void main() {
  test(
    'transparent paints and zero stroke width retain valid CSS semantics',
    () {
      final graph = parseNativeMermaidFlowchart(
        'flowchart LR\nA[Test]\nstyle A fill:none,stroke:none,stroke-width:0',
      );
      expect(graph.nodes.single.style.fill, const Color(0x00000000));
      expect(graph.nodes.single.style.stroke, const Color(0x00000000));
      expect(graph.nodes.single.style.strokeWidth, 0);
      expect(
        () => parseNativeMermaidFlowchart(
          'flowchart LR\nA[Test]\nstyle A color:none',
        ),
        throwsFormatException,
      );
    },
  );

  test('inline classes preserve adjacent dotted and solid edges', () {
    for (final edge in ['-->', '-.->', '==>']) {
      final graph = parseNativeMermaidFlowchart(
        'flowchart LR\nclassDef hot fill:red\nA[Start]:::hot${edge}B[End]',
      );
      expect(graph.nodes.first.style.fill, const Color(0xffff0000));
      expect(graph.nodes.last.id, 'B');
      expect(graph.edges.single.to, 'B');
    }
  });

  test('parses the pinned TD flowchart syntax and legacy labels', () {
    final graph = parseNativeMermaidFlowchart('''
flowchart TD
A[Start] --> B{Ready?}
B -- yes --> C[Run]
B -- no --> D[Wait]
''');

    expect(graph.direction, 'TB');
    expect(graph.nodes.map((node) => node.id), ['A', 'B', 'C', 'D']);
    expect(graph.nodes[1].shape, MermaidFlowNodeShape.diamond);
    expect(graph.edges, hasLength(3));
    expect(graph.edges.map((edge) => edge.label), ['', 'yes', 'no']);
    expect(
      graph.edges.every((edge) => edge.endMarker == MermaidFlowMarker.arrow),
      isTrue,
    );
  });

  test('parses direction, shapes, chained edges, line styles and markers', () {
    final graph = parseNativeMermaidFlowchart('''
flowchart LR
A((Start)) -.->|dotted| B(Round) ==> C{Decision} --- D[End]
E o--o F
''');

    expect(graph.direction, 'LR');
    expect(graph.nodes.map((node) => node.shape), [
      MermaidFlowNodeShape.circle,
      MermaidFlowNodeShape.rounded,
      MermaidFlowNodeShape.diamond,
      MermaidFlowNodeShape.rectangle,
      MermaidFlowNodeShape.rectangle,
      MermaidFlowNodeShape.rectangle,
    ]);
    expect(graph.edges.map((edge) => edge.lineStyle), [
      MermaidFlowLineStyle.dotted,
      MermaidFlowLineStyle.thick,
      MermaidFlowLineStyle.solid,
      MermaidFlowLineStyle.solid,
    ]);
    expect(graph.edges.first.label, 'dotted');
    expect(graph.edges.last.startMarker, MermaidFlowMarker.circle);
    expect(graph.edges.last.endMarker, MermaidFlowMarker.circle);
  });

  test('layout ranks directed edges and bounds cycles safely', () {
    final dag = parseNativeMermaidFlowchart('''
flowchart LR
A[One] --> B[Two] --> C[Three]
''');
    final dagLayout = layoutNativeMermaidFlowchart(dag);
    final dagById = {
      for (final node in dagLayout.nodes) node.node.id: node.bounds,
    };
    expect(dagById['A']!.center.dx, lessThan(dagById['B']!.center.dx));
    expect(dagById['B']!.center.dx, lessThan(dagById['C']!.center.dx));

    final graph = parseNativeMermaidFlowchart('''
flowchart LR
A[One] --> B[Two] --> C[Three]
C --> A
''');
    final layout = layoutNativeMermaidFlowchart(graph);
    final byId = {for (final node in layout.nodes) node.node.id: node.bounds};

    expect(layout.size.width, greaterThan(0));
    expect(layout.size.height, greaterThan(0));
    expect(byId.keys, containsAll(['A', 'B', 'C']));
    expect(layout.edges, hasLength(3));
    expect(
      layout.edges.every((edge) => edge.path.computeMetrics().first.length > 0),
      isTrue,
    );
    expect(byId.values.toSet(), hasLength(3));
  });

  test('lays out every supported direction along its directed axis', () {
    for (final direction in ['TD', 'TB', 'LR', 'BT', 'RL']) {
      final graph = parseNativeMermaidFlowchart('''
flowchart $direction
A[Start] --> B[Finish]
''');
      final layout = layoutNativeMermaidFlowchart(graph);
      final bounds = {
        for (final node in layout.nodes) node.node.id: node.bounds,
      };
      final start = bounds['A']!.center;
      final finish = bounds['B']!.center;

      if (direction == 'LR') {
        expect(start.dx, lessThan(finish.dx), reason: direction);
      } else if (direction == 'RL') {
        expect(start.dx, greaterThan(finish.dx), reason: direction);
      } else if (direction == 'BT') {
        expect(start.dy, greaterThan(finish.dy), reason: direction);
      } else {
        expect(start.dy, lessThan(finish.dy), reason: direction);
      }
    }
  });

  test('reports unsupported directives and incomplete syntax', () {
    expect(
      () => parseNativeMermaidFlowchart(
        'flowchart TD\nclassDef hot font-size:18px',
      ),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidFlowchart(
        '%%{init: {"theme":"dark"}}%%\nflowchart TD\nA-->B',
      ),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidFlowchart('flowchart TD\nA -->'),
      throwsFormatException,
    );
  });

  test('parses adjacent dotted operators without absorbing them into IDs', () {
    final graph = parseNativeMermaidFlowchart('''
flowchart LR
A-.->B-.->C
''');

    expect(graph.nodes.map((node) => node.id), ['A', 'B', 'C']);
    expect(graph.edges, hasLength(2));
    expect(
      graph.edges.every(
        (edge) => edge.lineStyle == MermaidFlowLineStyle.dotted,
      ),
      isTrue,
    );
  });

  testWidgets('builds a native painter with a semantic chart label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NativeMermaidFlowchart(
            source: 'flowchart TD\nA[Start] --> B[End]',
            dark: false,
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('native-mermaid-flowchart')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'Flowchart, direction TB.*Start.*End')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
