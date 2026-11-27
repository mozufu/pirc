// Safety regressions here stay in the default suite (plans/client.md,
// Testing); the other tests are tier 3.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'support/legacy_scripts_platform.dart';

class ScriptsGateway extends LegacyScriptsPlatform {
  final calls = <(String, Json)>[];
  Completer<dynamic>? opening;
  Completer<dynamic>? evaluation;
  bool supported = true, fail = false, failInit = false;
  bool fatalClick = false, failClickSnapshot = false;
  int clicks = 0;
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    calls.add((method, args));
    switch (method) {
      case 'documentScriptCapabilities':
        return {'supported': supported, 'reason': 'engine unavailable'};
      case 'documentScriptOpen':
        return opening?.future ?? {'id': 1};
      case 'documentScriptEvaluate':
        if (fail) {
          throw PlatformException(code: 'SCRIPT_TIMEOUT', message: 'timeout');
        }
        if (evaluation != null) return evaluation!.future;
        if (failInit && '${args['source']}'.startsWith('__pircDocument.init')) {
          return {
            'value': jsonEncode({
              'html': '',
              'diagnostics': [
                {'code': 'runtime.input_limit', 'message': 'source too large'},
              ],
            }),
          };
        }
        final click = '${args['source']}'.startsWith('__pircDocument.dispatch');
        if (click) clicks++;
        if (failClickSnapshot &&
            clicks > 0 &&
            '${args['source']}'.startsWith('__pircDocument.snapshot')) {
          throw PlatformException(
            code: 'SCRIPT_TIMEOUT',
            message: 'snapshot timeout',
          );
        }
        return {
          'value': jsonEncode({
            'html': '<html><body>你好 $clicks</body></html>',
            'diagnostics': click && fatalClick
                ? [
                    {
                      'code': 'runtime.output_limit',
                      'message': 'output too large',
                    },
                  ]
                : [],
            'defaultPrevented': click,
          }),
        };
      case 'documentScriptClose':
        return null;
      default:
        throw StateError(method);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'initializes once and serializes events with persistent document owner',
    () async {
      final g = ScriptsGateway();
      final state = NativeDocumentScripts(g);
      await state.start(
        source: '<script>1</script>',
        url: 'https://example.test/',
      );
      expect(state.ready, true);
      expect(state.content!.bodyInnerHtml, '你好 0');
      await state.start(source: 'other', url: 'other');
      expect(g.calls.where((c) => c.$1 == 'documentScriptOpen'), hasLength(1));
      expect(
        await Future.wait([
          state.click('a', [
            {'id': 'input', 'value': '新值'},
          ]),
          state.click('b', []),
        ]),
        [true, true],
      );
      expect(state.content!.bodyInnerHtml, '你好 2');
      final evaluations = g.calls
          .where((c) => c.$1 == 'documentScriptEvaluate')
          .toList();
      expect(evaluations.last.$2['owner'], evaluations.first.$2['owner']);
      expect(
        evaluations
            .firstWhere(
              (call) =>
                  '${call.$2['source']}'.startsWith('__pircDocument.dispatch'),
            )
            .$2['source'],
        contains('新值'),
      );
      state.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(g.calls.last.$1, 'documentScriptClose');
    },
    tags: ['tier3'],
  );
  for (final fatalFirst in [true, false]) {
    test(
      'canceled default survives ${fatalFirst ? 'fatal first response' : 'failed follow-up snapshot'}',
      () async {
        final g = ScriptsGateway();
        final state = NativeDocumentScripts(g);
        await state.start(source: '', url: 'https://example.test/');
        g.fatalClick = fatalFirst;
        g.failClickSnapshot = !fatalFirst;
        expect(await state.dispatch('form', 'submit', []), true);
        expect(state.ready, false);
        expect(state.content!.bodyInnerHtml, '你好 0');
        expect(
          state.diagnostics.single,
          contains(fatalFirst ? 'output too large' : 'snapshot timeout'),
        );
        expect(g.calls.last.$1, 'documentScriptClose');
        state.dispose();
      },
      tags: ['tier3'],
    );
  }
  test(
    'fatal first response is retained without a follow-up snapshot',
    () async {
      final g = ScriptsGateway()..failInit = true;
      final state = NativeDocumentScripts(g);
      await state.start(source: '', url: 'https://example.test/');
      expect(state.ready, false);
      expect(state.content, isNull);
      expect(state.diagnostics.single, contains('source too large'));
      expect(
        g.calls.where(
          (c) => '${c.$2['source']}'.startsWith('__pircDocument.snapshot'),
        ),
        isEmpty,
      );
      expect(g.calls.last.$1, 'documentScriptClose');
      state.dispose();
    },
    tags: ['tier3'],
  );
  test(
    'queued events publish only the final snapshot and include submitter',
    () async {
      final g = ScriptsGateway();
      final state = NativeDocumentScripts(g);
      await state.start(source: '', url: 'https://example.test/');
      var notifications = 0;
      state.addListener(() => notifications++);
      await Future.wait([
        state.dispatch('field', 'input', [
          {'id': 'field', 'value': 'a'},
        ]),
        state.dispatch('field', 'change', [
          {'id': 'field', 'value': 'ab'},
        ]),
        state.dispatch('form', 'submit', [], submitter: 'send'),
      ]);
      expect(notifications, 1);
      expect(state.content!.bodyInnerHtml, '你好 3');
      expect(
        g.calls
            .lastWhere(
              (call) =>
                  '${call.$2['source']}'.startsWith('__pircDocument.dispatch'),
            )
            .$2['source'],
        contains('"submitter":"send"'),
      );
      state.dispose();
    },
    tags: ['tier3'],
  );
  test(
    'queued detailed metadata keeps the value captured at dispatch',
    () async {
      final g = ScriptsGateway();
      final state = NativeDocumentScripts(g);
      await state.start(source: '', url: 'https://example.test/');
      final data = <String, dynamic>{'key': 'Enter', 'isComposing': false};
      final pending = state.dispatchDetailed('field', 'keydown', [], data);
      data['key'] = 'Escape';
      expect(await pending, true);
      final source = g.calls
          .lastWhere(
            (c) => '${c.$2['source']}'.startsWith('__pircDocument.dispatch'),
          )
          .$2['source'];
      expect(
        source,
        contains('"eventData":{"key":"Enter","isComposing":false}'),
      );
      state.dispose();
    },
    tags: ['tier3'],
  );
  test('failed queue publishes diagnostics after skipped events', () async {
    final g = ScriptsGateway();
    final state = NativeDocumentScripts(g);
    await state.start(source: '', url: 'https://example.test/');
    var notifications = 0;
    state.addListener(() => notifications++);
    g.fail = true;
    expect(
      await Future.wait([
        state.dispatch('a', 'input', []),
        state.dispatch('a', 'change', []),
      ]),
      [false, false],
    );
    expect(notifications, 1);
    expect(state.ready, false);
    expect(state.diagnostics.single, contains('timeout'));
    state.dispose();
  }, tags: ['tier3']);
  test('late open is closed when document leaves history', () async {
    final g = ScriptsGateway()..opening = Completer();
    final state = NativeDocumentScripts(g);
    final starting = state.start(source: '', url: 'https://example.test/');
    await Future<void>.delayed(Duration.zero);
    state.dispose();
    g.opening!.complete({'id': 17});
    await starting;
    expect(g.calls.last.$1, 'documentScriptClose');
    expect(g.calls.last.$2['id'], 17);
    expect(g.calls.where((c) => c.$1 == 'documentScriptEvaluate'), isEmpty);
  });
  test(
    'unsupported engine retains readable source and gives diagnostic',
    () async {
      final g = ScriptsGateway()..supported = false;
      final state = NativeDocumentScripts(g);
      await state.start(
        source: '<p>Readable</p>',
        url: 'https://example.test/',
      );
      expect(state.ready, false);
      expect(state.content, isNull);
      expect(state.diagnostics.single, contains('engine unavailable'));
      expect(g.calls, hasLength(1));
      state.dispose();
    },
    tags: ['tier3'],
  );
  test(
    'failed event keeps last good snapshot, closes environment and preserves default',
    () async {
      final g = ScriptsGateway();
      final state = NativeDocumentScripts(g);
      await state.start(source: '', url: 'https://example.test/');
      g.fail = true;
      expect(await state.click('a', []), false);
      expect(state.content!.bodyInnerHtml, '你好 0');
      expect(state.ready, false);
      expect(state.diagnostics.single, contains('timeout'));
      expect(g.calls.last.$1, 'documentScriptClose');
      state.dispose();
    },
    tags: ['tier3'],
  );
  test(
    'disposed in-flight event cannot change content or report success',
    () async {
      final g = ScriptsGateway();
      final state = NativeDocumentScripts(g);
      await state.start(source: '', url: 'https://example.test/');
      g.evaluation = Completer();
      final click = state.click('a', []);
      await Future<void>.delayed(Duration.zero);
      state.dispose();
      g.evaluation!.complete({
        'value': jsonEncode({'html': '<body>stale</body>'}),
      });
      expect(await click, true);
      expect(state.content!.bodyInnerHtml, '你好 0');
    },
  );
}
