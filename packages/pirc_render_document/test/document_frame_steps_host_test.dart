@Tags(['tier3'])
library;

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'support/legacy_scripts_platform.dart';

class _FrameGateway extends LegacyScriptsPlatform {
  _FrameGateway({this.steps = 1});
  final int steps;
  void Function()? onBudget;
  int dispatches = 0;
  final dispatchAtContinuation = <int>[];
  int revision = 1, measuredRevision = 0, continuations = 0;
  bool requiredLayout = true, scheduled = false, pending = false;
  final calls = <String>[];
  Json snapshot() => {
    'html':
        '<html><body><button data-pirc-script-id="pirc-1">frame</button></body></html>',
    'layout': {
      'revision': revision,
      'required': requiredLayout,
      'ids': ['pirc-1'],
    },
    'frameContinuation': pending ? {'id': 42} : null,
    'diagnostics': [],
    'canvases': [],
    'imageReferences': [],
    'scheduler': {
      'timerDelayMs': pending ? 0 : null,
      'animationFrame': scheduled,
    },
  };
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'documentScriptCapabilities') return {'supported': true};
    if (method == 'documentScriptOpen') return {'id': 1};
    if (method == 'documentScriptClose') return null;
    if (method != 'documentScriptEvaluate') throw StateError(method);
    final source = args['source'] as String;
    calls.add(source);
    if (source == 'runtime') return {'value': ''};
    if (source.startsWith('__pircDocument.dispatch(')) {
      dispatches++;
      dispatchAtContinuation.add(continuations);
      scheduled = dispatches == 1;
    }
    if (source.startsWith('__pircDocument.updateLayout(')) {
      final packet = obj(
        jsonDecode(
          source.substring(source.indexOf('(') + 1, source.lastIndexOf(')')),
        ),
      );
      measuredRevision = packet['revision'] as int;
      requiredLayout = false;
      return {
        'value': jsonEncode({...snapshot(), 'layoutAccepted': true}),
      };
    }
    if (source.startsWith('__pircDocument.pump(') && !pending) {
      if (!source.contains('"nativeFrameSteps":true') ||
          measuredRevision != revision) {
        throw StateError(
          'Pump entered without native frame setup or current geometry',
        );
      }
      scheduled = false;
      pending = true;
      final staleSerializedResult = jsonEncode(snapshot());
      // A real Promise job runs after response() serialized the initiating task.
      revision++;
      requiredLayout = true;
      return {'value': staleSerializedResult};
    }
    if (source.startsWith('__pircDocument.continueAnimationFrame(')) {
      if (!source.contains('"id":42') || measuredRevision != revision) {
        throw StateError(
          'Frame continuation ran before measuring Promise mutation',
        );
      }
      continuations++;
      pending = continuations < steps;
      if (continuations == 128) onBudget?.call();
    }
    return {'value': jsonEncode(snapshot())};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'frame continuation survives the host task budget without replay or a new frame',
    (tester) async {
      final gateway = _FrameGateway(steps: 140);
      final scripts = NativeDocumentScripts(gateway);
      scripts.bindLayout(
        Object(),
        (revision, generation) async => {
          'revision': revision,
          'generation': generation,
        },
      );
      await scripts.start(
        source: '<button>frame</button>',
        url: 'https://example.test/frame',
      );
      Future<bool>? clickDuringBudget;
      gateway.onBudget = () {
        clickDuringBudget = scripts.click('pirc-1', []);
      };
      await scripts.click('pirc-1', []);
      for (var i = 0; i < 100 && gateway.continuations < 140; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(gateway.continuations, 140);
      expect(clickDuringBudget, isNotNull);
      await clickDuringBudget;
      expect(
        gateway.dispatchAtContinuation,
        [0, 140],
        reason:
            'A queued DOM event must wait until all selected frame callbacks finish',
      );
      expect(
        gateway.revision,
        2,
        reason:
            'Only the initial callback ran; resuming a paused frame must not replay it',
      );
      expect(scripts.ready, isTrue);
      expect(scripts.diagnostics, isEmpty);
      scripts.dispose();
      await scripts.closed;
      await tester.pump(Duration.zero);
    },
  );
  for (final suspension in ['none', 'detach', 'hide']) {
    final detachAtCapture = suspension != 'none';
    testWidgets(
      detachAtCapture
          ? '$suspension during the frame checkpoint suspends the continuation and resumes it once'
          : 'Promise changes after serialized task results are measured before frame continuation',
      (tester) async {
        final gateway = _FrameGateway();
        final scripts = NativeDocumentScripts(gateway);
        var detached = false;
        final captured = <int>[];
        final owner = Object();
        scripts.bindLayout(owner, (revision, generation) async {
          captured.add(revision);
          if (detachAtCapture && revision == 2 && !detached) {
            detached = true;
            scripts.setActivity(
              attached: suspension != 'detach',
              visible: suspension != 'hide',
            );
            return null;
          }
          return {
            'revision': revision,
            'generation': generation,
            'viewport': {
              'width': 390,
              'height': 844,
              'scrollX': 0,
              'scrollY': 0,
            },
            'boxes': [],
          };
        });
        await scripts.start(
          source: '<button>frame</button>',
          url: 'https://example.test/frame',
        );
        expect(scripts.ready, isTrue);
        await scripts.click('pirc-1', []);
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          if (detached || gateway.continuations > 0) break;
        }
        if (detachAtCapture) {
          expect(
            detached,
            isTrue,
            reason:
                '${scripts.ready}: ${scripts.diagnostics}; ${gateway.calls}',
          );
          expect(gateway.continuations, 0);
          scripts.setActivity(attached: true, visible: true);
          for (var i = 0; i < 30 && gateway.continuations == 0; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
        }
        expect(
          gateway.continuations,
          1,
          reason: '${scripts.ready}: ${scripts.diagnostics}; ${gateway.calls}',
        );
        expect(captured, contains(2));
        expect(scripts.ready, isTrue);
        expect(scripts.diagnostics, isEmpty);
        final mutationCapture = gateway.calls.indexWhere(
          (s) => s.startsWith('__pircDocument.updateLayout({"revision":2'),
        );
        final continuation = gateway.calls.indexWhere(
          (s) => s.startsWith('__pircDocument.continueAnimationFrame('),
        );
        expect(mutationCapture, greaterThanOrEqualTo(0));
        expect(continuation, greaterThan(mutationCapture));
        scripts.dispose();
        await scripts.closed;
        await tester.pump(Duration.zero);
      },
    );
  }
}
