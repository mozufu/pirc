import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_document_styles.dart';

void main() {
  final fixtures =
      jsonDecode(
            File(
              'test/fixtures/parity/document-element-scroll-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final raw in fixtures['cases'] as List) {
    final capture = raw as Map;
    test(
      'overflow computed styles match Chromium ${capture['name']} ${capture['viewportWidth']} ${capture['theme']}',
      () {
        final doc = html.parse(capture['authoredHTML'] as String);
        final result = NativeDocumentStyleEngine(
          stylesheets: [
            NativeDocumentStylesheet(
              doc.querySelector('style')!.text,
              baseUrl: 'https://scroll.example/',
            ),
          ],
          viewportWidth: (capture['viewportWidth'] as num).toDouble(),
          dark: capture['theme'] == 'dark',
        ).apply(doc);
        final targets = capture['targets'] as List;
        for (final id in targets) {
          final styles =
              result.stylesByElement[doc.getElementById(id as String)] ?? {};
          // Expected computed values are read from the independent browser fixture.
          final expected =
              (((capture['expected'] as Map)['stages'] as List).first
                      as Map)['targets'][id]
                  as Map;
          expect(
            styles['overflow-x'] ?? 'visible',
            expected['overflowX'],
            reason: id,
          );
          expect(
            styles['overflow-y'] ?? 'visible',
            expected['overflowY'],
            reason: id,
          );
        }
        expect(
          result.diagnostics.where((d) => d.property == 'overflow'),
          isEmpty,
        );
      },
    );
  }
  test(
    'overflow shorthand variables, cascade, axis normalization and inheritance',
    () {
      final doc = html.parse('<div id="parent"><div id="child"></div></div>');
      final result = NativeDocumentStyleEngine(
        stylesheets: [
          NativeDocumentStylesheet(
            '#parent{--axes:clip scroll;overflow:var(--axes)}#child{overflow:inherit;overflow-x:visible!important;overflow:clip;overflow-y:invalid}',
            baseUrl: 'https://scroll.example/',
          ),
        ],
        viewportWidth: 390,
        dark: false,
      ).apply(doc);
      expect(
        result.stylesByElement[doc.getElementById('parent')]!['overflow-x'],
        'hidden',
      );
      expect(
        result.stylesByElement[doc.getElementById('parent')]!['overflow-y'],
        'scroll',
      );
      expect(
        result.stylesByElement[doc.getElementById('child')]!['overflow-x'],
        'visible',
      );
      expect(
        result.stylesByElement[doc.getElementById('child')]!['overflow-y'],
        'clip',
      );
      expect(
        result.diagnostics.any((d) => d.code == 'invalid-overflow-value'),
        isTrue,
      );
    },
  );
}
