import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/app_document_route.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_form_submission.dart';

import 'document_navigation_widget_test.dart'
    show DocumentGateway, app, clickSubmit, response;
import 'native_html_test.dart' show tapText;

const _root = 'https://gateway.example/';
const _description =
    'A calm command surface for persistent coding-agent sessions.';

String _pircShell() =>
    '<!doctype html><html lang="en"><head>'
    '<meta name="description" content="$_description">'
    '<meta name="apple-mobile-web-app-title" content="pirc">'
    '<title>pirc</title></head><body><div id="app"></div>'
    '<script type="module" src="/src/main.ts"></script>'
    '</body></html>';

class _FailFirstDocumentGateway extends DocumentGateway {
  bool _failed = false;

  @override
  Future<dynamic> call(String method, [Map<String, dynamic> args = const {}]) {
    if (method == 'documentPrepareRequest') {
      return Future.value({
        'nativeCookieRequestKey':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      });
    }
    if (method == 'document' && !_failed) {
      _failed = true;
      calls.add(args);
      return Future.error(StateError('temporary network error'));
    }
    return super.call(method, args);
  }
}

class _DelayedDocumentGateway extends DocumentGateway {
  final responseCompleter = Completer<Map<String, dynamic>>();

  @override
  Future<dynamic> call(String method, [Map<String, dynamic> args = const {}]) {
    if (method == 'documentPrepareRequest') {
      return Future.value({
        'nativeCookieRequestKey':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      });
    }
    if (method == 'document') {
      calls.add(args);
      return responseCompleter.future;
    }
    return super.call(method, args);
  }
}

class _DelayedUncoverController extends LiveController {
  _DelayedUncoverController(super.gateway);

  final uncoverStarted = Completer<void>();
  final uncoverCompleter = Completer<void>();
  int coverCalls = 0;

  @override
  Future<void> coverDocument() async {
    coverCalls++;
  }

  @override
  Future<void> uncoverDocument() {
    if (!uncoverStarted.isCompleted) uncoverStarted.complete();
    return uncoverCompleter.future;
  }
}

List<NativeAppDocumentRoute> _routes = [];
Future<void> _captureRoute(NativeAppDocumentRoute route) async {
  _routes.add(route);
}

void main() {
  setUp(() => _routes = []);

  testWidgets('primary GET of the Pirc shell routes after the HTTP request', (
    t,
  ) async {
    final gateway = DocumentGateway()
      ..responses.add(
        response('/?session=linked&workspace=project%3Aone', _pircShell()),
      );
    var callsWhenRouted = 0;
    final windows = NativeDocumentWindows(
      gateway,
      onAppRoute: (route) async {
        callsWhenRouted = gateway.calls.length;
        await _captureRoute(route);
      },
    );
    addTearDown(windows.dispose);

    await t.pumpWidget(
      app(
        gateway,
        windows,
        '<form action="/" method="get">'
        '<input type="hidden" name="session" value="linked">'
        '<input type="hidden" name="workspace" value="project:one">'
        '<button>Open Pirc route</button></form>',
      ),
    );
    await t.pumpAndSettle();
    await clickSubmit(t);

    expect(gateway.calls, hasLength(1));
    expect(gateway.calls.single['method'], 'GET');
    expect(
      gateway.calls.single['url'],
      'https://gateway.example/?session=linked&workspace=project%3Aone',
    );
    expect(
      callsWhenRouted,
      1,
      reason: 'routing follows the completed HTTP request',
    );
    expect(_routes, hasLength(1));
    expect(_routes.single.workspaceId, 'project:one');
    expect(_routes.single.target, isA<NativeAppSessionRouteTarget>());
    expect(
      (_routes.single.target! as NativeAppSessionRouteTarget).sessionId,
      'linked',
    );
    expect(find.byType(NativeDocumentWorkspace), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('POST response that looks like the shell remains a document', (
    t,
  ) async {
    final gateway = DocumentGateway()
      ..responses.add(
        response('/?session=linked', _pircShell(), finalMethod: 'POST'),
      );
    final windows = NativeDocumentWindows(gateway, onAppRoute: _captureRoute);
    addTearDown(windows.dispose);

    await t.pumpWidget(
      app(
        gateway,
        windows,
        '<form action="/submit" method="post">'
        '<input name="note" value="raw + body"><button>Send</button></form>',
      ),
    );
    await t.pumpAndSettle();
    await clickSubmit(t);

    expect(gateway.calls.single['method'], 'POST');
    expect(gateway.calls.single['body'], 'note=raw+%2B+body');
    expect(_routes, isEmpty);
    expect(windows.active!.current!.document!.status, 200);
    expect(windows.active!.current!.document!.reloadRequest!.method, 'POST');
    expect(find.byType(NativeDocumentWorkspace), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'POST redirected to a shell GET routes with the exact submitted bytes',
    (t) async {
      final gateway = DocumentGateway()
        ..responses.add(
          response(
            '/?open=schedules&schedule=cron-1',
            _pircShell(),
            finalMethod: 'GET',
          ),
        );
      final windows = NativeDocumentWindows(gateway, onAppRoute: _captureRoute);
      addTearDown(windows.dispose);

      await t.pumpWidget(
        app(
          gateway,
          windows,
          '<form action="/submit" method="post">'
          '<input name="value" value="raw + body"><button>Submit</button></form>',
        ),
      );
      await t.pumpAndSettle();
      await clickSubmit(t);

      expect(gateway.calls, hasLength(1));
      expect(gateway.calls.single['url'], 'https://gateway.example/submit');
      expect(gateway.calls.single['method'], 'POST');
      expect(gateway.calls.single['body'], 'value=raw+%2B+body');
      expect(
        gateway.calls.single['contentType'],
        'application/x-www-form-urlencoded',
      );
      expect(_routes, hasLength(1));
      expect(_routes.single.target, isA<NativeAppSchedulesRouteTarget>());
      expect(
        (_routes.single.target! as NativeAppSchedulesRouteTarget).scheduleId,
        'cron-1',
      );
      expect(find.byType(NativeDocumentWorkspace), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'confirmed Pirc shell on a same-origin SPA fallback path routes',
    (t) async {
      final gateway = DocumentGateway()
        ..responses.add(
          response('/workspace/project?session=deep', _pircShell()),
        );
      final windows = NativeDocumentWindows(gateway, onAppRoute: _captureRoute);
      addTearDown(windows.dispose);
      await t.pumpWidget(
        app(
          gateway,
          windows,
          '<form action="/workspace/project" method="get">'
          '<input type="hidden" name="session" value="deep">'
          '<button>Open deep app route</button></form>',
        ),
      );
      await t.pumpAndSettle();

      await clickSubmit(t);

      expect(gateway.calls, hasLength(1));
      expect(
        gateway.calls.single['url'],
        'https://gateway.example/workspace/project?session=deep',
      );
      expect(_routes.single.isSpaFallbackPath, isTrue);
      expect(_routes.single.target, isA<NativeAppSessionRouteTarget>());
      expect(
        (_routes.single.target! as NativeAppSessionRouteTarget).sessionId,
        'deep',
      );
      expect(find.byType(NativeDocumentWorkspace), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('403 API documents are fetched and never become app routes', (
    t,
  ) async {
    final gateway = DocumentGateway()
      ..responses.addAll([
        for (final path in [
          '/api/devices',
          '/api/providers',
          '/api/provider-auth/sessions',
        ])
          response(path, _pircShell(), status: 403),
      ]);
    final windows = NativeDocumentWindows(gateway, onAppRoute: _captureRoute);
    addTearDown(windows.dispose);

    final primary = windows.target('', null, sourceUrl: _root);
    for (final path in [
      '/api/devices',
      '/api/providers',
      '/api/provider-auth/sessions',
    ]) {
      final result = await primary.load(
        NativeHtmlFormRequest(url: path, method: 'GET', target: ''),
        baseUrl: _root,
      );
      expect(result, NativeDocumentLoadResult.committed, reason: path);
      expect(primary.current!.document!.status, 403, reason: path);
      expect(primary.pendingAppRoute, isNull, reason: path);
    }

    expect(gateway.calls.map((call) => call['url']), [
      'https://gateway.example/api/devices',
      'https://gateway.example/api/providers',
      'https://gateway.example/api/provider-auth/sessions',
    ]);
    expect(_routes, isEmpty);
  });

  testWidgets('204 keeps source and does not route an empty response', (
    t,
  ) async {
    final gateway = DocumentGateway()
      ..responses.add(response('/?open=memory', '', status: 204));
    final windows = NativeDocumentWindows(gateway, onAppRoute: _captureRoute);
    addTearDown(windows.dispose);
    await t.pumpWidget(
      app(
        gateway,
        windows,
        '<form action="/?open=memory"><input name="x" value="kept">'
        '<button>Submit</button></form>',
      ),
    );
    await t.pumpAndSettle();

    await clickSubmit(t);

    expect(gateway.calls, hasLength(1));
    expect(windows.windows, isEmpty);
    expect(_routes, isEmpty);
    expect(find.byType(NativeDocumentWorkspace), findsNothing);
    expect(t.takeException(), isNull);
  });

  test(
    'named and blank windows commit shell responses instead of routing',
    () async {
      final gateway = DocumentGateway()
        ..responses.addAll([
          response('/?session=one', _pircShell()),
          response('/?session=two', _pircShell()),
        ]);
      final windows = NativeDocumentWindows(gateway, onAppRoute: _captureRoute);
      addTearDown(windows.dispose);
      final primary = windows.target('', null, sourceUrl: _root);
      final blank = windows.target('_blank', primary, sourceUrl: _root);
      final named = windows.target('report', primary, sourceUrl: _root);

      for (final window in [blank, named]) {
        expect(window.canReturnToSource, isFalse);
        final result = await window.load(
          const NativeHtmlFormRequest(
            url: '/?session=other',
            method: 'GET',
            target: '',
          ),
          baseUrl: _root,
        );
        expect(result, NativeDocumentLoadResult.committed);
        expect(window.history, hasLength(1));
        expect(window.pendingAppRoute, isNull);
      }
      expect(_routes, isEmpty);
      expect(gateway.calls, hasLength(2));
    },
  );

  testWidgets('ordinary scripted HTML at root stays a native document', (
    t,
  ) async {
    const ordinary = '''
      <!doctype html><html><head><title>Another app</title></head>
      <body><div id="app">ordinary page</div>
        <script type="module" src="/other/main.js"></script>
      </body></html>
    ''';
    final gateway = DocumentGateway()..responses.add(response('/', ordinary));
    final windows = NativeDocumentWindows(gateway, onAppRoute: _captureRoute);
    addTearDown(windows.dispose);
    await t.pumpWidget(
      app(
        gateway,
        windows,
        '<form action="/"><button>Open ordinary page</button></form>',
      ),
    );
    await t.pumpAndSettle();

    await clickSubmit(t);

    expect(_routes, isEmpty);
    expect(windows.active!.current!.document!.content.title, 'Another app');
    expect(find.byType(NativeDocumentWorkspace), findsOneWidget);
    expect(find.text('ordinary page', findRichText: true), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('ordinary HTML on an SPA fallback path stays a native document', (
    t,
  ) async {
    const ordinary = '''
      <!doctype html><html><head><title>Another page</title></head>
      <body><div id="app">ordinary fallback page</div>
        <script type="module" src="/other/main.js"></script>
      </body></html>
    ''';
    final gateway = DocumentGateway()
      ..responses.add(response('/workspace/project?x=1', ordinary));
    final windows = NativeDocumentWindows(gateway, onAppRoute: _captureRoute);
    addTearDown(windows.dispose);
    await t.pumpWidget(
      app(
        gateway,
        windows,
        '<form action="/workspace/project" method="get">'
        '<input type="hidden" name="x" value="1">'
        '<button>Open ordinary fallback</button></form>',
      ),
    );
    await t.pumpAndSettle();

    await clickSubmit(t);

    expect(_routes, isEmpty);
    expect(windows.active!.current!.document!.content.title, 'Another page');
    expect(find.byType(NativeDocumentWorkspace), findsOneWidget);
    expect(
      find.text('ordinary fallback page', findRichText: true),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'a document link to a Pirc workspace route pops back and calls the app',
    (t) async {
      final gateway = DocumentGateway()
        ..responses.addAll([
          response(
            '/page',
            '<title>Native page</title><a href="/?workspace=project%3Aone">'
                'Open workspace</a>',
          ),
          response('/?workspace=project%3Aone', _pircShell()),
        ]);
      final windows = NativeDocumentWindows(gateway, onAppRoute: _captureRoute);
      addTearDown(windows.dispose);
      await t.pumpWidget(
        app(
          gateway,
          windows,
          '<form action="/page"><button>Open page</button></form>',
        ),
      );
      await t.pumpAndSettle();
      await clickSubmit(t);
      expect(find.byType(NativeDocumentWorkspace), findsOneWidget);

      await tapText(t, 'Open workspace');
      await t.pumpAndSettle();

      expect(gateway.calls, hasLength(2));
      expect(gateway.calls.last['method'], 'GET');
      expect(_routes, hasLength(1));
      expect(_routes.single.workspaceId, 'project:one');
      expect(find.byType(NativeDocumentWorkspace), findsNothing);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'app navigation changing during delayed uncover suppresses the route callback',
    (t) async {
      final gateway = DocumentGateway()
        ..responses.addAll([
          response(
            '/page',
            '<title>Native page</title><a href="/?workspace=project%3Aone">'
                'Open workspace</a>',
          ),
          response('/?workspace=project%3Aone', _pircShell()),
        ]);
      final owner = _DelayedUncoverController(gateway);
      Object navigationToken = Object();
      var callbackCount = 0;
      final windows = NativeDocumentWindows(
        gateway,
        owner: owner,
        appNavigationIdentity: () => navigationToken,
        onAppRoute: (_) async => callbackCount++,
      );
      addTearDown(windows.dispose);
      await t.pumpWidget(
        app(
          gateway,
          windows,
          '<form action="/page"><button>Open page</button></form>',
        ),
      );
      await t.pumpAndSettle();
      await clickSubmit(t);
      expect(owner.coverCalls, 1);
      expect(find.byType(NativeDocumentWorkspace), findsOneWidget);

      await tapText(t, 'Open workspace');
      await owner.uncoverStarted.future;
      expect(find.byType(NativeDocumentWorkspace), findsNothing);
      expect(callbackCount, 0);

      navigationToken = Object();
      owner.uncoverCompleter.complete();
      await t.pumpAndSettle();

      expect(callbackCount, 0);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('reload redirect to app shell routes to the app', (t) async {
    final gateway = DocumentGateway()
      ..responses.addAll([
        response('/page', '<title>Native page</title><p>Page body</p>'),
        response('/?open=memory', _pircShell()),
      ]);
    final windows = NativeDocumentWindows(gateway, onAppRoute: _captureRoute);
    addTearDown(windows.dispose);
    await t.pumpWidget(
      app(
        gateway,
        windows,
        '<form action="/page"><button>Open page</button></form>',
      ),
    );
    await t.pumpAndSettle();
    await clickSubmit(t);

    await t.tap(find.byTooltip("Reload"));
    await t.pumpAndSettle();

    expect(gateway.calls, hasLength(2));
    expect(gateway.calls.last['url'], 'https://gateway.example/page');
    expect(gateway.calls.last['method'], 'GET');
    expect(_routes.single.target, isA<NativeAppMemoryRouteTarget>());
    expect(find.byType(NativeDocumentWorkspace), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('retrying a failed GET to the app shell routes after the retry', (
    t,
  ) async {
    final gateway = _FailFirstDocumentGateway()
      ..responses.add(response('/?session=retry', _pircShell()));
    final windows = NativeDocumentWindows(gateway, onAppRoute: _captureRoute);
    addTearDown(windows.dispose);
    await t.pumpWidget(
      app(
        gateway,
        windows,
        '<form action="/retry?session=retry"><button>Open app</button></form>',
      ),
    );
    await t.pumpAndSettle();
    await clickSubmit(t);
    expect(find.text("Retry"), findsOneWidget);

    await t.tap(find.text("Retry"));
    await t.pumpAndSettle();

    expect(gateway.calls, hasLength(2));
    expect(gateway.calls.last['method'], 'GET');
    expect(_routes.single.target, isA<NativeAppSessionRouteTarget>());
    expect(
      (_routes.single.target! as NativeAppSessionRouteTarget).sessionId,
      'retry',
    );
    expect(find.byType(NativeDocumentWorkspace), findsNothing);
    expect(t.takeException(), isNull);
  });

  test(
    'stopping an in-flight shell request prevents its pending app route',
    () async {
      final gateway = _DelayedDocumentGateway();
      var callbackCount = 0;
      final windows = NativeDocumentWindows(
        gateway,
        onAppRoute: (_) async => callbackCount++,
      );
      addTearDown(windows.dispose);
      final primary = windows.target('', null, sourceUrl: _root);
      final loading = primary.load(
        const NativeHtmlFormRequest(
          url: '/?session=stale',
          method: 'GET',
          target: '',
        ),
        baseUrl: _root,
      );
      while (gateway.calls.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }

      primary.stop();
      gateway.responseCompleter.complete(
        response('/?session=stale', _pircShell()),
      );

      expect(await loading, NativeDocumentLoadResult.stale);
      expect(primary.pendingAppRoute, isNull);
      expect(primary.history, isEmpty);
      expect(callbackCount, 0);
    },
  );
}
