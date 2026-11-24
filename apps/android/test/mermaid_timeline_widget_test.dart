import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/mermaid/timeline_rendering.dart';
import 'live_test.dart' show theme;
import '../tool/parity/capture_fonts.dart' show loadParityFonts;

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/mermaid-timeline.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final id in ['timeline-bare-periods', 'timeline-vertical-td']) {
    testWidgets('timeline $id renders through the Markdown stream lifecycle', (
      tester,
    ) async {
      await tester.runAsync(loadParityFonts);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 900);
      addTearDown(tester.view.reset);
      final item =
          (fixture['cases'] as List).firstWhere((item) => item['id'] == id)
              as Map;
      Widget host(bool streaming) => MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: NativeMarkdown(
              source: item['source'] as String,
              streaming: streaming,
              lineHeight: 1.65,
            ),
          ),
        ),
      );
      await tester.pumpWidget(host(true));
      await tester.pumpAndSettle();
      expect(find.byType(NativeMermaidTimeline), findsNothing);
      await tester.pumpWidget(host(false));
      await tester.pumpAndSettle();
      expect(find.byType(NativeMermaidTimeline), findsOneWidget);
      final canvas = tester.widget<CustomPaint>(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is NativeTimelinePainter,
        ),
      );
      final layout = (canvas.painter! as NativeTimelinePainter).layout;
      expect(
        layout.nodes.where((n) => n.kind == 'task').length,
        id == 'timeline-bare-periods' ? 2 : 3,
      );
      expect(
        layout.nodes.where((n) => n.kind == 'event').length,
        id == 'timeline-bare-periods' ? 3 : 4,
      );
      expect(layout.size.width, lessThanOrEqualTo(332));
      expect(layout.viewBox.width, greaterThan(332));
      expect(
        layout.diagram.direction,
        id == 'timeline-bare-periods' ? 'LR' : 'TD',
      );
      // SVG tspans are already wrapped by the source algorithm. A second
      // paragraph wrap can hide the last word inside the fixed font cell.
      final timelineTexts = find.descendant(
        of: find.byType(NativeMermaidTimeline),
        matching: find.byType(Text),
      );
      for (var index = 0; index < timelineTexts.evaluate().length; index++) {
        final textFinder = timelineTexts.at(index);
        final text = tester.widget<Text>(textFinder).data!;
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: textFinder, matching: find.byType(RichText)),
        );
        final selectedBoxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: text.length),
        );
        expect(selectedBoxes, hasLength(1), reason: text);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
