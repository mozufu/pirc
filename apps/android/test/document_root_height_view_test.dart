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
    url: 'https://example.test/root-height',
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
        baseUrl: 'https://example.test/root-height',
      ),
    ],
  );
}

void main() {
  testWidgets('fetched page uses its viewport for root heights and resizes '
      'without losing form edits or scrolling', (t) async {
    final visited = <String>[];
    final document = _document(
      'html,body,#app{height:100%} #quarter{height:25%} '
          '#overflow{height:1600px}',
      '<div id="app"><div id="quarter"></div>'
          '<input name="message" value="Initial"><div id="overflow"></div>'
          '<a href="/done">At end</a></div>',
    );
    addTearDown(document.dispose);
    addTearDown(t.view.reset);
    Future<void> render(Size viewport) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = viewport;
      await t.pumpWidget(
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
      await t.pumpAndSettle();
    }

    await render(const Size(390, 844));
    for (final id in ['root', 'body', 'app']) {
      expect(t.getSize(_box(id)).height, 844, reason: '#$id full height');
    }
    expect(t.getSize(_box('quarter')).height, 211);
    await t.enterText(find.byType(EditableText), 'Retained edit');
    final input = t.widget<EditableText>(find.byType(EditableText)).controller;
    FocusManager.instance.primaryFocus?.unfocus();
    await t.pumpAndSettle();
    expect(document.scroll.position.maxScrollExtent, greaterThan(900));
    document.scroll.jumpTo(80);
    await t.pump();

    await render(const Size(844, 390));
    for (final id in ['root', 'body', 'app']) {
      expect(t.getSize(_box(id)).height, 390, reason: '#$id resized height');
    }
    expect(t.getSize(_box('quarter')).height, 97.5);
    expect(
      t.widget<EditableText>(find.byType(EditableText)).controller,
      same(input),
    );
    expect(input.text, 'Retained edit');
    expect(document.scroll.offset, 80);
    document.scroll.jumpTo(document.scroll.position.maxScrollExtent);
    await t.pumpAndSettle();
    await t.tap(find.text('At end', findRichText: true));
    await t.pumpAndSettle();
    expect(visited, ['/done']);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fetched page viewport excludes surrounding app chrome', (
    t,
  ) async {
    final document = _document(
      'html,body,#app{height:100%}',
      '<div id="app"></div>',
    );
    addTearDown(document.dispose);
    addTearDown(t.view.reset);
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(390, 844);
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: 120),
              Expanded(
                child: NativeFetchedDocumentView(
                  document: document,
                  gateway: Gateway(),
                  onLink: (_) {},
                  onSubmit: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(t.getSize(_box('app')).height, 724);
    expect(document.scroll.position.maxScrollExtent, 0);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
