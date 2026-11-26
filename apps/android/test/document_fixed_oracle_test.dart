import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/document_element_scroll.dart';
import 'package:pirc_render/src/document_absolute_position.dart';
import 'live_test.dart' show theme;
import 'native_html_document_layout_test.dart' show prepareNativeLayoutDocument;

final fixture =
    jsonDecode(
          File(
            '../../packages/pirc_render/test/fixtures/parity/document-fixed-chromium153.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;
void main() {
  for (final row in fixture['cases'] as List) {
    testWidgets(
      'fixed oracle ${row['mode']} ${row['viewport']['width']} dpr${row['dpr']} ${row['theme']}',
      (tester) async {
        final scroll = ScrollController(),
            layout = NativeDocumentLayoutController(),
            elements = NativeDocumentElementScrollController();
        addTearDown(scroll.dispose);
        addTearDown(layout.dispose);
        addTearDown(elements.dispose);
        addTearDown(tester.view.reset);
        final key = GlobalKey(), identity = Object(), hits = <String>[];
        var revision = 0, lastMarkup = '', lastSize = Size.zero;
        final dpr = (row['dpr'] as num).toDouble();
        for (final step in row['states'] as List) {
          final v = step['viewport'],
              size = Size(
                (v['width'] as num).toDouble(),
                (v['height'] as num).toDouble(),
              );
          tester.view.devicePixelRatio = dpr;
          tester.view.physicalSize = size * dpr;
          final document = html.parse(step['html'] as String);
          document.getElementById('probe')!.text = 'WAIT';
          final ids = <String>{};
          for (final e in document.querySelectorAll('[id]')) {
            ids.add(e.id);
            e.attributes['data-pirc-script-click'] = '';
          }
          final markup = document.outerHtml;
          if (markup != lastMarkup || size != lastSize) {
            lastMarkup = markup;
            lastSize = size;
            revision++;
            final prepared = prepareNativeLayoutDocument(
              {
                'html': markup,
                'targets': ids.toList(),
                'viewportWidth': size.width,
                'theme': row['theme'],
              },
              viewportHeight: size.height,
              devicePixelRatio: dpr,
            );
            await tester.pumpWidget(
              RepaintBoundary(
                key: key,
                child: MaterialApp(
                  theme: theme.build(
                    row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
                  ),
                  home: Scaffold(
                    body: ColoredBox(
                      color: const Color(0xff22c55e),
                      child: NativeDocumentPositioningViewport(
                        scrollChanges: scroll,
                        child: SingleChildScrollView(
                          controller: scroll,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minHeight: size.height),
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
                                  imageViewport: size,
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
              ),
            );
            await tester.pumpAndSettle();
          }
          final state = step['state'];
          scroll.jumpTo((state['scrollY'] as num).toDouble());
          if (row['mode'] == 'nested_scroll' && (state['phase'] as num) >= 1) {
            elements.applyActions([
              {'id': 'host', 'op': 'to', 'top': 60},
            ]);
          }
          await tester.pumpAndSettle();
          if (row['mode'] == 'nested_scroll') {
            expect(elements.metricsFor('host')?['top'], state['hostScrollTop']);
          }
          expect(tester.takeException(), isNull);
          expect(
            scroll.position.maxScrollExtent + size.height,
            closeTo((state['scrollHeight'] as num).toDouble(), .01),
            reason: '${row['mode']} scroll height',
          );
          final packet = layout.capture(
            revision: revision,
            generation: 1,
            viewport: size,
            scrollOffset: Offset(0, scroll.offset),
          )!;
          final boxes = {for (final b in packet['boxes'] as List) b['id']: b};
          for (final entry
              in (state['boxes'] as Map<String, dynamic>).entries) {
            final actual = boxes[entry.key]!;
            final rect = {
              'x': actual['x'] ?? 0,
              'y':
                  (actual['y'] ?? 0) -
                  (actual['kind'] == 'none' ? 0 : scroll.offset),
              'width': actual['width'] ?? 0,
              'height': actual['height'] ?? 0,
            };
            for (final axis in ['x', 'y', 'width', 'height']) {
              expect(
                rect[axis],
                closeTo(
                  (entry.value[axis] as num).toDouble(),
                  row['mode'] == 'percent' ? 1 / 32 : 0.01,
                ),
                reason:
                    '${row['mode']} phase${state['phase']} ${entry.key}.$axis',
              );
            }
          }
          final point = Offset(
            (step['point']['x'] as num).toDouble(),
            (step['point']['y'] as num).toDouble(),
          );
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = (await tester.runAsync(
            () => boundary.toImage(pixelRatio: dpr),
          ))!;
          try {
            final bytes = (await tester.runAsync(
              () =>
                  image.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
            ))!;
            final offset =
                ((point.dy * dpr).floor() * image.width +
                    (point.dx * dpr).floor()) *
                4;
            expect(
              [for (var c = 0; c < 4; c++) bytes.getUint8(offset + c)],
              step['rgba'],
              reason: '${row['mode']} paint phase${state['phase']}',
            );
          } finally {
            image.dispose();
          }
          hits.clear();
          expect(
            layout.hitTestDocument(point, revision: revision)?.elementId,
            step['target'],
          );
          await tester.tapAt(point);
          await tester.pumpAndSettle();
          expect(hits, [
            step['target'],
          ], reason: '${row['mode']} click phase${state['phase']}');
        }
      },
    );
  }
}
