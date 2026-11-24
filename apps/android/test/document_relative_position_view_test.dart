import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_box.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/document_element_scroll.dart';
import 'live_test.dart' show theme;

Finder _box(String id) => find.byWidgetPredicate(
  (widget) =>
      widget is NativeDocumentBox &&
      widget.geometryOwner is dom.Element &&
      (widget.geometryOwner as dom.Element).id == id,
);
NativeFetchedDocument _document(String css, String markup) {
  final bytes = Uint8List.fromList(
    utf8.encode('<!doctype html><html><body>$markup</body></html>'),
  );
  return NativeFetchedDocument(
    id: 0,
    url: 'https://example.test/relative',
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
      NativeDocumentStylesheet(
        'html,body{margin:0;padding:0}$css',
        baseUrl: 'https://example.test/relative',
      ),
    ],
  );
}

Future<void> _render(
  WidgetTester tester,
  NativeFetchedDocument document,
  List<String> visited, {
  Size viewport = const Size(390, 844),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = viewport;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.build(Brightness.light),
      home: Scaffold(
        body: NativeFetchedDocumentView(
          document: document,
          gateway: Gateway(),
          onLink: (link) => visited.add(link.href),
          onSubmit: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('default inline grid links retain separate cells and shifted hits', (
    tester,
  ) async {
    final document = _document(
      '#grid{display:grid;width:300px;grid-template-columns:100px 100px;grid-template-rows:60px;border:1px solid}#link{position:relative;left:20px;top:40px;width:80px;height:30px}#after{width:60px;height:20px}',
      '<div id="grid">\n  <a id="link" href="/grid">Grid link</a>\n  <span id="after"></span>\n</div>',
    );
    addTearDown(document.dispose);
    addTearDown(tester.view.reset);
    final visited = <String>[];
    await _render(tester, document, visited);
    expect(tester.getTopLeft(_box('link')), const Offset(21, 41));
    expect(tester.getTopLeft(_box('after')), const Offset(101, 1));
    expect(tester.getSize(_box('grid')).height, 62);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(visited, isEmpty);
    await tester.tapAt(tester.getCenter(_box('link')));
    await tester.pumpAndSettle();
    expect(visited, ['/grid']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'relative fetched links paint and hit at shifted positions while siblings retain flow',
    (tester) async {
      final document = _document(
        '#parent{width:250px;height:200px;border:1px solid;padding:10px}#link{display:block;position:relative;left:80px;top:90px;width:100px;height:30px}#sibling{height:20px}',
        '<div id="parent"><a id="link" href="/shifted">Shifted link</a><div id="sibling"></div></div>',
      );
      addTearDown(document.dispose);
      addTearDown(tester.view.reset);
      final visited = <String>[];
      await _render(tester, document, visited);
      expect(tester.getTopLeft(_box('link')), const Offset(91, 101));
      expect(tester.getTopLeft(_box('sibling')).dy, 41);
      await tester.tapAt(const Offset(61, 26));
      await tester.pumpAndSettle();
      expect(visited, isEmpty);
      await tester.tapAt(tester.getCenter(_box('link')));
      await tester.pumpAndSettle();
      expect(visited, ['/shifted']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'relative overflow contributes scroll extent and clipped shifted link becomes reachable',
    (tester) async {
      final document = _document(
        '#scroller{width:200px;height:100px;overflow:auto;border:1px solid}#link{display:block;position:relative;left:120px;top:200px;width:80px;height:20px;line-height:20px;white-space:nowrap}',
        '<div id="scroller"><a id="link" href="/overflow">Overflow link</a></div>',
      );
      addTearDown(document.dispose);
      addTearDown(tester.view.reset);
      final visited = <String>[];
      await _render(tester, document, visited);
      final viewport = tester.widget<NativeDocumentElementScroll>(
        find
            .descendant(
              of: _box('scroller'),
              matching: find.byType(NativeDocumentElementScroll),
            )
            .first,
      );
      final metrics = viewport.controller.metricsFor(viewport.id)!;
      expect(metrics['height'], 220);
      expect(metrics['width'], 200);
      await tester.tapAt(tester.getCenter(_box('link')));
      await tester.pumpAndSettle();
      expect(visited, isEmpty);
      viewport.controller.applyActions([
        {'id': viewport.id, 'op': 'scrollTo', 'top': 120},
      ]);
      await tester.pumpAndSettle();
      expect(viewport.controller.metricsFor(viewport.id)!['top'], 120);
      expect(tester.getTopLeft(_box('link')), const Offset(121, 81));
      await tester.tapAt(tester.getCenter(_box('link')));
      await tester.pumpAndSettle();
      expect(visited, ['/overflow']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'relative percentages resize without losing form edits or page scrolling',
    (tester) async {
      final document = _document(
        '#parent{height:200px;padding:10px;border:1px solid}#link{display:block;position:relative;left:10%;top:10%;width:100px;height:30px}#sibling{height:20px}#spacer{height:1400px}',
        '<div id="parent"><a id="link" href="/resized">Resized</a><div id="sibling"></div></div><input name="draft" value="Initial"><div id="spacer"></div>',
      );
      addTearDown(document.dispose);
      addTearDown(tester.view.reset);
      final visited = <String>[];
      await _render(tester, document, visited);
      expect(tester.getTopLeft(_box('link')).dx, closeTo(47.8, .01));
      expect(tester.getTopLeft(_box('link')).dy, 31);
      expect(tester.getTopLeft(_box('sibling')).dy, 41);
      await tester.enterText(
        find.byType(EditableText),
        'Retained relative draft',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final input = tester
          .widget<EditableText>(find.byType(EditableText))
          .controller;
      document.scroll.jumpTo(50);
      await tester.pump();
      await _render(tester, document, visited, viewport: const Size(768, 1024));
      expect(tester.getTopLeft(_box('link')).dx, closeTo(85.6, .01));
      expect(tester.getTopLeft(_box('link')).dy, -19);
      expect(document.scroll.offset, 50);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller,
        same(input),
      );
      expect(input.text, 'Retained relative draft');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
