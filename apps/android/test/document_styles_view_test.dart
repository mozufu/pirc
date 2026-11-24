import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_document_styles.dart';

import 'live_test.dart' show theme;

void main() {
  testWidgets('responsive author styles reflow while retaining native edits', (
    t,
  ) async {
    final bytes = Uint8List.fromList(
      utf8.encode('''<!doctype html><html><body>
      <p id="probe">Responsive text</p><input name="message" value="Initial">
      <button type="button">Styled button</button><pre>Inherited pre</pre><div style="height:1200px"></div>
      </body></html>'''),
    );
    final document = NativeFetchedDocument(
      id: 0,
      url: 'https://example.test/',
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
        NativeDocumentStylesheet('''
        body {margin:0;font-family:sans-serif}
        button, pre {font:inherit}
        #probe {font-size:14px;color:rgb(10,20,30)}
        @media (min-width:600px) {#probe {font-size:24px;color:rgb(70,80,90)}}
      ''', baseUrl: 'https://example.test/'),
      ],
    );
    addTearDown(document.dispose);
    Future<void> render(double width) async {
      t.view.physicalSize = Size(width, 844);
      t.view.devicePixelRatio = 1;
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

    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    TextStyle probeStyle() => t
        .widgetList<RichText>(find.byType(RichText))
        .singleWhere((r) => r.text.toPlainText() == 'Responsive text')
        .text
        .style!;
    await render(390);
    final buttonStyle = t
        .widgetList<RichText>(find.byType(RichText))
        .singleWhere((r) => r.text.toPlainText() == 'Styled button')
        .text
        .style!;
    expect(buttonStyle.fontSize, 16);
    expect(buttonStyle.fontFamily, 'sans-serif');
    expect(buttonStyle.color, Colors.black);
    final preStyle = t
        .widgetList<RichText>(find.byType(RichText))
        .singleWhere((r) => r.text.toPlainText() == 'Inherited pre')
        .text
        .style!;
    expect(preStyle.fontSize, 16);
    expect(preStyle.fontFamily, 'sans-serif');

    expect(probeStyle().fontSize, 14);
    expect(probeStyle().color, const Color.fromRGBO(10, 20, 30, 1));
    await t.enterText(find.byType(EditableText), 'Edited and retained');
    final controller = t
        .widget<EditableText>(find.byType(EditableText))
        .controller;
    FocusManager.instance.primaryFocus?.unfocus();
    await t.pumpAndSettle();
    document.scroll.jumpTo(123);
    await t.pump();
    await render(768);
    expect(probeStyle().fontSize, 24);
    expect(probeStyle().color, const Color.fromRGBO(70, 80, 90, 1));
    expect(
      t.widget<EditableText>(find.byType(EditableText)).controller,
      same(controller),
    );
    expect(controller.text, 'Edited and retained');
    expect(document.scroll.offset, 123);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
