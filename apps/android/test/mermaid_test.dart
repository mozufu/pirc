import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import 'package:pirc_render/src/mermaid/pie.dart';
import 'package:pirc_render/src/mermaid/flowchart.dart';
import 'package:pirc_render/src/mermaid/sequence.dart';
import 'package:pirc_render/src/mermaid/class_diagram.dart';
import 'package:pirc_render/src/mermaid/state_diagram.dart';
import 'package:pirc_render/src/mermaid/er_rendering.dart';
import 'live_test.dart' show theme;

void main() {
  Future<void> show(
    WidgetTester t,
    String source, {
    bool streaming = false,
  }) async {
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: NativeMarkdown(source: source, streaming: streaming),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }

  testWidgets(
    'Markdown fences dispatch native diagrams and hide source on success',
    (t) async {
      for (final (source, type) in [
        ('flowchart LR\nA[Start] --> B[End]', NativeMermaidFlowchart),
        ('sequenceDiagram\nA->>B: Hello', NativeMermaidSequence),
        ('pie title Budget\n"Build":60\n"Test":40', NativeMermaidPie),
        ('classDiagram\nAnimal <|-- Duck', NativeMermaidClassDiagram),
        ('erDiagram\nCUSTOMER ||--o{ ORDER : places', NativeMermaidErDiagram),
        (
          'stateDiagram-v2\n[*] --> Idle\nIdle --> [*]',
          NativeMermaidStateDiagram,
        ),
      ]) {
        await show(t, '~~~mermaid\n$source\n~~~');
        expect(find.byType(NativeMermaid), findsOneWidget);
        expect(find.byType(type), findsOneWidget);
        expect(find.text(source), findsNothing);
        expect(find.text('Copy'), findsNothing);
      }
    },
  );
  testWidgets(
    'multiline pie description renders through Markdown and remains accessible',
    (t) async {
      const source =
          'pie\naccTitle: Budget\naccDescr {\nFirst line\n  Second line\n}\n"Build":60\n"Test":40';
      final semantics = t.ensureSemantics();
      try {
        await show(t, '~~~mermaid\n$source\n~~~');
        expect(find.byType(NativeMermaidPie), findsOneWidget);
        expect(find.textContaining('Mermaid:'), findsNothing);
        expect(
          find.bySemanticsLabel(
            'Budget, First line\nSecond line, Build: 60.0, Test: 40.0',
          ),
          findsOneWidget,
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('streaming Mermaid remains source until stream completion', (
    t,
  ) async {
    const source = 'pie title Budget\n"Build":60\n"Test":40';
    await show(t, '~~~mermaid\n$source\n~~~', streaming: true);
    expect(find.byType(NativeMermaidPie), findsNothing);
    expect(find.text(source), findsOneWidget);
    expect(find.textContaining('Mermaid:'), findsNothing);
    await show(t, '~~~mermaid\n$source\n~~~');
    expect(find.byType(NativeMermaidPie), findsOneWidget);
  });
  testWidgets(
    'unsupported and invalid diagrams retain source with explicit error',
    (t) async {
      for (final source in [
        'gantt\ntitle Timeline',
        'pie\n"Negative": -5',
        'flowchart TD\nA -->',
      ]) {
        await show(t, '~~~mermaid\n$source\n~~~');
        expect(find.text(source), findsOneWidget);
        expect(find.textContaining('Mermaid:'), findsOneWidget);
      }
    },
  );
  testWidgets('Mermaid works inside mixed HTML and preserves literal code', (
    t,
  ) async {
    await show(
      t,
      '<details open><summary>Chart</summary>\n\n~~~mermaid\npie\n"A":1\n~~~\n\n</details>',
    );
    expect(find.byType(NativeMermaidPie), findsOneWidget);
    await show(t, '~~~text\npie\n"A":1\n~~~');
    expect(find.byType(NativeMermaid), findsNothing);
  });
  testWidgets(
    'native diagrams fit required widths with surrounding text scale 2',
    (t) async {
      const source =
          '~~~mermaid\nflowchart LR\nA[Start] --> B[End]\n~~~\n\n~~~mermaid\nsequenceDiagram\nA->>B: Hello\n~~~\n\n~~~mermaid\npie\n"A":60\n"B":40\n~~~\n\n~~~mermaid\nerDiagram\ndirection LR\nCUSTOMER ||--o{ ORDER : places\n~~~';
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      for (final width in [390.0, 650.0, 651.0, 768.0, 860.0, 861.0, 1024.0]) {
        t.view.physicalSize = Size(width, 900);
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.dark),
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 900),
                textScaler: const TextScaler.linear(2),
              ),
              child: const Scaffold(
                body: SingleChildScrollView(
                  child: NativeMarkdown(source: source),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: 'width $width');
        expect(find.byType(NativeMermaid), findsNWidgets(4));
        expect(find.textContaining('Mermaid:'), findsNothing);
        for (final element in find.byType(NativeMermaid).evaluate()) {
          expect(
            (element.renderObject as RenderBox).size.width,
            lessThanOrEqualTo(width),
          );
        }
      }
    },
  );
  test(
    'pie preserves first duplicate and original legend, omits sub-percent arcs',
    () {
      final p = parseNativeMermaidPie(
        'pie showData title Counts\n"A":1000\n"Tiny":5\n"B":995\n"A":2',
      );
      expect(p.sections, {'A': 1000.0, 'Tiny': 5.0, 'B': 995.0});
      expect(p.slices.map((e) => e.key), ['A', 'B']);
      expect(p.legend(p.sections.entries.first), 'A [1000]');
    },
  );
  test(
    'pie rejects configuration or trailing statements without dropping them',
    () {
      for (final source in [
        '%%{init: {"theme":"dark"}}%%\npie\n"A":1',
        'pie\n"A":1 ignored',
      ]) {
        expect(() => parseNativeMermaidPie(source), throwsFormatException);
      }
    },
  );
}
