import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:csslib/parser.dart' as css_parser;
import 'package:csslib/visitor.dart' as css;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_document_grid.dart';
import 'package:pirc_render/src/html_grid_template.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'live_test.dart' show theme;

NativeGridTemplate template(String source) {
  final sheet = css_parser.parse('.x{grid-template-columns:$source}');
  final rule = sheet.topLevels.single as css.RuleSet;
  return NativeGridTemplate.parse(
    rule.declarationGroup.declarations
        .whereType<css.Declaration>()
        .single
        .expression,
  )!;
}

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-grid-tracks.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final c in fixture['cases'] as List) {
    for (final mode in ['render', 'document-light', 'document-dark']) {
      testWidgets('Chrome grid ${c['id']} $mode', (tester) async {
        tester.view.physicalSize = const Size(1200, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final width = (c['width'] as num).toDouble();
        final brightness = mode == 'document-dark'
            ? Brightness.dark
            : Brightness.light;
        late Widget content;
        NativeFetchedDocument? document;
        if (mode == 'render') {
          content = Directionality(
            textDirection: c['direction'] == 'rtl'
                ? TextDirection.rtl
                : TextDirection.ltr,
            child: SizedBox(
              width: width,
              child: NativeDocumentGrid(
                template: template(c['template'] as String),
                spans: (c['spans'] as List).cast<int>(),
                stretchRows: [for (final _ in c['rects'] as List) false],
                columnGap: (c['gap'] as num).toDouble(),
                rowGap: (c['rowGap'] as num).toDouble(),
                children: [
                  for (final rect in c['rects'] as List)
                    SizedBox(height: (rect['height'] as num).toDouble()),
                ],
              ),
            ),
          );
        } else {
          final markup = c['authoredHTML'] as String;
          final bytes = Uint8List.fromList(utf8.encode(markup));
          final parsed = html.parse(markup);
          document = NativeFetchedDocument(
            id: 0,
            url: 'https://grid.example/',
            status: 200,
            bytes: bytes,
            mimeType: 'text/html',
            headers: {},
            content: NativeHtmlDocumentContent.fromBytes(
              bytes,
              mimeType: 'text/html',
              charset: 'utf-8',
            ),
            stylesheets: [
              for (final style in parsed.querySelectorAll('style'))
                NativeDocumentStylesheet(
                  style.text,
                  baseUrl: 'https://grid.example/',
                ),
            ],
          );
          content = NativeFetchedDocumentView(
            document: document,
            gateway: Gateway(),
            onLink: (_) {},
            onSubmit: (_) {},
          );
        }
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(brightness),
              home: Scaffold(
                body: Align(alignment: Alignment.topLeft, child: content),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final finder = find.byType(NativeDocumentGrid);
          expect(finder, findsOneWidget);
          final grid = tester.renderObject<RenderBox>(finder);
          final origin = grid.localToGlobal(Offset.zero);
          final children = <RenderBox>[];
          grid.visitChildren((child) {
            children.add(child as RenderBox);
          });
          final rects = c['rects'] as List;
          expect(children.length, rects.length);
          for (var i = 0; i < children.length; i++) {
            final child = children[i], expected = rects[i] as Map;
            final offset = child.localToGlobal(Offset.zero) - origin;
            for (final entry in {
              'x': offset.dx,
              'y': offset.dy,
              'width': child.size.width,
              'height': child.size.height,
            }.entries) {
              expect(
                entry.value,
                closeTo((expected[entry.key] as num).toDouble(), .1),
                reason: '${c['id']} $mode item ${i + 1} ${entry.key}',
              );
            }
          }
          expect(
            grid.size.height,
            closeTo((c['height'] as num).toDouble(), .1),
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          document?.dispose();
        }
      });
    }
  }
  testWidgets('responsive grid reflows without losing native form edits', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const markup =
        '<html><body><div id="cards">'
        '<div class="card"><input name="note" value="Initial"></div>'
        '<div class="card">Second card</div><div class="card">Third card</div>'
        '</div></body></html>';
    final bytes = Uint8List.fromList(utf8.encode(markup));
    final document = NativeFetchedDocument(
      id: 0,
      url: 'https://grid.example/',
      status: 200,
      bytes: bytes,
      mimeType: 'text/html',
      headers: {},
      content: NativeHtmlDocumentContent.fromBytes(
        bytes,
        mimeType: 'text/html',
        charset: 'utf-8',
      ),
      stylesheets: const [
        NativeDocumentStylesheet(
          'body{margin:0}#cards{display:grid;width:100%;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));column-gap:12px;row-gap:8px}.card{min-width:0}input{width:100%;min-width:0;box-sizing:border-box}',
          baseUrl: 'https://grid.example/',
        ),
      ],
    );
    Future<void> render(double width) async {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: NativeFetchedDocumentView(
              document: document,
              gateway: Gateway(),
              onLink: (_) {},
              onSubmit: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    double firstCellWidth() {
      final grid = tester.renderObject<RenderBox>(
        find.byType(NativeDocumentGrid),
      );
      final children = <RenderBox>[];
      grid.visitChildren((child) => children.add(child as RenderBox));
      return children.first.size.width;
    }

    try {
      await render(260);
      expect(firstCellWidth(), closeTo(124, .1));
      await tester.enterText(
        find.byType(TextField).first,
        'Draft survives column count change',
      );
      await render(650);
      expect(firstCellWidth(), closeTo((650 - 24) / 3, .1));
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Draft survives column count change',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      document.dispose();
    }
  });
}
