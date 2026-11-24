import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/document_absolute_position.dart';
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/document_scroll_anchor.dart';
import 'package:pirc_render/src/document_element_scroll.dart';
import 'package:pirc_render/src/document_margin_collapse.dart';
import 'package:pirc_render/src/document_computed_styles.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'live_test.dart' show theme;
import 'native_html_document_layout_test.dart' show prepareNativeLayoutDocument;

final fixture =
    jsonDecode(
          File(
            'tool/parity/fixtures/document-element-anchor-chromium153.json',
          ).readAsStringSync(),
        )
        as Map;
void main() {
  for (final row in fixture['cases'] as List) {
    testWidgets(
      'element anchor ${row['mode']} ${row['viewport']['width']} dpr${row['dpr']} ${row['theme']}',
      (tester) async {
        final dpr = (row['dpr'] as num).toDouble(),
            size = Size(
              (row['viewport']['width'] as num).toDouble(),
              (row['viewport']['height'] as num).toDouble(),
            );
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = size * dpr;
        addTearDown(tester.view.reset);
        final scroll = NativeDocumentScrollController(),
            layout = NativeDocumentLayoutController(),
            elements = NativeDocumentElementScrollController(),
            data = NativeDocumentScrollAnchorData(),
            identity = Object();
        addTearDown(scroll.dispose);
        addTearDown(layout.dispose);
        addTearDown(elements.dispose);
        final paintKey = GlobalKey();
        var revision = 0;
        String? lastMarkup;
        for (final step in row['states'] as List) {
          final state = step['state'] as Map, phase = state['phase'] as int;
          final document = html.parse(step['html'] as String);
          document.getElementById('probe')!.text = 'WAIT';
          final domIds = {
            for (final e in document.querySelectorAll('[id]')) e.id,
          };
          final scriptIds = <String, String>{};
          for (final e in document.querySelectorAll('[id]')) {
            var generation = '1';
            var parent = e;
            while (true) {
              if (parent.attributes['data-generation'] != null) {
                generation = parent.attributes['data-generation']!;
                break;
              }
              final next = parent.parent;
              if (next == null) break;
              parent = next;
            }
            final scriptId = generation == '1' ? e.id : '${e.id}@$generation';
            scriptIds[e.id] = scriptId;
            e.attributes['data-pirc-script-id'] = scriptId;
          }
          final ids = scriptIds.values.toSet();
          if (document.outerHtml != lastMarkup) {
            lastMarkup = document.outerHtml;
            revision++;
            final cascade = NativeDocumentStyleEngine(
              viewportWidth: size.width,
              viewportHeight: size.height,
              devicePixelRatio: dpr,
              dark: row['theme'] == 'dark',
              stylesheets: [
                for (final style in document.querySelectorAll('style'))
                  NativeDocumentStylesheet(
                    style.text,
                    baseUrl: 'https://anchor.test/',
                  ),
              ],
            ).apply(document);
            var nextStyleKey = 0;
            for (final e in document.querySelectorAll('*')) {
              e.attributes['data-pirc-document-style'] = '${nextStyleKey++}';
            }
            final computed = nativeDocumentComputedStyleSpecs(
              document: document,
              stylesByElement: cascade.stylesByElement,
              viewportWidth: size.width,
              viewportHeight: size.height,
            );
            data.nodes = nativeDocumentScrollAnchorNodes(
              document: document,
              stylesByElement: cascade.stylesByElement,
              computedStyles: computed,
            );
            final prepared = prepareNativeLayoutDocument(
              {
                'html': lastMarkup,
                'targets': domIds.toList(),
                'viewportWidth': size.width,
                'theme': row['theme'],
              },
              viewportHeight: size.height,
              devicePixelRatio: dpr,
              scriptIdOverrides: scriptIds,
            );
            await tester.pumpWidget(
              MaterialApp(
                builder: (context, child) =>
                    RepaintBoundary(key: paintKey, child: child!),
                theme: theme.build(
                  row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
                ),
                home: Scaffold(
                  body: NativeDocumentScrollAnchorViewport(
                    controller: scroll,
                    layout: layout,
                    data: data,
                    elements: elements,
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
                                style: const TextStyle(fontSize: 16),
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
                                documentTopMargins:
                                    nativeDocumentCollapsedTopMargins(
                                      document: document,
                                      stylesByElement: cascade.stylesByElement,
                                    ),
                                documentPercentTopMargins:
                                    nativeDocumentPercentTopMarginGroups(
                                      document: document,
                                      stylesByElement: cascade.stylesByElement,
                                    ),
                                layoutRevision: revision,
                                layoutKnownIds: ids,
                                layoutNoBoxIds: prepared.noBoxIds,
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
          if (phase == 1) {
            scroll.jumpTo((state['scrollY'] as num).toDouble());
            elements.applyActions([
              for (final entry in (state['scroll'] as Map).entries)
                {
                  'id': scriptIds[entry.key],
                  'op': 'to',
                  'top': entry.value['top'],
                  'left': entry.value['left'],
                },
            ]);
          }
          if (phase >= 2 && row['mode'] == 'scroll_to') {
            elements.applyActions([
              {
                'id': scriptIds['outer'],
                'op': 'to',
                'top': phase == 2 ? 400 : 200,
              },
            ]);
          }
          if (phase >= 2 && row['mode'] == 'scroll_by') {
            elements.applyActions([
              {
                'id': scriptIds['outer'],
                'op': 'by',
                'top': phase == 2 ? 30 : -20,
              },
            ]);
          }
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            scroll.offset,
            closeTo((state['scrollY'] as num).toDouble(), .01),
            reason: 'phase $phase offset',
          );
          expect(
            (scroll.position.maxScrollExtent + size.height).roundToDouble(),
            closeTo((state['scrollHeight'] as num).toDouble(), .01),
            reason: 'phase $phase extent',
          );
          final packet = layout.capture(
            revision: revision,
            generation: phase + 1,
            viewport: size,
            scrollOffset: Offset(0, scroll.offset),
          )!;
          final boxes = {for (final b in packet['boxes'] as List) b['id']: b};
          for (final entry in (state['boxes'] as Map).entries) {
            final box = boxes[scriptIds[entry.key]] as Map;
            if (box['kind'] == 'none') {
              expect(entry.value['width'], 0);
              expect(entry.value['height'], 0);
              continue;
            }
            expect(box['kind'], 'box', reason: '${entry.key} phase $phase');
            for (final axis in ['x', 'y', 'width', 'height']) {
              final actual =
                  (box[axis] as num).toDouble() -
                  (axis == 'y' ? scroll.offset : 0);
              expect(
                actual,
                closeTo((entry.value[axis] as num).toDouble(), .01),
                reason: '${entry.key}.$axis phase $phase',
              );
            }
          }
          for (final entry in (state['scroll'] as Map).entries) {
            final expected = entry.value as Map, id = scriptIds[entry.key]!;
            final actual = elements.metricsFor(id);
            expect(
              actual?['top'] ?? 0,
              closeTo((expected['top'] as num).toDouble(), .01),
              reason: '${entry.key} phase $phase scrollTop',
            );
            expect(
              actual?['left'] ?? 0,
              closeTo((expected['left'] as num).toDouble(), .01),
            );
          }
          final boundary =
              paintKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = (await tester.runAsync(
            () => boundary.toImage(pixelRatio: dpr),
          ))!;
          try {
            final bytes = (await tester.runAsync(
              () =>
                  image.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
            ))!;
            final point = step['point'] as Map;
            final pixel =
                (((point['y'] as num) * dpr).floor() * image.width +
                    ((point['x'] as num) * dpr).floor()) *
                4;
            expect(
              [
                for (var channel = 0; channel < 4; channel++)
                  bytes.getUint8(pixel + channel),
              ],
              step['rgba'],
              reason: 'phase $phase actual paint',
            );
          } finally {
            image.dispose();
          }
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
