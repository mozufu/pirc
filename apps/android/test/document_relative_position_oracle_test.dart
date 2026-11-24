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
import 'package:pirc_render/src/document_margin_collapse.dart';
import 'package:pirc_render/src/document_offsets.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';

import 'live_test.dart' show theme;

const _fixturePath =
    'tool/parity/fixtures/document-relative-positions-chromium153.json';
const _revision = 1;

final Map<String, dynamic> _fixture =
    jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;

void main() {
  for (final raw in _fixture['cases'] as List) {
    final capture = raw as Map<String, dynamic>;
    final name = capture['name'] as String;
    final viewport = Size(
      (capture['viewportWidth'] as num).toDouble(),
      (capture['viewportHeight'] as num).toDouble(),
    );
    final resizeFrom = capture['resizedFrom'] as Map<String, dynamic>?;
    final initialViewport = resizeFrom == null
        ? viewport
        : Size(
            (resizeFrom['width'] as num).toDouble(),
            (resizeFrom['height'] as num).toDouble(),
          );

    testWidgets(
      'Native document relative positions from Chromium: $name ${viewport.width.toInt()}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = initialViewport;
        addTearDown(tester.view.reset);

        final prepared = _prepareDocument(capture, viewport);
        final ids = (capture['targets'] as List).cast<String>().toSet();
        final layout = NativeDocumentLayoutController();
        final elementScroll = NativeDocumentElementScrollController();
        final windowScroll = ScrollController();
        addTearDown(layout.dispose);
        addTearDown(elementScroll.dispose);
        addTearDown(windowScroll.dispose);

        var generation = 0;
        Future<Map<String, dynamic>> pumpAndCapture(
          Size currentViewport,
          int revision,
        ) async {
          tester.view.physicalSize = currentViewport;
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(Brightness.light),
              home: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: currentViewport.width,
                  height: currentViewport.height,
                  child: SingleChildScrollView(
                    controller: windowScroll,
                    child: NativeHtmlDocument(
                      key: const ValueKey('relative-position-oracle-document'),
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
                      imageViewport: currentViewport,
                      authorStylesBuilder: (element) =>
                          prepared.stylesByKey[element
                              .attributes['data-pirc-document-style']],
                      layoutController: layout,
                      elementScrollController: elementScroll,
                      layoutRevision: revision,
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
          generation++;
          final packet = layout.capture(
            revision: revision,
            generation: generation,
            viewport: currentViewport,
            scrollOffset: Offset(
              0,
              windowScroll.hasClients ? windowScroll.offset : 0,
            ),
            elementScrollMetrics: elementScroll.metricsFor,
            scrollEvents: elementScroll.pendingScrollEvents,
          );
          expect(packet, isNotNull, reason: '$name native layout is ready');
          return packet!;
        }

        try {
          if (resizeFrom != null) {
            final beforeResizePacket = await pumpAndCapture(
              initialViewport,
              _revision,
            );
            _expectGeometry(
              packet: beforeResizePacket,
              capture: capture,
              expected: capture['beforeResizeExpected'] as Map<String, dynamic>,
              noBoxIds: prepared.noBoxIds,
            );
            await pumpAndCapture(viewport, _revision + 1);
          } else {
            await pumpAndCapture(viewport, _revision);
          }

          final states = (capture['states'] as List)
              .cast<Map<String, dynamic>>();
          for (final state in states) {
            final expected = state['expected'] as Map<String, dynamic>;
            final window =
                state['windowScroll'] as Map<String, dynamic>? ??
                const <String, dynamic>{'x': 0, 'y': 0};
            final desiredWindowY = (window['y'] as num).toDouble();
            if (windowScroll.hasClients &&
                (windowScroll.offset - desiredWindowY).abs() > .001) {
              windowScroll.jumpTo(desiredWindowY);
            }

            final scroller = expected['scroller'] as Map<String, dynamic>?;
            final scroll = scroller?['scroll'] as Map<String, dynamic>?;
            if (scroll != null) {
              elementScroll.applyActions([
                <String, dynamic>{
                  'id': 'scroller',
                  'op': 'scrollTo',
                  'left': (scroll['left'] as num).toDouble(),
                  'top': (scroll['top'] as num).toDouble(),
                },
              ]);
            }
            await tester.pumpAndSettle();
            generation++;
            final packet = layout.capture(
              revision: resizeFrom == null ? _revision : _revision + 1,
              generation: generation,
              viewport: viewport,
              scrollOffset: Offset(
                0,
                windowScroll.hasClients ? windowScroll.offset : 0,
              ),
              elementScrollMetrics: elementScroll.metricsFor,
              scrollEvents: elementScroll.pendingScrollEvents,
            );
            expect(
              packet,
              isNotNull,
              reason: '$name ${state['name']} native layout is ready',
            );
            _expectGeometry(
              packet: packet!,
              capture: capture,
              expected: expected,
              noBoxIds: prepared.noBoxIds,
            );
          }

          expect(tester.takeException(), isNull, reason: name);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
        }
      },
    );
  }
}

void _expectGeometry({
  required Map<String, dynamic> packet,
  required Map<String, dynamic> capture,
  required Map<String, dynamic> expected,
  required Set<String> noBoxIds,
}) {
  final name = capture['name'] as String;
  final ids = (capture['targets'] as List).cast<String>().toSet();
  final boxes = {
    for (final box in (packet['boxes'] as List).cast<Map<String, dynamic>>())
      box['id'] as String: box,
  };
  expect(boxes.keys.toSet(), ids, reason: '$name target IDs');

  final differences = <String, dynamic>{};
  void compare(String label, num actual, num browser, [double tolerance = 0]) {
    if ((actual - browser).abs() > tolerance) {
      differences[label] = {'native': actual, 'browser': browser};
    }
  }

  final packetViewport = packet['viewport'] as Map<String, dynamic>;
  final scrollX = (packetViewport['scrollX'] as num).toDouble();
  final scrollY = (packetViewport['scrollY'] as num).toDouble();
  for (final id in ids) {
    final actual = boxes[id]!;
    if (noBoxIds.contains(id)) {
      expect(actual['kind'], 'none', reason: '$name #$id has no CSS box');
      expect(
        actual.containsKey('offset'),
        isFalse,
        reason: '$name #$id has no offset data without a CSS box',
      );
      continue;
    }

    expect(actual['kind'], 'box', reason: '$name #$id');
    final browser = expected[id] as Map<String, dynamic>;
    final rect = browser['rect'] as Map<String, dynamic>;
    compare(
      '#$id rect.x',
      (actual['x'] as num) - scrollX,
      rect['x'] as num,
      .25,
    );
    compare(
      '#$id rect.y',
      (actual['y'] as num) - scrollY,
      rect['y'] as num,
      .25,
    );
    compare(
      '#$id rect.width',
      actual['width'] as num,
      rect['width'] as num,
      .25,
    );
    compare(
      '#$id rect.height',
      actual['height'] as num,
      rect['height'] as num,
      .25,
    );

    final offset = actual['offset'] as Map<String, dynamic>?;
    expect(offset, isNotNull, reason: '$name #$id offset metadata');
    compare(
      '#$id offsetTop',
      offset!['top'] as num,
      browser['offsetTop'] as num,
    );
    compare(
      '#$id offsetLeft',
      offset['left'] as num,
      browser['offsetLeft'] as num,
    );
    if (offset['parentId'] != browser['offsetParentId']) {
      differences['#$id offsetParent'] = {
        'native': offset['parentId'],
        'browser': browser['offsetParentId'],
      };
    }

    final browserScroll = browser['scroll'] as Map<String, dynamic>?;
    if (browserScroll != null) {
      final nativeScroll = actual['scroll'] as Map<String, dynamic>?;
      expect(nativeScroll, isNotNull, reason: '$name #$id scroll metrics');
      compare(
        '#$id scrollLeft',
        nativeScroll!['left'] as num,
        browserScroll['left'] as num,
      );
      compare(
        '#$id scrollTop',
        nativeScroll['top'] as num,
        browserScroll['top'] as num,
      );
      compare(
        '#$id scrollWidth',
        nativeScroll['width'] as num,
        browserScroll['width'] as num,
        .25,
      );
      compare(
        '#$id scrollHeight',
        nativeScroll['height'] as num,
        browserScroll['height'] as num,
        .25,
      );
    }
  }

  expect(
    differences,
    _knownDifferences[name] ?? const <String, dynamic>{},
    reason: '$name native geometry and offsets vs Chromium',
  );
}

const _knownDifferences = <String, Map<String, dynamic>>{};

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

_PreparedDocument _prepareDocument(
  Map<String, dynamic> capture,
  Size viewport,
) {
  final document = html.parse(capture['authoredHTML'] as String);
  final root = document.documentElement!;
  final body = document.body!;
  final targets = (capture['targets'] as List).cast<String>();
  for (final id in targets) {
    final element = document.getElementById(id);
    if (element == null) throw StateError('Missing fixture target #$id');
    element.attributes['data-pirc-script-id'] = id;
  }

  final captureSettings = _fixture['capture'] as Map<String, dynamic>;
  final cascade = NativeDocumentStyleEngine(
    stylesheets: [
      for (final style in document.querySelectorAll('style'))
        NativeDocumentStylesheet(
          style.text,
          baseUrl: 'https://relative-positions.example/',
        ),
    ],
    viewportWidth: viewport.width,
    viewportHeight: viewport.height,
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

  String attrs(dom.Element element) => element.attributes.entries
      .map(
        (entry) => ' ${entry.key}="${const HtmlEscape().convert(entry.value)}"',
      )
      .join();

  return _PreparedDocument(
    markup:
        '<div${attrs(root)}>'
        '<div${attrs(body)}>${body.innerHtml}</div></div>',
    stylesByKey: stylesByKey,
    noBoxIds: noBoxIds,
    offsetSpecs: offsetSpecs,
    documentTopMargins: nativeDocumentCollapsedTopMargins(
      document: document,
      stylesByElement: stylesByElement,
    ),
  );
}
