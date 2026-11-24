import 'dart:convert';

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
  for (final scenario in [
    (
      name: 'percentage',
      parent: 'width:350px;height:240px',
      style: 'width:50%;height:50%',
      width: '175px',
      height: '120px',
    ),
    (
      name: 'narrow',
      parent: 'width:200px;height:120px',
      style: '',
      width: '300px',
      height: '150px',
    ),
    (
      name: 'narrow-block',
      parent: 'width:200px;height:120px',
      style: 'display:block',
      width: '300px',
      height: '150px',
    ),
  ]) {
    testWidgets(
      'Canvas native measurement agrees with sizing proof: ${scenario.name}',
      (tester) async {
        const viewport = Size(390, 844);
        final prepared = _prepareDocument({
          'html':
              '<!doctype html><html><head><style>html,body{margin:0;padding:0}</style></head><body><div id="parent" style="${scenario.parent}"><canvas id="child" style="${scenario.style}"></canvas></div></body></html>',
        }, viewport);
        final layout = NativeDocumentLayoutController();
        addTearDown(layout.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: SizedBox(
              width: 390,
              height: 844,
              child: SingleChildScrollView(
                child: NativeHtmlDocument(
                  nodes: [NativeHtmlRaw(prepared.markup)],
                  style: const TextStyle(fontSize: 16),
                  styles: fm.MarkdownStyleSheet(),
                  builders: const {},
                  markdownStyles: false,
                  imageViewport: viewport,
                  authorStylesBuilder: (e) => prepared
                      .stylesByKey[e.attributes['data-pirc-document-style']],
                  layoutController: layout,
                  layoutRevision: 1,
                  layoutKnownIds: prepared.ids,
                  layoutNoBoxIds: prepared.noBoxIds,
                  layoutComputedStyles: prepared.computedStyleSpecs,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final packet = layout.capture(
          revision: 1,
          generation: 1,
          viewport: viewport,
          scrollOffset: Offset.zero,
        )!;
        for (final box in packet['boxes'] as List) {
          if (box['id'] == 'child') {
            expect(box['computedStyle']['width'], scenario.width);
            expect(box['computedStyle']['height'], scenario.height);
            expect(box['canvasSizingProjection'], isNotNull);
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

class _PreparedDocument {
  const _PreparedDocument({
    required this.markup,
    required this.ids,
    required this.stylesByKey,
    required this.noBoxIds,
    required this.computedStyleSpecs,
  });

  final String markup;
  final Set<String> ids;
  final Map<String, Map<String, String>> stylesByKey;
  final Set<String> noBoxIds;
  final Map<String, NativeDocumentComputedStyleSpec> computedStyleSpecs;
}

_PreparedDocument _prepareDocument(
  Map<String, dynamic> capture,
  Size viewport,
) {
  final document = html.parse(capture['html'] as String);
  final root = document.documentElement!;
  final body = document.body!;
  final expectedById = {'parent': {}, 'child': {}};
  final ids = <String>{};
  for (final entry in expectedById.entries) {
    final element = document.getElementById(entry.key);
    if (element == null) continue;
    element.attributes['data-pirc-script-id'] = entry.key;
    ids.add(entry.key);
  }

  final cascade = NativeDocumentStyleEngine(
    stylesheets: [
      for (final style in document.querySelectorAll('style'))
        NativeDocumentStylesheet(
          style.text,
          baseUrl: 'https://replaced-styles.example/',
        ),
    ],
    viewportWidth: viewport.width,
    viewportHeight: viewport.height,
    devicePixelRatio: 1,
    dark: false,
  ).apply(document);
  final stylesByElement = <dom.Element, Map<String, String>>{
    for (final element in document.querySelectorAll('*'))
      element: {
        if (identical(element, body)) 'margin': '8px',
        ...?cascade.stylesByElement[element],
      },
  };
  final computedStyleSpecs = nativeDocumentComputedStyleSpecs(
    document: document,
    stylesByElement: stylesByElement,
    viewportWidth: viewport.width,
    viewportHeight: viewport.height,
    dark: false,
    canvasBitmapAttributesIndependent: true,
    inlineBoxStyleOverridesIndependent: true,
  );
  final noBoxIds = nativeDocumentNoBoxIds(
    document: document,
    knownIds: ids,
    stylesByElement: stylesByElement,
  );

  final stylesByKey = <String, Map<String, String>>{};
  var nextStyleKey = 0;
  for (final element in document.querySelectorAll('*')) {
    final key = (nextStyleKey++).toString();
    element.attributes['data-pirc-document-style'] = key;
    stylesByKey[key] = Map<String, String>.of(stylesByElement[element]!);
    element.attributes.remove('style');
  }

  String attrs(dom.Element element) => element.attributes.entries
      .map(
        (entry) => ' ${entry.key}="${const HtmlEscape().convert(entry.value)}"',
      )
      .join();

  return _PreparedDocument(
    markup:
        '<div${attrs(root)}><div${attrs(body)}>${body.innerHtml}</div></div>',
    ids: ids,
    stylesByKey: stylesByKey,
    noBoxIds: noBoxIds,
    computedStyleSpecs: computedStyleSpecs,
  );
}
