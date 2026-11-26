import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:pirc_render_document/src/document_computed_styles.dart';
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/document_layout_visibility.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'live_test.dart' show theme;

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../packages/pirc_render/test/fixtures/parity/document-resize-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  testWidgets(
    'resize payload survives unavailable computed declarations and withholds unsupported boxes',
    (tester) async {
      final controller = NativeDocumentLayoutController();
      addTearDown(controller.dispose);
      NativeDocumentComputedStyleSpec spec({bool supported = true}) =>
          NativeDocumentComputedStyleSpec(
            values: {
              'display': 'block',
              for (final side in ['left', 'right', 'top', 'bottom']) ...{
                'padding-$side': '2px',
                'border-$side-width': '1px',
              },
            },
            lengths: const {},
            fontSize: 16,
            rootFontSize: 16,
            available: false,
            resizeSupported: supported,
          );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: NativeDocumentLayoutRoot(
              controller: controller,
              revision: 1,
              knownIds: const {'normal', 'unsupported'},
              computedStyles: {
                'normal': spec(),
                'unsupported': spec(supported: false),
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final id in ['normal', 'unsupported'])
                    NativeDocumentLayoutElement(
                      controller: controller,
                      revision: 1,
                      id: id,
                      child: const SizedBox(width: 100, height: 40),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final packet = controller.capture(
        revision: 1,
        generation: 1,
        viewport: const Size(400, 300),
      )!;
      final boxes = {for (final box in packet['boxes'] as List) box['id']: box};
      expect(boxes['normal'], isNot(contains('computedStyle')));
      expect(boxes['normal']['resize'], {
        'kind': 'box',
        'contentRect': {'x': 2.0, 'y': 2.0, 'width': 94.0, 'height': 34.0},
        'borderBoxSize': {'inlineSize': 100.0, 'blockSize': 40.0},
      });
      expect(boxes['unsupported'], isNot(contains('resize')));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('vertical writing and SVG observation data are withheld', () {
    final doc = html.parse(
      '<div id="normal"></div><div id="vertical"><span id="child"></span></div><svg id="vector"></svg>',
    );
    for (final e in doc.querySelectorAll('[id]')) {
      e.attributes['data-pirc-script-id'] = e.id;
    }
    final specs = nativeDocumentComputedStyleSpecs(
      document: doc,
      stylesByElement: {
        doc.getElementById('vertical')!: {'writing-mode': 'vertical-rl'},
      },
      viewportWidth: 390,
      viewportHeight: 844,
    );
    expect(specs['normal']!.resizeSupported, isTrue);
    expect(specs['vertical']!.resizeSupported, isFalse);
    expect(specs['child']!.resizeSupported, isFalse);
    expect(specs['vector']!.resizeSupported, isFalse);
  });

  for (final record in fixture['records'] as List) {
    final viewport = Size(
      (record['viewport']['width'] as num).toDouble(),
      (record['viewport']['height'] as num).toDouble(),
    );
    for (final stage in record['stages'] as List) {
      testWidgets(
        'Native ResizeObserver boxes match Chromium ${viewport.width} ${stage['name']}',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = viewport;
          addTearDown(tester.view.reset);
          final document = html.parse(stage['html'] as String);
          final ids = <String>{'target', 'canvas', 'inline'};
          for (final id in ids) {
            document.getElementById(id)!.attributes['data-pirc-script-id'] = id;
          }
          final cascade = NativeDocumentStyleEngine(
            dark: false,
            stylesheets: [
              for (final style in document.querySelectorAll('style'))
                NativeDocumentStylesheet(
                  style.text,
                  baseUrl: 'https://resize.example/',
                ),
            ],
            viewportWidth: viewport.width,
            viewportHeight: viewport.height,
          ).apply(document);
          final styles = <dom.Element, Map<String, String>>{
            for (final element in document.querySelectorAll('*'))
              element: {...?cascade.stylesByElement[element]},
          };
          final specs = nativeDocumentComputedStyleSpecs(
            document: document,
            stylesByElement: styles,
            viewportWidth: viewport.width,
            viewportHeight: viewport.height,
          );
          final noBox = nativeDocumentNoBoxIds(
            document: document,
            knownIds: ids,
            stylesByElement: styles,
          );
          final byKey = <String, Map<String, String>>{};
          var next = 0;
          for (final element in document.querySelectorAll('*')) {
            final key = '${next++}';
            element.attributes['data-pirc-document-style'] = key;
            byKey[key] = styles[element]!;
            element.attributes.remove('style');
          }
          String attrs(dom.Element e) => e.attributes.entries
              .map((a) => ' ${a.key}="${const HtmlEscape().convert(a.value)}"')
              .join();
          final markup =
              '<div${attrs(document.documentElement!)}><div${attrs(document.body!)}>${document.body!.innerHtml}</div></div>';
          final controller = NativeDocumentLayoutController();
          addTearDown(controller.dispose);
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(Brightness.light),
              home: Align(
                alignment: Alignment.topLeft,
                child: SingleChildScrollView(
                  child: NativeHtmlDocument(
                    nodes: [NativeHtmlRaw(markup)],
                    style: const TextStyle(
                      inherit: false,
                      fontSize: 16,
                      height: kTextHeightNone,
                      color: Colors.black,
                    ),
                    styles: fm.MarkdownStyleSheet(),
                    builders: const {},
                    markdownStyles: false,
                    imageViewport: viewport,
                    authorStylesBuilder: (e) =>
                        byKey[e.attributes['data-pirc-document-style']],
                    layoutController: controller,
                    layoutRevision: 1,
                    layoutKnownIds: ids,
                    layoutNoBoxIds: noBox,
                    layoutComputedStyles: specs,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final packet = controller.capture(
            revision: 1,
            generation: 1,
            viewport: viewport,
          )!;
          final boxes = {
            for (final box in packet['boxes'] as List) box['id']: box,
          };
          for (final expected in stage['boxes'] as List) {
            final actual = boxes[expected['id']]['resize'];
            expect(
              actual,
              isNotNull,
              reason: '${expected['id']} provides measured resize data',
            );
            _expectMetrics(
              actual,
              expected['resize'],
              expected['id'] as String,
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}

void _expectMetrics(Object? actual, Object? expected, String field) {
  if (expected is Map) {
    expect(actual, isA<Map>(), reason: field);
    final values = actual! as Map;
    expect(values.keys.toSet(), expected.keys.toSet(), reason: field);
    for (final key in expected.keys) {
      _expectMetrics(values[key], expected[key], '$field.$key');
    }
  } else if (expected is num) {
    expect(actual, closeTo(expected, .02), reason: field);
  } else {
    expect(actual, expected, reason: field);
  }
}
