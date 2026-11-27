@Tags(['tier3'])
library;

import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'support/legacy_scripts_platform.dart';
import 'document_scripts_test.dart' show ScriptsGateway;

class FormActionGateway extends ScriptsGateway {
  List<Json> initial = [], followup = [];
  bool handled = false;
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    final result = await super.call(method, args);
    if (method != 'documentScriptEvaluate') return result;
    final decoded = obj(jsonDecode(result['value'] as String));
    final source = '${args['source']}';
    final snapshot = source.startsWith('__pircDocument.snapshot');
    final dispatch = source.startsWith('__pircDocument.dispatch');
    final init = source.startsWith('__pircDocument.init');
    decoded['formActions'] = snapshot
        ? followup
        : (dispatch || init ? initial : []);
    if (snapshot) followup = [];
    if (dispatch || init) initial = [];
    decoded['defaultPrevented'] = false;
    decoded['defaultHandled'] = dispatch && handled;
    return {'value': jsonEncode(decoded)};
  }
}

Json submission(String value) => {
  'kind': 'submit',
  'formId': 'form',
  'action': '/save',
  'entries': [
    {'name': 'value', 'value': value},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'initial and microtask commands coalesce and are consumed once',
    () async {
      final gateway = FormActionGateway()
        ..initial = [submission('initial')]
        ..followup = [submission('microtask')];
      final scripts = NativeDocumentScripts(gateway);
      addTearDown(scripts.dispose);
      await scripts.start(source: '', url: 'https://example.test/');
      expect(scripts.formActions, hasLength(1));
      expect(scripts.formActions.single['entries'], [
        {'name': 'value', 'value': 'microtask'},
      ]);
      final sequence = scripts.formActions.single['sequence'] as int;
      scripts.acknowledgeFormActions([sequence]);
      await scripts.click('button', []);
      expect(scripts.formActions, isEmpty);
    },
  );

  test(
    'handled submit default blocks native repeat without pretending click cancellation',
    () async {
      final gateway = FormActionGateway();
      final scripts = NativeDocumentScripts(gateway);
      addTearDown(scripts.dispose);
      await scripts.start(source: '', url: 'https://example.test/');
      gateway.handled = true;
      gateway.initial = [submission('captured')];
      gateway.followup = [
        {
          'kind': 'invalid',
          'formId': 'form',
          'controlId': 'field',
          'message': 'Required',
        },
      ];
      expect(await scripts.click('button', []), true);
      expect(scripts.formActions.map((a) => a['kind']), ['submit', 'invalid']);
      scripts.setActivity(attached: false, visible: false);
      expect(scripts.formActions, isEmpty);
    },
  );

  test('a replaced or detached painted command cannot be consumed', () async {
    final gateway = FormActionGateway();
    final scripts = NativeDocumentScripts(gateway);
    addTearDown(scripts.dispose);
    await scripts.start(source: '', url: 'https://example.test/');
    gateway.initial = [submission('old')];
    await scripts.click('button', []);
    final old = scripts.formActions.single['sequence'] as int;
    gateway.initial = [submission('new')];
    await scripts.click('button', []);
    final latest = scripts.formActions.single['sequence'] as int;
    expect(scripts.takeFormActions([old]), isEmpty);
    expect(scripts.formActions, hasLength(1));
    expect(scripts.takeFormActions([latest]).single['entries'], [
      {'name': 'value', 'value': 'new'},
    ]);
    expect(scripts.takeFormActions([latest]), isEmpty);
    gateway.initial = [submission('blocked history')];
    await scripts.click('button', []);
    final pending = scripts.formActions.single['sequence'] as int;
    scripts.setActivity(attached: false, visible: false);
    expect(scripts.takeFormActions([pending]), isEmpty);
  });

  test(
    'detached in-flight document cannot enqueue navigation on return',
    () async {
      final gateway = FormActionGateway();
      final scripts = NativeDocumentScripts(gateway);
      addTearDown(scripts.dispose);
      await scripts.start(source: '', url: 'https://example.test/');
      gateway.initial = [submission('old page')];
      final pending = Completer<dynamic>();
      gateway.evaluation = pending;
      final click = scripts.click('button', []);
      await Future<void>.delayed(Duration.zero);
      scripts.setActivity(attached: false, visible: false);
      scripts.setActivity(attached: true, visible: true);
      gateway.evaluation = null;
      pending.complete({
        'value': jsonEncode({
          'html': '<html><body>old page</body></html>',
          'diagnostics': [],
        }),
      });
      await click;
      scripts.setActivity(attached: true, visible: true);
      expect(scripts.formActions, isEmpty);
    },
  );

  test(
    'failed follow-up snapshot never commits initial submission command',
    () async {
      final gateway = FormActionGateway();
      final scripts = NativeDocumentScripts(gateway);
      addTearDown(scripts.dispose);
      await scripts.start(source: '', url: 'https://example.test/');
      gateway.initial = [submission('uncertain')];
      gateway.handled = true;
      gateway.failClickSnapshot = true;
      expect(await scripts.click('button', []), true);
      expect(scripts.formActions, isEmpty);
      expect(scripts.ready, false);
    },
  );
}
