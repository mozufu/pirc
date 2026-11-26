import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/document_absolute_position.dart';
import 'package:pirc_render_document/src/document_computed_styles.dart';
import 'package:pirc_render/src/document_element_scroll.dart';
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/document_layout_visibility.dart';
import 'package:pirc_render/src/document_offsets.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'live_test.dart' show theme;

void numbers(
  List actual,
  List expected,
  String label, {
  double tolerance = 1 / 32,
}) {
  expect(actual.length, expected.length, reason: label);
  for (var i = 0; i < expected.length; i++) {
    expect(
      actual[i],
      closeTo((expected[i] as num).toDouble(), tolerance),
      reason: '$label[$i]',
    );
  }
}

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../packages/pirc_render/test/fixtures/parity/document-into-view-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final row in fixture['cases'] as List) {
    testWidgets(
      'native reveal geometry ${row['mode']} ${row['viewport']['width']} dpr${row['dpr']} ${row['theme']}',
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
            elements = NativeDocumentElementScrollController();
        addTearDown(layout.dispose);
        addTearDown(scroll.dispose);
        addTearDown(elements.dispose);
        final document = html.parse(row['html'] as String),
            root = document.documentElement!,
            body = document.body!;
        root.attributes['data-pirc-script-id'] = 'root';
        body.attributes['data-pirc-script-id'] = 'body';
        final ids = <String>{'root', 'body'};
        for (final e in document.querySelectorAll('[id]')) {
          ids.add(e.id);
          e.attributes['data-pirc-script-id'] = e.id;
        }
        final cascade = NativeDocumentStyleEngine(
          stylesheets: [
            for (final style in document.querySelectorAll('style'))
              NativeDocumentStylesheet(
                style.text,
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
            e: {...?cascade.stylesByElement[e]},
        };
        final specs = nativeDocumentComputedStyleSpecs(
              document: document,
              stylesByElement: stylesByElement,
              viewportWidth: viewport.width,
              viewportHeight: viewport.height,
            ),
            offsets = nativeDocumentOffsetSpecs(
              document: document,
              stylesByElement: stylesByElement,
            ),
            noBox = nativeDocumentNoBoxIds(
              document: document,
              knownIds: ids,
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
            .map((a) => ' ${a.key}="${const HtmlEscape().convert(a.value)}"')
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
                          scriptDocument: Object(),
                          imageViewport: viewport,
                          authorStylesBuilder: (e) =>
                              styles[e.attributes['data-pirc-document-style']],
                          layoutController: layout,
                          elementScrollController: elements,
                          layoutRevision: 1,
                          layoutKnownIds: ids,
                          layoutNoBoxIds: noBox,
                          layoutOffsetSpecs: offsets,
                          layoutComputedStyles: specs,
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
        Map<String, dynamic> capture() => layout.capture(
          revision: 1,
          generation: 1,
          viewport: viewport,
          scrollOffset: Offset(0, scroll.offset),
          elementScrollMetrics: elements.metricsFor,
          elementScrollRanges: elements.scrollRangeFor,
          elementScrollActivity: elements.isScrollingFor,
          elementScrollSurfaces: elements.scrollGeometrySurfaces,
        )!;
        final packet = capture(),
            boxes = {for (final b in packet['boxes'] as List) b['id']: b};
        final measurements = row['measurements'] as Map;
        for (final name in ['root', 'outer', 'inner', 'target']) {
          final reference = measurements[name];
          if (reference == null) continue;
          final box = boxes[name] as Map;
          if (reference['style']['display'] == 'none') {
            expect(box['kind'], 'none');
            continue;
          }
          for (final entry in (reference['style'] as Map).entries) {
            if (['display', 'position'].contains(entry.key)) continue;
            expect(
              box['computedStyle'][entry.key],
              entry.value,
              reason: '$name ${entry.key}',
            );
          }
          numbers(
            [box['x'], box['y'], box['width'], box['height']],
            reference['rect'] as List,
            '$name bbox',
          );
        }
        if (measurements['target'] != null && row['mode'] != 'hidden') {
          final proof = boxes['target']['scrollReveal'] as Map?;
          expect(proof, isNotNull);
          expect(proof!['viewport'], isTrue);
          final ports = proof['ports'] as List;
          expect(ports.map((p) => p['id']), ['inner', 'outer']);
          for (final port in ports) {
            final m = measurements[port['id']];
            numbers(
              port['rect'] as List,
              m['targetRect'] as List,
              '${port['id']} relative rect',
            );
            numbers(
              port['origin'] as List,
              m['origin'] as List,
              '${port['id']} origin',
            );
            numbers(
              port['axes'] as List,
              m['axes'] as List,
              '${port['id']} axes',
              tolerance: 0.0001,
            );
            expect([port['width'], port['height']], [m['width'], m['height']]);
          }
        }
        // Execute independently frozen browser destinations to verify native scroll
        // ownership, clipping, and final target geometry; JS planner is tested apart.
        if (![
          'contract',
          'append-await',
          'replacement',
        ].contains(row['mode'])) {
          final result = row['result']['settled'] as Map,
              positions = result['positions'] as Map;
          scroll.jumpTo((positions['root']['top'] as num).toDouble());
          elements.applyActions([
            for (final id in ['inner', 'outer'])
              {
                'id': id,
                'op': 'to',
                'left': positions[id]['left'],
                'top': positions[id]['top'],
                'behavior': 'instant',
              },
          ]);
          await tester.pumpAndSettle();
          final after = {
            for (final b in capture()['boxes'] as List) b['id']: b,
          };
          if (row['mode'] != 'hidden') {
            final b = after['target'];
            numbers(
              [
                b['x'],
                (b['y'] as num) - scroll.offset,
                b['width'],
                b['height'],
              ],
              result['rect'] as List,
              'settled target',
            );
          }
          for (final id in ['outer', 'inner']) {
            final m = elements.metricsFor(id)!;
            expect(m['left'], positions[id]['left']);
            expect(m['top'], positions[id]['top']);
            expect(elements.isScrollingFor(id), isFalse);
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
