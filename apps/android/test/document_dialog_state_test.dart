import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_render_document/src/document_computed_styles.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'live_test.dart' show theme;

void main() {
  for (final markup in [
    '<dialog></dialog>',
    '<form method="DIALOG"></form>',
    '<button formmethod="dialog">Close</button>',
    '<input formmethod="dialog">',
  ]) {
    test(
      'dialog semantics activate the runtime without authored scripts: $markup',
      () {
        final content = NativeHtmlDocumentContent.fromBytes(
          Uint8List.fromList(utf8.encode(markup)),
          mimeType: 'text/html',
        );
        expect(content.hasScripts, isFalse);
        expect(NativeDocumentScripts.needsRuntime(content), isTrue);
      },
    );
  }
  for (final row in [
    (false, false, 'none'),
    (true, false, 'block'),
    (false, true, 'block'),
  ]) {
    test('dialog computed display open=${row.$1} authored=${row.$2}', () {
      final document = html.parse(
        '<dialog data-pirc-script-id="pirc-1" ${row.$1 ? 'open' : ''}>Content</dialog>',
      );
      final element = document.querySelector('dialog')!;
      final specs = nativeDocumentComputedStyleSpecs(
        document: document,
        stylesByElement: {
          if (row.$2) element: {'display': 'block'},
        },
        viewportWidth: 390,
        viewportHeight: 796,
      );
      expect(specs['pirc-1']!.values['display'], row.$3);
    });
    testWidgets('dialog native visibility open=${row.$1} authored=${row.$2}', (
      t,
    ) async {
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: NativeHtmlDocument(
              nodes: [
                NativeHtmlRaw(
                  '<dialog ${row.$1 ? 'open' : ''}>Dialog body</dialog>',
                ),
              ],
              style: const TextStyle(fontSize: 16),
              styles: MarkdownStyleSheet(),
              builders: const {},
              markdownStyles: false,
              authorStylesBuilder: row.$2
                  ? (element) => element.localName == 'dialog'
                        ? {'display': 'block'}
                        : null
                  : null,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        find.text('Dialog body', findRichText: true),
        row.$3 == 'none' ? findsNothing : findsOneWidget,
      );
      expect(t.takeException(), isNull);
    });
  }
}
