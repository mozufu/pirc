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

import 'live_test.dart' show theme;

Finder _box(String id) => find.byWidgetPredicate(
  (widget) =>
      widget is NativeDocumentBox &&
      widget.geometryOwner is dom.Element &&
      (widget.geometryOwner as dom.Element).id == id,
);

NativeFetchedDocument _document(String css, String body) {
  final bytes = Uint8List.fromList(
    utf8.encode(
      '<!doctype html><html id="root"><body id="body">$body</body></html>',
    ),
  );
  return NativeFetchedDocument(
    id: 0,
    url: 'https://example.test/margins',
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
      NativeDocumentStylesheet(css, baseUrl: 'https://example.test/margins'),
    ],
  );
}

Future<void> _render(
  WidgetTester t,
  NativeFetchedDocument document,
  Size viewport,
) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = viewport;
  await t.pumpWidget(
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
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'fetched page collapses actual parent bounds and retains fixed height on resize',
    (t) async {
      final document = _document(
        'html,body{margin:0;padding:0}#outer{border:1px solid}'
            '#parent{height:80px;margin-top:20px;background:#ff0000}'
            '#child{margin-top:30px;height:10px;width:30px}#next{height:10px}',
        '<div id="outer"><div id="parent"><div id="child"></div></div><div id="next"></div></div>',
      );
      addTearDown(document.dispose);
      addTearDown(t.view.reset);
      for (final viewport in [const Size(390, 844), const Size(768, 1024)]) {
        await _render(t, document, viewport);
        expect(t.getTopLeft(_box('parent')).dy, 31);
        expect(t.getTopLeft(_box('child')).dy, 31);
        expect(t.getSize(_box('parent')).height, 80);
        expect(t.getTopLeft(_box('next')).dy, 111);
        expect(t.getSize(_box('outer')).height, 122);
        expect(t.takeException(), isNull);
      }
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'fetched body moves with its large first margin and scrolls normally',
    (t) async {
      final document = _document(
        'html{margin:0;padding:0}body{margin:8px}#child{margin-top:1000px;height:10px;width:30px}',
        '<div id="child"></div>',
      );
      addTearDown(document.dispose);
      addTearDown(t.view.reset);
      await _render(t, document, const Size(390, 844));
      expect(t.getTopLeft(_box('body')).dy, 1000);
      expect(t.getTopLeft(_box('child')).dy, 1000);
      expect(t.getSize(_box('body')).height, 10);
      document.scroll.jumpTo(100);
      await t.pump();
      expect(t.getTopLeft(_box('body')).dy, 900);
      expect(t.getTopLeft(_box('child')).dy, 900);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
}
