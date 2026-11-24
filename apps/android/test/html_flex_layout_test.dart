import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_document_flex.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'live_test.dart' show theme;

NativeFetchedDocument flexDocument(String markup) {
  final bytes = Uint8List.fromList(utf8.encode(markup));
  final parsed = html.parse(markup);
  return NativeFetchedDocument(
    id: 0,
    url: 'https://flex.example/',
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
        NativeDocumentStylesheet(style.text, baseUrl: 'https://flex.example/'),
    ],
  );
}

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-flex-layout.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final c in fixture['cases'] as List) {
    final input = c['input'] as Map, expected = c['result'] as Map;
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('Chromium flex ${input['id']} ${brightness.name}', (t) async {
        final viewport = input['viewport'] as Map;
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = Size(
          (viewport['width'] as num).toDouble(),
          (viewport['height'] as num).toDouble(),
        );
        addTearDown(t.view.reset);
        final document = flexDocument(c['authoredHTML'] as String);
        try {
          await t.pumpWidget(
            MaterialApp(
              theme: theme.build(brightness),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: (viewport['width'] as num).toDouble(),
                    height: (viewport['height'] as num).toDouble(),
                    child: NativeFetchedDocumentView(
                      document: document,
                      gateway: Gateway(),
                      onLink: (_) {},
                      onSubmit: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          final finder = find.byType(NativeDocumentFlex);
          expect(finder, findsAtLeastNWidgets(1));
          final flex = t.renderObject<RenderBox>(finder.first);
          final origin = flex.localToGlobal(Offset.zero);
          final container = expected['containerRect'] as Map;
          final containerStyles = expected['containerComputedStyle'] as Map;
          double edge(String name) =>
              double.parse('${containerStyles[name]}'.replaceAll('px', ''));
          final left = edge('padding-left') + edge('border-left-width');
          final right = edge('padding-right') + edge('border-right-width');
          final top = edge('padding-top') + edge('border-top-width');
          final bottom = edge('padding-bottom') + edge('border-bottom-width');
          expect(
            origin.dx,
            closeTo((container['x'] as num).toDouble() + left, .1),
          );
          expect(
            origin.dy,
            closeTo((container['y'] as num).toDouble() + top, .1),
          );
          final children = <RenderBox>[];
          flex.visitChildren((child) => children.add(child as RenderBox));
          final rects = (expected['itemRects'] as List)
              .where(
                (row) => (row['computedStyle'] as Map)['display'] != 'none',
              )
              .toList();
          expect(children.length, rects.length);
          for (var i = 0; i < children.length; i++) {
            final child = children[i], rect = rects[i] as Map;
            final offset = child.localToGlobal(Offset.zero) - origin;
            for (final entry in {
              'x': offset.dx,
              'y': offset.dy,
              'width': child.size.width,
              'height': child.size.height,
            }.entries) {
              expect(
                entry.value,
                closeTo(
                  (rect[entry.key] as num).toDouble() -
                      (entry.key == 'x'
                          ? left
                          : entry.key == 'y'
                          ? top
                          : 0),
                  .1,
                ),
                reason: '${input['id']} ${rect['id']} ${entry.key}',
              );
            }
          }
          expect(
            flex.size.width,
            closeTo((container['width'] as num).toDouble() - left - right, .1),
          );
          expect(
            flex.size.height,
            closeTo((container['height'] as num).toDouble() - top - bottom, .1),
          );
          expect(t.takeException(), isNull);
        } finally {
          await t.pumpWidget(const SizedBox());
          document.dispose();
        }
      });
    }
  }

  testWidgets('responsive flex wrapping retains native input edits and focus', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final document = flexDocument(
      '<html><head><style>body{margin:0}#cards{display:flex;flex-wrap:wrap;gap:12px;width:100%}.card{flex:1 1 200px;min-width:0}input{box-sizing:border-box;width:100%;min-width:0}</style></head><body><div id="cards"><div class="card"><input name="note" value="Initial"></div><div class="card">Second card</div><div class="card">Third card</div></div></body></html>',
    );
    Future<void> render(double width) async {
      t.view.physicalSize = Size(width, 900);
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: 900,
                child: NativeFetchedDocumentView(
                  document: document,
                  gateway: Gateway(),
                  onLink: (_) {},
                  onSubmit: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
    }

    try {
      await render(390);
      final field = find.byType(TextField);
      await t.enterText(field, '保留 Flex 草稿');
      final controller = t.widget<TextField>(field).controller;
      final focus = t.widget<TextField>(field).focusNode;
      expect(focus!.hasFocus, isTrue);
      final rectBefore = t.getRect(field);
      await render(768);
      expect(t.widget<TextField>(field).controller, same(controller));
      expect(controller!.text, '保留 Flex 草稿');
      expect(t.widget<TextField>(field).focusNode, same(focus));
      expect(focus.hasFocus, isTrue);
      expect(t.getRect(field).width, lessThan(rectBefore.width));
      await render(390);
      expect(controller.text, '保留 Flex 草稿');
      expect(t.getRect(field).width, closeTo(rectBefore.width, .1));
      expect(t.takeException(), isNull);
    } finally {
      await t.pumpWidget(const SizedBox());
      document.dispose();
    }
  });
  for (final scenario in ['anonymous-text', 'max-width-text']) {
    testWidgets('flex retains item rules with $scenario', (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(500, 900);
      addTearDown(t.view.reset);
      final body = scenario == 'anonymous-text'
          ? '<div style="display:flex;width:300px;gap:10px">Search <button style="flex:1">Go</button></div>'
          : '<div style="display:flex;width:200px"><div style="flex:0 1 auto;max-width:50px">WWWWWWWWWWWWWW</div></div>';
      final document = flexDocument(
        '<html><head><style>body{margin:0}</style></head><body>$body</body></html>',
      );
      try {
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 500,
                  height: 900,
                  child: NativeFetchedDocumentView(
                    document: document,
                    gateway: Gateway(),
                    onLink: (_) {},
                    onSubmit: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        final flex = t.renderObject<RenderBox>(
          find.byType(NativeDocumentFlex).first,
        );
        final children = <RenderBox>[];
        flex.visitChildren((child) => children.add(child as RenderBox));
        if (scenario == 'anonymous-text') {
          expect(children, hasLength(2));
          expect(children.last.size.width, greaterThan(150));
          expect(
            children.fold<double>(10, (sum, child) => sum + child.size.width),
            closeTo(300, .1),
          );
          expect(find.text('Go', findRichText: true), findsOneWidget);
        } else {
          expect(children, hasLength(1));
          expect(children.single.size.width, closeTo(50, .1));
          expect(
            find.text('WWWWWWWWWWWWWW', findRichText: true),
            findsOneWidget,
          );
        }
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        document.dispose();
      }
    });
  }
}
