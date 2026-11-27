@Tags(['tier3'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render_document/src/document_style_loading.dart';
import 'package:pirc_render/src/html_document_styles.dart';

void main() {
  test(
    'loaded author cascade matches actual Chrome response style probes',
    () async {
      final fixture =
          jsonDecode(
                File(
                  '../../fixtures/mobile-parity/html-document-styles.json',
                ).readAsStringSync(),
              )
              as Map;
      final web =
          jsonDecode(
                File(
                  '../../fixtures/mobile-parity/html-document-styles-expected.json',
                ).readAsStringSync(),
              )
              as Map;
      expect(web['reference'], fixture['webRevision']);
      expect(web['fixture'], fixture['id']);
      final requests = <String>[];
      final loaded =
          await NativeDocumentStyleLoader(
            isCurrent: () => true,
            resolve: (reference, base) async =>
                Uri.parse(base).resolve(reference).toString(),
            fetch: (url, base) async {
              final path = Uri.parse(url).path;
              requests.add(path);
              final source = fixture['stylesheets'][path] as String;
              return {
                'status': 200,
                'mimeType': 'text/css',
                'charset': 'UTF-8',
                'finalUrl': url,
                'bytes': Uint8List.fromList(utf8.encode(source)),
              };
            },
          ).load(
            fixture['responseHtml'] as String,
            baseUrl: '${web['origin']}${fixture['responsePath']}',
            documentEncoding: 'utf-8',
          );
      expect(requests.toSet(), (fixture['stylesheets'] as Map).keys.toSet());
      expect(loaded.diagnostics, isEmpty);
      final mismatches = <String>[];
      for (final capture in web['captures'] as List) {
        final width = (capture['width'] as num).toDouble();
        final dark = capture['colorScheme'] == 'dark';
        final document = html.parse(fixture['responseHtml'] as String);
        final result = NativeDocumentStyleEngine(
          stylesheets: loaded.stylesheets,
          viewportWidth: width,
          dark: dark,
        ).apply(document);
        for (final invariant in fixture['invariants'] as List) {
          final applies = switch (invariant['appliesTo']) {
            'all' => true,
            'narrow' => width < 600,
            'wide' => width >= 600,
            'light' => !dark,
            'dark' => dark,
            _ => false,
          };
          if (!applies) continue;
          final name = invariant['node'] as String;
          final selector = fixture['snapshotNodes'][name] as String;
          final property = invariant['property'] as String;
          final native = result
              .stylesByElement[document.querySelector(selector)]?[property];
          final expected =
              capture['document']['nodes'][name]['computed'][property]
                  as String;
          String normalized(String? value) => (value ?? '<absent>')
              .replaceAll(RegExp(r'\s+'), '')
              .toLowerCase();
          if (normalized(native) != normalized(expected)) {
            mismatches.add(
              '$width/${capture['colorScheme']} $name.$property: $native vs $expected',
            );
          }
        }
      }
      expect(mismatches, isEmpty, reason: mismatches.join('\n'));
    },
  );
}
