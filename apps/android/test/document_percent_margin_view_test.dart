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

void main() {
  testWidgets(
    'fetched percent margins resize while preserving edited input and window scrolling',
    (t) async {
      final bytes = Uint8List.fromList(
        utf8.encode(
          '<!doctype html><html><body>'
          '<div id="outer"><div id="parent"><div id="child"></div>'
          '<input name="draft" value="Initial"></div><div id="spacer"></div></div>'
          '</body></html>',
        ),
      );
      final document = NativeFetchedDocument(
        id: 0,
        url: 'https://example.test/percent-margins',
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
            'html,body{margin:0;padding:0}#outer{border:1px solid}'
            '#parent{height:80px;margin-top:20px;background:#ff0000}'
            '#child{height:10px;width:30px;margin-top:5%}#spacer{height:1400px}',
            baseUrl: 'https://example.test/percent-margins',
          ),
        ],
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
                onLink: (_) {},
                onSubmit: (_) {},
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
      }

      await render(const Size(390, 844));
      expect(t.getTopLeft(_box('parent')).dy, 21);
      expect(t.getTopLeft(_box('child')).dy, 21);
      expect(t.getSize(_box('parent')).height, 80);
      await t.enterText(find.byType(EditableText), 'Retained percent draft');
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pumpAndSettle();
      final input = t
          .widget<EditableText>(find.byType(EditableText))
          .controller;
      document.scroll.jumpTo(120);
      await t.pump();
      await render(const Size(768, 1024));
      expect(
        t.getTopLeft(_box('parent')).dy,
        closeTo(1 + 766 * .05 - 120, .05),
      );
      expect(t.getTopLeft(_box('child')).dy, closeTo(1 + 766 * .05 - 120, .05));
      expect(t.getSize(_box('parent')).height, 80);
      expect(document.scroll.offset, 120);
      expect(
        t.widget<EditableText>(find.byType(EditableText)).controller,
        same(input),
      );
      expect(input.text, 'Retained percent draft');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
}
