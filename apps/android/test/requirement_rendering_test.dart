import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/mermaid/requirement_rendering.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import 'live_test.dart' show theme;

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/mermaid-requirement-parser-expected.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final input in fixture['cases'] as List) {
    for (final width in [390.0, 768.0]) {
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 2.0]) {
          testWidgets(
            'requirement ${input['id']} $width ${brightness.name} $scale',
            (t) async {
              t.view.devicePixelRatio = 1;
              t.view.physicalSize = Size(width, 900);
              addTearDown(t.view.reset);
              const boundary = ValueKey('requirement-capture');
              await t.pumpWidget(
                MaterialApp(
                  theme: theme.build(brightness),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: SingleChildScrollView(
                      child: RepaintBoundary(
                        key: boundary,
                        child: NativeMarkdown(
                          source: '~~~mermaid\n${input['source']}\n~~~',
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await t.pumpAndSettle();
              expect(find.byType(NativeMermaidRequirement), findsOneWidget);
              expect(find.textContaining('Mermaid:'), findsNothing);
              expect(find.text(input['source'] as String), findsNothing);
              final canvas = find.byWidgetPredicate(
                (w) =>
                    w is CustomPaint && w.painter is NativeRequirementPainter,
              );
              expect(canvas, findsOneWidget);
              final layout =
                  (t.widget<CustomPaint>(canvas).painter!
                          as NativeRequirementPainter)
                      .layout;
              final raw = input['parser']['db']['raw'] as Map;
              expect(
                layout.nodes,
                hasLength(
                  (raw['requirements'] as List).length +
                      (raw['elements'] as List).length,
                ),
              );
              expect(
                layout.edges,
                hasLength((raw['relations'] as List).length),
              );
              final bounds = Offset.zero & layout.size;
              expect(
                layout.size.width.isFinite && layout.size.height.isFinite,
                isTrue,
              );
              for (final node in layout.nodes) {
                expect(node.bounds.width, greaterThan(0));
                expect(node.bounds.height, greaterThan(0));
                expect(
                  bounds.inflate(.1).contains(node.bounds.topLeft) &&
                      bounds.inflate(.1).contains(node.bounds.bottomRight),
                  isTrue,
                );
                for (final field in node.fields) {
                  final box = node.fieldBounds(field);
                  expect(
                    node.bounds.inflate(.5).contains(box.topLeft) &&
                        node.bounds.inflate(.5).contains(box.bottomRight),
                    isTrue,
                    reason: '${node.node.name} ${field.label.text}',
                  );
                }
              }
              for (final edge in layout.edges) {
                expect(edge.path.computeMetrics(), isNotEmpty);
                expect(edge.label.text, '<<${edge.relation.type}>>');
              }
              final pixels = await t.runAsync(() async {
                final image = await t
                    .renderObject<RenderRepaintBoundary>(find.byKey(boundary))
                    .toImage(pixelRatio: 1);
                try {
                  final bytes = (await image.toByteData(
                    format: ui.ImageByteFormat.rawRgba,
                  ))!.buffer.asUint8List();
                  final colors = <int>{};
                  for (var i = 0; i + 3 < bytes.length; i += 16) {
                    if (bytes[i + 3] != 0) {
                      colors.add(
                        (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2],
                      );
                    }
                  }
                  return colors.length;
                } finally {
                  image.dispose();
                }
              });
              expect(pixels, greaterThan(1));
              expect(t.takeException(), isNull);
              await t.pumpWidget(const SizedBox());
            },
          );
        }
      }
    }
  }
  testWidgets('invalid and streaming requirement preserve source', (t) async {
    for (final ready in [true, false]) {
      const source = 'requirementDiagram\nrequirement Bad { risk: critical }';
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: NativeMermaid(source: source, ready: ready),
          ),
        ),
      );
      await t.pump();
      expect(find.byType(NativeMermaidRequirement), findsNothing);
      expect(find.textContaining(source), findsWidgets);
      expect(t.takeException(), isNull);
    }
  });
}
