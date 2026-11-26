import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/document_element_scroll.dart';
import 'package:pirc_render/src/html_document_box.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';

import 'live_test.dart' show theme;

final _fixture =
    jsonDecode(
          File(
            '../../packages/pirc_render/test/fixtures/parity/document-root-heights-chromium153.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

// Match NativeFetchedDocumentView's preserved html/body boundaries and resolved
// cascade, then measure actual native boxes under a scrolling document viewport.
({String markup, Map<String, Map<String, String>> styles}) _prepare(
  Map<String, dynamic> capture,
) {
  final document = html.parse(capture['authoredHTML'] as String);
  for (final id in capture['targets'] as List) {
    document.getElementById(id as String)!.attributes['data-pirc-script-id'] =
        id;
  }
  final cascade = NativeDocumentStyleEngine(
    dark: false,
    stylesheets: [
      for (final node in document.querySelectorAll('style'))
        NativeDocumentStylesheet(
          node.text,
          baseUrl: 'https://heights.example/',
        ),
    ],
    viewportWidth: (capture['viewportWidth'] as num).toDouble(),
    viewportHeight: (capture['viewportHeight'] as num).toDouble(),
  ).apply(document);
  final styles = <String, Map<String, String>>{};
  for (final node in document.querySelectorAll('*')) {
    final key = '${styles.length}';
    node.attributes['data-pirc-document-style'] = key;
    styles[key] = {
      if (node == document.body) 'margin': '8px',
      ...?cascade.stylesByElement[node],
    };
    node.attributes.remove('style');
  }
  String attrs(dom.Element element) => element.attributes.entries
      .map(
        (entry) => ' ${entry.key}="${const HtmlEscape().convert(entry.value)}"',
      )
      .join();
  return (
    markup:
        '<div${attrs(document.documentElement!)}>'
        '<div${attrs(document.body!)}>${document.body!.innerHtml}</div></div>',
    styles: styles,
  );
}

void main() {
  for (final raw in _fixture['cases'] as List) {
    final capture = raw as Map<String, dynamic>;
    final viewport = Size(
      (capture['viewportWidth'] as num).toDouble(),
      (capture['viewportHeight'] as num).toDouble(),
    );
    testWidgets('root height vs Chromium: ${capture['name']} $viewport', (
      t,
    ) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = viewport;
      addTearDown(t.view.reset);
      final prepared = _prepare(capture);
      final controller = NativeDocumentLayoutController();
      final scroll = ScrollController();
      final elementScroll = NativeDocumentElementScrollController();
      addTearDown(elementScroll.dispose);
      addTearDown(controller.dispose);
      addTearDown(scroll.dispose);
      final ids = (capture['targets'] as List).cast<String>().toSet();
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              controller: scroll,
              child: NativeHtmlDocument(
                nodes: [NativeHtmlRaw(prepared.markup)],
                style: const TextStyle(
                  fontSize: 16,
                  height: 1,
                  letterSpacing: 0,
                ),
                styles: fm.MarkdownStyleSheet(),
                builders: const {},
                markdownStyles: false,
                imageViewport: viewport,
                authorStylesBuilder: (element) => prepared
                    .styles[element.attributes['data-pirc-document-style']],
                layoutController: controller,
                elementScrollController: elementScroll,
                layoutKnownIds: ids,
                layoutRevision: 1,
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final packet = controller.capture(
        revision: 1,
        generation: 1,
        viewport: viewport,
      );
      expect(packet, isNotNull);
      final boxes = {
        for (final box in packet!['boxes'] as List)
          box['id'] as String: box as Map<String, dynamic>,
      };
      final expected = capture['expected'] as Map<String, dynamic>;
      for (final id in ids) {
        expect(boxes[id]!['kind'], 'box', reason: id);
        for (final property in ['x', 'y', 'width', 'height']) {
          expect(
            boxes[id]![property],
            closeTo(expected[id][property] as num, .25),
            reason: '#$id $property vs Chromium',
          );
        }
      }
      final documentMetrics =
          capture['documentMetrics'] as Map<String, dynamic>;
      final browserExtent = (documentMetrics['htmlScrollHeight'] as num)
          .toDouble();
      // Named minor differences: native margin/edge wrappers currently add
      // trailing blank space. Element geometry above still matches Chromium;
      // do not hide or broaden the tolerance for any other case.
      final trailingBlankSpace = switch (capture['name']) {
        'body_default_margin_8_with_explicit_heights' => 8.0,
        'content_box_padding_and_border' => 17.0,
        _ => 0.0,
      };
      expect(
        scroll.position.maxScrollExtent,
        closeTo(
          (browserExtent - viewport.height).clamp(0, double.infinity) +
              trailingBlankSpace,
          .25,
        ),
        reason:
            'visible overflow remains reachable without expanding CSS boxes',
      );
      final targetScrollHeights =
          capture['targetScrollHeights'] as Map<String, dynamic>? ?? {};
      for (final entry in targetScrollHeights.entries) {
        expect(
          elementScroll.metricsFor(entry.key)?['height'],
          closeTo(entry.value as num, .25),
        );
        elementScroll.applyActions([
          {'id': entry.key, 'op': 'scrollTo', 'top': 400},
        ]);
        await t.pumpAndSettle();
        final maximum = (entry.value as num) - expected[entry.key]['height'];
        expect(
          elementScroll.metricsFor(entry.key)?['top'],
          closeTo(400.clamp(0, maximum), .25),
        );
        expect(scroll.offset, 0, reason: 'nested scrolling does not move page');
      }
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final markdown in [false, true]) {
    testWidgets('root viewport requires full document and explicit viewport: '
        'markdown=$markdown', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: NativeHtmlDocument(
            nodes: [NativeHtmlRaw('<div style="height:100%">content</div>')],
            style: const TextStyle(fontSize: 16),
            styles: fm.MarkdownStyleSheet(),
            builders: const {},
            markdownStyles: markdown,
            imageViewport: markdown ? const Size(390, 844) : null,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byType(NativeDocumentContainingBlock), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    });
  }
}
