@Tags(['tier3'])
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'package:pirc_render_document/src/document_environment.dart';
import 'support/legacy_scripts_platform.dart';

class _Gateway extends LegacyScriptsPlatform {
  int revision = 1;
  bool requiredLayout = true, pendingScript = true;
  int rejectLayoutPackets = 0;
  bool lastLayoutAccepted = false;
  final calls = <String>[];
  List<Json> pendingActions = [];
  List<Json> pendingScroll = [];
  Completer<void>? historyEntered, historyRelease;
  Json snapshot() => {
    'html':
        '<html><body><div data-pirc-script-id="pirc-1">revision $revision</div></body></html>',
    'layout': {
      'revision': revision,
      'required': requiredLayout,
      'ids': ['pirc-1'],
    },
    'classicScript': pendingScript ? {'id': 1} : null,
    'diagnostics': [],
    'canvases': [],
    'imageReferences': [],
    'scheduler': {'timerDelayMs': null, 'animationFrame': false},
    'layoutAccepted': lastLayoutAccepted,
    'formActions': [for (final action in pendingActions) action],
    'scrollActions': [...pendingScroll],
  };
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'documentScriptCapabilities') return {'supported': true};
    if (method == 'documentScriptOpen') return {'id': 1};
    if (method == 'documentScriptClose') return null;
    if (method != 'documentScriptEvaluate') throw StateError(method);
    final source = args['source'] as String;
    calls.add(source);
    if (source.startsWith('__pircDocument.updateHistory(') &&
        historyRelease != null) {
      if (historyEntered?.isCompleted == false) historyEntered!.complete();
      await historyRelease!.future;
    }
    if (source == 'runtime') return {'value': ''};
    if (source.startsWith('__pircDocument.beginClassicScript(')) {
      return {
        'value': jsonEncode({'id': 1, 'source': 'var measured = true;'}),
      };
    }
    if (source.startsWith('var measured = true;')) return {'value': ''};
    if (source.startsWith('__pircDocument.finishClassicScript(')) {
      revision++;
      requiredLayout = true;
      pendingScript = false;
    }
    if (source.startsWith('__pircDocument.updateLayout(')) {
      lastLayoutAccepted = rejectLayoutPackets == 0;
      if (rejectLayoutPackets > 0) rejectLayoutPackets--;
      requiredLayout = !lastLayoutAccepted;
    }
    final result = snapshot();
    pendingActions = [];
    pendingScroll = [];
    return {'value': jsonEncode(result)};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Json scroll(int id, {String kind = 'to', num? y = 120}) => {
    'actionId': id,
    'kind': kind,
    'x': null,
    'y': y,
    'behavior': 'instant',
  };
  for (final closeDuringStartup in [false, true]) {
    test(
      closeDuringStartup
          ? 'closing startup cancels an early tap without dispatching into a closed VM'
          : 'visible startup controls queue a tap until initialization completes',
      () async {
        final gateway = _Gateway()..pendingScript = false;
        final scripts = NativeDocumentScripts(gateway);
        addTearDown(() async {
          scripts.dispose();
          await scripts.closed;
        });
        final entered = Completer<void>();
        final frame = Completer<Json?>();
        scripts.bindLayout(Object(), (revision, generation) {
          if (generation == 1) {
            entered.complete();
            return frame.future;
          }
          return Future.value({'revision': revision, 'generation': generation});
        });
        final startup = scripts.start(
          source: '<button>Early tap</button><script></script>',
          url: 'https://example.test/',
        );
        await entered.future;
        expect(scripts.loading, isTrue);
        expect(scripts.ready, isFalse);
        expect(
          scripts.content,
          isNotNull,
          reason: 'The DOM is already visible.',
        );
        final tap = scripts.dispatch('pirc-1', 'click', const []);
        await Future<void>.delayed(Duration.zero);
        expect(
          gateway.calls.where((s) => s.startsWith('__pircDocument.dispatch(')),
          isEmpty,
        );
        if (closeDuringStartup) {
          scripts.dispose();
        } else {
          frame.complete({'revision': 1, 'generation': 1});
        }
        await startup;
        await tap;
        expect(
          gateway.calls.where((s) => s.startsWith('__pircDocument.dispatch(')),
          hasLength(closeDuringStartup ? 0 : 1),
        );
        if (!closeDuringStartup) {
          expect(scripts.ready, isTrue);
        }
      },
    );
  }

  test('suspending startup cancels a queued visible control tap', () async {
    final gateway = _Gateway()..pendingScript = false;
    final scripts = NativeDocumentScripts(gateway);
    addTearDown(() async {
      scripts.dispose();
      await scripts.closed;
    });
    final entered = Completer<void>();
    final frame = Completer<Json?>();
    scripts.bindLayout(Object(), (revision, generation) {
      if (!entered.isCompleted) entered.complete();
      return frame.future;
    });
    final startup = scripts.start(
      source: '<script></script>',
      url: 'https://example.test/',
    );
    await entered.future;
    final tap = scripts.dispatch('pirc-1', 'click', const []);
    await Future<void>.delayed(Duration.zero);
    scripts.setActivity(attached: false, visible: false);
    await startup;
    expect(await tap, isTrue);
    expect(
      gateway.calls.where((s) => s.startsWith('__pircDocument.dispatch(')),
      isEmpty,
    );
  });

  test(
    'a no-op layout refresh flushes native work queued by the preceding event',
    () async {
      final gateway = _Gateway()..pendingScript = false;
      final scripts = NativeDocumentScripts(gateway);
      addTearDown(() async {
        scripts.dispose();
        await scripts.closed;
      });
      scripts.bindLayout(
        Object(),
        (revision, generation) async => {
          'revision': revision,
          'generation': generation,
        },
      );
      await scripts.start(
        source: '<script></script>',
        url: 'https://example.test/',
      );
      final delivered = Completer<void>();
      scripts.addListener(() {
        if (scripts.scrollActions.isNotEmpty && !delivered.isCompleted) {
          delivered.complete();
        }
      });
      gateway.pendingScroll = [scroll(1)];
      final click = scripts.dispatch('pirc-1', 'click', const []);
      scripts.refreshLayout();
      await click;
      await delivered.future.timeout(const Duration(seconds: 2));
      expect(scripts.takeScrollActions().map((a) => a['actionId']), [1]);
    },
  );

  test('matching History snapshots wait for queued VM publication', () async {
    final gateway = _Gateway()..pendingScript = false;
    final scripts = NativeDocumentScripts(gateway);
    addTearDown(() async {
      scripts.dispose();
      await scripts.closed;
    });
    await scripts.start(
      source: '<div>Page</div>',
      url: 'https://example.test/',
    );
    gateway.historyEntered = Completer<void>();
    gateway.historyRelease = Completer<void>();
    final snapshot = <String, dynamic>{
      'url': 'https://example.test/#one',
      'entryKey': 'entry-1',
      'index': 0,
      'length': 1,
    };
    final first = scripts.updateHistory(snapshot);
    await gateway.historyEntered!.future;
    var published = false;
    final duplicate = scripts.updateHistory(snapshot).then((_) {
      published = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(published, isFalse);
    gateway.historyRelease!.complete();
    await first;
    await duplicate;
    expect(published, isTrue);
    expect(
      gateway.calls.where((s) => s.startsWith('__pircDocument.updateHistory(')),
      hasLength(1),
    );
  });

  test('native scroll events acknowledge only accepted captures', () async {
    final gateway = _Gateway()
      ..pendingScript = false
      ..rejectLayoutPackets = 1;
    final scripts = NativeDocumentScripts(gateway);
    addTearDown(() async {
      scripts.dispose();
      await scripts.closed;
    });
    final accepted = <int>[];
    scripts.bindLayout(
      Object(),
      (revision, generation) async => {
        'revision': revision,
        'generation': generation,
        'scrollEvents': [
          {'id': 'pirc-1', 'sequence': 42},
        ],
      },
      onAccepted: (packet) => accepted.add(packet['generation'] as int),
    );
    await scripts.start(
      source: '<script></script>',
      url: 'https://example.test/',
    );
    expect(scripts.ready, isTrue, reason: scripts.diagnostics.join('\n'));
    expect(accepted, [2]);
  });

  test(
    'scroll commands survive layout barriers, consume once and freeze safely',
    () async {
      final gateway = _Gateway()
        ..pendingScroll = [scroll(1), scroll(2, kind: 'by', y: 40)];
      final scripts = NativeDocumentScripts(gateway);
      addTearDown(() async {
        scripts.dispose();
        await scripts.closed;
      });
      scripts.bindLayout(
        Object(),
        (revision, generation) async => {
          'revision': revision,
          'generation': generation,
        },
      );
      await scripts.start(
        source: '<script></script>',
        url: 'https://example.test/',
      );
      expect(scripts.ready, isTrue, reason: scripts.diagnostics.join('\n'));
      expect(scripts.resolvedScrollActionId, 0);
      expect(scripts.takeScrollActions().map((a) => a['actionId']), [1, 2]);
      expect(scripts.resolvedScrollActionId, 2);
      expect(scripts.takeScrollActions(), isEmpty);
      gateway.pendingScroll = [scroll(3)];
      await scripts.dispatch('pirc-1', 'click', const []);
      expect(scripts.scrollActions, hasLength(1));
      expect(scripts.resolvedScrollActionId, 2);
      scripts.setActivity(attached: false, visible: false);
      expect(scripts.resolvedScrollActionId, 3);
      expect(scripts.takeScrollActions(), isEmpty);
      scripts.setActivity(attached: true, visible: true);
      expect(scripts.takeScrollActions(), isEmpty);
    },
  );

  for (final invalid in [
    {...scroll(1), 'elementId': null},
    {...scroll(1), 'elementId': 'foreign-id'},
    scroll(0),
    {...scroll(1), 'behavior': 'invalid'},
    {...scroll(1), 'y': '120'},
    {...scroll(1), 'actionId': 9007199254740992},
  ]) {
    test('invalid native scroll command is rejected: $invalid', () async {
      final gateway = _Gateway()
        ..pendingScroll = [invalid]
        ..pendingScript = false;
      final scripts = NativeDocumentScripts(gateway);
      addTearDown(() async {
        scripts.dispose();
        await scripts.closed;
      });
      await scripts.start(
        source: '<script></script>',
        url: 'https://example.test/',
      );
      expect(scripts.ready, isFalse);
      expect(scripts.scrollActions, isEmpty);
    });
  }

  test('publishes each DOM revision before its raw Script runs', () async {
    final gateway = _Gateway();
    final scripts = NativeDocumentScripts(gateway);
    addTearDown(() async {
      scripts.dispose();
      await scripts.closed;
    });
    final measured = <int>[];
    scripts.bindLayout(Object(), (revision, generation) async {
      expect(scripts.content!.text, contains('revision $revision'));
      expect(scripts.layoutElementIds, {'pirc-1'});
      measured.add(revision);
      return {'revision': revision, 'generation': generation};
    });
    await scripts.start(
      source: '<script></script>',
      url: 'https://example.test/',
    );
    expect(scripts.ready, isTrue, reason: scripts.diagnostics.join('\n'));
    expect(measured, [1, 2]);
    final firstLayout = gateway.calls.indexWhere(
      (s) => s.startsWith('__pircDocument.updateLayout('),
    );
    final raw = gateway.calls.indexWhere(
      (s) => s.startsWith('var measured = true;'),
    );
    expect(firstLayout, lessThan(raw));
    expect(
      gateway.calls.where((s) => s.startsWith('var measured = true;')),
      hasLength(1),
    );
  });

  test(
    'unbinding a pending layout cancels Script execution and preserves actions',
    () async {
      final gateway = _Gateway()
        ..pendingActions = [
          {'kind': 'invalid', 'formId': 'before-wait'},
        ];
      final scripts = NativeDocumentScripts(gateway);
      addTearDown(() async {
        scripts.dispose();
        await scripts.closed;
      });
      final owner = Object(),
          entered = Completer<void>(),
          measurement = Completer<Json?>();
      scripts.bindLayout(owner, (revision, generation) {
        entered.complete();
        return measurement.future;
      });
      final start = scripts.start(
        source: '<script></script>',
        url: 'https://example.test/',
      );
      await entered.future;
      scripts.bindLayout(owner, null);
      await start;
      expect(scripts.ready, isTrue);
      expect(
        gateway.calls.where((s) => s.startsWith('var measured = true;')),
        isEmpty,
      );
      expect(scripts.formActions.map((a) => a['formId']), ['before-wait']);
      measurement.complete({'revision': 1, 'generation': 1});
      await Future<void>.delayed(Duration.zero);
      expect(
        gateway.calls.where(
          (s) => s.startsWith('__pircDocument.updateLayout('),
        ),
        isEmpty,
      );
    },
  );

  test(
    'a suspended resize commits drained actions and retries the environment after resume',
    () async {
      final gateway = _Gateway()..pendingScript = false;
      final scripts = NativeDocumentScripts(gateway);
      addTearDown(() async {
        scripts.dispose();
        await scripts.closed;
      });
      final owner = Object();
      scripts.bindLayout(
        owner,
        (revision, generation) async => {
          'revision': revision,
          'generation': generation,
        },
      );
      await scripts.start(
        source: '<script></script>',
        url: 'https://example.test/',
      );
      final entered = Completer<void>(), measurement = Completer<Json?>();
      // Rebind while attached=false, so bind itself cannot enqueue a refresh.
      scripts.setActivity(attached: false, visible: false);
      scripts.bindLayout(owner, (revision, generation) {
        if (!entered.isCompleted) entered.complete();
        return measurement.future;
      });
      gateway.pendingActions = [
        {'kind': 'invalid', 'formId': 'pre-event'},
      ];
      scripts.setActivity(attached: true, visible: true);
      final event = scripts.updateEnvironment(
        const NativeDocumentEnvironment(width: 768, height: 900),
      );
      await entered.future;
      scripts.didChangeAppLifecycleState(AppLifecycleState.paused);
      await event;
      expect(scripts.formActions.map((a) => a['formId']), ['pre-event']);
      expect(
        gateway.calls.where(
          (s) => s.startsWith('__pircDocument.updateEnvironment('),
        ),
        isEmpty,
      );
      measurement.complete(null);
      scripts.bindLayout(
        owner,
        (revision, generation) async => {
          'revision': revision,
          'generation': generation,
        },
      );
      scripts.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        gateway.calls.where(
          (s) => s.startsWith('__pircDocument.updateEnvironment('),
        ),
        hasLength(1),
      );
    },
  );
}
