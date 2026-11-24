import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import 'package:pirc_render/src/mermaid/mindmap_rendering.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'live_test.dart' show theme;
import '../tool/parity/capture_fonts.dart' show loadParityFonts;

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/mermaid-mindmap.json',
            ).readAsStringSync(),
          )
          as Map;
  final basic =
      (fixture['cases'] as List).firstWhere(
            (item) => item['id'] == 'mindmap-basic-tree',
          )['source']
          as String;
  testWidgets(
    'Markdown mindmap waits for streaming and preserves all painted labels',
    (tester) async {
      await tester.runAsync(loadParityFonts);
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Widget host(bool streaming, String source) => MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: NativeMarkdown(source: source, streaming: streaming),
          ),
        ),
      );
      await tester.pumpWidget(host(true, basic));
      await tester.pumpAndSettle();
      expect(find.byType(NativeMermaid), findsOneWidget);
      expect(find.byType(NativeMermaidMindmap), findsNothing);
      await tester.pumpWidget(host(false, basic));
      await tester.pumpAndSettle();
      expect(find.byType(NativeMermaidMindmap), findsOneWidget);
      final painter =
          tester
                  .widget<CustomPaint>(
                    find.byWidgetPredicate(
                      (w) =>
                          w is CustomPaint && w.painter is NativeMindmapPainter,
                    ),
                  )
                  .painter!
              as NativeMindmapPainter;
      expect(painter.layout.nodes.map((n) => n.node.label), [
        'Planning',
        'Research',
        'Sources',
        'Notes',
        'Build',
        'Prototype',
        'Review',
        'Ship',
      ]);
      expect(painter.layout.edges.length, 7);
      expect(find.text('Planning', findRichText: true), findsOneWidget);
      expect(painter.layout.size.width, lessThanOrEqualTo(332));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        host(false, basic.replaceFirst('mindmap', 'Mindmap')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NativeMermaidMindmap), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        host(false, '~~~mermaid\nmindmap\nroot\nother\n~~~'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NativeMermaidMindmap), findsNothing);
      expect(find.textContaining('There can be only one root'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
