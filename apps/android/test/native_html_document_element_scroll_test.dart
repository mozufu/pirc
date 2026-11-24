import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/document_element_scroll.dart';
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_mobile/theme.dart';

const _fixturePath =
    'tool/parity/fixtures/document-element-scroll-chromium153.json';
const _revision = 63;

// Keep fixture I/O synchronous: testWidgets runs in a fake-async zone.
final Map<String, dynamic> _fixture =
    jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;
final PircTheme _theme = PircTheme(
  jsonDecode(File('assets/design-tokens.json').readAsStringSync())
      as Map<String, dynamic>,
);

void main() {
  testWidgets(
    'a real HTML button remains clickable after native two-axis scrolling',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1000);
      addTearDown(tester.view.reset);
      final prepared = _prepareDocument({
        'authoredHTML': '''<!doctype html><html><head><style>
      html,body{margin:0;padding:0}
      #scroller{width:140px;height:100px;overflow:auto;padding:8px;border:3px solid}
      #child{box-sizing:border-box;width:420px;height:320px;padding-top:180px;padding-left:240px}
      #target{display:block;box-sizing:border-box;width:80px;height:32px;margin:0;padding:0;border:0}
      </style></head><body><div id="scroller"><div id="child"><button id="target" type="button">Inside scroll</button></div></div></body></html>''',
        'targets': ['scroller', 'child', 'target'],
        'viewportWidth': 390,
        'viewportHeight': 1000,
        'deviceScaleFactor': 1,
        'theme': 'light',
      });
      final scroll = NativeDocumentElementScrollController();
      addTearDown(scroll.dispose);
      var clicks = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme.build(Brightness.light),
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 390,
              height: 1000,
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
                elementScrollController: scroll,
                layoutRevision: _revision,
                layoutKnownIds: const {'scroller', 'child', 'target'},
                onScriptEvent: (id, type, controls, {submitter}) async {
                  if (id == 'target' && type == 'click') clicks++;
                  return false;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final offscreenButton = find.byWidgetPredicate(
        (widget) =>
            widget is NativeHtmlButtonWidget &&
            widget.button.label == 'Inside scroll',
      );
      await tester.tapAt(tester.getCenter(offscreenButton));
      await tester.pumpAndSettle();
      expect(
        clicks,
        0,
        reason:
            'A CSS-clipped button must not receive a tap through the document overflow fallback.',
      );
      scroll.applyActions([
        {'id': 'scroller', 'op': 'scrollTo', 'left': 240, 'top': 180},
      ]);
      await tester.pumpAndSettle();
      expect(scroll.metricsFor('scroller')?['left'], 240);
      expect(scroll.metricsFor('scroller')?['top'], 180);
      final button = find.byWidgetPredicate(
        (widget) =>
            widget is NativeHtmlButtonWidget &&
            widget.button.label == 'Inside scroll',
      );
      final center = tester.getCenter(button);
      expect(center.dx, inExclusiveRange(3, 159));
      expect(center.dy, inExclusiveRange(3, 119));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(clicks, 1);
      expect(tester.takeException(), isNull);
    },
  );
  for (final raw in _fixture['cases'] as List) {
    final capture = raw as Map<String, dynamic>;
    final name = capture['name'] as String;
    final width = (capture['viewportWidth'] as num).toDouble();
    final brightness = capture['theme'] == 'dark'
        ? Brightness.dark
        : Brightness.light;
    testWidgets(
      'Native document element scrolling from Chromium: $name ${width.toInt()} ${brightness.name}',
      (tester) async {
        final height = (capture['viewportHeight'] as num).toDouble();
        final dpr = (capture['deviceScaleFactor'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(width * dpr, height * dpr);
        addTearDown(tester.view.reset);

        final prepared = _prepareDocument(capture);
        final targets = (capture['targets'] as List).cast<String>().toSet();
        final layout = NativeDocumentLayoutController();
        final elementScroll = NativeDocumentElementScrollController();
        addTearDown(layout.dispose);
        addTearDown(elementScroll.dispose);

        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: _theme.build(brightness),
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
                    layoutController: layout,
                    elementScrollController: elementScroll,
                    layoutRevision: _revision,
                    layoutKnownIds: targets,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final browserStages =
              (capture['expected'] as Map<String, dynamic>)['stages'] as List;
          expect(
            browserStages,
            hasLength(1 + (capture['actions'] as List).length),
          );

          var generation = 1;
          var packet = _capture(
            layout,
            elementScroll,
            width,
            height,
            generation++,
          );
          _expectStage(
            packet,
            browserStages.first as Map<String, dynamic>,
            targets,
            '${capture['name']} initial',
          );

          for (
            var index = 0;
            index < (capture['actions'] as List).length;
            index++
          ) {
            final action =
                (capture['actions'] as List)[index] as Map<String, dynamic>;
            elementScroll.applyActions(_normalizeAction(action));
            // Actions are applied to actual native scroll render objects. Pump
            // through layout and notification callbacks before reading them.
            await tester.pump();
            await tester.pump();
            packet = _capture(
              layout,
              elementScroll,
              width,
              height,
              generation++,
            );
            _expectStage(
              packet,
              browserStages[index + 1] as Map<String, dynamic>,
              targets,
              '${capture['name']} ${(action['label'] as String)}',
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

class _PreparedDocument {
  const _PreparedDocument({required this.markup, required this.stylesByKey});

  final String markup;
  final Map<String, Map<String, String>> stylesByKey;
}

_PreparedDocument _prepareDocument(Map<String, dynamic> capture) {
  final document = html.parse(capture['authoredHTML'] as String);
  final root = document.documentElement!;
  final body = document.body!;
  final targets = (capture['targets'] as List).cast<String>();
  for (final id in targets) {
    final target = document.getElementById(id);
    if (target == null) throw StateError('Missing fixture target #$id');
    target.attributes['data-pirc-script-id'] = id;
  }

  final width = (capture['viewportWidth'] as num).toDouble();
  final height = (capture['viewportHeight'] as num).toDouble();
  final stylesheets = [
    for (final style in document.querySelectorAll('style'))
      NativeDocumentStylesheet(style.text, baseUrl: 'https://scroll.example/'),
  ];
  final cascade = NativeDocumentStyleEngine(
    stylesheets: stylesheets,
    viewportWidth: width,
    viewportHeight: height,
    devicePixelRatio: (capture['deviceScaleFactor'] as num).toDouble(),
    dark: capture['theme'] == 'dark',
  ).apply(document);

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

  return _PreparedDocument(
    markup:
        '<div${_attributes(root)}><div${_attributes(body)}>${body.innerHtml}</div></div>',
    stylesByKey: stylesByKey,
  );
}

String _attributes(dom.Element element) => element.attributes.entries
    .map(
      (entry) => ' ${entry.key}="${const HtmlEscape().convert(entry.value)}"',
    )
    .join();

List<Map<String, dynamic>> _normalizeAction(Map<String, dynamic> action) {
  Map<String, dynamic> scrollAction(
    String id,
    String op, {
    double? left,
    double? top,
  }) => {'id': id, 'op': op, 'left': left ?? 0, 'top': top ?? 0};

  switch (action['op']) {
    case 'set':
      return [
        scrollAction(
          action['id'] as String,
          'scrollTo',
          left: (action['left'] as num?)?.toDouble(),
          top: (action['top'] as num?)?.toDouble(),
        ),
      ];
    case 'scrollTo':
    case 'scrollBy':
      return [
        scrollAction(
          action['id'] as String,
          action['op'] as String,
          left: (action['left'] as num?)?.toDouble(),
          top: (action['top'] as num?)?.toDouble(),
        ),
      ];
    case 'setBoth':
      return [
        for (final id in action['ids'] as List)
          scrollAction(
            id as String,
            'scrollTo',
            top: (action['top'] as num).toDouble(),
          ),
      ];
    case 'setSequence':
      return [
        for (final raw in action['sequence'] as List)
          scrollAction(
            (raw as Map<String, dynamic>)['id'] as String,
            'scrollTo',
            left: ((raw)['left'] as num?)?.toDouble(),
            top: ((raw)['top'] as num?)?.toDouble(),
          ),
      ];
    default:
      throw StateError('Unknown fixture scroll action ${action['op']}');
  }
}

Map<String, dynamic> _capture(
  NativeDocumentLayoutController layout,
  NativeDocumentElementScrollController scroll,
  double width,
  double height,
  int generation,
) {
  final packet = layout.capture(
    revision: _revision,
    generation: generation,
    viewport: Size(width, height),
    elementScrollMetrics: scroll.metricsFor,
    scrollEvents: scroll.pendingScrollEvents,
  );
  expect(packet, isNotNull, reason: 'Native document layout is ready.');
  return packet!;
}

void _expectStage(
  Map<String, dynamic> packet,
  Map<String, dynamic> browserStage,
  Set<String> ids,
  String label,
) {
  final boxes = {
    for (final box in (packet['boxes'] as List).cast<Map<String, dynamic>>())
      box['id'] as String: box,
  };
  expect(boxes.keys.toSet(), ids, reason: '$label target IDs');
  final browserTargets = browserStage['targets'] as Map<String, dynamic>;

  for (final id in ids) {
    final actual = boxes[id];
    expect(actual, isNotNull, reason: '$label #$id native layout');
    expect(actual!['kind'], 'box', reason: '$label #$id');
    final browser = browserTargets[id] as Map<String, dynamic>;
    final rect = browser['rect'] as Map<String, dynamic>;
    for (final key in ['x', 'y', 'width', 'height']) {
      expect(
        (actual[key] as num).toDouble(),
        closeTo((rect[key] as num).toDouble(), .25),
        reason: '$label #$id $key vs Chromium BCR',
      );
    }
    for (final key in ['offsetWidth', 'offsetHeight']) {
      expect(
        actual[key],
        closeTo((browser[key] as num).toDouble(), .25),
        reason: '$label #$id $key vs Chromium',
      );
    }
    for (final key in [
      'clientWidth',
      'clientHeight',
      'clientLeft',
      'clientTop',
    ]) {
      final value = actual[key];
      expect(value, isNotNull, reason: '$label #$id native $key is reported');
      expect(
        (value as num).toDouble(),
        closeTo((browser[key] as num).toDouble(), .25),
        reason: '$label #$id $key vs Chromium',
      );
    }

    final metrics = actual['scroll'] as Map<String, dynamic>?;
    expect(metrics, isNotNull, reason: '$label #$id scroll metrics');
    for (final entry in const {
      'width': 'scrollWidth',
      'height': 'scrollHeight',
      'left': 'scrollLeft',
      'top': 'scrollTop',
    }.entries) {
      expect(
        (metrics![entry.key] as num).toDouble(),
        closeTo((browser[entry.value] as num).toDouble(), .25),
        reason: '$label #$id scroll.${entry.key} vs Chromium ${entry.value}',
      );
    }
  }
}
