@Tags(['tier3'])
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'support/legacy_scripts_platform.dart';
import 'document_scripts_test.dart' show ScriptsGateway;

class FocusGateway extends ScriptsGateway {
  List<Json> initial = [], followup = [];
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    final result = await super.call(method, args);
    if (method != 'documentScriptEvaluate') return result;
    final decoded = obj(jsonDecode(result['value'] as String));
    final source = '${args['source']}';
    final snapshot = source.startsWith('__pircDocument.snapshot');
    final action =
        source.startsWith('__pircDocument.dispatch') ||
        source.startsWith('__pircDocument.init');
    decoded['focusActions'] = snapshot
        ? followup
        : action
        ? initial
        : [];
    if (snapshot) followup = [];
    if (action) initial = [];
    decoded['defaultPrevented'] = false;
    return {'value': jsonEncode(decoded)};
  }
}

Json action(int order, {String id = 'pirc-8', String kind = 'focus'}) => {
  'kind': kind,
  'controlId': id,
  'preventScroll': true,
  'actionOrder': order,
};
Future<NativeDocumentScripts> start(FocusGateway gateway) async {
  final scripts = NativeDocumentScripts(gateway);
  await scripts.start(source: '', url: 'https://example.test/');
  return scripts;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'startup/microtask focus commands retain order and consume once',
    () async {
      final gateway = FocusGateway()
        ..initial = [action(1)]
        ..followup = [action(2, kind: 'blur'), action(3, id: 'pirc-9')];
      final scripts = await start(gateway);
      addTearDown(scripts.dispose);
      expect(scripts.ready, true);
      expect(scripts.focusActions.map((a) => a['actionOrder']), [1, 2, 3]);
      final ids = scripts.focusActions
          .map((a) => a['sequence'] as int)
          .toList();
      expect(scripts.takeFocusActions(ids).map((a) => a['kind']), [
        'focus',
        'blur',
        'focus',
      ]);
      expect(scripts.takeFocusActions(ids), isEmpty);
    },
  );
  test('new focus supersedes older unpainted commands', () async {
    final gateway = FocusGateway()..initial = [action(1)];
    final scripts = await start(gateway);
    addTearDown(scripts.dispose);
    final old = scripts.focusActions.single['sequence'] as int;
    gateway.initial = [action(2, id: 'pirc-9')];
    await scripts.dispatch('pirc-3', 'input', []);
    expect(scripts.takeFocusActions([old]), isEmpty);
    expect(scripts.focusActions.single['controlId'], 'pirc-9');
    expect(
      () => scripts.focusActions.single['kind'] = 'blur',
      throwsUnsupportedError,
    );
  });
  test('hide/detach/background invalidates painted commands', () async {
    for (final transition in ['hide', 'detach', 'background']) {
      final gateway = FocusGateway()..initial = [action(1)];
      final scripts = await start(gateway);
      final sequence = scripts.focusActions.single['sequence'] as int;
      if (transition == 'background') {
        scripts.didChangeAppLifecycleState(AppLifecycleState.inactive);
        scripts.didChangeAppLifecycleState(AppLifecycleState.resumed);
      } else {
        scripts.setActivity(attached: transition != 'detach', visible: false);
        scripts.setActivity(attached: true, visible: true);
      }
      expect(scripts.takeFocusActions([sequence]), isEmpty, reason: transition);
      scripts.dispose();
      await scripts.closed;
    }
  });
  test(
    'in-flight result cannot refocus a retired and reactivated window',
    () async {
      for (final background in [false, true]) {
        final gateway = FocusGateway();
        final scripts = await start(gateway);
        final pending = Completer<dynamic>();
        gateway.evaluation = pending;
        gateway.initial = [action(1)];
        final dispatch = scripts.dispatch('pirc-8', 'input', []);
        await Future<void>.delayed(Duration.zero);
        if (background) {
          scripts.didChangeAppLifecycleState(AppLifecycleState.inactive);
          scripts.didChangeAppLifecycleState(AppLifecycleState.resumed);
        } else {
          scripts.setActivity(attached: false, visible: false);
          scripts.setActivity(attached: true, visible: true);
        }
        gateway.evaluation = null;
        pending.complete({
          'value': jsonEncode({
            'html': '<html><body>ready</body></html>',
            'diagnostics': [],
            'defaultPrevented': false,
          }),
        });
        await dispatch;
        expect(scripts.focusActions, isEmpty);
        scripts.dispose();
        await scripts.closed;
      }
    },
  );
  test('malformed and replayed focus commands fail closed', () async {
    for (final invalid in <dynamic>[
      'not-an-action',
      {...action(1), 'controlId': 'forged'},
      {...action(1), 'kind': 'click'},
      {...action(1), 'preventScroll': 'yes'},
      {...action(1), 'actionOrder': 0},
      {...action(1), 'actionOrder': 1.5},
    ]) {
      final gateway = FocusGateway();
      // Invalid list entries are exercised through the JSON bridge directly.
      gateway.initial = [
        invalid is Map ? Map<String, dynamic>.from(invalid) : {'kind': invalid},
      ];
      final scripts = await start(gateway);
      expect(scripts.ready, false);
      expect(scripts.focusActions, isEmpty);
      scripts.dispose();
      await scripts.closed;
    }
    final gateway = FocusGateway()..initial = [action(1)];
    final scripts = await start(gateway);
    addTearDown(scripts.dispose);
    gateway.initial = [action(1)];
    await scripts.dispatch('pirc-8', 'input', []);
    expect(scripts.ready, false);
    expect(scripts.focusActions, isEmpty);
  });
  test('oversized combined batches publish no partial focus command', () async {
    final gateway = FocusGateway()
      ..initial = [for (var i = 1; i <= 128; i++) action(i)]
      ..followup = [action(129)];
    final scripts = await start(gateway);
    addTearDown(scripts.dispose);
    expect(scripts.ready, false);
    expect(scripts.focusActions, isEmpty);
  });
  test('disposed document cannot consume a focus command', () async {
    final gateway = FocusGateway()..initial = [action(1)];
    final scripts = await start(gateway);
    final id = scripts.focusActions.single['sequence'] as int;
    scripts.dispose();
    await scripts.closed;
    expect(scripts.takeFocusActions([id]), isEmpty);
  });
}
