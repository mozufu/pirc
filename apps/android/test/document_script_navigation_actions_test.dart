import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'document_navigation_widget_test.dart' show DocumentGateway, response;
import 'package:pirc_mobile/live/gateway.dart';
import 'document_scripts_test.dart' show ScriptsGateway;

class NavigationGateway extends ScriptsGateway {
  List<Json> initial = [], followup = [], forms = [];
  int? nativeLinkOrder;
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    final result = await super.call(method, args);
    if (method != 'documentScriptEvaluate') return result;
    final decoded = obj(jsonDecode(result['value'] as String));
    final source = '${args['source']}';
    final snapshot = source.startsWith('__pircDocument.snapshot');
    final dispatch = source.startsWith('__pircDocument.dispatch');
    final init = source.startsWith('__pircDocument.init');
    decoded['defaultPrevented'] = false;
    if (dispatch && nativeLinkOrder != null) {
      decoded['nativeLinkDefaultOrder'] = nativeLinkOrder;
    }
    decoded['formActions'] = dispatch || init ? forms : [];
    if (dispatch || init) forms = [];
    decoded['navigationActions'] = snapshot
        ? followup
        : (dispatch || init ? initial : []);
    if (snapshot) followup = [];
    if (dispatch || init) initial = [];
    return {'value': jsonEncode(decoded)};
  }
}

Json navigation(String path, {String target = '_self'}) => {
  'kind': 'navigate',
  'url': 'https://example.test/$path',
  'target': target,
  'replace': false,
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'microtasks replace pending current-window navigation and consume once',
    () async {
      final gateway = NavigationGateway()
        ..initial = [navigation('old')]
        ..followup = [navigation('popup', target: '_blank'), navigation('new')];
      final scripts = NativeDocumentScripts(
        gateway,
        loadRuntime: () async => 'runtime',
      );
      addTearDown(scripts.dispose);
      await scripts.start(source: '', url: 'https://example.test/');
      expect(scripts.navigationActions.map((a) => a['url']), [
        'https://example.test/new',
      ]);
      final ids = scripts.navigationActions
          .map((a) => a['sequence'] as int)
          .toList();
      expect(scripts.takeNavigationActions(ids), hasLength(1));
      expect(scripts.takeNavigationActions(ids), isEmpty);
    },
  );
  test('host rejects startup popups even if an isolate returns one', () async {
    final gateway = NavigationGateway()
      ..initial = [navigation('blocked', target: '_blank')];
    final scripts = NativeDocumentScripts(
      gateway,
      loadRuntime: () async => 'runtime',
    );
    addTearDown(scripts.dispose);
    await scripts.start(source: '', url: 'https://example.test/');
    expect(scripts.navigationActions, isEmpty);
    gateway.initial = [navigation('allowed', target: '_blank')];
    await scripts.click('button', []);
    expect(
      scripts.navigationActions.single['url'],
      'https://example.test/allowed',
    );
  });

  test(
    'stale rendered actions and detached documents cannot navigate',
    () async {
      final gateway = NavigationGateway()..initial = [navigation('old')];
      final scripts = NativeDocumentScripts(
        gateway,
        loadRuntime: () async => 'runtime',
      );
      addTearDown(scripts.dispose);
      await scripts.start(source: '', url: 'https://example.test/');
      final old = scripts.navigationActions.single['sequence'] as int;
      gateway.initial = [navigation('new')];
      await scripts.click('button', []);
      expect(scripts.takeNavigationActions([old]), isEmpty);
      final current = scripts.navigationActions.single['sequence'] as int;
      scripts.setActivity(attached: false, visible: false);
      scripts.setActivity(attached: true, visible: true);
      expect(scripts.takeNavigationActions([current]), isEmpty);
    },
  );
  test('a failed snapshot cannot execute initial navigation', () async {
    final gateway = NavigationGateway();
    final scripts = NativeDocumentScripts(
      gateway,
      loadRuntime: () async => 'runtime',
    );
    addTearDown(scripts.dispose);
    await scripts.start(source: '', url: 'https://example.test/');
    gateway.initial = [navigation('uncertain')];
    gateway.failClickSnapshot = true;
    await scripts.click('button', []);
    expect(scripts.navigationActions, isEmpty);
    expect(scripts.ready, false);
  });
  test(
    'unsafe navigation payload disables interaction without executing',
    () async {
      final gateway = NavigationGateway()
        ..initial = [
          {...navigation('safe'), 'url': 'javascript:alert(1)'},
        ];
      final scripts = NativeDocumentScripts(
        gateway,
        loadRuntime: () async => 'runtime',
      );
      addTearDown(scripts.dispose);
      await scripts.start(source: '', url: 'https://example.test/');
      expect(scripts.ready, false);
      expect(scripts.navigationActions, isEmpty);
    },
  );
  test(
    'last same-window operation wins across forms and navigation snapshots',
    () async {
      final gateway = NavigationGateway();
      final scripts = NativeDocumentScripts(
        gateway,
        loadRuntime: () async => 'runtime',
      );
      addTearDown(scripts.dispose);
      await scripts.start(source: '', url: 'https://example.test/');
      gateway.initial = [
        {...navigation('superseded'), 'actionOrder': 1},
      ];
      gateway.forms = [
        {'kind': 'submit', 'formId': 'f', 'actionOrder': 2, 'target': '_self'},
      ];
      await scripts.click('button', []);
      expect(scripts.navigationActions, isEmpty);
      expect(scripts.formActions, hasLength(1));
      gateway.followup = [
        {...navigation('final'), 'actionOrder': 3},
      ];
      await scripts.click('button', []);
      expect(scripts.formActions, isEmpty);
      expect(
        scripts.navigationActions.single['url'],
        'https://example.test/final',
      );
    },
  );

  test(
    'native link default supersedes both handler and microtask navigation',
    () async {
      final gateway = NavigationGateway();
      final scripts = NativeDocumentScripts(
        gateway,
        loadRuntime: () async => 'runtime',
      );
      addTearDown(scripts.dispose);
      await scripts.start(source: '', url: 'https://example.test/');
      gateway.nativeLinkOrder = 2;
      gateway.initial = [
        {...navigation('onclick'), 'actionOrder': 1},
      ];
      expect(await scripts.click('anchor', []), false);
      expect(scripts.navigationActions, isEmpty);
      gateway.nativeLinkOrder = 3;
      gateway.followup = [
        {...navigation('microtask'), 'actionOrder': 4},
      ];
      expect(await scripts.click('anchor', []), false);
      expect(scripts.navigationActions, isEmpty);
    },
  );

  test(
    'fragment replace and clearing retain controls and avoid duplicate history',
    () async {
      final gateway = DocumentGateway()
        ..responses.add(response('/page', '<input value="retained">'));
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = windows.target(
        '',
        null,
        sourceUrl: 'https://gateway.example/',
      );
      await window.load(
        const NativeHtmlFormRequest(url: '/page', method: 'GET', target: ''),
        baseUrl: 'https://gateway.example/',
      );
      final document = window.currentDocument;
      await window.load(
        const NativeHtmlFormRequest(url: '#one', method: 'GET', target: ''),
        baseUrl: window.current!.url,
        fragmentAllowed: true,
      );
      expect(window.history, hasLength(2));
      await window.load(
        const NativeHtmlFormRequest(url: '#two', method: 'GET', target: ''),
        baseUrl: window.current!.url,
        fragmentAllowed: true,
        replaceCurrent: true,
      );
      expect(window.history, hasLength(2));
      expect(window.current!.url, endsWith('#two'));
      await window.load(
        const NativeHtmlFormRequest(url: '#two', method: 'GET', target: ''),
        baseUrl: window.current!.url,
        fragmentAllowed: true,
      );
      expect(window.history, hasLength(2));
      await window.load(
        const NativeHtmlFormRequest(
          url: 'https://gateway.example/page',
          method: 'GET',
          target: '',
        ),
        baseUrl: window.current!.url,
        fragmentAllowed: true,
        allowFragmentRemoval: true,
      );
      expect(window.history, hasLength(3));
      expect(window.current!.url, 'https://gateway.example/page');
      expect(window.currentDocument, same(document));
      expect(gateway.calls, hasLength(1));
    },
  );

  test('same-document URL updates are queued once and retain the VM', () async {
    final gateway = NavigationGateway();
    final scripts = NativeDocumentScripts(
      gateway,
      loadRuntime: () async => 'runtime',
    );
    addTearDown(scripts.dispose);
    await scripts.start(source: '', url: 'https://example.test/');
    await scripts.updateLocation('https://example.test/#next');
    await scripts.updateLocation('https://example.test/#next');
    final updates = gateway.calls.where(
      (c) =>
          c.$1 == 'documentScriptEvaluate' &&
          '${c.$2['source']}'.startsWith('__pircDocument.updateLocation'),
    );
    expect(updates, hasLength(1));
    expect(
      gateway.calls.where((c) => c.$1 == 'documentScriptOpen'),
      hasLength(1),
    );
  });
}
