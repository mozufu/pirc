import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/html_text_fields.dart';

import 'live_test.dart' show theme;

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'control owns CSS and scales its prepared font once at $scale',
      (t) async {
        const source = '''<!doctype html><html><body><form>
        <input id="field" name="message" value="Initial">
        <textarea id="area" name="body">Text</textarea>
        <input id="hidden" name="hidden" value="Hidden value">
        </form></body></html>''';
        final bytes = Uint8List.fromList(utf8.encode(source));
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
          body {font-family:sans-serif;font-size:16px;color:rgb(30,40,50)}
          input, textarea {font:inherit}
          #field {font-size:20px;color:rgb(90,100,110);width:210px;box-sizing:border-box;
            padding:3px 7px;border:2px solid rgb(80,90,100);background-color:rgb(230,240,250)}
          #area {font-size:18px;line-height:24px}
          #hidden {display:none}
        ''', baseUrl: 'https://example.test/'),
          ],
        );
        addTearDown(document.dispose);
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(390, 844),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: NativeFetchedDocumentView(
                  document: document,
                  gateway: Gateway(),
                  onLink: (_) {},
                  onSubmit: (_) {},
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        final fields = t
            .widgetList<NativeHtmlTextFieldWidget>(
              find.byType(NativeHtmlTextFieldWidget),
            )
            .toList();
        expect(fields, hasLength(2));
        final field = fields.singleWhere((f) => f.field.name == 'message');
        final area = fields.singleWhere((f) => f.field.name == 'body');
        expect(field.textStyle.fontSize, 20 * scale);
        expect(field.textStyle.color, const Color.fromRGBO(90, 100, 110, 1));
        expect(area.textStyle.fontSize, 18 * scale);
        expect(t.getSize(find.byWidget(field)).width, 210);
        final editable = find.descendant(
          of: find.byWidget(field),
          matching: find.byType(EditableText),
        );
        expect(
          t
              .state<EditableTextState>(editable)
              .renderEditable
              .textScaler
              .scale(field.textStyle.fontSize!),
          20 * scale,
        );
        await t.enterText(editable, 'Kept edit');
        await t.pumpAndSettle();
        expect(field.state.valueFor(field.field.key), 'Kept edit');
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      },
    );
  }
}
