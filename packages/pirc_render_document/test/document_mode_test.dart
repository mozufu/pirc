@Tags(['tier3'])
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'document_scripts_test.dart' show ScriptsGateway;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture =
      jsonDecode(
            File(
              '../../packages/pirc_render/test/fixtures/parity/document-scrolling-element-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  final modes = <String>{};
  for (final row in fixture['cases'] as List) {
    if (!modes.add(row['mode'] as String)) continue;
    test(
      'native startup passes the HTML parser mode matching Chromium: ${row['mode']}',
      () async {
        final gateway = ScriptsGateway();
        final scripts = NativeDocumentScripts(gateway);
        try {
          await scripts.start(
            source: row['html'] as String,
            url: 'https://example.test/mode',
          );
          expect(scripts.ready, isTrue, reason: scripts.diagnostics.join('\n'));
          final init = gateway.calls
              .where((c) => c.$1 == 'documentScriptEvaluate')
              .map((c) => c.$2['source'] as String)
              .singleWhere((s) => s.startsWith('__pircDocument.init('));
          final payload =
              jsonDecode(
                    init.substring(
                      '__pircDocument.init('.length,
                      init.length - 1,
                    ),
                  )
                  as Map;
          expect(
            payload['documentMode'],
            isIn(['quirks', 'limited quirks', 'no quirks']),
          );
          final compat = payload['documentMode'] == 'quirks'
              ? 'BackCompat'
              : 'CSS1Compat';
          expect(compat, row['result']['immediate']['compatMode']);
          if (row['mode'] == 'legacy-limited') {
            expect(payload['documentMode'], 'limited quirks');
          }
        } finally {
          scripts.dispose();
          await scripts.closed;
        }
      },
    );
  }
}
