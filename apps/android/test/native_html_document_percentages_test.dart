import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/document_margin_collapse.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_mobile/theme.dart';

const _fixturePath =
    '../../packages/pirc_render/test/fixtures/parity/document-percentages-chromium153.json';
const _revision = 41;

// Load synchronously: testWidgets runs in a fake-async zone, where an async
// fixture read can leave a test waiting for an event that the zone cannot pump.
final Map<String, dynamic> _fixture =
    jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;
final PircTheme _theme = PircTheme(
  jsonDecode(File('assets/design-tokens.json').readAsStringSync())
      as Map<String, dynamic>,
);

void main() {
  for (final raw in _fixture['cases'] as List) {
    final capture = raw as Map<String, dynamic>;
    final name = capture['name'] as String;
    final width = (capture['viewportWidth'] as num).toDouble();
    final themeName = capture['theme'] as String;
    testWidgets('NativeHtmlDocument percentage geometry from Chromium: '
        '$name ${width.toInt()} $themeName', (tester) async {
      final height = (capture['viewportHeight'] as num).toDouble();
      final dpr = (capture['deviceScaleFactor'] as num).toDouble();
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = Size(width * dpr, height * dpr);
      addTearDown(tester.view.reset);

      final prepared = _prepareDocument(capture);
      final ids = (capture['targets'] as List).cast<String>().toSet();
      final controller = NativeDocumentLayoutController();
      addTearDown(controller.dispose);

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: _theme.build(
              themeName == 'dark' ? Brightness.dark : Brightness.light,
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
                  imageViewport: Size(width, height),
                  documentTopMargins: prepared.topMargins,
                  documentPercentTopMargins: prepared.percentTopMargins,
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
        expect(packet, isNotNull, reason: '$name has a completed layout.');
        final actualBoxes = _boxes(packet!);
        final browserExpected = capture['expected'] as Map<String, dynamic>;

        expect(actualBoxes.keys.toSet(), ids, reason: '$name target IDs');
        for (final id in ids) {
          if (prepared.noBoxIds.contains(id)) {
            expect(actualBoxes[id]?['kind'], 'none', reason: '$name #$id');
            expect(
              (browserExpected[id]['clientRects'] as List),
              isEmpty,
              reason: '$name #$id is not rendered by Chromium.',
            );
            continue;
          }
          _expectChromiumGeometry(
            actualBoxes,
            browserExpected,
            id,
            caseName: name,
          );
        }

        expect(tester.takeException(), isNull, reason: '$name Flutter error');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }
}

class _PreparedDocument {
  const _PreparedDocument({
    required this.markup,
    required this.stylesByKey,
    required this.noBoxIds,
    required this.topMargins,
    required this.percentTopMargins,
  });

  final String markup;
  final Map<String, Map<String, String>> stylesByKey;
  final Set<String> noBoxIds;
  final Map<String, double> topMargins;
  final Map<String, NativeDocumentTopMarginGroup> percentTopMargins;
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
  final dark = capture['theme'] == 'dark';
  final stylesheets = [
    for (final style in document.querySelectorAll('style'))
      NativeDocumentStylesheet(
        style.text,
        baseUrl: 'https://percentages.example/',
      ),
  ];
  final cascade = NativeDocumentStyleEngine(
    stylesheets: stylesheets,
    viewportWidth: width,
    viewportHeight: height,
    devicePixelRatio: (capture['deviceScaleFactor'] as num).toDouble(),
    dark: dark,
  ).apply(document);

  final noBoxIds = <String>{};
  for (final id in targets) {
    var current = document.getElementById(id)!;
    while (true) {
      if (cascade.stylesByElement[current]?['display'] == 'none' ||
          current.attributes.containsKey('hidden')) {
        noBoxIds.add(id);
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
  // The native document view supplies the browser's default body margin when
  // the page has not authored one. Explicit fixture declarations still win.
  stylesByKey[bodyKey] = {'margin': '8px', ...stylesByKey[bodyKey]!};

  return _PreparedDocument(
    markup:
        '<div${_attributes(root)}><div${_attributes(body)}>${body.innerHtml}</div></div>',
    stylesByKey: stylesByKey,
    noBoxIds: noBoxIds,
    topMargins: nativeDocumentCollapsedTopMargins(
      document: document,
      stylesByElement: cascade.stylesByElement,
    ),
    percentTopMargins: nativeDocumentPercentTopMarginGroups(
      document: document,
      stylesByElement: cascade.stylesByElement,
    ),
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

void _expectChromiumGeometry(
  Map<String, Map<String, dynamic>> actualBoxes,
  Map<String, dynamic> browserExpected,
  String id, {
  required String caseName,
}) {
  final actual = actualBoxes[id];
  expect(actual, isNotNull, reason: '$caseName #$id is in the native packet.');
  expect(actual!['kind'], 'box', reason: '$caseName #$id');

  final browser = browserExpected[id] as Map<String, dynamic>;
  final rect = browser['rect'] as Map<String, dynamic>;
  final clientRects = browser['clientRects'] as List;
  expect(clientRects, hasLength(1), reason: '$caseName #$id browser fragments');

  for (final key in ['x', 'y', 'width', 'height']) {
    expect(
      (actual[key] as num).toDouble(),
      closeTo((rect[key] as num).toDouble(), .25),
      reason: '$caseName #$id $key vs Chromium getBoundingClientRect()',
    );
  }

  for (final key in ['offsetWidth', 'offsetHeight']) {
    expect(
      (actual[key] as num).toDouble(),
      closeTo((browser[key] as num).toDouble(), .25),
      reason: '$caseName #$id $key vs Chromium',
    );
  }

  // Client metrics are intentionally absent from the native packet when a
  // subtree has multiple/unsupported borders. Compare every metric it reports;
  // boxes with a single unambiguous border report all four fields.
  for (final key in [
    'clientLeft',
    'clientTop',
    'clientWidth',
    'clientHeight',
  ]) {
    final value = actual[key];
    if (value == null) continue;
    expect(
      (value as num).toDouble(),
      closeTo((browser[key] as num).toDouble(), .25),
      reason: '$caseName #$id $key vs Chromium',
    );
  }
}
