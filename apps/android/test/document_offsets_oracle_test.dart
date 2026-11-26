import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/document_element_scroll.dart';
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/document_layout_visibility.dart';
import 'package:pirc_render/src/document_offsets.dart';
import 'package:pirc_render/src/document_margin_collapse.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';

import 'live_test.dart' show theme;

const _fixturePath =
    '../../packages/pirc_render/test/fixtures/parity/document-offsets-chromium153.json';
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
      'Native document offsets from Chromium: $name ${width.toInt()}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = viewport;
        addTearDown(tester.view.reset);

        final prepared = _prepareDocument(capture);
        final ids = (capture['targets'] as List).cast<String>().toSet();
        final layout = NativeDocumentLayoutController();
        final elementScroll = NativeDocumentElementScrollController();
        final windowScroll = ScrollController();
        addTearDown(layout.dispose);
        addTearDown(elementScroll.dispose);
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
                      elementScrollController: elementScroll,
                      layoutRevision: _revision,
                      layoutKnownIds: ids,
                      layoutNoBoxIds: prepared.noBoxIds,
                      layoutOffsetSpecs: prepared.offsetSpecs,
                      documentTopMargins: prepared.topMargins,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final differences = <String, dynamic>{};
          void compare(
            String label,
            num actual,
            num expected, [
            double tolerance = 0,
          ]) {
            if ((actual - expected).abs() > tolerance) {
              differences[label] = {'native': actual, 'browser': expected};
            }
          }

          final states = _statesFor(capture);
          for (var index = 0; index < states.length; index++) {
            final state = states[index];
            final expectedTargets = state['expected'] as Map<String, dynamic>;
            final expectedWindowScroll =
                state['windowScroll'] as Map<String, dynamic>? ??
                const <String, dynamic>{'x': 0, 'y': 0};
            final expectedWindowY = (expectedWindowScroll['y'] as num)
                .toDouble();
            if ((windowScroll.offset - expectedWindowY).abs() > .001) {
              windowScroll.jumpTo(expectedWindowY);
            }

            final scroller =
                expectedTargets['scroller'] as Map<String, dynamic>?;
            if (scroller != null) {
              elementScroll.applyActions([
                <String, dynamic>{
                  'id': 'scroller',
                  'op': 'scrollTo',
                  'left': (scroller['scrollLeft'] as num).toDouble(),
                  'top': (scroller['scrollTop'] as num).toDouble(),
                },
              ]);
            }
            if (index > 0) {
              await tester.pump();
              await tester.pump();
            }

            final packet = layout.capture(
              revision: _revision,
              generation: index + 1,
              viewport: viewport,
              scrollOffset: Offset(0, windowScroll.offset),
              elementScrollMetrics: elementScroll.metricsFor,
              scrollEvents: elementScroll.pendingScrollEvents,
            );
            expect(
              packet,
              isNotNull,
              reason: '$name ${state['name']} native layout is ready',
            );
            final boxes = {
              for (final box
                  in (packet!['boxes'] as List).cast<Map<String, dynamic>>())
                box['id'] as String: box,
            };
            expect(boxes.keys.toSet(), ids, reason: '$name target IDs');
            final packetViewport = packet['viewport'] as Map<String, dynamic>;
            final scrollX = (packetViewport['scrollX'] as num).toDouble();
            final scrollY = (packetViewport['scrollY'] as num).toDouble();
            expect(scrollX, (expectedWindowScroll['x'] as num).toDouble());
            expect(scrollY, expectedWindowY);

            for (final id in ids) {
              final actual = boxes[id]!;
              if (prepared.noBoxIds.contains(id)) {
                expect(
                  actual['kind'],
                  'none',
                  reason: '$name #$id has no CSS box',
                );
                expect(
                  actual.containsKey('offset'),
                  isFalse,
                  reason: '$name #$id has no measured offset data',
                );
                continue;
              }

              expect(actual['kind'], 'box', reason: '$name #$id');
              final expected = expectedTargets[id] as Map<String, dynamic>;
              final offset = actual['offset'] as Map<String, dynamic>?;
              expect(
                offset,
                isNotNull,
                reason: '$name #$id native offset data',
              );
              compare(
                '${state['name']} #$id offsetTop',
                offset!['top'] as num,
                expected['offsetTop'] as num,
              );
              compare(
                '${state['name']} #$id offsetLeft',
                offset['left'] as num,
                expected['offsetLeft'] as num,
              );
              expect(
                offset['parentId'],
                expected['offsetParentId'],
                reason: '$name ${state['name']} #$id offsetParent',
              );

              if (id == 'scroller') {
                final scroll = actual['scroll'] as Map<String, dynamic>?;
                expect(
                  scroll,
                  isNotNull,
                  reason: '$name ${state['name']} #scroller metrics',
                );
                expect(scroll!['left'], expected['scrollLeft']);
                expect(scroll['top'], expected['scrollTop']);
              }

              final rect = expected['rect'] as Map<String, dynamic>;
              compare(
                '${state['name']} #$id rect.x',
                (actual['x'] as num) - scrollX,
                rect['x'] as num,
                .25,
              );
              compare(
                '${state['name']} #$id rect.y',
                (actual['y'] as num) - scrollY,
                rect['y'] as num,
                .25,
              );
              if (const {
                'row_flex_shrink_unequal_bases_signed_left_margins',
                'column_flex_grow_and_shrink_positive_block_margins',
                'row_flex_align_center_positive_cross_axis_margins',
              }.contains(name)) {
                for (final axis in ['width', 'height']) {
                  compare(
                    '${state['name']} #$id rect.$axis',
                    actual[axis] as num,
                    rect[axis] as num,
                    .25,
                  );
                }
              }
            }
          }

          // Compare actual native border origins against the unchanged browser
          // oracle. The previously named top-margin gaps now match as well.
          expect(differences, isEmpty, reason: name);
          expect(tester.takeException(), isNull, reason: name);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
        }
      },
    );
  }
}

class _PreparedDocument {
  const _PreparedDocument({
    required this.markup,
    required this.stylesByKey,
    required this.noBoxIds,
    required this.offsetSpecs,
    required this.topMargins,
  });

  final String markup;
  final Map<String, Map<String, String>> stylesByKey;
  final Set<String> noBoxIds;
  final Map<String, NativeDocumentOffsetSpec> offsetSpecs;
  final Map<String, double> topMargins;
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

  // The browser keeps a reference to this target, then removes it before
  // measuring. The native snapshot represents that absence as a no-box ID.
  if (capture['name'] == 'detached_element') {
    document.getElementById('detached')?.remove();
  }

  final width = (capture['viewportWidth'] as num).toDouble();
  final height = (capture['viewportHeight'] as num).toDouble();
  final captureSettings = _fixture['capture'] as Map<String, dynamic>;
  final stylesheets = [
    for (final style in document.querySelectorAll('style'))
      NativeDocumentStylesheet(style.text, baseUrl: 'https://offset.example/'),
  ];
  final cascade = NativeDocumentStyleEngine(
    stylesheets: stylesheets,
    viewportWidth: width,
    viewportHeight: height,
    devicePixelRatio: (captureSettings['deviceScaleFactor'] as num).toDouble(),
    dark: false,
  ).apply(document);

  final stylesByElement = <dom.Element, Map<String, String>>{
    for (final element in document.querySelectorAll('*'))
      element: {
        if (identical(element, body)) 'margin': '8px',
        ...?cascade.stylesByElement[element],
      },
  };

  // Resolve parent IDs and coordinate origins from the original DOM and its
  // winning cascade before html/body become native wrapper elements.
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

  return _PreparedDocument(
    markup:
        '<div${_attributes(root)}>'
        '<div${_attributes(body)}>${body.innerHtml}</div></div>',
    stylesByKey: stylesByKey,
    noBoxIds: noBoxIds,
    offsetSpecs: offsetSpecs,
    topMargins: nativeDocumentCollapsedTopMargins(
      document: document,
      stylesByElement: stylesByElement,
    ),
  );
}

List<Map<String, dynamic>> _statesFor(Map<String, dynamic> capture) {
  final states = capture['states'] as List<dynamic>?;
  if (states != null) return states.cast<Map<String, dynamic>>();
  return [
    <String, dynamic>{
      'name': 'initial',
      'windowScroll': capture['windowScroll'] ?? const {'x': 0, 'y': 0},
      'expected': capture['expected'],
    },
  ];
}

String _attributes(dom.Element element) => element.attributes.entries
    .map(
      (entry) => ' ${entry.key}="${const HtmlEscape().convert(entry.value)}"',
    )
    .join();
