@Tags(['tier3'])
library;

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'support/legacy_scripts_platform.dart';

class _ScrollFrameGateway extends LegacyScriptsPlatform {
  double nativeY = 0, initialExpected = 180, expected = 180;
  bool measured = false, scheduled = false, pending = false;
  int pumps = 0, continuations = 0;
  final actions = <Json>[];
  Json snapshot() {
    final outgoing = List<Json>.of(actions);
    actions.clear();
    return {
      'html':
          '<html><body><button data-pirc-script-id="pirc-1">scroll</button></body></html>',
      'layout': {
        'revision': 1,
        'required': !measured,
        'ids': ['pirc-1'],
      },
      'frameContinuation': pending ? {'id': 42} : null,
      'diagnostics': [],
      'canvases': [],
      'imageReferences': [],
      'scheduler': {'timerDelayMs': null, 'animationFrame': scheduled},
      'scrollActions': outgoing,
    };
  }

  Json action(int id, String kind, int y) => {
    'actionId': id,
    'kind': kind,
    'x': 0,
    'y': y,
    'behavior': 'auto',
  };
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'documentScriptCapabilities') return {'supported': true};
    if (method == 'documentScriptOpen') return {'id': 1};
    if (method == 'documentScriptClose') return null;
    if (method != 'documentScriptEvaluate') throw StateError(method);
    final source = args['source'] as String;
    if (source == 'runtime') return {'value': ''};
    if (source.startsWith('__pircDocument.dispatch(')) {
      actions.add(action(1, 'to', 180));
      scheduled = true;
    }
    if (source.startsWith('__pircDocument.updateLayout(')) {
      final packet = obj(
        jsonDecode(
          source.substring(source.indexOf('(') + 1, source.lastIndexOf(')')),
        ),
      );
      nativeY = (obj(packet['viewport'])['scrollY'] as num).toDouble();
      measured = true;
      return {
        'value': jsonEncode({...snapshot(), 'layoutAccepted': true}),
      };
    }
    if (source.startsWith('__pircDocument.pump(')) {
      if (nativeY != initialExpected) {
        throw StateError(
          'RAF entered before native scroll acknowledgement: $nativeY',
        );
      }
      pumps++;
      scheduled = false;
      pending = true;
      actions.add(action(2, 'by', 20));
      final serialized = jsonEncode(snapshot());
      // A Promise job after the serialized callback adds another ordered scroll.
      actions.add(action(3, 'by', 5));
      expected = initialExpected + 25;
      return {'value': serialized};
    }
    if (source.startsWith('__pircDocument.continueAnimationFrame(')) {
      if (nativeY != expected) {
        throw StateError(
          'Continuation ran before composed scrollBy: $nativeY/$expected',
        );
      }
      continuations++;
      pending = false;
    }
    return {'value': jsonEncode(snapshot())};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final suspension in ['none', 'detach', 'hide']) {
    testWidgets(
      'native scroll acknowledgement precedes RAF without replay; $suspension',
      (tester) async {
        final gateway = _ScrollFrameGateway();
        final document = NativeDocumentScripts(gateway);
        final executed = <int>[];
        var cancelled = false, position = 0.0;
        document.bindLayout(Object(), (revision, generation) async {
          if (suspension != 'none' &&
              !cancelled &&
              document.scrollActions.isNotEmpty) {
            cancelled = true;
            document.setActivity(
              attached: suspension != 'detach',
              visible: false,
            );
            return null;
          }
          for (final action in document.takeScrollActions()) {
            executed.add(action['actionId'] as int);
            position = action['kind'] == 'by'
                ? position + (action['y'] as num).toDouble()
                : (action['y'] as num).toDouble();
          }
          return {
            'revision': revision,
            'generation': generation,
            'viewport': {
              'width': 390,
              'height': 844,
              'scrollX': 0,
              'scrollY': position,
            },
            'boxes': [],
          };
        });
        await document.start(
          source: '<button>scroll</button>',
          url: 'https://example.test/scroll-frame',
        );
        await document.click('pirc-1', []);
        if (suspension != 'none') {
          expect(cancelled, isTrue);
          expect(executed, isEmpty);
          await tester.pump(const Duration(milliseconds: 50));
          expect(gateway.pumps, 0);
          gateway.initialExpected = 0;
          document.setActivity(attached: true, visible: true);
        }
        for (var i = 0; i < 100 && gateway.continuations == 0; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(gateway.continuations, 1, reason: '${document.diagnostics}');
        expect(gateway.pumps, 1);
        expect(executed, suspension == 'none' ? [1, 2, 3] : [2, 3]);
        expect(document.scrollActions, isEmpty);
        expect(document.diagnostics, isEmpty);
        document.dispose();
        await document.closed;
        await tester.pump(Duration.zero);
      },
    );
  }
}
