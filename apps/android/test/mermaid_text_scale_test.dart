import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import 'live_test.dart' show theme;

void main() {
  testWidgets('SVG diagram geometry is independent of surrounding text scale', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final width in [390.0, 768.0, 1024.0]) {
      tester.view.physicalSize = Size(width, 900);
      for (final source in [
        'flowchart LR\nA[Start] --> B[End]',
        'sequenceDiagram\nA->>B: Hello',
        'pie title Budget\n"Build":60\n"Test":40',
        'classDiagram\nAnimal <|-- Duck',
        'erDiagram\nCUSTOMER ||--o{ ORDER : places',
        'stateDiagram-v2\n[*] --> Idle\nIdle --> [*]',
        'quadrantChart\ntitle Priorities\nx-axis Low --> High\ny-axis Low --> High\nA: [0.2, 0.8]',
      ]) {
        Size? original;
        for (final scale in [1.0, 2.0]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(Brightness.light),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: NativeMermaid(source: source),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final paint = find
              .descendant(
                of: find.byType(NativeMermaid),
                matching: find.byType(CustomPaint),
              )
              .first;
          final paintedSize = tester.getRect(paint).size;
          if (original == null) {
            original = paintedSize;
          } else {
            expect(
              paintedSize.width,
              closeTo(original.width, .01),
              reason: '$width / $source',
            );
            expect(
              paintedSize.height,
              closeTo(original.height, .01),
              reason: '$width / $source',
            );
          }
        }
      }
    }
  });
}
