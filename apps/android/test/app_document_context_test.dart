import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/app.dart';
import 'package:pirc_mobile/live/app_document_route.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/scoped_gateway.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/html_document_urls.dart';

import 'app_document_live_routes_test.dart' show RouteGateway, finish, scope;
import 'live_test.dart' show theme;

const _origin = 'https://gateway.example';
const _stamp = 'test-pairing';

final _shellHtml = File('../web/index.html').readAsStringSync();
final _api = obj(
  jsonDecode(
    File(
      '../../fixtures/mobile-parity/app-document-routes.json',
    ).readAsStringSync(),
  ),
);
final _apiFixture = obj(_api['apiFixture']);

class ContextRouteGateway extends RouteGateway {
  ContextRouteGateway() {
    preferences = {
      'appearance': 'light',
      'mode': 'chat',
      'sidebarCollapsed': false,
      'goalExpanded': true,
    };
  }

  Json preferences = {};
  final openedContexts = <String, String>{};
  final closedContexts = <String>[];
  final selectedByContext = <String, String>{'primary': 'session-latest'};
  final draftsByContext = <String, Map<String, String>>{};
  final watchTagsByContext = <String, String>{};
  final watchedContexts = <String>[];
  final unwatchedContexts = <String>[];
  final documentCalls = <Json>[];
  String pairingStamp = _stamp;

  String _context(Json args) => '${args['contextId'] ?? 'primary'}';

  Json _snapshot(String sessionId) {
    final session = rows(
      _apiFixture['sessions'],
    ).firstWhere((row) => row['id'] == sessionId);
    return {
      'session': session,
      'messages': [
        {
          'id': 'message-$sessionId',
          'role': 'assistant',
          'content': 'Context content for $sessionId',
        },
      ],
      'interactions': <Json>[],
      'widgets': <String, dynamic>{},
      'queue': <Json>[],
    };
  }

  Json _response(String url, String body) => {
    'status': 200,
    'finalUrl': url,
    'finalMethod': 'GET',
    'mimeType': 'text/html',
    'charset': 'UTF-8',
    'bytes': Uint8List.fromList(utf8.encode(body)),
    'headersRelevant': <String, dynamic>{},
  };

  String _sourceHtml() => '''
    <!doctype html>
    <html><head><title>Root source page</title></head><body>
      <h1>Root source page</h1>
      <form action="/index.html" method="get" target="_blank">
        <input type="hidden" name="session" value="session-second">
        <button>Open blank second</button>
      </form>
      <form action="/index.html" method="get" target="_blank">
        <input type="hidden" name="session" value="session-work">
        <button>Open blank workspace session</button>
      </form>
      <form action="/regular-named" method="get" target="named-app">
        <button>Open named document</button>
      </form>
      <form action="/index.html" method="get" target="named-app">
        <input type="hidden" name="session" value="session-work">
        <button>Reuse named session</button>
      </form>
      <form action="/index.html" method="get" target="named-app">
        <input type="hidden" name="session" value="session-work">
        <input type="hidden" name="workspace" value="work-local">
        <button>Reuse named workspace</button>
      </form>
    </body></html>
  ''';

  String _namedHtml() => '''
    <!doctype html>
    <html><head><title>Named landing document</title></head><body>
      <h1>Named landing document</h1>
      <form action="/index.html" method="get" target="_self">
        <input type="hidden" name="session" value="session-second">
        <button>Open app in this window</button>
      </form>
    </body></html>
  ''';

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'documentPrepareRequest') {
      return {
        'nativeCookieRequestKey':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      };
    }
    final recorded = Map<String, dynamic>.of(args);
    calls.add((method, recorded));
    final contextId = _context(recorded);
    switch (method) {
      case 'boot':
        return {
          'origin': _origin,
          'clientId': 'shared-client',
          'pairingStamp': pairingStamp,
          'targetSession': 'session-latest',
        };
      case 'preferences':
        return Map<String, dynamic>.of(preferences);
      case 'savePreferences':
        preferences = {...preferences, ...recorded};
        preferences.remove('contextId');
        stream.add({
          'type': 'preferencesChanged',
          'scope': 'account',
          'data': Map<String, dynamic>.of(preferences),
        });
        return Map<String, dynamic>.of(preferences);
      case 'openContext':
        final id = '${recorded['contextId']}';
        if (recorded['pairingStamp'] != pairingStamp) {
          throw StateError('Wrong pairing stamp for $id.');
        }
        openedContexts[id] = '${recorded['pairingStamp']}';
        return {'contextId': id};
      case 'closeContext':
        final id = '${recorded['contextId']}';
        if (openedContexts[id] != recorded['pairingStamp']) {
          throw StateError('Unexpected close for $id.');
        }
        openedContexts.remove(id);
        closedContexts.add(id);
        return null;
      case 'watch':
        final sessionId = '${recorded['sessionId']}';
        final tag = '${recorded['watchTag']}';
        selectedByContext[contextId] = sessionId;
        watchTagsByContext[contextId] = tag;
        watchedContexts.add(contextId);
        stream.add({
          'type': 'snapshot',
          'contextId': contextId,
          'watchTag': tag,
          'sessionId': sessionId,
          'data': _snapshot(sessionId),
        });
        stream.add({
          'type': 'connection',
          'contextId': contextId,
          'watchTag': tag,
          'sessionId': sessionId,
          'data': 'live',
        });
        stream.add({
          'type': 'control',
          'contextId': contextId,
          'watchTag': tag,
          'sessionId': sessionId,
          'data': {'held': true, 'generation': 1},
        });
        return drafts[sessionId] ?? '';
      case 'unwatch':
        unwatchedContexts.add(contextId);
        if (watchTagsByContext[contextId] == recorded['watchTag']) {
          watchTagsByContext.remove(contextId);
        }
        return null;
      case 'draft':
        final sessionId = '${recorded['sessionId']}';
        draftsByContext.putIfAbsent(contextId, () => {})[sessionId] =
            '${recorded['text'] ?? ''}';
        drafts[sessionId] = '${recorded['text'] ?? ''}';
        return null;
      case 'refresh':
        final sessionId = selectedByContext[contextId] ?? 'session-latest';
        return _snapshot(sessionId);
      case 'commandStatus':
        return false;
      case 'control':
        return {'held': true, 'generation': 1};
      case 'resolveDocumentUrl':
        return resolveNativeDocumentUrl(
          '${recorded['reference']}',
          '${recorded['baseUrl']}',
        );
      case 'document':
        documentCalls.add(recorded);
        final url = '${recorded['url']}';
        final path = Uri.parse(url).path;
        if (path == '/source' || path.startsWith('/source-')) {
          return _response(url, _sourceHtml());
        }
        if (path == '/regular-named') return _response(url, _namedHtml());
        if (path == '/index.html' || path == '/') {
          return _response(url, _shellHtml);
        }
        throw StateError('Unexpected document request: $url');
      default:
        return normal(method, recorded);
    }
  }
}

List<LiveShell> _liveShells(WidgetTester tester) => tester
    .widgetList<LiveShell>(find.byType(LiveShell, skipOffstage: false))
    .toList();

LiveShell _childShell(WidgetTester tester, NativeDocumentWindow window) =>
    _liveShells(tester).firstWhere(
      (shell) =>
          shell.documentWindow == window &&
          shell.controller.gateway is DartScopedGateway &&
          !(shell.controller.gateway as DartScopedGateway).isPrimary,
    );

Future<NativeDocumentWindow> _openRootSource(
  WidgetTester tester,
  NativeDocumentWindows windows,
) async {
  final source = windows.target(
    '',
    null,
    sourceUrl: scope(tester).documentUrl ?? '$_origin/',
  );
  final result = await source.load(
    const NativeHtmlFormRequest(url: '/source', method: 'GET', target: ''),
    baseUrl: scope(tester).documentUrl ?? '$_origin/',
  );
  expect(result, NativeDocumentLoadResult.committed);
  windows.select(source);
  await tester.pumpAndSettle();
  return source;
}

Future<void> _reloadRootSource(
  WidgetTester tester,
  NativeDocumentWindow source, {
  required String path,
}) async {
  final baseUrl = source.current?.url ?? '$_origin/';
  final result = await source.load(
    NativeHtmlFormRequest(url: path, method: 'GET', target: ''),
    baseUrl: baseUrl,
  );
  expect(result, NativeDocumentLoadResult.committed);
  source.windows.select(source);
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester, String buttonText) async {
  final button = find.byWidgetPredicate(
    (widget) =>
        widget is RichText && widget.text.toPlainText().contains(buttonText),
  );
  expect(button, findsOneWidget, reason: 'Find HTML submitter $buttonText.');
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

Future<void> _forward(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'blank forms create isolated App contexts and switching watches only the selected window',
    (tester) async {
      final gateway = ContextRouteGateway();
      final root = LiveController(DartScopedGateway(gateway));
      await tester.pumpWidget(MobileApp(theme: theme, controller: root));
      await tester.pumpAndSettle();
      expect(root.sessionId, 'session-latest');
      root.editDraft('root draft stays here');
      await root.flushDraft();

      final windows = scope(tester).windows;
      final source = await _openRootSource(tester, windows);
      await _submit(tester, 'Open blank second');
      final first = windows.active!;
      expect(first, isNot(same(source)));
      expect(
        (first.currentAppRoute!.target as NativeAppSessionRouteTarget)
            .sessionId,
        'session-second',
      );
      final firstShell = _childShell(tester, first);
      final firstController = firstShell.controller;
      final firstScope = firstController.gateway as DartScopedGateway;
      firstController.editDraft('first child draft');
      await firstController.flushDraft();
      await tester.pumpAndSettle();

      expect(firstScope.contextId, startsWith('app-'));
      expect(gateway.openedContexts[firstScope.contextId], _stamp);
      expect(firstController.clientId, root.clientId);
      expect(firstController.preferences, gateway.preferences);
      expect(firstController.sessionId, 'session-second');
      expect(root.sessionId, 'session-latest');
      expect(root.draft, 'root draft stays here');
      expect(root.active, isFalse);
      expect(
        gateway.draftsByContext[firstScope.contextId]?['session-second'],
        'first child draft',
      );

      await _reloadRootSource(tester, source, path: '/source-second');
      expect(windows.active, same(source));
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText().contains(
                'Open blank workspace session',
              ),
        ),
        findsOneWidget,
      );
      final documentRequestCount = gateway.documentCalls.length;
      await _submit(tester, 'Open blank workspace session');
      expect(gateway.documentCalls, hasLength(documentRequestCount + 1));
      final second = windows.active!;
      expect(second, isNot(same(first)));
      expect(
        second.currentAppRoute,
        isNotNull,
        reason:
            'active=${second.current?.url} error=${second.error} history=${second.history.map((entry) => entry.url).toList()} requests=${gateway.documentCalls}',
      );
      expect(
        (second.currentAppRoute!.target as NativeAppSessionRouteTarget)
            .sessionId,
        'session-work',
      );
      final secondShell = _childShell(tester, second);
      final secondController = secondShell.controller;
      final secondScope = secondController.gateway as DartScopedGateway;
      secondController.editDraft('second child draft');
      await secondController.flushDraft();
      await tester.pumpAndSettle();

      expect(secondScope.contextId, isNot(firstScope.contextId));
      expect(
        gateway.openedContexts.keys,
        containsAll([firstScope.contextId, secondScope.contextId]),
      );
      expect(secondController.clientId, root.clientId);
      expect(secondController.preferences, gateway.preferences);
      expect(
        gateway.draftsByContext[secondScope.contextId]?['session-work'],
        'second child draft',
      );
      expect(root.sessionId, 'session-latest');
      expect(root.draft, 'root draft stays here');

      windows.select(first);
      await tester.pumpAndSettle();
      expect(firstController.active, isTrue);
      expect(secondController.active, isFalse);
      expect(gateway.watchedContexts, contains(firstScope.contextId));
      expect(gateway.unwatchedContexts, contains(secondScope.contextId));

      windows.select(second);
      await tester.pumpAndSettle();
      expect(firstController.active, isFalse);
      expect(secondController.active, isTrue);
      expect(gateway.unwatchedContexts, contains(firstScope.contextId));
      expect(gateway.watchedContexts, contains(secondScope.contextId));
      expect(root.sessionId, 'session-latest');
      expect(root.draft, 'root draft stays here');
      expect(tester.takeException(), isNull);

      await finish(tester, gateway, root);
    },
  );

  testWidgets(
    'named target reuses its child scope and app history restores the same controller',
    (tester) async {
      final gateway = ContextRouteGateway();
      final root = LiveController(DartScopedGateway(gateway));
      await tester.pumpWidget(MobileApp(theme: theme, controller: root));
      await tester.pumpAndSettle();
      root.editDraft('root draft retained through named app');
      await root.flushDraft();

      final windows = scope(tester).windows;
      final source = await _openRootSource(tester, windows);
      await _submit(tester, 'Open named document');
      final named = windows.active!;
      expect(named.name, 'named-app');
      expect(named.currentDocument?.content.title, 'Named landing document');

      await _submit(tester, 'Open app in this window');
      expect(windows.active, same(named));
      expect(named.history, hasLength(2));
      expect(
        (named.currentAppRoute!.target as NativeAppSessionRouteTarget)
            .sessionId,
        'session-second',
      );
      final childShell = _childShell(tester, named);
      final child = childShell.controller;
      final childGateway = child.gateway as DartScopedGateway;
      final contextId = childGateway.contextId;
      child.editDraft('named child draft');
      await child.flushDraft();
      await tester.pumpAndSettle();
      expect(child.clientId, root.clientId);
      expect(child.preferences, gateway.preferences);
      expect(root.sessionId, 'session-latest');
      expect(root.draft, 'root draft retained through named app');

      await _back(tester);
      expect(windows.active, same(named));
      expect(named.currentDocument?.content.title, 'Named landing document');
      expect(child.active, isFalse);
      expect(gateway.unwatchedContexts, contains(contextId));

      await _forward(tester);
      expect(windows.active, same(named));
      expect(named.currentAppRoute, isNotNull);
      expect(identical(_childShell(tester, named).controller, child), isTrue);
      expect(child.sessionId, 'session-second');
      expect(child.draft, 'named child draft');

      await _back(tester);
      await _back(tester); // Back from its source document closes this child.
      expect(windows.windows, isNot(contains(named)));
      expect(gateway.closedContexts, contains(contextId));

      // The root window remains on its source document. Returning to the root
      // App restores its own session and draft, independent of the closed child.
      expect(windows.active, same(source));
      await _back(tester);
      expect(root.sessionId, 'session-latest');
      expect(root.draft, 'root draft retained through named app');
      expect(tester.takeException(), isNull);
      await finish(tester, gateway, root);
    },
  );

  testWidgets('a named window route changes session and workspace in place', (
    tester,
  ) async {
    final gateway = ContextRouteGateway();
    final root = LiveController(DartScopedGateway(gateway));
    await tester.pumpWidget(MobileApp(theme: theme, controller: root));
    await tester.pumpAndSettle();
    final windows = scope(tester).windows;
    final source = await _openRootSource(tester, windows);
    await _submit(tester, 'Open named document');
    final named = windows.active!;
    await _submit(tester, 'Open app in this window');
    final child = _childShell(tester, named).controller;
    final childGateway = child.gateway as DartScopedGateway;
    final contextId = childGateway.contextId;
    expect(child.sessionId, 'session-second');

    await _reloadRootSource(tester, source, path: '/source-session');
    await _submit(tester, 'Reuse named session');
    await tester.pumpAndSettle();
    expect(windows.active, same(named));
    expect(named.name, 'named-app');
    expect(child.gateway, same(childGateway));
    expect(childGateway.contextId, contextId);
    expect(child.sessionId, 'session-work');
    expect(named.currentAppRoute?.workspaceId, isNull);

    await _reloadRootSource(tester, source, path: '/source-workspace');
    await _submit(tester, 'Reuse named workspace');
    await tester.pumpAndSettle();
    expect(windows.active, same(named));
    expect(child.gateway, same(childGateway));
    expect(child.sessionId, 'session-work');
    expect(named.currentAppRoute?.workspaceId, 'work-local');
    expect(named.history, hasLength(4));
    expect(
      gateway.openedContexts.keys.where((id) => id == contextId),
      hasLength(1),
    );
    expect(root.sessionId, 'session-latest');
    expect(tester.takeException(), isNull);
    await finish(tester, gateway, root);
  });

  testWidgets(
    'pairing change removes every document and closes child contexts',
    (tester) async {
      final gateway = ContextRouteGateway();
      final root = LiveController(DartScopedGateway(gateway));
      await tester.pumpWidget(MobileApp(theme: theme, controller: root));
      await tester.pumpAndSettle();
      final windows = scope(tester).windows;
      await _openRootSource(tester, windows);
      await _submit(tester, 'Open blank second');
      final child = _childShell(tester, windows.active!).controller;
      final childGateway = child.gateway as DartScopedGateway;
      final contextId = childGateway.contextId;
      expect(gateway.openedContexts, contains(contextId));

      final accountRevision = root.accountRevision;
      // An unrelated root operation may hold the UI busy while the account
      // authority changes. The pairing event must still invalidate all scopes.
      root.busy = true;
      gateway.stream.add({
        'type': 'pairingChanged',
        'scope': 'account',
        'contextId': contextId,
        'data': {
          'origin': 'https://next-gateway.example',
          'clientId': 'next-client',
          'pairingStamp': 'next-pairing',
        },
      });
      // Root remains busy, so its progress animation intentionally never
      // settles. Pump a few frames to flush the event and widget teardown.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(windows.windows, isEmpty);
      expect(root.accountRevision, accountRevision + 1);
      expect(root.origin, 'https://next-gateway.example');
      expect(root.pairingStamp, 'next-pairing');
      expect(gateway.closedContexts, contains(contextId));
      expect(gateway.openedContexts, isEmpty);
      expect(gateway.closedContexts.where((id) => id == 'primary'), isEmpty);
      expect(tester.takeException(), isNull);
      await finish(tester, gateway, root);
    },
  );

  testWidgets(
    'child appearance preference updates the shared root theme without changing another context mode',
    (tester) async {
      final gateway = ContextRouteGateway();
      final root = LiveController(DartScopedGateway(gateway));
      await tester.pumpWidget(MobileApp(theme: theme, controller: root));
      await tester.pumpAndSettle();
      root.editDraft('root draft survives appearance change');
      await root.flushDraft();

      final windows = scope(tester).windows;
      final source = await _openRootSource(tester, windows);
      await _submit(tester, 'Open blank second');
      final childWindow = windows.active!;
      final childShell = _childShell(tester, childWindow);
      final child = childShell.controller;
      final childGateway = child.gateway as DartScopedGateway;
      final contextId = childGateway.contextId;
      expect(child.sessionId, 'session-second');
      expect(root.sessionId, 'session-latest');

      await root.setMode('work');
      await tester.pumpAndSettle();
      expect(root.mode, 'work');
      expect(child.preferences['mode'], 'work');
      expect(child.mode, 'chat');

      await child.savePreferences({'appearance': 'dark'});
      await tester.pumpAndSettle();
      expect(root.preferences['appearance'], 'dark');
      expect(child.preferences['appearance'], 'dark');
      expect(root.preferences['mode'], 'work');
      expect(child.preferences['mode'], 'work');
      expect(root.mode, 'work');
      expect(child.mode, 'chat');
      expect(
        (Theme.of(tester.element(find.byWidget(childShell))).brightness),
        Brightness.dark,
      );
      final preferenceCall = gateway.calls.lastWhere(
        (entry) => entry.$1 == 'savePreferences',
      );
      expect(preferenceCall.$2, {'appearance': 'dark'});
      expect(windows.active, same(childWindow));
      expect(root.sessionId, 'session-latest');
      expect(root.draft, 'root draft survives appearance change');

      await _back(tester); // Close the child App window.
      expect(gateway.closedContexts, contains(contextId));
      expect(windows.active, same(source));
      await _back(tester); // Return to the root App shell.
      await tester.pumpAndSettle();
      final rootShell = _liveShells(
        tester,
      ).firstWhere((shell) => identical(shell.controller, root));
      expect(
        Theme.of(tester.element(find.byWidget(rootShell))).brightness,
        Brightness.dark,
      );
      // The root's own pre-document view is restored independently of the
      // shared stored preference value.
      expect(root.mode, 'chat');
      expect(root.sessionId, 'session-latest');
      expect(root.draft, 'root draft survives appearance change');
      expect(tester.takeException(), isNull);
      await finish(tester, gateway, root);
    },
  );

  test(
    'same-session controllers keep local drafts but share persisted drafts',
    () async {
      final gateway = ContextRouteGateway();
      final rootGateway = DartScopedGateway(gateway);
      final root = LiveController(rootGateway);
      await root.boot();
      await root.open('session-second');
      root.editDraft('root saved value');
      await root.flushDraft();

      final childGateway = DartScopedGateway(gateway, contextId: 'app-same');
      final child = LiveController(childGateway);
      await child.boot();
      await child.open('session-second');
      expect(child.draft, 'root saved value');
      child.editDraft('child last saved value');
      await child.flushDraft();

      expect(root.draft, 'root saved value');
      expect(child.draft, 'child last saved value');
      expect(gateway.drafts['session-second'], 'child last saved value');
      expect(
        gateway.draftsByContext['primary']?['session-second'],
        'root saved value',
      );
      expect(
        gateway.draftsByContext['app-same']?['session-second'],
        'child last saved value',
      );

      final siblingGateway = DartScopedGateway(
        gateway,
        contextId: 'app-sibling',
      );
      final sibling = LiveController(siblingGateway);
      await sibling.boot();
      await sibling.open('session-second');
      expect(sibling.draft, 'child last saved value');
      expect(root.draft, 'root saved value');
      expect(child.draft, 'child last saved value');

      root.dispose();
      child.dispose();
      sibling.dispose();
      await childGateway.closeContext();
      await siblingGateway.closeContext();
      await gateway.stream.close();
    },
  );
}
