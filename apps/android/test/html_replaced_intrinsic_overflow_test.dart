import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_canvas.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';

import 'live_test.dart' show theme;

void main() {
  testWidgets(
    'raw HTML canvases overflow intrinsically unless CSS constrains them',
    (tester) async {
      const markup = '''
<div style="width:120px"><canvas id="natural-canvas"></canvas></div>
<div style="width:120px"><canvas id="sized-canvas" style="width:240px;height:90px"></canvas></div>
<div style="width:120px"><canvas id="fitted-canvas" style="max-width:100%"></canvas></div>
<div style="width:120px"><canvas id="height-canvas" style="display:block;height:100px"></canvas></div>
<div style="width:120px"><canvas id="max-height-canvas" style="display:block;max-height:50px"></canvas></div>
''';

      await tester.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 120,
              height: 480,
              child: SingleChildScrollView(
                child: NativeHtmlDocument(
                  nodes: [NativeHtmlRaw(markup)],
                  style: const TextStyle(fontSize: 16),
                  styles: MarkdownStyleSheet(),
                  builders: const {},
                  markdownStyles: false,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final canvasFinder = find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter is NativeDocumentCanvasPainter,
      );
      final canvasSizes = [
        for (var index = 0; index < canvasFinder.evaluate().length; index++)
          tester.getSize(canvasFinder.at(index)),
      ];
      expect(canvasSizes, const [
        Size(300, 150),
        Size(240, 90),
        Size(120, 60),
        Size(200, 100),
        Size(100, 50),
      ]);

      expect(tester.takeException(), isNull);
    },
  );
}
