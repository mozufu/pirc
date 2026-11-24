import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
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
              'tool/parity/fixtures/document-transform-scroll-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final row in fixture['cases'] as List) {
    testWidgets(
      'native transformed scroll ${row['mode']} ${row['viewport']['width']} dpr${row['dpr']} ${row['theme']}',
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
            identity = Object(),
            paintKey = GlobalKey(),
            hits = <String>[];
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
            document
                    .getElementById('target')!
                    .attributes['data-pirc-script-click'] =
                '';
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
              RepaintBoundary(
                key: paintKey,
                child: MaterialApp(
                  theme: theme.build(
                    row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
                  ),
                  home: Scaffold(
                    body: NativeDocumentPositioningViewport(
                      scrollChanges: scroll,
                      child: SingleChildScrollView(
                        controller: scroll,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: viewport.height,
                          ),
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
                                onScriptClick: (id, controls) async {
                                  hits.add(id);
                                  return true;
                                },
                              ),
                            ],
                          ),
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
            {
              'id': 'host',
              'op': 'to',
              'left': phase == 'before' ? 0 : 16,
              'top': phase == 'before' ? 0 : 20,
            },
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
          final state = row['result'][phase] as Map;
          expect(elements.metricsFor('host'), {
            for (final k in ['left', 'top', 'width', 'height']) k: state[k],
          }, reason: '$phase scroll metrics');
          expect(
            [boxes['host']['clientWidth'], boxes['host']['clientHeight']],
            [state['clientWidth'], state['clientHeight']],
            reason: '$phase client sizes',
          );
          for (final entry in (state['boxes'] as Map).entries) {
            final actual = boxes[entry.key] as Map,
                expected = entry.value as Map;
            expect(
              actual['offset'],
              expected['offset'],
              reason: '$phase ${entry.key} offset',
            );
            final rect = expected['rect'] as List;
            final values = [
              actual['x'],
              (actual['y'] as num) - scroll.offset,
              actual['width'],
              actual['height'],
            ];
            for (var i = 0; i < 4; i++) {
              expect(
                values[i],
                closeTo((rect[i] as num).toDouble(), 1 / 32),
                reason: '$phase ${entry.key}[$i]',
              );
            }
          }
          final pixel = row['pixels'][phase];
          if (pixel is Map) {
            final boundary =
                paintKey.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = (await tester.runAsync(
              () => boundary.toImage(pixelRatio: dpr),
            ))!;
            try {
              final data = (await tester.runAsync(
                () => image.toByteData(
                  format: ui.ImageByteFormat.rawStraightRgba,
                ),
              ))!;
              final start =
                  (((pixel['y'] as num) * dpr).floor() * image.width +
                      ((pixel['x'] as num) * dpr).floor()) *
                  4;
              expect(
                data.buffer.asUint8List().sublist(start, start + 4),
                pixel['rgba'],
                reason: '$phase target/clip pixel',
              );
            } finally {
              image.dispose();
            }
            hits.clear();
            await tester.tapAt(
              Offset(
                (pixel['x'] as num).toDouble(),
                (pixel['y'] as num).toDouble(),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              hits,
              ((row['clicks'][phase] as num) -
                          (phase == 'changed'
                              ? row['clicks']['before'] as num
                              : 0)) ==
                      1
                  ? ['target']
                  : isEmpty,
              reason: '$phase native clipping click',
            );
          }
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
