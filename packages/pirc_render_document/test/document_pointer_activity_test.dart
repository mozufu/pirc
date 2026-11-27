@Tags(['tier3'])
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'document_scripts_test.dart' show ScriptsGateway;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final type in ['pointerdown', 'mouseout']) {
    for (final mode in [
      'hidden',
      'detached',
      'background',
      'hidden-resumed',
      'background-resumed',
    ]) {
      test('queued $type events expire when document is $mode', () async {
        final gateway = ScriptsGateway();
        final scripts = NativeDocumentScripts(gateway);
        addTearDown(() async {
          scripts.dispose();
          await scripts.closed;
        });
        await scripts.start(
          source: '<canvas></canvas>',
          url: 'https://example.test/',
        );
        final gate = Completer<dynamic>();
        gateway.evaluation = gate;
        final blocker = scripts.click('blocker', []);
        await Future<void>.delayed(Duration.zero);
        final pointer = scripts.dispatchDetailed(
          'canvas',
          type,
          [],
          type == 'mouseout'
              ? {'clientX': 385, 'clientY': 120}
              : {'pointerId': 3, 'pointerType': 'touch'},
        );
        if (mode.startsWith('background')) {
          scripts.didChangeAppLifecycleState(AppLifecycleState.paused);
          if (mode.endsWith('resumed')) {
            scripts.didChangeAppLifecycleState(AppLifecycleState.resumed);
          }
        } else {
          scripts.setActivity(attached: mode != 'detached', visible: false);
          if (mode.endsWith('resumed')) {
            scripts.setActivity(attached: true, visible: true);
          }
        }
        gateway.evaluation = null;
        gate.complete({
          'value': jsonEncode({
            'html': '<html><body></body></html>',
            'diagnostics': [],
          }),
        });
        await blocker;
        expect(await pointer, true);
        expect(
          gateway.calls.where(
            (c) =>
                c.$1 == 'documentScriptEvaluate' &&
                '${c.$2['source']}'.contains('"type":"$type"'),
          ),
          isEmpty,
        );
      });
    }
  }
}
