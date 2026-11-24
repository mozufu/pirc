import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_urls.dart';
import 'package:pirc_render/src/html_form_submission.dart';

typedef _DocumentHandler = FutureOr<Json> Function(Json arguments);

class _RecordedCall {
  const _RecordedCall(this.method, this.arguments);

  final String method;
  final Json arguments;
}

class _FakeDocumentGateway extends Gateway {
  final calls = <_RecordedCall>[];
  final bootResponse = <String, dynamic>{
    'origin': 'https://gateway.example',
    'pairingStamp': 'stamp',
  };
  _DocumentHandler? onDocument;

  List<_RecordedCall> get documentCalls =>
      calls.where((call) => call.method == 'document').toList();

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'documentPrepareRequest') {
      return {
        'nativeCookieRequestKey':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      };
    }
    final arguments = Map<String, dynamic>.from(args);
    calls.add(_RecordedCall(method, arguments));
    switch (method) {
      case 'documentStorageWindowOpen':
      case 'documentStorageWindowClose':
        return null;
      case 'boot':
        return Map<String, dynamic>.from(bootResponse);
      case 'resolveDocumentUrl':
        return resolveNativeDocumentUrl(
          arguments['reference'] as String,
          arguments['baseUrl'] as String,
        );
      case 'document':
        final handler = onDocument;
        if (handler != null) return await handler(arguments);
        return _htmlResponse(arguments, '<html><body></body></html>');
      default:
        throw StateError('Unexpected gateway call: $method');
    }
  }
}

Json _htmlResponse(
  Json arguments,
  String html, {
  int status = 200,
  String? finalUrl,
  String? finalMethod,
  String mimeType = 'text/html',
  String? charset = 'utf-8',
  Json? headersRelevant,
}) => _documentResponse(
  arguments,
  bytes: utf8.encode(html),
  status: status,
  finalUrl: finalUrl,
  finalMethod: finalMethod,
  mimeType: mimeType,
  charset: charset,
  headersRelevant: headersRelevant,
);

Json _documentResponse(
  Json arguments, {
  required List<int> bytes,
  int status = 200,
  String? finalUrl,
  String? finalMethod,
  String mimeType = 'text/html',
  String? charset = 'utf-8',
  Json? headersRelevant,
}) => {
  'bytes': Uint8List.fromList(bytes),
  'mimeType': mimeType,
  'charset': charset,
  'status': status,
  'finalUrl': finalUrl ?? arguments['url'],
  'finalMethod': finalMethod ?? arguments['method'],
  'headersRelevant':
      headersRelevant ??
      <String, dynamic>{
        'content-type': charset == null
            ? mimeType
            : '$mimeType; charset=$charset',
        'x-document-test': 'present',
      },
};

NativeHtmlFormRequest _request(
  String url, {
  String method = 'GET',
  String target = '',
  String? body,
  String? contentType,
}) => NativeHtmlFormRequest(
  url: url,
  method: method,
  target: target,
  body: body,
  contentType: contentType,
);

NativeDocumentWindow _rootWindow(NativeDocumentWindows windows) =>
    windows.target('', null, sourceUrl: 'https://site.example/source.html');

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 20 && !condition(); attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'Storage namespace survives reload, clones opener once and closes with its window',
    () async {
      final gateway = _FakeDocumentGateway();
      gateway.bootResponse['documentStorage'] = true;
      final windows = NativeDocumentWindows(gateway);
      final root = _rootWindow(windows);
      expect(
        await root.load(_request('/first'), baseUrl: root.sourceUrl),
        NativeDocumentLoadResult.committed,
      );
      expect(
        await root.load(_request('/second'), baseUrl: root.sourceUrl),
        NativeDocumentLoadResult.committed,
      );
      final rootKey = root.storageSessionKey;
      final child = windows.target('child', root, sourceUrl: root.current!.url);
      await child.load(_request('/child'), baseUrl: root.sourceUrl);
      final blank = windows.target(
        '_blank',
        root,
        sourceUrl: root.current!.url,
      );
      await blank.load(_request('/blank'), baseUrl: root.sourceUrl);
      final explicitOpener = windows.target(
        '_blank',
        root,
        sourceUrl: root.current!.url,
        noopener: false,
      );
      await explicitOpener.load(_request('/opener'), baseUrl: root.sourceUrl);
      final opens = gateway.calls
          .where((call) => call.method == 'documentStorageWindowOpen')
          .toList();
      expect(opens.length, 4);
      expect(opens[0].arguments['sessionKey'], rootKey);
      expect(opens[1].arguments['openerKey'], rootKey);
      expect(opens[2].arguments.containsKey('openerKey'), false);
      expect(opens[3].arguments['openerKey'], rootKey);
      expect(opens.map((e) => e.arguments['sessionKey']).toSet().length, 4);
      final openIndex = gateway.calls.indexOf(opens[0]);
      expect(
        openIndex,
        lessThan(gateway.calls.indexOf(gateway.documentCalls.first)),
      );
      windows.close(child);
      await _waitUntil(
        () => gateway.calls.any(
          (call) => call.method == 'documentStorageWindowClose',
        ),
      );
      expect(
        gateway.calls
            .where((call) => call.method == 'documentStorageWindowClose')
            .single
            .arguments['sessionKey'],
        child.storageSessionKey,
      );
      windows.dispose();
    },
  );

  test(
    'noopener named targets create isolated windows rather than reusing the named opener',
    () {
      final windows = NativeDocumentWindows(_FakeDocumentGateway());
      final root = _rootWindow(windows);
      final named = windows.target('named', root, sourceUrl: root.sourceUrl);
      final isolated = windows.target(
        'named',
        root,
        sourceUrl: root.sourceUrl,
        noopener: true,
      );
      expect(isolated, isNot(same(named)));
      expect(isolated.name, '');
      expect(isolated.storageOpenerKey, isNull);
      expect(
        windows.target('named', root, sourceUrl: root.sourceUrl),
        same(named),
      );
      windows.dispose();
    },
  );

  test('load decodes response bytes using the transport charset', () async {
    final gateway = _FakeDocumentGateway();
    final windows = NativeDocumentWindows(gateway);
    addTearDown(windows.dispose);
    final window = _rootWindow(windows);
    const finalUrl = 'https://site.example/redirected/page.html';
    final bytes = <int>[
      ...ascii.encode(
        '<!doctype html><html><head><title>Decoded response</title></head>'
        '<body><p>',
      ),
      0x80,
      ...ascii.encode('</p></body></html>'),
    ];
    gateway.onDocument = (arguments) => _documentResponse(
      arguments,
      bytes: bytes,
      finalUrl: finalUrl,
      charset: 'windows-1252',
      headersRelevant: {'content-type': 'text/html; charset=windows-1252'},
    );

    final result = await window.load(
      _request('/document'),
      baseUrl: 'https://site.example/source.html',
    );

    expect(result, NativeDocumentLoadResult.committed);
    expect(window.current!.url, finalUrl);
    expect(window.current!.document!.content.encoding, 'windows-1252');
    expect(window.current!.document!.content.title, 'Decoded response');
    expect(window.current!.document!.content.bodyInnerHtml, '<p>€</p>');
    expect(
      window.current!.document!.headers['content-type'],
      'text/html; charset=windows-1252',
    );
    expect(gateway.documentCalls.single.arguments['pairingStamp'], 'stamp');
  });

  test(
    'reload request uses final redirect method and original POST bytes',
    () async {
      for (final finalMethod in ['GET', 'POST']) {
        final gateway = _FakeDocumentGateway()
          ..onDocument = (arguments) => _htmlResponse(
            arguments,
            '<html><body>result</body></html>',
            finalUrl: 'https://site.example/final?kept=%7E',
            finalMethod: finalMethod,
          );
        final windows = NativeDocumentWindows(gateway);
        addTearDown(windows.dispose);
        final window = _rootWindow(windows);
        const originalBody = 'message=%E4%B8%AD&space=+';
        const originalContentType = 'application/x-www-form-urlencoded';

        expect(
          await window.load(
            _request(
              '/start',
              method: 'POST',
              body: originalBody,
              contentType: originalContentType,
            ),
            baseUrl: 'https://site.example/start',
          ),
          NativeDocumentLoadResult.committed,
        );

        final reload = window.current!.document!.reloadRequest!;
        expect(reload.url, 'https://site.example/final?kept=%7E');
        expect(reload.method, finalMethod);
        if (finalMethod == 'POST') {
          expect(reload.body, originalBody);
          expect(reload.contentType, originalContentType);
        } else {
          expect(reload.body, isNull);
          expect(reload.contentType, isNull);
        }
      }
    },
  );

  test(
    'binary POST freezes transport and replay bytes across redirects',
    () async {
      for (final finalMethod in ['GET', 'POST']) {
        final gateway = _FakeDocumentGateway()
          ..onDocument = (arguments) => _htmlResponse(
            arguments,
            '<html><body>uploaded</body></html>',
            finalUrl: 'https://site.example/final',
            finalMethod: finalMethod,
          );
        final windows = NativeDocumentWindows(gateway);
        addTearDown(windows.dispose);
        final window = _rootWindow(windows);
        final original = Uint8List.fromList([0, 127, 128, 255, 13, 10]);
        final expected = List<int>.from(original);
        final pending = window.load(
          NativeHtmlFormRequest(
            url: '/upload',
            method: 'POST',
            target: '',
            bodyBytes: original,
            contentType: 'multipart/form-data; boundary=test',
          ),
          baseUrl: 'https://site.example/start',
        );
        original.fillRange(0, original.length, 42);
        expect(await pending, NativeDocumentLoadResult.committed);
        final sent = gateway.documentCalls.single.arguments;
        expect(sent['body'], isNull);
        expect(sent['bodyBytes'], orderedEquals(expected));
        expect(sent['contentType'], 'multipart/form-data; boundary=test');
        final reload = window.current!.document!.reloadRequest!;
        expect(reload.method, finalMethod);
        if (finalMethod == 'POST') {
          expect(reload.bodyBytes, orderedEquals(expected));
          expect(() => reload.bodyBytes![0] = 99, throwsUnsupportedError);
        } else {
          expect(reload.bodyBytes, isNull);
          expect(reload.contentType, isNull);
        }
      }
    },
  );

  test('resolves baseHref against the response final URL', () async {
    final gateway = _FakeDocumentGateway()
      ..onDocument = (arguments) => _htmlResponse(
        arguments,
        '<html><head><base href="assets/"></head><body>page</body></html>',
        finalUrl: 'https://site.example/redirected/section/index.html',
      );
    final windows = NativeDocumentWindows(gateway);
    addTearDown(windows.dispose);
    final window = _rootWindow(windows);

    final result = await window.load(
      _request('/original'),
      baseUrl: 'https://site.example/source.html',
    );

    expect(result, NativeDocumentLoadResult.committed);
    expect(window.current!.document!.content.baseHref, 'assets/');
    expect(
      window.current!.document!.effectiveBase,
      'https://site.example/redirected/section/assets/',
    );
  });

  test(
    'form GET with a fragment fetches while a link may use history',
    () async {
      final gateway = _FakeDocumentGateway()
        ..onDocument = (arguments) =>
            _htmlResponse(arguments, '<html><body><p>Page</p></body></html>');
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = _rootWindow(windows);
      const base = 'https://site.example/page#before';

      expect(
        await window.load(_request(base), baseUrl: base),
        NativeDocumentLoadResult.committed,
      );
      final firstDocument = window.current!.document!;

      // Form callers leave fragmentAllowed false, so this identical-path GET
      // still goes through the transport.
      expect(
        await window.load(_request('/page#submitted'), baseUrl: base),
        NativeDocumentLoadResult.committed,
      );
      final formDocument = window.current!.document!;
      expect(gateway.documentCalls, hasLength(2));
      expect(formDocument, isNot(same(firstDocument)));

      expect(
        await window.load(
          _request('#linked'),
          baseUrl: window.current!.url,
          fragmentAllowed: true,
        ),
        NativeDocumentLoadResult.committed,
      );
      expect(gateway.documentCalls, hasLength(2));
      expect(window.history, hasLength(3));
      expect(window.current!.url, 'https://site.example/page#linked');
      expect(window.history[2].document, same(formDocument));
    },
  );

  test(
    '204 and 205 retain the current document and its history item',
    () async {
      final gateway = _FakeDocumentGateway();
      var responseIndex = 0;
      final servedStatuses = <int>[];
      gateway.onDocument = (arguments) {
        if (responseIndex++ == 0) {
          return _htmlResponse(arguments, '<html><body>editable</body></html>');
        }
        final status = responseIndex == 2 ? 204 : 205;
        servedStatuses.add(status);
        return _documentResponse(
          arguments,
          bytes: const [],
          status: status,
          charset: null,
        );
      };
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = _rootWindow(windows);
      await window.load(
        _request('/edit'),
        baseUrl: 'https://site.example/source.html',
      );
      final item = window.current!;
      final document = item.document!;
      document.resolvedBase = 'https://site.example/edited-base/';
      document.viewport.resolvingAnchor = true;

      for (final expectedStatus in [204, 205]) {
        final result = await window.load(
          _request('/submit', method: 'POST', body: 'field=edited'),
          baseUrl: item.url,
        );

        expect(result, NativeDocumentLoadResult.retained);
        expect(window.history, hasLength(1));
        expect(window.current, same(item));
        expect(window.current!.document!, same(document));
        expect(document.resolvedBase, 'https://site.example/edited-base/');
        expect(document.viewport.resolvingAnchor, isTrue);
        expect(gateway.documentCalls.last.arguments['method'], 'POST');
        expect(gateway.documentCalls.last.arguments['body'], 'field=edited');
        expect(servedStatuses.last, expectedStatus);
      }
      expect(servedStatuses, [204, 205]);
    },
  );

  test('4xx response bodies commit as documents', () async {
    final gateway = _FakeDocumentGateway()
      ..onDocument = (arguments) => _htmlResponse(
        arguments,
        '<html><head><title>Missing</title></head>'
        '<body><p>Not here</p></body></html>',
        status: 404,
      );
    final windows = NativeDocumentWindows(gateway);
    addTearDown(windows.dispose);
    final window = _rootWindow(windows);

    final result = await window.load(
      _request('/missing'),
      baseUrl: 'https://site.example/source.html',
    );

    expect(result, NativeDocumentLoadResult.committed);
    expect(window.current!.document!.status, 404);
    expect(window.current!.document!.content.title, 'Missing');
    expect(window.current!.document!.content.bodyInnerHtml, '<p>Not here</p>');
    expect(window.error, isNull);
  });

  test(
    'back and forward reuse history documents without replaying POST',
    () async {
      final gateway = _FakeDocumentGateway()
        ..onDocument = (arguments) => _htmlResponse(
          arguments,
          '<html><body>${arguments['url']}</body></html>',
        );
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = _rootWindow(windows);

      expect(
        await window.load(
          _request(
            '/submitted',
            method: 'POST',
            body: 'name=first',
            contentType: 'application/x-www-form-urlencoded',
          ),
          baseUrl: 'https://site.example/source.html',
        ),
        NativeDocumentLoadResult.committed,
      );
      final postDocument = window.current!.document!;
      expect(
        await window.load(_request('/next'), baseUrl: window.current!.url),
        NativeDocumentLoadResult.committed,
      );
      final getDocument = window.current!.document!;

      expect(gateway.documentCalls, hasLength(2));
      expect(gateway.documentCalls.first.arguments['method'], 'POST');
      expect(gateway.documentCalls.first.arguments['body'], 'name=first');
      expect(gateway.documentCalls.last.arguments['method'], 'GET');

      window.back();
      expect(window.current!.document!, same(postDocument));
      window.forward();
      expect(window.current!.document!, same(getDocument));
      expect(gateway.documentCalls, hasLength(2));
    },
  );

  test('a stale response cannot replace a newer committed document', () async {
    final gateway = _FakeDocumentGateway();
    final slowResponse = Completer<Json>();
    gateway.onDocument = (arguments) {
      if ((arguments['url'] as String).endsWith('/slow')) {
        return slowResponse.future;
      }
      return _htmlResponse(arguments, '<html><body>fast</body></html>');
    };
    final windows = NativeDocumentWindows(gateway);
    addTearDown(windows.dispose);
    final window = _rootWindow(windows);
    const base = 'https://site.example/start';

    final staleLoad = window.load(_request('/slow'), baseUrl: base);
    await _waitUntil(
      () => gateway.documentCalls.any(
        (call) => (call.arguments['url'] as String).endsWith('/slow'),
      ),
    );
    expect(
      gateway.documentCalls.any(
        (call) => (call.arguments['url'] as String).endsWith('/slow'),
      ),
      isTrue,
    );

    expect(
      await window.load(_request('/fast'), baseUrl: base),
      NativeDocumentLoadResult.committed,
    );
    slowResponse.complete(
      _htmlResponse({
        'url': 'https://site.example/slow',
      }, '<html><body>slow</body></html>'),
    );

    expect(await staleLoad, NativeDocumentLoadResult.stale);
    expect(window.history, hasLength(1));
    expect(window.current!.url, 'https://site.example/fast');
    expect(window.current!.document!.content.bodyInnerHtml, 'fast');
  });

  test('owner changes clear documents and suppress pending replies', () async {
    final gateway = _FakeDocumentGateway();
    final owner = LiveController(gateway)
      ..origin = 'https://gateway.example'
      ..clientId = 'client'
      ..pairingStamp = 'stamp';
    final windows = NativeDocumentWindows(gateway, owner: owner);
    addTearDown(() {
      windows.dispose();
      owner.dispose();
    });
    final window = _rootWindow(windows);
    gateway.onDocument = (arguments) =>
        _htmlResponse(arguments, '<html><body>current</body></html>');
    expect(
      await window.load(
        _request('/current'),
        baseUrl: 'https://site.example/source.html',
      ),
      NativeDocumentLoadResult.committed,
    );
    final lateResponse = Completer<Json>();
    gateway.onDocument = (arguments) {
      if ((arguments['url'] as String).endsWith('/late')) {
        return lateResponse.future;
      }
      return _htmlResponse(arguments, '<html><body>unexpected</body></html>');
    };
    final staleLoad = window.load(
      _request('/late'),
      baseUrl: window.current!.url,
    );
    await _waitUntil(
      () => gateway.documentCalls.any(
        (call) => (call.arguments['url'] as String).endsWith('/late'),
      ),
    );
    expect(
      gateway.documentCalls.any(
        (call) => (call.arguments['url'] as String).endsWith('/late'),
      ),
      isTrue,
    );

    owner.origin = 'https://replacement.example';
    owner.changed();
    expect(windows.windows, isEmpty);
    expect(windows.active, isNull);
    expect(windows.connectionError, isNotNull);
    expect(window.disposed, isTrue);
    expect(window.history, isEmpty);

    lateResponse.complete(
      _htmlResponse({
        'url': 'https://site.example/late',
      }, '<html><body>late</body></html>'),
    );
    expect(await staleLoad, NativeDocumentLoadResult.stale);
    expect(windows.windows, isEmpty);
  });

  test('_blank creates contexts and named targets reuse their own window', () {
    final windows = NativeDocumentWindows(_FakeDocumentGateway());
    addTearDown(windows.dispose);
    final source = _rootWindow(windows);

    final blank = windows.target(
      '_BLANK',
      source,
      sourceUrl: 'https://site.example/page',
    );
    final secondBlank = windows.target(
      '_blank',
      source,
      sourceUrl: 'https://site.example/page',
    );
    final named = windows.target(
      'ReportWindow',
      source,
      sourceUrl: 'https://site.example/page',
    );
    final reused = windows.target(
      'ReportWindow',
      blank,
      sourceUrl: 'https://site.example/other',
    );

    expect(blank, isNot(same(source)));
    expect(secondBlank, isNot(same(blank)));
    expect(named, same(reused));
    expect(named, isNot(same(source)));
    expect(named, isNot(same(blank)));
    expect(
      windows.target(
        'reportwindow',
        source,
        sourceUrl: 'https://site.example/page',
      ),
      isNot(same(named)),
    );
  });

  test(
    'empty target and reserved target keywords are ASCII case-insensitive',
    () {
      final windows = NativeDocumentWindows(_FakeDocumentGateway());
      addTearDown(windows.dispose);
      final root = _rootWindow(windows);

      for (final target in [
        '',
        '_self',
        '_SELF',
        '_parent',
        '_PARENT',
        '_top',
        '_TOP',
      ]) {
        expect(
          windows.target(target, root, sourceUrl: 'https://site.example/other'),
          same(root),
          reason: target,
        );
      }
      expect(
        windows.target(
          '_sElF',
          null,
          sourceUrl: 'https://site.example/source.html',
        ),
        same(root),
      );
    },
  );

  test(
    'History API entries retain independent state and same document',
    () async {
      final gateway = _FakeDocumentGateway()
        ..onDocument = (arguments) => _htmlResponse(
          arguments,
          '<html><body>single document</body></html>',
        );
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = _rootWindow(windows);

      expect(
        await window.load(
          _request('/app/page'),
          baseUrl: 'https://site.example/source.html',
        ),
        NativeDocumentLoadResult.committed,
      );
      final document = window.current!.document!;
      final initialKey = window.current!.entryKey;
      window.current!.scrollOffset = 37;

      expect(window.scriptHistorySnapshot['index'], 1);
      expect(window.scriptHistorySnapshot['length'], 2);

      final firstState = <String, Object?>{
        'root': 'first',
        'nodes': <Object?>[1],
      };
      window.applyHistoryApiMutation(
        document: document,
        method: 'push',
        revision: 1,
        url: 'sub/page',
        entryKey: 'runtime:first',
        stateGraph: firstState,
        scrollRestoration: 'manual',
      );
      (firstState['nodes'] as List<Object?>).add(2);

      expect(window.current!.url, 'https://site.example/app/sub/page');
      expect(window.current!.document, same(document));
      expect(window.current!.entryKey, 'runtime:first');
      expect(window.current!.stateGraph, {
        'root': 'first',
        'nodes': [1],
      });
      expect(window.current!.scrollOffset, 37);
      expect(document.effectiveBase, 'https://site.example/app/sub/page');
      expect(
        resolveNativeDocumentUrl('child', document.effectiveBase),
        'https://site.example/app/sub/child',
      );

      window.applyHistoryApiMutation(
        document: document,
        method: 'pushState',
        revision: 2,
        url: window.current!.url,
        entryKey: 'runtime:second',
        stateGraph: {'root': 'second'},
        scrollRestoration: 'manual',
      );
      final replacedKey = window.current!.entryKey;
      window.applyHistoryApiMutation(
        document: document,
        method: 'replace',
        revision: 3,
        url: window.current!.url,
        entryKey: replacedKey,
        stateGraph: {'root': 'replaced'},
        scrollRestoration: 'auto',
      );

      expect(window.current!.entryKey, 'runtime:second');
      expect(window.current!.scrollRestoration, 'auto');
      expect(window.current!.stateGraph, {'root': 'replaced'});
      expect(window.scriptHistorySnapshot['index'], 3);
      expect(window.scriptHistorySnapshot['length'], 4);
      expect(document.historyApiAckRevision, 3);
      expect(gateway.documentCalls, hasLength(1));

      expect(
        await window.traverseHistory(1),
        NativeDocumentLoadResult.committed,
      );
      expect(window.current!.entryKey, 'runtime:first');
      expect(window.current!.stateGraph, {
        'root': 'first',
        'nodes': [1],
      });
      expect(window.current!.scrollRestoration, 'manual');
      expect(window.current!.document, same(document));
      expect(document.historyApiLocation, 'https://site.example/app/sub/page');
      expect(
        window.scriptHistorySnapshot['previousEntryKey'],
        'runtime:second',
      );
      expect(window.scriptHistorySnapshot['changeKind'], 'traverse');
      expect(window.current!.entryKey, isNot(initialKey));
      expect(gateway.documentCalls, hasLength(1));
    },
  );

  test(
    'History API rejects cross-origin, credential, and cyclic state input',
    () async {
      final gateway = _FakeDocumentGateway();
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = _rootWindow(windows);
      await window.load(
        _request('/page'),
        baseUrl: 'https://site.example/source.html',
      );
      final document = window.current!.document!;

      for (final url in [
        'https://other.example/page',
        'http://site.example/page',
        'https://user@site.example/page',
        'javascript:alert(1)',
      ]) {
        expect(
          () => window.applyHistoryApiMutation(
            document: document,
            method: 'push',
            revision: 1,
            url: url,
            entryKey: 'bad-url',
            stateGraph: const <String, Object?>{},
          ),
          throwsA(isA<FormatException>()),
          reason: url,
        );
        expect(document.historyApiAckRevision, 0);
        expect(window.history, hasLength(1));
      }

      final cyclic = <String, Object?>{};
      cyclic['self'] = cyclic;
      expect(
        () => window.applyHistoryApiMutation(
          document: document,
          method: 'push',
          revision: 1,
          url: window.current!.url,
          entryKey: 'cyclic',
          stateGraph: cyclic,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(document.historyApiAckRevision, 0);
      expect(window.history, hasLength(1));
    },
  );

  test(
    'GET history refetch preserves sibling History API state and keys',
    () async {
      final gateway = _FakeDocumentGateway()
        ..onDocument = (arguments) => _htmlResponse(
          arguments,
          '<html><body>${arguments['url']}</body></html>',
          headersRelevant: {
            'content-type': 'text/html; charset=utf-8',
            'cache-control': 'no-store',
          },
        );
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = _rootWindow(windows);
      await window.load(
        _request('/page'),
        baseUrl: 'https://site.example/source.html',
      );
      final oldDocument = window.current!.document!;
      final key0 = window.current!.entryKey;
      window.applyHistoryApiMutation(
        document: oldDocument,
        method: 'push',
        revision: 1,
        url: '#one',
        entryKey: 'state:one',
        stateGraph: {'value': 1},
      );
      window.applyHistoryApiMutation(
        document: oldDocument,
        method: 'push',
        revision: 2,
        url: '#two',
        entryKey: 'state:two',
        stateGraph: {'value': 2},
      );
      final key1 = window.history[1].entryKey;
      final key2 = window.history[2].entryKey;

      await window.load(_request('/next'), baseUrl: window.current!.url);
      expect(window.current!.url, 'https://site.example/next');

      expect(
        await window.traverseHistory(2),
        NativeDocumentLoadResult.committed,
      );
      final refreshedDocument = window.current!.document!;
      expect(refreshedDocument, isNot(same(oldDocument)));
      expect(window.current!.entryKey, key2);
      expect(window.current!.stateGraph, {'value': 2});
      expect(refreshedDocument.historyApiAckRevision, 2);
      expect(window.history[0].entryKey, key0);
      expect(window.history[1].entryKey, key1);
      expect(window.history[1].stateGraph, {'value': 1});
      expect(window.history[1].document, same(refreshedDocument));
      expect(window.history[0].document, same(refreshedDocument));
      expect(gateway.documentCalls, hasLength(3));

      expect(
        await window.traverseHistory(1),
        NativeDocumentLoadResult.committed,
      );
      expect(window.current!.entryKey, key1);
      expect(window.current!.stateGraph, {'value': 1});
      expect(window.current!.document, same(refreshedDocument));
      expect(gateway.documentCalls, hasLength(3));
    },
  );

  test(
    'cached POST document restoration keeps History API state and ack',
    () async {
      final gateway = _FakeDocumentGateway()
        ..onDocument = (arguments) => _htmlResponse(
          arguments,
          '<html><body>submitted</body></html>',
          finalMethod: arguments['method'] as String,
        );
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = _rootWindow(windows);
      await window.load(
        _request('/submitted', method: 'POST', body: 'field=value'),
        baseUrl: 'https://site.example/source.html',
      );
      final document = window.current!.document!;
      window.applyHistoryApiMutation(
        document: document,
        method: 'push',
        revision: 1,
        url: '#state',
        entryKey: 'post:state',
        stateGraph: {'value': 'kept'},
      );
      await window.load(_request('/next'), baseUrl: window.current!.url);

      expect(
        await window.traverseHistory(1),
        NativeDocumentLoadResult.committed,
      );
      expect(window.current!.entryKey, 'post:state');
      expect(window.current!.stateGraph, {'value': 'kept'});
      expect(window.current!.document, isNot(same(document)));
      expect(window.current!.document!.historyApiAckRevision, 1);
      expect(gateway.documentCalls, hasLength(2));
    },
  );
}
