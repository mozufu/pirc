import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/document_layout_visibility.dart';
import 'package:pirc_render/src/document_margin_collapse.dart';
import 'package:pirc_render/src/document_offsets.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';

import 'live_test.dart' show theme;

const _fixturePath =
    '../../packages/pirc_render/test/fixtures/parity/document-margins-chromium153.json';
const _revision = 1;

final Map<String, dynamic> _fixture =
    jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;

void main() {
  for (final raw in _fixture['cases'] as List) {
    final capture = raw as Map<String, dynamic>;
    final name = capture['name'] as String;
    final width = (capture['viewportWidth'] as num).toDouble();
    final height = (capture['viewportHeight'] as num).toDouble();
    final viewport = Size(width, height);

    testWidgets(
      'Native document top-margin collapse from Chromium: $name ${width.toInt()}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = viewport;
        addTearDown(tester.view.reset);

        final prepared = _prepareDocument(capture);
        final ids = (capture['targets'] as List).cast<String>().toSet();
        final layout = NativeDocumentLayoutController();
        final windowScroll = ScrollController();
        addTearDown(layout.dispose);
        addTearDown(windowScroll.dispose);

        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(Brightness.light),
              home: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  height: height,
                  child: SingleChildScrollView(
                    controller: windowScroll,
                    child: NativeHtmlDocument(
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
                      imageViewport: viewport,
                      authorStylesBuilder: (element) =>
                          prepared.stylesByKey[element
                              .attributes['data-pirc-document-style']],
                      layoutController: layout,
                      layoutRevision: _revision,
                      layoutKnownIds: ids,
                      layoutNoBoxIds: prepared.noBoxIds,
                      layoutOffsetSpecs: prepared.offsetSpecs,
                      documentTopMargins: prepared.documentTopMargins,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final packet = layout.capture(
            revision: _revision,
            generation: 1,
            viewport: viewport,
            scrollOffset: Offset(0, windowScroll.offset),
          );
          expect(packet, isNotNull, reason: '$name native layout is ready');
          final boxes = {
            for (final box
                in (packet!['boxes'] as List).cast<Map<String, dynamic>>())
              box['id'] as String: box,
          };
          expect(boxes.keys.toSet(), ids, reason: '$name target IDs');
          final expected = capture['expected'] as Map<String, dynamic>;
          final differences = <String, dynamic>{};
          final unsupportedIds = <String>{};
          void compare(
            String label,
            num actual,
            num browser, [
            double tolerance = 0,
          ]) {
            if ((actual - browser).abs() > tolerance) {
              differences[label] = {'native': actual, 'browser': browser};
            }
          }

          for (final id in ids) {
            final actual = boxes[id]!;
            if (actual['kind'] == 'unsupported') {
              unsupportedIds.add(id);
              continue;
            }
            if (prepared.noBoxIds.contains(id)) {
              expect(actual['kind'], 'none', reason: '$name #$id');
              expect(
                actual.containsKey('offset'),
                isFalse,
                reason: '$name #$id has no CSS box or offset data',
              );
              continue;
            }

            expect(actual['kind'], 'box', reason: '$name #$id');
            final browser = expected[id] as Map<String, dynamic>;
            final rect = browser['rect'] as Map<String, dynamic>;
            for (final property in ['x', 'y', 'width', 'height']) {
              compare(
                '#$id border-box $property',
                actual[property] as num,
                rect[property] as num,
                .25,
              );
            }

            final offset = actual['offset'] as Map<String, dynamic>?;
            expect(offset, isNotNull, reason: '$name #$id offset data');
            final actualOffset = offset!;
            compare(
              '#$id offsetTop',
              actualOffset['top'] as num,
              browser['offsetTop'] as num,
            );
            compare(
              '#$id offsetLeft',
              actualOffset['left'] as num,
              browser['offsetLeft'] as num,
            );
            if (actualOffset['parentId'] != browser['offsetParentId']) {
              differences['#$id offsetParent'] = {
                'native': actualOffset['parentId'],
                'browser': browser['offsetParentId'],
              };
            }
          }

          expect(
            differences,
            _knownDifferences[name] ?? const <String, dynamic>{},
            reason: '$name native layout vs Chromium',
          );
          expect(
            unsupportedIds,
            _knownUnsupportedIds[name] ?? const <String>{},
            reason: '$name unsupported native boxes',
          );
          expect(tester.takeException(), isNull, reason: name);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
        }
      },
    );
  }
}

const _knownDifferences = <String, Map<String, dynamic>>{};
const _knownUnsupportedIds = <String, Set<String>>{};

class _PreparedDocument {
  const _PreparedDocument({
    required this.markup,
    required this.stylesByKey,
    required this.noBoxIds,
    required this.offsetSpecs,
    required this.documentTopMargins,
  });

  final String markup;
  final Map<String, Map<String, String>> stylesByKey;
  final Set<String> noBoxIds;
  final Map<String, NativeDocumentOffsetSpec> offsetSpecs;
  final Map<String, double> documentTopMargins;
}

_PreparedDocument _prepareDocument(Map<String, dynamic> capture) {
  final document = html.parse(capture['authoredHTML'] as String);
  final root = document.documentElement!;
  final body = document.body!;
  final targets = (capture['targets'] as List).cast<String>();
  for (final id in targets) {
    final element = document.getElementById(id);
    if (element == null) throw StateError('Missing fixture target #$id');
    element.attributes['data-pirc-script-id'] = id;
  }

  final width = (capture['viewportWidth'] as num).toDouble();
  final height = (capture['viewportHeight'] as num).toDouble();
  final cascade = NativeDocumentStyleEngine(
    stylesheets: [
      for (final style in document.querySelectorAll('style'))
        NativeDocumentStylesheet(
          style.text,
          baseUrl: 'https://margins.example/',
        ),
    ],
    viewportWidth: width,
    viewportHeight: height,
    dark: false,
  ).apply(document);

  final stylesByElement = <dom.Element, Map<String, String>>{
    for (final element in document.querySelectorAll('*'))
      element: {
        if (identical(element, body)) 'margin': '8px',
        ...?cascade.stylesByElement[element],
      },
  };
  final offsetSpecs = nativeDocumentOffsetSpecs(
    document: document,
    stylesByElement: stylesByElement,
  );
  final noBoxIds = nativeDocumentNoBoxIds(
    document: document,
    knownIds: targets,
    stylesByElement: stylesByElement,
  );

  final stylesByKey = <String, Map<String, String>>{};
  var nextStyleKey = 0;
  for (final element in document.querySelectorAll('*')) {
    final key = '${nextStyleKey++}';
    element.attributes['data-pirc-document-style'] = key;
    stylesByKey[key] = Map<String, String>.of(stylesByElement[element]!);
    element.attributes.remove('style');
  }
  final documentTopMargins = nativeDocumentCollapsedTopMargins(
    document: document,
    stylesByElement: stylesByElement,
  );

  return _PreparedDocument(
    markup:
        '<div${_attributes(root)}>'
        '<div${_attributes(body)}>${body.innerHtml}</div></div>',
    stylesByKey: stylesByKey,
    noBoxIds: noBoxIds,
    offsetSpecs: offsetSpecs,
    documentTopMargins: documentTopMargins,
  );
}

String _attributes(dom.Element element) => element.attributes.entries
    .map(
      (entry) => ' ${entry.key}="${const HtmlEscape().convert(entry.value)}"',
    )
    .join();
