import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'live_test.dart' show theme;

void main() {
  testWidgets('identical markup in a new document resets edited fields', (
    t,
  ) async {
    final nodes = [
      NativeHtmlRaw('<input value="original" data-pirc-script-id="q">'),
    ];
    Future<void> show(Object identity) => t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: NativeHtmlDocument(
            nodes: nodes,
            style: const TextStyle(),
            styles: MarkdownStyleSheet(),
            builders: const {},
            markdownStyles: false,
            scriptDocument: identity,
          ),
        ),
      ),
    );
    await show(Object());
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'private draft');
    await show(Object());
    await t.pumpAndSettle();
    expect(
      t.widget<TextField>(find.byType(TextField)).controller!.text,
      'original',
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('fetched document retains standalone button controls', (t) async {
    final bytes = Uint8List.fromList(
      utf8.encode(
        '<html><body><input id="name" value="Initial"><button type="button" data-pirc-script-id="1">Add item</button><p>Count 0</p><button type="button">Reset field</button></body></html>',
      ),
    );
    final document = NativeFetchedDocument(
      id: 1,
      url: 'https://example.test/',
      status: 200,
      bytes: bytes,
      mimeType: 'text/html',
      content: NativeHtmlDocumentContent.fromBytes(
        bytes,
        mimeType: 'text/html',
        charset: 'utf-8',
      ),
      headers: {},
    );
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

    expect(find.byType(NativeHtmlButtonWidget), findsNWidgets(2));
    await t.pumpWidget(const SizedBox());
    document.dispose();
  });
  testWidgets(
    'viewport rebuild creates controls for the current document snapshot',
    (t) async {
      final viewport = NativeHtmlViewportController();
      Future<void> show(String source) => t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: NativeHtmlDocument(
              nodes: [NativeHtmlRaw(source)],
              style: const TextStyle(),
              styles: MarkdownStyleSheet(),
              builders: const {},
              markdownStyles: false,
              viewport: viewport,
              onScriptClick: (_, _) async => false,
            ),
          ),
        ),
      );
      await show('<p>Initial page</p>');
      await t.pumpAndSettle();
      await show(
        '<button type="button" data-pirc-script-id="a">Dynamic action</button>',
      );
      await t.pumpAndSettle();
      expect(find.byType(NativeHtmlButtonWidget), findsOneWidget);
      expect(
        t
            .widget<NativeHtmlButtonWidget>(find.byType(NativeHtmlButtonWidget))
            .button
            .label,
        'Dynamic action',
      );
      await show(
        '<button type="button" data-pirc-script-id="b">New action</button>',
      );
      await t.pumpAndSettle();
      expect(
        t
            .widget<NativeHtmlButtonWidget>(find.byType(NativeHtmlButtonWidget))
            .button
            .label,
        'New action',
      );
      expect(t.takeException(), isNull);
    },
  );
}
