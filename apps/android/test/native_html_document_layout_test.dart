import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';

import 'live_test.dart' show theme;

const _fixturePath = 'tool/parity/fixtures/document-layout-chromium153.json';
const _revision = 37;

final Map<String, dynamic> _fixture =
    jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;

void main() {
  const names = [
    'fixed_percent_nested_boxes',
    'content_box_and_border_box',
    'min_max_constraints',
    'flex_row',
    'flex_column',
    'display_none_descendants',
    'inline_canvas_and_image_with_and_without_padding',
    'inline_text_wrapping_unsupported_native',
  ];
  for (final raw in _fixture['cases'] as List) {
    final capture = raw as Map<String, dynamic>;
    final name = capture['name'] as String;
    if (!names.contains(name)) continue;
    testWidgets(
      'NativeHtmlDocument geometry from Chromium fixture: $name ${capture['viewportWidth']} ${capture['theme']}',
      (tester) async {
        final width = (capture['viewportWidth'] as num).toDouble();
        final height = (_fixture['viewport']['height'] as num).toDouble();
        final dpr = (_fixture['viewport']['deviceScaleFactor'] as num)
            .toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(width * dpr, height * dpr);
        addTearDown(tester.view.reset);

        final prepared = prepareNativeLayoutDocument(capture);
        final ids = (capture['targets'] as List).cast<String>().toSet();
        final controller = NativeDocumentLayoutController();
        addTearDown(controller.dispose);

        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(
                capture['theme'] == 'dark' ? Brightness.dark : Brightness.light,
              ),
              home: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  height: height,
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
                    authorStylesBuilder: (element) =>
                        prepared.stylesByKey[element
                            .attributes['data-pirc-document-style']],
                    layoutController: controller,
                    layoutRevision: _revision,
                    layoutKnownIds: ids,
                    layoutNoBoxIds: prepared.noBoxIds,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final packet = controller.capture(
            revision: _revision,
            generation: 1,
            viewport: Size(width, height),
          );
          expect(packet, isNotNull);
          final actualBoxes = _boxes(packet!);

          final browserExpected = capture['expected'] as Map<String, dynamic>;

          if (capture['nativeSupport'] == 'unsupported') {
            expect(
              browserExpected['wrapped']['clientRects'],
              isNotEmpty,
              reason: 'Chromium measured inline text fragments for the oracle.',
            );
            expect(actualBoxes['wrapped']?['kind'], 'unsupported');
            // Flutter unit tests use Ahem rather than the browser's font. This
            // checks the fixed wrapper width and explicit unsupported inline path;
            // text height/font fidelity is not an acceptance claim here.
            _expectGeometry(
              actualBoxes,
              browserExpected,
              'wrapper',
              checkHeight: false,
            );
          } else {
            for (final id in ids) {
              if (prepared.noBoxIds.contains(id)) {
                expect(actualBoxes[id]?['kind'], 'none', reason: id);
                expect(
                  (browserExpected[id]['clientRects'] as List),
                  isEmpty,
                  reason: '$id is display:none in the browser fixture.',
                );
              } else {
                _expectGeometry(actualBoxes, browserExpected, id);
              }
            }
          }

          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
        }
      },
    );
  }
}

class PreparedNativeLayoutDocument {
  const PreparedNativeLayoutDocument({
    required this.markup,
    required this.stylesByKey,
    required this.noBoxIds,
  });

  final String markup;
  final Map<String, Map<String, String>> stylesByKey;
  final Set<String> noBoxIds;
}

PreparedNativeLayoutDocument prepareNativeLayoutDocument(
  Map<String, dynamic> capture, {
  double? viewportHeight,
  double? devicePixelRatio,
  Map<String, String> scriptIdOverrides = const {},
}) {
  final document = html.parse(capture['html'] as String);
  final root = document.documentElement!;
  final body = document.body!;
  final targets = (capture['targets'] as List).cast<String>();
  for (final id in targets) {
    final element = document.getElementById(id);
    if (element == null) throw StateError('Missing fixture target #$id');
    element.attributes['data-pirc-script-id'] = scriptIdOverrides[id] ?? id;
  }

  final width = (capture['viewportWidth'] as num).toDouble();
  final viewport = _fixture['viewport'] as Map<String, dynamic>;
  final height = viewportHeight ?? (viewport['height'] as num).toDouble();
  final dark = capture['theme'] == 'dark';
  final stylesheets = [
    for (final style in document.querySelectorAll('style'))
      NativeDocumentStylesheet(style.text, baseUrl: 'https://layout.example/'),
  ];
  final cascade = NativeDocumentStyleEngine(
    stylesheets: stylesheets,
    viewportWidth: width,
    viewportHeight: height,
    devicePixelRatio:
        devicePixelRatio ?? (viewport['deviceScaleFactor'] as num).toDouble(),
    dark: dark,
  ).apply(document);

  final noBoxIds = <String>{};
  for (final id in targets) {
    var current = document.getElementById(id)!;
    while (true) {
      if (cascade.stylesByElement[current]?['display'] == 'none' ||
          current.attributes.containsKey('hidden')) {
        noBoxIds.add(scriptIdOverrides[id] ?? id);
        break;
      }
      final parent = current.parent;
      if (parent is! dom.Element) break;
      current = parent;
    }
  }

  final stylesByKey = <String, Map<String, String>>{};
  var nextStyleKey = 0;
  for (final element in document.querySelectorAll('*')) {
    final key = '${nextStyleKey++}';
    element.attributes['data-pirc-document-style'] = key;
    stylesByKey[key] = Map<String, String>.of(
      cascade.stylesByElement[element] ?? const <String, String>{},
    );
    element.attributes.remove('style');
  }

  final rootKey = root.attributes['data-pirc-document-style']!;
  final bodyKey = body.attributes['data-pirc-document-style']!;
  stylesByKey[rootKey] = Map<String, String>.of(stylesByKey[rootKey]!);
  stylesByKey[bodyKey] = {'margin': '8px', ...stylesByKey[bodyKey]!};

  // Match the production document view's explicit html/body block wrappers.
  // Root/body metrics require separate coverage: standards-mode root client
  // dimensions come from the viewport, while its bounding rect follows layout.
  return PreparedNativeLayoutDocument(
    markup:
        '<div${_attributes(root)}><div${_attributes(body)}>${body.innerHtml}</div></div>',
    stylesByKey: stylesByKey,
    noBoxIds: noBoxIds,
  );
}

String _attributes(dom.Element element) => element.attributes.entries
    .map(
      (entry) => ' ${entry.key}="${const HtmlEscape().convert(entry.value)}"',
    )
    .join();

Map<String, Map<String, dynamic>> _boxes(Map<String, dynamic> packet) => {
  for (final box in (packet['boxes'] as List).cast<Map<String, dynamic>>())
    box['id'] as String: box,
};

void _expectGeometry(
  Map<String, Map<String, dynamic>> actualBoxes,
  Map<String, dynamic> browserExpected,
  String id, {
  bool checkHeight = true,
}) {
  final actual = actualBoxes[id];
  expect(actual, isNotNull, reason: '$id is present in the native packet.');
  expect(actual!['kind'], 'box', reason: id);
  final browser = browserExpected[id] as Map<String, dynamic>;
  final rect = browser['rect'] as Map<String, dynamic>;
  for (final key in ['x', 'y', 'width', if (checkHeight) 'height']) {
    expect(
      (actual[key] as num).toDouble(),
      closeTo((rect[key] as num).toDouble(), .25),
      reason: '$id $key (Chromium getBoundingClientRect)',
    );
  }
  for (final key in [
    'offsetWidth',
    if (checkHeight) 'offsetHeight',
    'clientLeft',
    'clientTop',
    'clientWidth',
    if (checkHeight) 'clientHeight',
  ]) {
    final value = actual[key];
    if (value == null) continue;
    expect(
      (value as num).toDouble(),
      closeTo((browser[key] as num).toDouble(), .25),
      reason: '$id $key (Chromium box metric)',
    );
  }
}
