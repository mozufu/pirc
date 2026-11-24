import 'dart:convert';
import 'dart:io';
import 'package:html/parser.dart' as html;
import 'package:pirc_render_document/src/document_computed_styles.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_element_scroll.dart';
import 'package:pirc_render/src/document_scroll_commands.dart';
import 'package:pirc_render/src/document_scroll_anchor.dart';
import 'live_test.dart' show theme;

final fixture =
    jsonDecode(
          File(
            'tool/parity/fixtures/document-scroll-behavior-chromium153.json',
          ).readAsStringSync(),
        )
        as Map;
Widget scene(
  NativeDocumentScrollController root,
  NativeDocumentElementScrollController element,
  String behavior,
) => SingleChildScrollView(
  controller: root,
  child: SizedBox(
    height: 2200,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 180,
        height: 100,
        child: NativeDocumentElementScroll(
          controller: element,
          id: 'port',
          scrollBehavior: behavior,
          revision: 1,
          overflowX: NativeDocumentOverflow.auto,
          overflowY: NativeDocumentOverflow.auto,
          child: const OverflowBox(
            fit: OverflowBoxFit.deferToChild,
            alignment: Alignment.topLeft,
            minWidth: 600,
            maxWidth: 600,
            child: SizedBox(width: 600, height: 800),
          ),
        ),
      ),
    ),
  ),
);

void check(
  Map expected,
  NativeDocumentScrollController root,
  NativeDocumentElementScrollController element,
) {
  expect(root.offset, (expected['root']['top'] as num).toDouble());
  final metrics = element.metricsFor('port')!;
  expect(metrics['top'], (expected['element']['top'] as num).toDouble());
  expect(metrics['left'], (expected['element']['left'] as num).toDouble());
}

void main() {
  for (final row in fixture['cases'] as List) {
    testWidgets(
      'CSS behavior ${row['target']} ${row['mode']} ${row['viewport']['width']} dpr${row['dpr']} ${row['theme']}',
      (tester) async {
        final dpr = (row['dpr'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize =
            Size(
              (row['viewport']['width'] as num).toDouble(),
              (row['viewport']['height'] as num).toDouble(),
            ) *
            dpr;
        addTearDown(tester.view.reset);
        final doc = html.parse(row['html'] as String);
        for (final e in doc.querySelectorAll('[id],html')) {
          e.attributes['data-pirc-script-id'] = e.localName == 'html'
              ? 'root'
              : e.id;
        }
        if (row['mode'] == 'dynamic-frame') {
          doc.documentElement!.classes.add('changed');
          doc.getElementById('port')!.classes.add('changed');
        }
        final cascade = NativeDocumentStyleEngine(
          dark: row['theme'] == 'dark',
          stylesheets: [
            for (final style in doc.querySelectorAll('style'))
              NativeDocumentStylesheet(
                style.text,
                baseUrl: 'https://example.test/',
              ),
          ],
          viewportWidth: (row['viewport']['width'] as num).toDouble(),
          viewportHeight: (row['viewport']['height'] as num).toDouble(),
        ).apply(doc);
        final specs = nativeDocumentComputedStyleSpecs(
          document: doc,
          stylesByElement: cascade.stylesByElement,
          viewportWidth: (row['viewport']['width'] as num).toDouble(),
          viewportHeight: (row['viewport']['height'] as num).toDouble(),
        );
        final css = {
          'root': specs['root']!.values['scroll-behavior'],
          'element': specs['port']!.values['scroll-behavior'],
        };
        expect(css, row['result']['css']);
        final root = NativeDocumentScrollController(),
            element = NativeDocumentElementScrollController();
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(
                row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
              ),
              home: scene(root, element, css['element']!),
            ),
          );
          final behavior = row['requestBehavior'] as String;
          if (row['target'] == 'root') {
            applyNativeDocumentScrollAxis(
              root,
              180,
              relative: false,
              behavior: behavior,
              cssBehavior: css['root']!,
            );
          } else {
            element.applyActions([
              {'id': 'port', 'op': 'to', 'top': 180, 'behavior': behavior},
            ]);
          }
          // These are actual native positions immediately after command execution,
          // distinct from the still-deferred JS snapshot getters.
          check(row['result']['immediate'] as Map, root, element);
          expect(element.pendingScrollEvents.length, lessThanOrEqualTo(1));
          await tester.pumpAndSettle();
          check(row['result']['settled'] as Map, root, element);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          root.dispose();
          element.dispose();
        }
      },
    );
  }
}
