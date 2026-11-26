import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/document_absolute_position.dart';
import 'package:pirc_render/src/document_element_scroll.dart';
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/document_offsets.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'live_test.dart' show theme;

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../packages/pirc_render/test/fixtures/parity/document-transform-offset-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final row in fixture['cases'] as List) {
    testWidgets(
      'native transformed offsets ${row['mode']} ${row['viewport']['width']} dpr${row['dpr']} ${row['theme']}',
      (tester) async {
        final viewport = Size(
              (row['viewport']['width'] as num).toDouble(),
              (row['viewport']['height'] as num).toDouble(),
            ),
            dpr = (row['dpr'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = viewport * dpr;
        addTearDown(tester.view.reset);
        final layout = NativeDocumentLayoutController(),
            scroll = ScrollController(),
            elements = NativeDocumentElementScrollController(),
            identity = Object();
        addTearDown(layout.dispose);
        addTearDown(scroll.dispose);
        addTearDown(elements.dispose);
        var revision = 0;
        for (final phase in ['before', 'scrolled', 'changed']) {
          if (phase != 'scrolled') {
            revision++;
            final document = html.parse(row['html'] as String),
                root = document.documentElement!,
                body = document.body!;
            if (phase == 'changed') {
              document.getElementById('host')!.classes.add('changed');
            }
            final ids = <String>{};
            for (final e in document.querySelectorAll('[id]')) {
              ids.add(e.id);
              e.attributes['data-pirc-script-id'] = e.id;
            }
            final cascade = NativeDocumentStyleEngine(
              stylesheets: [
                for (final s in document.querySelectorAll('style'))
                  NativeDocumentStylesheet(
                    s.text,
                    baseUrl: 'https://example.test/',
                  ),
              ],
              viewportWidth: viewport.width,
              viewportHeight: viewport.height,
              devicePixelRatio: dpr,
              dark: row['theme'] == 'dark',
            ).apply(document);
            final stylesByElement = <dom.Element, Map<String, String>>{
              for (final e in document.querySelectorAll('*'))
                e: {
                  if (identical(e, body)) 'margin': '8px',
                  ...?cascade.stylesByElement[e],
                },
            };
            final specs = nativeDocumentOffsetSpecs(
                  document: document,
                  stylesByElement: stylesByElement,
                ),
                styles = <String, Map<String, String>>{};
            var next = 0;
            for (final e in document.querySelectorAll('*')) {
              final k = '${next++}';
              e.attributes['data-pirc-document-style'] = k;
              styles[k] = stylesByElement[e]!;
              e.attributes.remove('style');
            }
            String attrs(dom.Element e) => e.attributes.entries
                .map(
                  (a) => ' ${a.key}="${const HtmlEscape().convert(a.value)}"',
                )
                .join();
            final markup =
                '<div${attrs(root)}><div${attrs(body)}>${body.innerHtml}</div></div>';
            await tester.pumpWidget(
              MaterialApp(
                theme: theme.build(
                  row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
                ),
                home: Scaffold(
                  body: NativeDocumentPositioningViewport(
                    scrollChanges: scroll,
                    child: SingleChildScrollView(
                      controller: scroll,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: viewport.height),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            NativeHtmlDocument(
                              nodes: [NativeHtmlRaw(markup)],
                              style: const TextStyle(fontSize: 16),
                              styles: fm.MarkdownStyleSheet(),
                              builders: const {},
                              markdownStyles: false,
                              scriptDocument: identity,
                              imageViewport: viewport,
                              authorStylesBuilder: (e) =>
                                  styles[e
                                      .attributes['data-pirc-document-style']],
                              layoutController: layout,
                              elementScrollController: elements,
                              layoutRevision: revision,
                              layoutKnownIds: ids,
                              layoutOffsetSpecs: specs,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
          }
          scroll.jumpTo(phase == 'before' ? 0 : 40);
          elements.applyActions([
            {'id': 'scroller', 'op': 'to', 'top': phase == 'before' ? 0 : 20},
          ]);
          await tester.pumpAndSettle();
          final packet = layout.capture(
            revision: revision,
            generation: revision,
            viewport: viewport,
            scrollOffset: Offset(0, scroll.offset),
          );
          expect(packet, isNotNull);
          final boxes = {for (final b in packet!['boxes'] as List) b['id']: b};
          for (final entry in (row['result'][phase] as Map).entries) {
            final actual = boxes[entry.key] as Map,
                expected = entry.value as Map;
            expect(actual['offset'], {
              'left': expected['left'],
              'top': expected['top'],
              'parentId': expected['parentId'],
            }, reason: '$phase ${entry.key}');
            expect(
              [actual['offsetWidth'], actual['offsetHeight']],
              [expected['width'], expected['height']],
              reason: '$phase ${entry.key} sizes',
            );
          }
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
