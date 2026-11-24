import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/app_document_route.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_urls.dart';
import 'package:pirc_render/src/html_form_submission.dart';

typedef _Handler = FutureOr<Json> Function(Json arguments);

class _DocumentGateway extends Gateway {
  final calls = <Json>[];
  final responses = <Json>[];
  final delayed = <String, Completer<Json>>{};
  _Handler? handler;

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'documentPrepareRequest') {
      return {
        'nativeCookieRequestKey':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      };
    }
    final arguments = Map<String, dynamic>.from(args);
    switch (method) {
      case 'boot':
        return {'origin': 'https://gateway.example', 'pairingStamp': 'stamp'};
      case 'resolveDocumentUrl':
        return resolveNativeDocumentUrl(
          arguments['reference'] as String,
          arguments['baseUrl'] as String,
        );
      case 'document':
        calls.add(arguments);
        final pending = delayed[arguments['url']];
        if (pending != null) return pending.future;
        final selectedHandler = handler;
        if (selectedHandler != null) return await selectedHandler(arguments);
        return responses.removeAt(0);
      default:
        throw StateError('Unexpected method: $method');
    }
  }
}

Json _response(
  Json arguments,
  String body, {
  int status = 200,
  String? finalUrl,
  String? finalMethod,
}) => {
  'bytes': Uint8List.fromList(utf8.encode(body)),
  'mimeType': 'text/html',
  'charset': 'UTF-8',
  'status': status,
  'finalUrl': finalUrl ?? arguments['url'],
  'finalMethod': finalMethod ?? arguments['method'],
  'headersRelevant': <String, dynamic>{
    'content-type': 'text/html; charset=UTF-8',
  },
};

const _pircShell = '''
<!doctype html><html lang="en"><head>
<meta name="description" content="A calm command surface for persistent coding-agent sessions.">
<meta name="apple-mobile-web-app-title" content="pirc">
<title>pirc</title></head><body><div id="app"></div>
<script type="module" src="/src/main.ts"></script></body></html>
''';

NativeHtmlFormRequest _request(
  String url, {
  String method = 'GET',
  String? body,
  String? contentType,
}) => NativeHtmlFormRequest(
  url: url,
  method: method,
  target: '',
  body: body,
  contentType: contentType,
);

NativeDocumentWindow _primary(
  NativeDocumentWindows windows, {
  String sourceUrl = 'https://gateway.example/?session=initial',
}) => windows.target('', null, sourceUrl: sourceUrl);

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 50 && !condition(); attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'primary back and forward traverse the virtual App source locally',
    () async {
      final gateway = _DocumentGateway()
        ..responses.addAll([
          _response({
            'url': 'https://gateway.example/page',
            'method': 'GET',
          }, '<title>Page</title><input value="keep me">'),
        ]);
      Object appState = 'initial-app-state';
      String? appUrl = 'https://gateway.example/?session=initial';
      final restored = <Object>[];
      final windows = NativeDocumentWindows(
        gateway,
        captureAppState: () => appState,
        restoreAppState: (state) async => restored.add(state),
        appDocumentUrl: () => appUrl,
        managedPresentation: true,
      );
      addTearDown(windows.dispose);
      final window = _primary(windows);

      expect(window.index, -1);
      expect(window.sourceState, 'initial-app-state');
      expect(window.sourceUrl, appUrl);
      expect(
        await window.load(_request('/page'), baseUrl: window.sourceUrl),
        NativeDocumentLoadResult.committed,
      );
      final page = window.currentDocument;
      expect(page, isNotNull);
      expect(window.canBack, isTrue);
      final callsAfterFetch = gateway.calls.length;

      window.back();
      expect(window.index, -1);
      expect(window.current, isNull);
      expect(window.sourceState, 'initial-app-state');
      expect(window.canForward, isTrue);
      expect(
        restored,
        isEmpty,
        reason: 'the persistent host owns async restore',
      );

      appState = 'refreshed-app-state';
      appUrl = 'https://gateway.example/?workspace=project%3Aone';
      window.captureCurrentAppState();
      expect(window.sourceState, 'refreshed-app-state');
      expect(window.sourceUrl, appUrl);

      window.forward();
      expect(window.index, 0);
      expect(window.currentDocument, same(page));
      expect(gateway.calls, hasLength(callsAfterFetch));
    },
  );

  test(
    'app-shell response becomes a typed history entry around a document',
    () async {
      final gateway = _DocumentGateway()
        ..responses.addAll([
          _response({
            'url': 'https://gateway.example/page',
            'method': 'GET',
          }, '<title>Saved native page</title><input value="preserved">'),
          _response({
            'url': 'https://gateway.example/?open=memory',
            'method': 'GET',
          }, _pircShell),
        ]);
      var capturedState = 'memory-screen-state';
      final windows = NativeDocumentWindows(
        gateway,
        onAppRoute: (_) async {},
        captureAppState: () => capturedState,
        restoreAppState: (_) async {},
        managedPresentation: true,
      );
      addTearDown(windows.dispose);
      final window = _primary(windows);
      await window.load(_request('/page'), baseUrl: window.sourceUrl);
      final page = window.currentDocument;

      expect(
        await window.load(
          _request('/?open=memory'),
          baseUrl: window.current!.url,
        ),
        NativeDocumentLoadResult.appRoute,
      );
      expect(
        gateway.calls,
        hasLength(2),
        reason: 'the shell was fetched over HTTP',
      );
      expect(window.history, hasLength(2));
      expect(window.history[0].document, same(page));
      expect(window.history[0].appRoute, isNull);
      expect(window.history[1].document, isNull);
      expect(
        window.history[1].appRoute!.target,
        isA<NativeAppMemoryRouteTarget>(),
      );
      expect(window.pendingAppRoute, same(window.currentAppRoute));

      final appEntry = window.current!;
      capturedState = 'memory-after-route-apply';
      window.captureCurrentAppState();
      expect(appEntry.appState, 'memory-after-route-apply');

      final callsAtRoute = gateway.calls.length;
      window.back();
      expect(window.currentDocument, same(page));
      expect(window.currentAppRoute, isNull);
      expect(window.pendingAppRoute, isNull);
      window.forward();
      expect(window.currentAppRoute, same(appEntry.appRoute));
      expect(window.current, same(appEntry));
      expect(window.pendingAppRoute, same(appEntry.appRoute));
      expect(appEntry.appState, 'memory-after-route-apply');
      expect(gateway.calls, hasLength(callsAtRoute));
    },
  );

  test(
    'a new document navigation truncates and disposes forward history',
    () async {
      final gateway = _DocumentGateway()
        ..responses.addAll([
          _response({
            'url': 'https://gateway.example/one',
            'method': 'GET',
          }, 'one'),
          _response({
            'url': 'https://gateway.example/two',
            'method': 'GET',
          }, 'two'),
          _response({
            'url': 'https://gateway.example/branch',
            'method': 'GET',
          }, 'branch'),
        ]);
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = _primary(windows);
      await window.load(_request('/one'), baseUrl: window.sourceUrl);
      await window.load(_request('/two'), baseUrl: window.current!.url);
      final removed = window.history[1].document!;

      window.back();
      expect(window.current!.url, 'https://gateway.example/one');
      await window.load(_request('/branch'), baseUrl: window.current!.url);

      expect(window.history, hasLength(2));
      expect(window.history.map((entry) => entry.url), [
        'https://gateway.example/one',
        'https://gateway.example/branch',
      ]);
      expect(window.canForward, isFalse);
      expect(gateway.calls, hasLength(3));
      expect(() => removed.scroll.addListener(() {}), throwsFlutterError);
    },
  );

  test(
    'fragment entries share document lifetime through forward truncation',
    () async {
      final gateway = _DocumentGateway()
        ..responses.addAll([
          _response({
            'url': 'https://gateway.example/page',
            'method': 'GET',
          }, '<a id="target">target</a>'),
          _response({
            'url': 'https://gateway.example/other',
            'method': 'GET',
          }, 'other'),
          _response({
            'url': 'https://gateway.example/replacement',
            'method': 'GET',
          }, 'replacement'),
        ]);
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = _primary(windows);
      await window.load(_request('/page'), baseUrl: window.sourceUrl);
      final page = window.currentDocument!;
      await window.load(
        _request('#target'),
        baseUrl: window.current!.url,
        fragmentAllowed: true,
      );
      expect(window.history[0].document, same(page));
      expect(window.history[1].document, same(page));
      window.back();

      await window.load(_request('/other'), baseUrl: window.current!.url);
      expect(window.history, hasLength(2));
      expect(window.history.first.document, same(page));
      expect(window.currentDocument, isNot(same(page)));

      void listener() {}

      page.scroll.addListener(listener);
      page.scroll.removeListener(listener);
      window.back();
      window.back();
      expect(window.index, -1);
      await window.load(_request('/replacement'), baseUrl: window.sourceUrl);
      expect(() => page.scroll.addListener(() {}), throwsFlutterError);
    },
  );

  test(
    '204/205 retain history and only a final GET shell becomes an App entry',
    () async {
      final gateway = _DocumentGateway()
        ..responses.addAll([
          _response({
            'url': 'https://gateway.example/page',
            'method': 'GET',
          }, 'page'),
          {
            'bytes': Uint8List(0),
            'mimeType': 'text/html',
            'charset': null,
            'status': 204,
            'finalUrl': 'https://gateway.example/submit',
            'finalMethod': 'POST',
            'headersRelevant': <String, dynamic>{},
          },
          {
            'bytes': Uint8List(0),
            'mimeType': 'text/html',
            'charset': null,
            'status': 205,
            'finalUrl': 'https://gateway.example/submit',
            'finalMethod': 'POST',
            'headersRelevant': <String, dynamic>{},
          },
          _response(
            {'url': 'https://gateway.example/submit', 'method': 'POST'},
            _pircShell,
            finalUrl: 'https://gateway.example/?session=posted',
            finalMethod: 'GET',
          ),
        ]);
      final windows = NativeDocumentWindows(
        gateway,
        onAppRoute: (_) async {},
        managedPresentation: true,
      );
      addTearDown(windows.dispose);
      final window = _primary(windows);
      await window.load(_request('/page'), baseUrl: window.sourceUrl);
      final pageEntry = window.current!;

      for (final status in [204, 205]) {
        expect(
          await window.load(
            _request('/submit', method: 'POST', body: 'x=1'),
            baseUrl: pageEntry.url,
          ),
          NativeDocumentLoadResult.retained,
        );
        expect(window.current, same(pageEntry), reason: 'status $status');
        expect(window.history, hasLength(1), reason: 'status $status');
        expect(window.index, 0, reason: 'status $status');
      }

      expect(
        await window.load(
          _request(
            '/submit',
            method: 'POST',
            body: 'field=exact+bytes',
            contentType: 'application/x-www-form-urlencoded',
          ),
          baseUrl: pageEntry.url,
        ),
        NativeDocumentLoadResult.appRoute,
      );
      expect(gateway.calls.last['method'], 'POST');
      expect(gateway.calls.last['body'], 'field=exact+bytes');
      expect(window.history, hasLength(2));
      expect(window.currentAppRoute, isNotNull);
      expect(window.currentDocument, isNull);
      expect(
        window.currentAppRoute!.target,
        isA<NativeAppSessionRouteTarget>(),
      );
    },
  );

  test(
    'final POST shell and error shell responses remain HTTP documents',
    () async {
      final gateway = _DocumentGateway()
        ..responses.addAll([
          _response(
            {'url': 'https://gateway.example/submit', 'method': 'POST'},
            _pircShell,
            finalUrl: 'https://gateway.example/?session=posted',
            finalMethod: 'POST',
          ),
          _response(
            {'url': 'https://gateway.example/api/providers', 'method': 'GET'},
            _pircShell,
            status: 403,
            finalUrl: 'https://gateway.example/api/providers',
          ),
        ]);
      final windows = NativeDocumentWindows(gateway, onAppRoute: (_) async {});
      addTearDown(windows.dispose);
      final window = _primary(windows);

      expect(
        await window.load(
          _request('/submit', method: 'POST', body: 'x=1'),
          baseUrl: window.sourceUrl,
        ),
        NativeDocumentLoadResult.committed,
      );
      expect(window.currentDocument!.status, 200);
      expect(window.currentAppRoute, isNull);
      expect(window.currentDocument!.reloadRequest!.method, 'POST');

      expect(
        await window.load(
          _request('/api/providers'),
          baseUrl: window.current!.url,
        ),
        NativeDocumentLoadResult.committed,
      );
      expect(window.currentDocument!.status, 403);
      expect(window.currentAppRoute, isNull);
      expect(window.history, hasLength(2));
    },
  );

  test('account change purges document and app-route entries', () async {
    final gateway = _DocumentGateway()
      ..responses.addAll([
        _response({
          'url': 'https://gateway.example/page',
          'method': 'GET',
        }, 'page'),
        _response({
          'url': 'https://gateway.example/?open=memory',
          'method': 'GET',
        }, _pircShell),
      ]);
    final owner = LiveController(gateway)
      ..origin = 'https://gateway.example'
      ..clientId = 'client'
      ..pairingStamp = 'stamp';
    final windows = NativeDocumentWindows(
      gateway,
      owner: owner,
      onAppRoute: (_) async {},
      captureAppState: () => 'state',
    );
    addTearDown(() {
      windows.dispose();
      owner.dispose();
    });
    final window = _primary(windows);
    await window.load(_request('/page'), baseUrl: window.sourceUrl);
    await window.load(_request('/?open=memory'), baseUrl: window.current!.url);
    expect(window.history, hasLength(2));
    expect(window.sourceState, 'state');

    owner.origin = 'https://replacement.example';
    owner.changed();

    expect(windows.windows, isEmpty);
    expect(window.disposed, isTrue);
    expect(window.history, isEmpty);
    expect(window.sourceState, isNull);
    expect(window.index, -1);
  });

  test(
    'moving to virtual source makes an in-flight shell reply stale',
    () async {
      final gateway = _DocumentGateway()
        ..responses.add(
          _response({
            'url': 'https://gateway.example/page',
            'method': 'GET',
          }, 'page'),
        );
      final pendingRoute = Completer<Json>();
      gateway.delayed['https://gateway.example/?session=late'] = pendingRoute;
      final windows = NativeDocumentWindows(gateway, onAppRoute: (_) async {});
      addTearDown(windows.dispose);
      final window = _primary(windows);
      await window.load(_request('/page'), baseUrl: window.sourceUrl);
      final page = window.currentDocument;
      final loading = window.load(
        _request('/?session=late'),
        baseUrl: window.current!.url,
      );
      await _waitUntil(
        () => gateway.calls.any(
          (call) => call['url'] == 'https://gateway.example/?session=late',
        ),
      );

      window.back();
      expect(window.index, -1);
      pendingRoute.complete(
        _response({
          'url': 'https://gateway.example/?session=late',
          'method': 'GET',
        }, _pircShell),
      );

      expect(await loading, NativeDocumentLoadResult.stale);
      expect(window.history, hasLength(1));
      expect(window.current, isNull);
      expect(window.currentDocument, isNull);
      expect(window.pendingAppRoute, isNull);
      expect(window.canForward, isTrue);
      expect(page, isNotNull);
    },
  );
}
