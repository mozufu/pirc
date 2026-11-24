import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/document_computed_styles.dart';
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/document_layout_visibility.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'live_test.dart' show theme;

void main() {
  test(
    'unproved font and reference-box bases do not fabricate transform metadata',
    () {
      for (final unsupported in [
        <String, String>{'font-size': 'calc(2rem + 1px)'},
        <String, String>{'transform-box': 'content-box'},
      ]) {
        final doc = html.parse('<div data-pirc-script-id="target"></div>');
        final target = doc.querySelector('[data-pirc-script-id]')!;
        final spec = nativeDocumentComputedStyleSpecs(
          document: doc,
          stylesByElement: {
            target: {'transform': 'translate(1em, 10%)', ...unsupported},
          },
          viewportWidth: 390,
          viewportHeight: 844,
        )['target']!;
        expect(spec.transform, isNull);
        expect(spec.transformOrigin, isNull);
      }
    },
  );
  testWidgets(
    'unmeasured transform boxes withhold dimensions and percentage origins',
    (tester) async {
      final controller = NativeDocumentLayoutController();
      await tester.pumpWidget(
        NativeDocumentLayoutRoot(
          controller: controller,
          revision: 1,
          knownIds: const {'missing'},
          computedStyles: {
            'missing': NativeDocumentComputedStyleSpec(
              values: const {'display': 'block'},
              lengths: const {},
              fontSize: 16,
              rootFontSize: 16,
              transform: 'scale(2)',
              transformOrigin: '50% 50%',
            ),
          },
          child: const SizedBox(width: 80, height: 40),
        ),
      );
      final box =
          (controller.capture(
                        revision: 1,
                        generation: 1,
                        viewport: const Size(390, 844),
                      )!['boxes']
                      as List)
                  .single
              as Map;
      expect(box['kind'], 'unsupported');
      expect(box['computedStyle'], isNot(contains('transform')));
      expect(box['computedStyle'], isNot(contains('transform-origin')));
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  final fixture =
      jsonDecode(
            File(
              'tool/parity/fixtures/document-transform-style-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final row in fixture['cases'] as List) {
    final viewport = Size(
      (row['viewport']['width'] as num).toDouble(),
      (row['viewport']['height'] as num).toDouble(),
    );
    final dpr = (row['dpr'] as num).toDouble();
    testWidgets(
      'native transform style ${row['mode']} ${viewport.width.toInt()} dpr${dpr.toInt()} ${row['theme']}',
      (tester) async {
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = viewport * dpr;
        addTearDown(tester.view.reset);
        final layout = NativeDocumentLayoutController();
        addTearDown(layout.dispose);
        for (final stage in ['before', 'after']) {
          final document = html.parse(row['html'] as String),
              root = document.documentElement!,
              body = document.body!,
              target = document.getElementById('target')!;
          target.attributes['data-pirc-script-id'] = 'target';
          if (stage == 'after') target.classes.add('changed');
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
          final specs = nativeDocumentComputedStyleSpecs(
            document: document,
            stylesByElement: cascade.stylesByElement,
            viewportWidth: viewport.width,
            viewportHeight: viewport.height,
            dark: row['theme'] == 'dark',
          );
          final noBox = nativeDocumentNoBoxIds(
            document: document,
            knownIds: const {'target'},
            stylesByElement: cascade.stylesByElement,
          );
          final styles = <String, Map<String, String>>{};
          var next = 0;
          for (final element in document.querySelectorAll('*')) {
            final key = '${next++}';
            element.attributes['data-pirc-document-style'] = key;
            styles[key] = cascade.stylesByElement[element] ?? {};
            element.attributes.remove('style');
          }
          String attrs(element) => element.attributes.entries
              .map(
                (entry) =>
                    ' ${entry.key}="${const HtmlEscape().convert(entry.value)}"',
              )
              .join();
          final markup =
              '<div${attrs(root)}><div${attrs(body)}>${body.innerHtml}</div></div>';
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(
                row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
              ),
              home: SingleChildScrollView(
                child: NativeHtmlDocument(
                  nodes: [NativeHtmlRaw(markup)],
                  style: const TextStyle(
                    inherit: false,
                    fontFamily: 'serif',
                    fontSize: 16,
                    height: kTextHeightNone,
                    color: Colors.black,
                    letterSpacing: 0,
                  ),
                  styles: fm.MarkdownStyleSheet(),
                  builders: const {},
                  markdownStyles: false,
                  imageViewport: viewport,
                  authorStylesBuilder: (element) =>
                      styles[element.attributes['data-pirc-document-style']],
                  layoutController: layout,
                  layoutRevision: stage == 'before' ? 1 : 2,
                  layoutKnownIds: const {'target'},
                  layoutNoBoxIds: noBox,
                  layoutComputedStyles: specs,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final packet = layout.capture(
            revision: stage == 'before' ? 1 : 2,
            generation: stage == 'before' ? 1 : 2,
            viewport: viewport,
          );
          expect(packet, isNotNull);
          final box = (packet!['boxes'] as List).single as Map;
          final actual = box['computedStyle'] as Map;
          final expected = row['result'][stage] as Map;
          for (final property in ['transform', 'width', 'height']) {
            expect(
              actual[property],
              expected[property],
              reason: '$stage $property',
            );
          }
          expect(
            actual['transform-origin'],
            expected['origin'],
            reason: '$stage origin',
          );
          final expectedRect = expected['rect'] as List;
          if (box['kind'] == 'none') {
            expect(expectedRect, [0, 0, 0, 0]);
          } else {
            for (final pair in [
              (0, 'x'),
              (1, 'y'),
              (2, 'width'),
              (3, 'height'),
            ]) {
              expect(
                box[pair.$2],
                closeTo((expectedRect[pair.$1] as num).toDouble(), .001),
                reason: '$stage ${pair.$2}',
              );
            }
            expect([
              box['offsetWidth'],
              box['offsetHeight'],
            ], expected['offset']);
          }
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
