import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/document_absolute_position.dart';
import 'package:pirc_render/src/document_element_scroll.dart';
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'live_test.dart' show theme;
import 'native_html_document_layout_test.dart' show prepareNativeLayoutDocument;

void main() {
  final fixture =
      jsonDecode(
            File(
              'tool/parity/fixtures/document-transform-cb-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final row in fixture['cases'] as List) {
    testWidgets(
      'native transformed containing block ${row['mode']} ${row['viewport']['width']} dpr${row['dpr']} ${row['theme']}',
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
            paintKey = GlobalKey(),
            identity = Object(),
            hits = <String>[];
        addTearDown(layout.dispose);
        addTearDown(scroll.dispose);
        addTearDown(elements.dispose);
        const ids = {'host', 'middle', 'target', 'outside', 'scroller'};
        var revision = 0;
        for (final phase in ['before', 'scrolled', 'changed']) {
          final expected = row['result'][phase] as Map;
          if (phase != 'scrolled') {
            revision++;
            final document = html.parse(row['html'] as String);
            document
                    .getElementById('target')!
                    .attributes['data-pirc-script-click'] =
                '';
            if (phase == 'changed') {
              document.getElementById('host')!.classes.add('changed');
            }
            final prepared = prepareNativeLayoutDocument(
              {
                'html': document.outerHtml,
                'targets': ids.toList(),
                'viewportWidth': viewport.width,
                'theme': row['theme'],
              },
              viewportHeight: viewport.height,
              devicePixelRatio: dpr,
            );
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
                                nodes: [NativeHtmlRaw(prepared.markup)],
                                style: const TextStyle(
                                  inherit: false,
                                  fontFamily: 'serif',
                                  fontSize: 16,
                                  height: 1,
                                  color: Colors.black,
                                  letterSpacing: 0,
                                ),
                                styles: fm.MarkdownStyleSheet(),
                                builders: const {},
                                markdownStyles: false,
                                scriptDocument: identity,
                                imageViewport: viewport,
                                authorStylesBuilder: (e) =>
                                    prepared.stylesByKey[e
                                        .attributes['data-pirc-document-style']],
                                layoutController: layout,
                                elementScrollController: elements,
                                layoutRevision: revision,
                                layoutKnownIds: ids,
                                layoutNoBoxIds: prepared.noBoxIds,
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
          scroll.jumpTo((expected['scrollY'] as num).toDouble());
          elements.applyActions([
            {'id': 'scroller', 'op': 'to', 'top': expected['inner']},
          ]);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            elements.metricsFor('scroller')?['top'] ?? 0,
            expected['inner'],
          );
          final packet = layout.capture(
            revision: revision,
            generation: revision,
            viewport: viewport,
            scrollOffset: Offset(0, scroll.offset),
          );
          expect(packet, isNotNull);
          final boxes = {for (final b in packet!['boxes'] as List) b['id']: b};
          for (final entry in (expected['boxes'] as Map).entries) {
            final box = boxes[entry.key] as Map, r = entry.value as List;
            expect(box['kind'], 'box', reason: '$phase ${entry.key}');
            final values = [
              box['x'],
              (box['y'] as num) - scroll.offset,
              box['width'],
              box['height'],
            ];
            for (var i = 0; i < 4; i++) {
              expect(
                values[i],
                closeTo((r[i] as num).toDouble(), 1 / 32),
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
              final offset =
                  (((pixel['y'] as num) * dpr).floor() * image.width +
                      ((pixel['x'] as num) * dpr).floor()) *
                  4;
              expect(
                data.buffer.asUint8List().sublist(offset, offset + 4),
                pixel['rgba'],
                reason: '$phase painted target',
              );
            } finally {
              image.dispose();
            }
            final point = Offset(
              (pixel['x'] as num).toDouble(),
              (pixel['y'] as num).toDouble(),
            );
            expect(
              layout.hitTestDocument(point, revision: revision)?.elementId,
              pixel['hit'],
              reason: '$phase hit owner',
            );
            hits.clear();
            await tester.tapAt(point);
            await tester.pumpAndSettle();
            expect(hits, ['target'], reason: '$phase actual native click');
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
