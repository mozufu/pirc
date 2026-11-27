// Safety regressions here stay in the default suite (plans/client.md,
// Testing); the other tests are tier 3.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'support/legacy_scripts_platform.dart';

Json _snapshot({
  String html = '<html><body>snapshot</body></html>',
  int? timerDelayMs,
  List<Json> focusActions = const [],
  List<Json> formActions = const [],
  List<Json> cookieWrites = const [],
}) => {
  'html': html,
  'diagnostics': [],
  'canvases': [],
  'imageReferences': [],
  'focusActions': focusActions,
  'formActions': formActions,
  'cookieWrites': cookieWrites,
  'scheduler': {'timerDelayMs': timerDelayMs, 'animationFrame': false},
};

class _ClassicScriptsGateway extends LegacyScriptsPlatform {
  final calls = <(String, Json)>[];
  Json initResponse = {};
  final Map<int, String> sources = {};
  final Map<int, Json> finishResponses = {};
  final Map<int, Json> beginOverrides = {};
  final Map<String, PlatformException> sourceErrors = {};
  final List<Json> finishArguments = [];
  final resourceCalls = <Json>[];
  final resourceReply = Completer<Json>();
  final List<int> beginIds = [];
  final List<String> rawSources = [];
  final List<Json> snapshots = [];

  /// The cookie writes of each `cookies` call, by cookie name.
  List<List<Json>> get cookieBatches => [
    for (final (method, _, writes) in storeCalls)
      if (method == 'cookies' && (writes as List).isNotEmpty)
        [
          for (final line in writes) {'name': '$line'.split('=').first},
        ],
  ];
  int? cookieGeneration;
  Json? pumpResponse;
  Completer<Json>? beginReply;
  Completer<void>? beginStarted;
  Completer<void>? rawGate;
  Completer<void>? rawStarted;
  int _snapshotIndex = 0;
  bool _visibilitySnapshot = false;

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    calls.add((method, args));
    switch (method) {
      case 'documentScriptCapabilities':
        return {'supported': true};
      case 'documentScriptOpen':
        return {'id': 41};
      case 'documentScriptClose':
        return null;
      case 'documentScriptResource':
        resourceCalls.add(obj(args['request']));
        return resourceReply.future;
      case 'documentScriptEvaluate':
        return _evaluate(args['source'] as String);
      default:
        throw StateError('Unexpected gateway call: $method');
    }
  }

  Future<Json> _evaluate(String source) async {
    if (source == 'runtime') return {'value': ''};
    if (source.startsWith('__pircDocument.init(')) {
      cookieGeneration =
          obj(
                _arguments(source, '__pircDocument.init(')['cookieState'],
              )['generation']
              as int?;
      return _encoded(initResponse);
    }
    if (source.startsWith('__pircDocument.updateVisibility(')) {
      _visibilitySnapshot = true;
      return _encoded(_snapshot());
    }
    if (source.startsWith('__pircDocument.snapshot(')) {
      if (_visibilitySnapshot) {
        _visibilitySnapshot = false;
        final pending = pumpResponse?['classicScript'];
        return _encoded({
          ..._snapshot(timerDelayMs: pending == null ? null : 0),
          'classicScript': ?pending,
        });
      }

      if (_snapshotIndex < snapshots.length) {
        return _encoded(snapshots[_snapshotIndex++]);
      }
      return _encoded(_snapshot());
    }
    if (source.startsWith('__pircDocument.pump(')) {
      return _encoded(pumpResponse ?? _snapshot());
    }
    if (source.startsWith('__pircDocument.beginClassicScript(')) {
      final args = _arguments(source, '__pircDocument.beginClassicScript(');
      final id = args['id'] as int;
      beginIds.add(id);
      if (beginReply != null) {
        beginStarted?.complete();
        final reply = await beginReply!.future;
        return _encoded(reply);
      }
      return _encoded(
        beginOverrides[id] ?? {'id': id, 'source': sources[id] ?? ''},
      );
    }
    if (source.startsWith('__pircDocument.finishClassicScript(')) {
      final args = _arguments(source, '__pircDocument.finishClassicScript(');
      finishArguments.add(args);
      return _encoded(finishResponses[args['id']] ?? _snapshot());
    }
    if (source.startsWith('__pircDocument.syncCookies(')) {
      return {'value': ''};
    }

    rawSources.add(source);
    if (rawGate != null) {
      rawStarted?.complete();
      await rawGate!.future;
    }
    final failure = sourceErrors[source];
    if (failure != null) throw failure;
    return {'value': ''};
  }

  /// Gives each `{name}` cookie write the runtime's shape.
  Json _encoded(Json value) => {
    'value': jsonEncode({
      ...value,
      if (value['cookieWrites'] case final List writes)
        'cookieWrites': [
          for (final write in writes)
            {
              'url': 'https://example.test/',
              'line': '${obj(write)['name']}=1',
              'generation': cookieGeneration,
            },
        ],
    }),
  };

  Json _arguments(String expression, String prefix) => obj(
    jsonDecode(expression.substring(prefix.length, expression.length - 1)),
  );
}

Future<NativeDocumentScripts> _start(_ClassicScriptsGateway gateway) async {
  final scripts = NativeDocumentScripts(gateway);
  await scripts.start(
    source: '<script></script>',
    url: 'https://example.test/',
  );
  return scripts;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'runs raw classic scripts in order and merges their one-shot batches',
    (tester) async {
      final gateway = _ClassicScriptsGateway()
        ..initResponse = {
          'classicScript': {'id': 1},
          'diagnostics': [],
          'formActions': [
            {'kind': 'invalid', 'formId': 'init'},
          ],
          'cookieWrites': [
            {'name': 'init'},
          ],
        }
        ..sources[1] = 'let parityLexical = 1;'
        ..sources[2] = 'parityLexical += 1; class ParityClass {}'
        ..finishResponses[1] = {
          'classicScript': {'id': 2},
          'diagnostics': [],
          'focusActions': [
            {
              'kind': 'focus',
              'controlId': 'pirc-1',
              'preventScroll': false,
              'actionOrder': 1,
            },
          ],
          'formActions': [
            {'kind': 'invalid', 'formId': 'first'},
          ],
          'cookieWrites': [
            {'name': 'first'},
          ],
        }
        ..finishResponses[2] = {
          'diagnostics': [],
          'focusActions': [
            {
              'kind': 'blur',
              'controlId': 'pirc-2',
              'preventScroll': true,
              'actionOrder': 2,
            },
          ],
          'formActions': [
            {'kind': 'invalid', 'formId': 'second'},
          ],
          'cookieWrites': [
            {'name': 'second'},
          ],
        }
        ..snapshots.add(
          _snapshot(
            focusActions: [
              {
                'kind': 'focus',
                'controlId': 'pirc-3',
                'preventScroll': false,
                'actionOrder': 3,
              },
            ],
            formActions: [
              {'kind': 'invalid', 'formId': 'snapshot'},
            ],
            cookieWrites: [
              {'name': 'snapshot'},
            ],
          ),
        );
      final scripts = await _start(gateway);
      addTearDown(scripts.dispose);

      expect(scripts.ready, isTrue);
      expect(gateway.rawSources, [
        'let parityLexical = 1;\n;__pircDocument.endClassicScriptTurn(1);void 0;',
        'parityLexical += 1; class ParityClass {}\n;__pircDocument.endClassicScriptTurn(2);void 0;',
      ]);
      final protocolCalls = gateway.calls
          .where((call) => call.$1 == 'documentScriptEvaluate')
          .map((call) => call.$2['source'])
          .where((source) {
            final text = '$source';
            return text.startsWith('__pircDocument.beginClassicScript(') ||
                text.startsWith('__pircDocument.finishClassicScript(') ||
                text.startsWith('__pircDocument.snapshot(') ||
                gateway.rawSources.contains(source);
          })
          .toList();
      expect(protocolCalls.take(6), [
        '__pircDocument.beginClassicScript({"id":1})',
        gateway.rawSources[0],
        '__pircDocument.finishClassicScript({"id":1})',
        '__pircDocument.beginClassicScript({"id":2})',
        gateway.rawSources[1],
        '__pircDocument.finishClassicScript({"id":2})',
      ]);
      expect(protocolCalls.last, startsWith('__pircDocument.snapshot('));
      expect(scripts.content!.bodyInnerHtml, 'snapshot');
      expect(
        gateway.cookieBatches.single.map((write) => write['name']).toList(),
        ['init', 'first', 'second', 'snapshot'],
      );
      expect(scripts.formActions.map((action) => action['formId']).toList(), [
        'init',
        'first',
        'second',
        'snapshot',
      ]);
      expect(
        scripts.focusActions.map((action) => action['actionOrder']).toList(),
        [1, 2, 3],
      );
    },
    tags: ['tier3'],
  );

  testWidgets('drains a classic script discovered by a snapshot', (
    tester,
  ) async {
    final gateway = _ClassicScriptsGateway()
      ..initResponse = {'diagnostics': []}
      ..sources[1] = 'globalThis.dynamicClassic = true;'
      ..finishResponses[1] = {
        'diagnostics': [],
        'formActions': [
          {'kind': 'invalid', 'formId': 'finished'},
        ],
      }
      ..snapshots.addAll([
        {
          ..._snapshot(
            html: '<html><body>before dynamic classic</body></html>',
            formActions: [
              {'kind': 'invalid', 'formId': 'snapshot-before'},
            ],
          ),
          'classicScript': {'id': 1},
        },
        _snapshot(
          html: '<html><body>after dynamic classic</body></html>',
          formActions: [
            {'kind': 'invalid', 'formId': 'snapshot-after'},
          ],
        ),
      ]);
    final scripts = await _start(gateway);
    addTearDown(scripts.dispose);

    expect(gateway.rawSources, hasLength(1));
    expect(gateway.snapshots, hasLength(2));
    expect(scripts.content!.bodyInnerHtml, 'after dynamic classic');
    expect(scripts.formActions.map((action) => action['formId']).toList(), [
      'snapshot-before',
      'finished',
      'snapshot-after',
    ]);
  }, tags: ['tier3']);

  testWidgets('a script evaluation error is reported and parsing continues', (
    tester,
  ) async {
    final gateway = _ClassicScriptsGateway()
      ..initResponse = {
        'classicScript': {'id': 1},
        'diagnostics': [],
      }
      ..sources[1] = 'throw new Error("ordinary");'
      ..sources[2] = 'globalThis.afterError = true;'
      ..finishResponses[1] = {
        'classicScript': {'id': 2},
        'diagnostics': [],
      }
      ..finishResponses[2] = _snapshot();
    gateway.sourceErrors['throw new Error("ordinary");\n;__pircDocument.endClassicScriptTurn(1);void 0;'] =
        PlatformException(
          code: 'SCRIPT_EVALUATION',
          message: 'ordinary JS error',
        );
    final scripts = await _start(gateway);
    addTearDown(scripts.dispose);

    expect(scripts.ready, isTrue);
    expect(gateway.rawSources, [
      'throw new Error("ordinary");\n;__pircDocument.endClassicScriptTurn(1);void 0;',
      'void 0;',
      'globalThis.afterError = true;\n;__pircDocument.endClassicScriptTurn(2);void 0;',
    ]);
    expect(gateway.finishArguments.first['error'], 'ordinary JS error');
    expect(gateway.beginIds, [1, 2]);
    final errorIndex = gateway.calls.indexWhere(
      (call) =>
          call.$1 == 'documentScriptEvaluate' &&
          call.$2['source'] == gateway.rawSources[0],
    );
    final checkpointIndex = gateway.calls.indexWhere(
      (call) =>
          call.$1 == 'documentScriptEvaluate' && call.$2['source'] == 'void 0;',
    );
    final finishIndex = gateway.calls.indexWhere(
      (call) =>
          call.$1 == 'documentScriptEvaluate' &&
          '${call.$2['source']}'.startsWith(
            '__pircDocument.finishClassicScript(',
          ),
    );
    expect(errorIndex, lessThan(checkpointIndex));
    expect(checkpointIndex, lessThan(finishIndex));
  }, tags: ['tier3']);

  testWidgets('an engine error during the error checkpoint stays fatal', (
    tester,
  ) async {
    final gateway = _ClassicScriptsGateway()
      ..initResponse = {
        'classicScript': {'id': 1},
        'diagnostics': [],
      }
      ..sources[1] = 'throw new Error("ordinary");'
      ..finishResponses[1] = _snapshot();
    gateway
      ..sourceErrors['throw new Error("ordinary");\n;__pircDocument.endClassicScriptTurn(1);void 0;'] =
          PlatformException(code: 'SCRIPT_EVALUATION', message: 'ordinary')
      ..sourceErrors['void 0;'] = PlatformException(
        code: 'SCRIPT_ENGINE',
        message: 'checkpoint failed',
      );
    final scripts = await _start(gateway);
    addTearDown(scripts.dispose);

    expect(scripts.ready, isFalse);
    expect(gateway.finishArguments, isEmpty);
    expect(gateway.rawSources, hasLength(2));
  }, tags: ['tier3']);

  testWidgets('a timeout during source evaluation remains fatal', (
    tester,
  ) async {
    final gateway = _ClassicScriptsGateway()
      ..initResponse = {
        'classicScript': {'id': 1},
        'diagnostics': [],
      }
      ..sources[1] = 'globalThis.neverContinues = true;'
      ..finishResponses[1] = _snapshot();
    gateway.sourceErrors['globalThis.neverContinues = true;\n;__pircDocument.endClassicScriptTurn(1);void 0;'] =
        PlatformException(code: 'SCRIPT_TIMEOUT', message: 'engine timeout');
    final scripts = await _start(gateway);
    addTearDown(scripts.dispose);

    expect(scripts.ready, isFalse);
    expect(scripts.diagnostics.single, contains('engine timeout'));
    expect(gateway.finishArguments, isEmpty);
    expect(gateway.calls.last.$1, 'documentScriptClose');
  }, tags: ['tier3']);

  testWidgets('invalid and repeated script descriptors are rejected', (
    tester,
  ) async {
    final malformed = _ClassicScriptsGateway()
      ..initResponse = {
        'classicScript': {'id': 0},
        'diagnostics': [],
      };
    final malformedScripts = await _start(malformed);
    addTearDown(malformedScripts.dispose);
    expect(malformedScripts.ready, isFalse);
    expect(malformed.beginIds, isEmpty);

    final repeated = _ClassicScriptsGateway()
      ..initResponse = {
        'classicScript': {'id': 1},
        'diagnostics': [],
      }
      ..sources[1] = 'globalThis.once = true;'
      ..finishResponses[1] = {
        'classicScript': {'id': 1},
        'diagnostics': [],
      };
    final repeatedScripts = await _start(repeated);
    addTearDown(repeatedScripts.dispose);
    expect(repeatedScripts.ready, isFalse);
    expect(repeated.rawSources, hasLength(1));

    final badSource = _ClassicScriptsGateway()
      ..initResponse = {
        'classicScript': {'id': 1},
        'diagnostics': [],
      }
      ..beginOverrides[1] = {'id': 1, 'source': 42};
    final badSourceScripts = await _start(badSource);
    addTearDown(badSourceScripts.dispose);
    expect(badSourceScripts.ready, isFalse);
    expect(badSource.rawSources, isEmpty);
  });

  testWidgets('oversized source including the epilog is rejected', (
    tester,
  ) async {
    const epilog = '\n;__pircDocument.endClassicScriptTurn(1);void 0;';
    final source = 'a' * (4 * 1024 * 1024 - epilog.length + 1);
    final gateway = _ClassicScriptsGateway()
      ..initResponse = {
        'classicScript': {'id': 1},
        'diagnostics': [],
      }
      ..sources[1] = source;
    final scripts = await _start(gateway);
    addTearDown(scripts.dispose);

    expect(scripts.ready, isFalse);
    expect(gateway.rawSources, isEmpty);
  });

  testWidgets('disposal during a raw script prevents later source evaluation', (
    tester,
  ) async {
    final gateway = _ClassicScriptsGateway()
      ..initResponse = {
        'classicScript': {'id': 1},
        'diagnostics': [],
      }
      ..sources[1] = 'globalThis.beforeDispose = true;'
      ..sources[2] = 'globalThis.afterDispose = true;'
      ..finishResponses[1] = {
        'classicScript': {'id': 2},
        'diagnostics': [],
      }
      ..rawGate = Completer<void>()
      ..rawStarted = Completer<void>();
    final scripts = NativeDocumentScripts(gateway);
    final starting = scripts.start(
      source: '<script></script>',
      url: 'https://example.test/',
    );
    await gateway.rawStarted!.future;
    scripts.dispose();
    gateway.rawGate!.complete();
    await starting;

    expect(gateway.rawSources, hasLength(1));
    expect(gateway.finishArguments, isEmpty);
    expect(gateway.beginIds, [1]);
  });

  testWidgets(
    'classic script draining yields after 128 tasks to the scheduler',
    (tester) async {
      final gateway = _ClassicScriptsGateway()
        ..initResponse = {
          'classicScript': {'id': 1},
          'diagnostics': [],
        }
        ..pumpResponse = {
          'classicScript': {'id': 129},
          'diagnostics': [],
        };
      for (var id = 1; id <= 129; id++) {
        gateway.sources[id] = 'globalThis.script$id = true;';
        gateway.finishResponses[id] = id == 128
            ? {
                'classicScript': {'id': 129},
                ..._snapshot(timerDelayMs: 0),
              }
            : {
                'classicScript': {'id': id + 1},
                'diagnostics': [],
              };
      }
      gateway.finishResponses[129] = _snapshot();
      final scripts = await _start(gateway);
      addTearDown(scripts.dispose);

      expect(gateway.rawSources, hasLength(128));
      expect(gateway.beginIds.last, 128);
      expect(
        gateway.calls.where(
          (call) =>
              call.$1 == 'documentScriptEvaluate' &&
              '${call.$2['source']}'.startsWith('__pircDocument.snapshot('),
        ),
        isEmpty,
      );

      await tester.pump(const Duration(milliseconds: 20));
      expect(scripts.diagnostics, isEmpty);
      expect(gateway.rawSources, hasLength(129));
      expect(gateway.beginIds.last, 129);
    },
    tags: ['tier3'],
  );

  testWidgets(
    'a stale activity change after begin prevents source evaluation',
    (tester) async {
      final gateway = _ClassicScriptsGateway()
        ..initResponse = {
          'classicScript': {'id': 1},
          'diagnostics': [],
        }
        ..sources[1] = 'globalThis.mustStayPaused = true;'
        ..beginReply = Completer<Json>()
        ..beginStarted = Completer<void>();
      final scripts = NativeDocumentScripts(gateway);
      final starting = scripts.start(
        source: '<script></script>',
        url: 'https://example.test/',
      );
      await gateway.beginStarted!.future;
      scripts.setActivity(attached: false, visible: false);
      gateway.beginReply!.complete({'id': 1, 'source': gateway.sources[1]});
      await starting;
      addTearDown(scripts.dispose);

      expect(gateway.rawSources, isEmpty);
      expect(gateway.finishArguments, isEmpty);
    },
  );
  testWidgets(
    'lifecycle pause retains drained requests and cookie writes for resume',
    (tester) async {
      final gateway = _ClassicScriptsGateway()
        ..initResponse = {
          ..._snapshot(timerDelayMs: 0),
          'classicScript': {'id': 1},
          'resourceRequests': [
            {
              'id': 'fetch-1',
              'kind': 'fetch',
              'url': 'https://example.test/data',
            },
          ],
          'cookieWrites': [
            {'name': 'before-pause'},
          ],
        }
        ..sources[1] = 'globalThis.resumed = true;'
        ..pumpResponse = {
          ..._snapshot(),
          'classicScript': {'id': 1},
        }
        ..beginReply = Completer<Json>()
        ..beginStarted = Completer<void>();
      final scripts = NativeDocumentScripts(gateway);
      addTearDown(scripts.dispose);
      final starting = scripts.start(
        source: '<script></script>',
        url: 'https://example.test/',
      );
      await gateway.beginStarted!.future;
      scripts.setActivity(attached: false, visible: false);
      gateway.beginReply!.complete({'id': 1, 'source': gateway.sources[1]});
      await starting;
      expect(scripts.ready, isTrue);
      expect(gateway.rawSources, isEmpty);
      expect(gateway.resourceCalls, isEmpty);
      expect(gateway.cookieBatches.expand((batch) => batch).toList(), [
        {'name': 'before-pause'},
      ]);
      gateway.beginReply = null;
      scripts.setActivity(attached: true, visible: true);
      await tester.pump(const Duration(milliseconds: 20));
      expect(gateway.resourceCalls.map((r) => r['id']), ['fetch-1']);
      expect(gateway.beginIds, [1, 1]);
      expect(gateway.rawSources.single, contains('globalThis.resumed = true;'));
      expect(scripts.diagnostics, isEmpty);
      scripts.dispose();
      gateway.resourceReply.complete({
        'status': 200,
        'url': 'https://example.test/data',
        'bodyBytes': <int>[],
      });
      await tester.pump();
    },
    tags: ['tier3'],
  );
  testWidgets('hidden current documents still run parser Scripts', (
    tester,
  ) async {
    final gateway = _ClassicScriptsGateway()
      ..initResponse = {
        ..._snapshot(),
        'classicScript': {'id': 1},
      }
      ..sources[1] = 'let hiddenGlobal=1;'
      ..finishResponses[1] = {
        ..._snapshot(),
        'classicScript': {'id': 2},
      }
      ..sources[2] = 'hiddenGlobal++;';
    final scripts = NativeDocumentScripts(gateway);
    addTearDown(scripts.dispose);
    scripts.setActivity(attached: true, visible: false);
    await scripts.start(
      source: '<script></script>',
      url: 'https://example.test/',
    );
    expect(scripts.ready, isTrue);
    expect(scripts.diagnostics, isEmpty);
    expect(gateway.beginIds, [1, 2]);
    expect(gateway.rawSources, hasLength(2));
  }, tags: ['tier3']);
}
