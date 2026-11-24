import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_form_submission.dart';

import 'document_navigation_widget_test.dart' show DocumentGateway, response;
import 'live_test.dart' show theme;

NativeHtmlFormRequest _get(String url) =>
    NativeHtmlFormRequest(url: url, method: 'GET', target: '');

const _pircDescription =
    'A calm command surface for persistent coding-agent sessions.';

String _pircShell() =>
    '<!doctype html><html><head>'
    '<meta name="description" content="$_pircDescription">'
    '<meta name="apple-mobile-web-app-title" content="pirc">'
    '<title>pirc</title></head><body><div id="app"></div>'
    '<script type="module" src="/src/main.ts"></script>'
    '</body></html>';

Json _cacheableResponse(String path, String body) {
  final result = response(path, body);
  result['headersRelevant'] = <String, String>{
    'Cache-Control': 'max-age=3600',
    'Content-Type': 'text/html; charset=utf-8',
    'ETag': '"history-v1"',
  };
  return result;
}

Json _noStoreResponse(String path, String body) {
  final result = response(path, body, finalMethod: 'POST');
  result['headersRelevant'] = <String, String>{
    'Cache-Control': 'no-store',
    'Content-Type': 'text/html; charset=utf-8',
  };
  return result;
}

Json _cacheablePostResponse(
  String path,
  String body, {
  String cacheControl = 'public, max-age=3600',
}) {
  final result = response(path, body, finalMethod: 'POST');
  result['headersRelevant'] = <String, String>{
    'Cache-Control': cacheControl,
    'Content-Location': 'https://gateway.example$path',
    'Content-Type': 'text/html; charset=utf-8',
  };
  return result;
}

class _NamedHistory {
  const _NamedHistory({
    required this.gateway,
    required this.windows,
    required this.opener,
    required this.window,
  });

  final DocumentGateway gateway;
  final NativeDocumentWindows windows;
  final NativeDocumentWindow opener;
  final NativeDocumentWindow window;
}

Future<_NamedHistory> _createNamedHistory(
  DocumentGateway gateway, {
  String firstBody = '<title>First old</title>',
  String secondBody = '<title>Second old</title>',
}) async {
  gateway.responses.addAll([
    response('/opener', '<title>Opener</title>'),
    response('/first', firstBody),
    response('/second', secondBody),
  ]);
  final windows = NativeDocumentWindows(gateway);
  final opener = windows.target(
    'opener',
    null,
    sourceUrl: 'https://gateway.example/',
  );
  await opener.load(_get('/opener'), baseUrl: opener.sourceUrl);
  final window = windows.target(
    'report',
    opener,
    sourceUrl: opener.current!.url,
  );
  await window.load(_get('/first'), baseUrl: opener.current!.url);
  await window.load(_get('/second'), baseUrl: window.current!.url);
  return _NamedHistory(
    gateway: gateway,
    windows: windows,
    opener: opener,
    window: window,
  );
}

Widget _hostedApp(NativeDocumentWindows windows, {Key? hostKey}) => MaterialApp(
  theme: theme.build(Brightness.light),
  home: NativeDocumentScope(
    windows: windows,
    documentUrl: 'https://gateway.example/?session=source',
    sourceIdentity: windows.accountIdentity,
    child: NativeDocumentHost(
      key: hostKey,
      windows: windows,
      child: const Scaffold(body: Center(child: Text('App source'))),
    ),
  ),
);

class _GateDocumentGateway extends DocumentGateway {
  String? blockedUrl;
  Completer<void>? entered;
  Completer<void>? release;

  void block(String url) {
    blockedUrl = url;
    entered = Completer<void>();
    release = Completer<void>();
  }

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'documentPrepareRequest') {
      return {
        'nativeCookieRequestKey':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      };
    }
    if (method != 'document') return super.call(method, args);
    calls.add(args);
    final result = responses.removeAt(0);
    if (args['url'] == blockedUrl) {
      if (!entered!.isCompleted) entered!.complete();
      await release!.future;
    }
    return result;
  }
}

void main() {
  group('named-window GET history restoration', () {
    test(
      'Back and Forward refetch GET entries and replace their slots',
      () async {
        final gateway = DocumentGateway();
        final fixture = await _createNamedHistory(gateway);
        addTearDown(fixture.windows.dispose);
        final window = fixture.window;
        final oldFirst = window.history[0].document!;
        final oldSecond = window.currentDocument!;
        gateway.responses.addAll([
          response('/first', '<title>First refreshed</title>'),
          response('/second', '<title>Second refreshed</title>'),
        ]);
        final length = window.history.length;

        expect(
          await window.traverseHistory(0),
          NativeDocumentLoadResult.committed,
        );

        expect(gateway.calls, hasLength(4));
        expect(gateway.calls.last['url'], 'https://gateway.example/first');
        expect(gateway.calls.last['method'], 'GET');
        expect(gateway.calls.last['body'], isNull);
        expect(gateway.calls.last['cacheMode'], 'default');
        expect(window.index, 0);
        expect(window.history, hasLength(length));
        expect(window.canForward, isTrue);
        expect(window.currentDocument, isNot(same(oldFirst)));
        expect(oldFirst.historyControls.isDisposed, isTrue);
        expect(window.currentDocument!.content.title, 'First refreshed');

        expect(
          await window.traverseHistory(1),
          NativeDocumentLoadResult.committed,
        );
        expect(gateway.calls, hasLength(5));
        expect(gateway.calls.last['url'], 'https://gateway.example/second');
        expect(gateway.calls.last['method'], 'GET');
        expect(window.index, 1);
        expect(window.history, hasLength(length));
        expect(window.currentDocument, isNot(same(oldSecond)));
        expect(window.currentDocument!.content.title, 'Second refreshed');
      },
    );

    for (final status in [204, 205]) {
      test(
        '$status keeps the visible entry and cursor during history GET',
        () async {
          final gateway = DocumentGateway();
          final fixture = await _createNamedHistory(gateway);
          addTearDown(fixture.windows.dispose);
          final window = fixture.window;
          final visibleDocument = window.currentDocument;
          final length = window.history.length;
          gateway.responses.add(response('/first', '', status: status));

          expect(
            await window.traverseHistory(0),
            NativeDocumentLoadResult.retained,
          );

          expect(window.index, 1);
          expect(window.history, hasLength(length));
          expect(window.currentDocument, same(visibleDocument));
          expect(window.canForward, isFalse);
          expect(gateway.calls.last['url'], 'https://gateway.example/first');
          expect(gateway.calls.last['method'], 'GET');
        },
      );
    }

    test(
      'fresh cache hit builds a new document without another network fetch',
      () async {
        final gateway = DocumentGateway()
          ..responses.addAll([
            response('/opener', '<title>Opener</title>'),
            _cacheableResponse('/first', '<title>Cached first</title>'),
            response('/second', '<title>Second</title>'),
          ]);
        final windows = NativeDocumentWindows(gateway);
        addTearDown(windows.dispose);
        final opener = windows.target(
          'opener',
          null,
          sourceUrl: 'https://gateway.example/',
        );
        await opener.load(_get('/opener'), baseUrl: opener.sourceUrl);
        final window = windows.target(
          'report',
          opener,
          sourceUrl: opener.current!.url,
        );
        await window.load(_get('/first'), baseUrl: opener.current!.url);
        final first = window.currentDocument!;
        await window.load(_get('/second'), baseUrl: first.url);
        expect(window.history[0].requiresHistoryRefetch, isTrue);
        final callsBeforeBack = gateway.calls.length;

        expect(
          await window.traverseHistory(0),
          NativeDocumentLoadResult.committed,
        );

        final restored = window.currentDocument!;
        expect(gateway.calls, hasLength(callsBeforeBack));
        expect(window.history, hasLength(2));
        expect(window.index, 0);
        expect(restored, isNot(same(first)));
        expect(restored.id, isNot(first.id));
        expect(restored.bytes, orderedEquals(first.bytes));
        expect(restored.content.title, 'Cached first');
        expect(first.historyControls.isDisposed, isTrue);
      },
    );

    test(
      'named App-shell history refetches and replaces its route entry',
      () async {
        final gateway = DocumentGateway()
          ..responses.addAll([
            response('/opener', '<title>Opener</title>'),
            response('/index.html?session=one', _pircShell()),
            response('/next', '<title>Next document</title>'),
            response('/index.html?session=one', _pircShell()),
          ]);
        final windows = NativeDocumentWindows(
          gateway,
          onAppRoute: (_) async {},
          appBuilder: (_) => const SizedBox.shrink(),
        );
        addTearDown(windows.dispose);
        final opener = windows.target(
          'opener',
          null,
          sourceUrl: 'https://gateway.example/',
        );
        await opener.load(_get('/opener'), baseUrl: opener.sourceUrl);
        final window = windows.target(
          'report',
          opener,
          sourceUrl: opener.current!.url,
        );
        expect(
          await window.load(
            _get('/index.html?session=one'),
            baseUrl: opener.current!.url,
          ),
          NativeDocumentLoadResult.appRoute,
        );
        final oldRoute = window.history.single;
        await window.load(_get('/next'), baseUrl: oldRoute.url);
        expect(oldRoute.requiresHistoryRefetch, isTrue);
        final length = window.history.length;

        expect(
          await window.traverseHistory(0),
          NativeDocumentLoadResult.appRoute,
        );

        expect(gateway.calls, hasLength(4));
        expect(
          gateway.calls.last['url'],
          'https://gateway.example/index.html?session=one',
        );
        expect(gateway.calls.last['method'], 'GET');
        expect(window.history, hasLength(length));
        expect(window.index, 0);
        expect(window.currentDocument, isNull);
        expect(window.currentAppRoute, isNotNull);
        expect(window.current, isNot(same(oldRoute)));
        expect(window.pendingAppRoute, same(window.currentAppRoute));
      },
    );

    test(
      '404 is a real history response and replaces the target entry',
      () async {
        final gateway = DocumentGateway();
        final fixture = await _createNamedHistory(gateway);
        addTearDown(fixture.windows.dispose);
        final window = fixture.window;
        final oldFirst = window.history[0].document!;
        gateway.responses.add(
          response('/first', '<title>Not found</title>', status: 404),
        );

        expect(
          await window.traverseHistory(0),
          NativeDocumentLoadResult.committed,
        );

        expect(window.index, 0);
        expect(window.history, hasLength(2));
        expect(window.currentDocument, isNot(same(oldFirst)));
        expect(window.currentDocument!.status, 404);
        expect(window.currentDocument!.content.title, 'Not found');
        expect(gateway.calls.last['method'], 'GET');
      },
    );

    test(
      'POST history shows resubmission state without replaying the POST',
      () async {
        final gateway = DocumentGateway()
          ..responses.addAll([
            response('/opener', '<title>Opener</title>'),
            _noStoreResponse('/posted', '<title>Posted</title>'),
            response('/after', '<title>After POST</title>'),
            _noStoreResponse('/posted', '<title>Posted again</title>'),
          ]);
        final windows = NativeDocumentWindows(gateway);
        addTearDown(windows.dispose);
        final opener = windows.target(
          'opener',
          null,
          sourceUrl: 'https://gateway.example/',
        );
        await opener.load(_get('/opener'), baseUrl: opener.sourceUrl);
        final window = windows.target(
          'report',
          opener,
          sourceUrl: opener.current!.url,
        );
        const body = 'note=typed%20value';
        const type = 'application/x-www-form-urlencoded';
        await window.load(
          const NativeHtmlFormRequest(
            url: '/posted',
            method: 'POST',
            target: '',
            body: body,
            contentType: type,
          ),
          baseUrl: opener.current!.url,
        );
        final savedPost = window.currentDocument;
        await window.load(_get('/after'), baseUrl: window.current!.url);
        final callsBeforeBack = gateway.calls.length;

        expect(
          await window.traverseHistory(0),
          NativeDocumentLoadResult.committed,
        );
        expect(window.index, 0);
        expect(window.currentDocument, same(savedPost));
        expect(window.historyPostResubmissionRequired, isTrue);
        expect(gateway.calls, hasLength(callsBeforeBack));

        // A confirmed resend is a new explicit POST navigation and clears the
        // browser-style resubmission interstitial only after its response.
        await window.load(
          const NativeHtmlFormRequest(
            url: '/posted',
            method: 'POST',
            target: '',
            body: body,
            contentType: type,
          ),
          baseUrl: window.current!.url,
          replaceCurrent: true,
        );
        expect(gateway.calls, hasLength(callsBeforeBack + 1));
        expect(gateway.calls.last['method'], 'POST');
        expect(gateway.calls.last['body'], body);
        expect(gateway.calls.last['contentType'], type);
        expect(window.historyPostResubmissionRequired, isFalse);
        expect(window.history, hasLength(2));
      },
    );

    test(
      'no-store POST in an unowned _blank context keeps ERR_CACHE_MISS state',
      () async {
        final gateway = DocumentGateway()
          ..responses.addAll([
            _noStoreResponse('/posted', '<title>Uncacheable POST</title>'),
            response('/after', '<title>After POST</title>'),
          ]);
        final windows = NativeDocumentWindows(gateway);
        addTearDown(windows.dispose);
        final blank = windows.target(
          '_blank',
          null,
          sourceUrl: 'https://gateway.example/',
        );
        await blank.load(
          const NativeHtmlFormRequest(
            url: '/posted',
            method: 'POST',
            target: '',
            body: 'x=1',
            contentType: 'application/x-www-form-urlencoded',
          ),
          baseUrl: blank.sourceUrl,
        );
        final postDocument = blank.currentDocument;
        await blank.load(_get('/after'), baseUrl: blank.current!.url);
        final callsBeforeBack = gateway.calls.length;

        expect(
          await blank.traverseHistory(0),
          NativeDocumentLoadResult.committed,
        );

        expect(blank.index, 0);
        expect(blank.currentDocument, same(postDocument));
        expect(blank.historyPostResubmissionRequired, isTrue);
        expect(gateway.calls, hasLength(callsBeforeBack));
        expect(gateway.calls.map((call) => call['method']), ['POST', 'GET']);
      },
    );

    test(
      'fresh cacheable POST history restores a new document without POST',
      () async {
        final gateway = DocumentGateway()
          ..responses.addAll([
            _cacheablePostResponse(
              '/posted',
              '<title>Fresh POST result</title><input name="value" value="server">',
            ),
            response('/after', '<title>After POST</title>'),
          ]);
        final windows = NativeDocumentWindows(gateway);
        addTearDown(windows.dispose);
        final blank = windows.target(
          '_blank',
          null,
          sourceUrl: 'https://gateway.example/',
        );
        await blank.load(
          const NativeHtmlFormRequest(
            url: '/posted',
            method: 'POST',
            target: '',
            body: 'value=submitted',
            contentType: 'application/x-www-form-urlencoded',
          ),
          baseUrl: blank.sourceUrl,
        );
        final originalPost = blank.currentDocument!;
        await blank.load(_get('/after'), baseUrl: originalPost.url);
        final callsBeforeBack = gateway.calls.length;

        expect(
          await blank.traverseHistory(0),
          NativeDocumentLoadResult.committed,
        );

        expect(blank.historyPostResubmissionRequired, isFalse);
        expect(blank.index, 0);
        expect(blank.history, hasLength(2));
        expect(blank.currentDocument, isNot(same(originalPost)));
        expect(blank.currentDocument!.id, isNot(originalPost.id));
        expect(blank.currentDocument!.bytes, orderedEquals(originalPost.bytes));
        expect(blank.currentDocument!.content.title, 'Fresh POST result');
        expect(gateway.calls, hasLength(callsBeforeBack));
        expect(gateway.calls.map((call) => call['method']), ['POST', 'GET']);
        expect(originalPost.historyControls.isDisposed, isTrue);
      },
    );

    for (final cacheControl in ['no-cache', 'max-age=0']) {
      test(
        'POST with $cacheControl history restores from cache without POST',
        () async {
          final gateway = DocumentGateway()
            ..responses.addAll([
              _cacheablePostResponse(
                '/posted',
                '<title>Cached POST result</title>',
                cacheControl: cacheControl,
              ),
              response('/after', '<title>After POST</title>'),
            ]);
          final windows = NativeDocumentWindows(gateway);
          addTearDown(windows.dispose);
          final blank = windows.target(
            '_blank',
            null,
            sourceUrl: 'https://gateway.example/',
          );
          await blank.load(
            const NativeHtmlFormRequest(
              url: '/posted',
              method: 'POST',
              target: '',
              body: 'value=submitted',
              contentType: 'application/x-www-form-urlencoded',
            ),
            baseUrl: blank.sourceUrl,
          );
          final postDocument = blank.currentDocument!;
          await blank.load(_get('/after'), baseUrl: postDocument.url);
          final callsBeforeBack = gateway.calls.length;

          expect(
            await blank.traverseHistory(0),
            NativeDocumentLoadResult.committed,
          );

          expect(blank.historyPostResubmissionRequired, isFalse);
          expect(blank.index, 0);
          expect(blank.currentDocument, isNot(same(postDocument)));
          expect(blank.currentDocument!.id, isNot(postDocument.id));
          expect(blank.currentDocument!.content.title, 'Cached POST result');
          expect(gateway.calls, hasLength(callsBeforeBack));
          expect(gateway.calls.map((call) => call['method']), ['POST', 'GET']);
        },
      );
    }

    test(
      'failed refetch and retry replace the target without appending',
      () async {
        final gateway = DocumentGateway();
        final fixture = await _createNamedHistory(gateway);
        addTearDown(fixture.windows.dispose);
        final window = fixture.window;
        final target = window.history[0];
        final visible = window.currentDocument;
        final length = window.history.length;

        expect(
          await window.traverseHistory(0),
          NativeDocumentLoadResult.failed,
        );
        expect(window.index, 1);
        expect(window.currentDocument, same(visible));
        expect(window.history, hasLength(length));
        expect(window.failedRequest?.method, 'GET');

        // A retry can fail too; it must keep targeting the same history slot.
        expect(await window.retryRead(), NativeDocumentLoadResult.failed);
        expect(window.index, 1);
        expect(window.history, hasLength(length));
        expect(window.history[0], same(target));

        gateway.responses.add(
          response('/first', '<title>Recovered first</title>'),
        );
        expect(await window.retryRead(), NativeDocumentLoadResult.committed);
        expect(window.index, 0);
        expect(window.history, hasLength(length));
        expect(window.history[0], isNot(same(target)));
        expect(window.currentDocument!.content.title, 'Recovered first');
        expect(window.canForward, isTrue);
        expect(gateway.calls.last['url'], 'https://gateway.example/first');
        expect(gateway.calls.last['method'], 'GET');
        expect(gateway.calls.last['cacheMode'], 'default');
      },
    );

    testWidgets('refetch restores edited controls and saved scroll', (
      tester,
    ) async {
      final longParagraphs = List.generate(
        36,
        (i) =>
            '<p>row $i with enough words to extend the document viewport</p>',
      ).join();
      final firstMarkup =
          '<title>Editable first</title>'
          '<input name="note" value="server first">$longParagraphs';
      final gateway = DocumentGateway()
        ..responses.addAll([
          response('/opener', '<title>Opener</title>'),
          response('/first', firstMarkup),
        ]);
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final opener = windows.target(
        'opener',
        null,
        sourceUrl: 'https://gateway.example/',
      );
      await opener.load(_get('/opener'), baseUrl: opener.sourceUrl);
      final window = windows.target(
        'report',
        opener,
        sourceUrl: opener.current!.url,
      );
      await window.load(_get('/first'), baseUrl: opener.current!.url);
      final oldDocument = window.currentDocument!;
      final host = GlobalKey<NativeDocumentHostState>();
      await tester.pumpWidget(_hostedApp(windows, hostKey: host));
      windows.select(window);
      await tester.pumpAndSettle();

      expect(find.text('Editable first'), findsOneWidget);
      await tester.enterText(find.byType(EditableText).first, 'edited value');
      await tester.pumpAndSettle();
      expect(oldDocument.scroll.hasClients, isTrue);
      expect(oldDocument.scroll.position.maxScrollExtent, greaterThan(0));
      oldDocument.scroll.jumpTo(80);
      await tester.pumpAndSettle();

      final savedOffset = oldDocument.scroll.offset;
      gateway.responses.addAll([
        response('/second', '<title>Second page</title>'),
        response(
          '/first',
          '<title>Editable first refreshed</title>'
              '<input name="note" value="server changed">$longParagraphs',
        ),
      ]);
      await window.load(_get('/second'), baseUrl: oldDocument.url);
      await tester.pumpAndSettle();
      expect(window.history[0].formControlSnapshot, isNotNull);
      expect(
        window.history[0].formControlSnapshot!.controls.values
            .where((value) => value.text != null)
            .map((value) => value.text),
        contains('edited value'),
      );

      await host.currentState!.back();
      await tester.pumpAndSettle();
      expect(window.index, 0);
      expect(window.currentDocument, isNot(same(oldDocument)));
      expect(find.text('Editable first refreshed'), findsOneWidget);
      expect(find.byType(EditableText), findsOneWidget);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'edited value',
      );
      expect(window.currentDocument!.scroll.hasClients, isTrue);
      expect(window.currentDocument!.scroll.offset, closeTo(savedOffset, 1));
      expect(gateway.calls.last['method'], 'GET');
      expect(gateway.calls.last['url'], 'https://gateway.example/first');
      expect(tester.takeException(), isNull);
    });

    test(
      'same-document fragments and unowned _blank histories stay local',
      () async {
        final gateway = DocumentGateway()
          ..responses.addAll([
            response('/primary', '<title>Primary</title>'),
            response('/blank-one', '<title>Blank one</title>'),
            response('/blank-two', '<title>Blank two</title>'),
          ]);
        final windows = NativeDocumentWindows(gateway);
        addTearDown(windows.dispose);
        final primary = windows.target(
          '',
          null,
          sourceUrl: 'https://gateway.example/?session=s',
        );
        await primary.load(_get('/primary'), baseUrl: primary.sourceUrl);
        final primaryDocument = primary.currentDocument;
        expect(
          await primary.load(
            _get('#section'),
            baseUrl: primary.current!.url,
            fragmentAllowed: true,
          ),
          NativeDocumentLoadResult.committed,
        );
        expect(primary.currentDocument, same(primaryDocument));
        final beforeFragmentBack = gateway.calls.length;
        expect(
          await primary.traverseHistory(0),
          NativeDocumentLoadResult.committed,
        );
        expect(gateway.calls, hasLength(beforeFragmentBack));

        final blank = windows.target(
          '_blank',
          null,
          sourceUrl: 'https://gateway.example/',
        );
        await blank.load(_get('/blank-one'), baseUrl: blank.sourceUrl);
        final blankOne = blank.currentDocument;
        await blank.load(_get('/blank-two'), baseUrl: blank.current!.url);
        final beforeBlankBack = gateway.calls.length;
        expect(
          await blank.traverseHistory(0),
          NativeDocumentLoadResult.committed,
        );
        expect(blank.currentDocument, same(blankOne));
        expect(gateway.calls, hasLength(beforeBlankBack));
      },
    );

    test('a newer navigation makes a pending history response stale', () async {
      final gateway = _GateDocumentGateway();
      final fixture = await _createNamedHistory(gateway);
      addTearDown(fixture.windows.dispose);
      final window = fixture.window;
      gateway.responses.addAll([
        response('/first', '<title>Late history</title>'),
        response('/new', '<title>New navigation</title>'),
      ]);
      gateway.block('https://gateway.example/first');
      final traversal = window.traverseHistory(0);
      await gateway.entered!.future;

      expect(
        await window.load(_get('/new'), baseUrl: window.current!.url),
        NativeDocumentLoadResult.committed,
      );
      gateway.release!.complete();

      expect(await traversal, NativeDocumentLoadResult.stale);
      expect(window.index, 2);
      expect(window.history, hasLength(3));
      expect(window.currentDocument!.content.title, 'New navigation');
    });

    test(
      'account invalidation makes a pending history response stale',
      () async {
        final gateway = _GateDocumentGateway();
        final fixture = await _createNamedHistory(gateway);
        addTearDown(fixture.windows.dispose);
        gateway.responses.add(
          response('/first', '<title>Late account</title>'),
        );
        gateway.block('https://gateway.example/first');
        final traversal = fixture.window.traverseHistory(0);
        await gateway.entered!.future;

        fixture.windows.invalidateNativeConnection();
        gateway.release!.complete();

        expect(await traversal, NativeDocumentLoadResult.stale);
        expect(fixture.windows.windows, isEmpty);
      },
    );

    test(
      'Forward during pending Back stops the response at the visible entry',
      () async {
        final gateway = _GateDocumentGateway();
        final fixture = await _createNamedHistory(gateway);
        addTearDown(fixture.windows.dispose);
        final window = fixture.window;
        final visible = window.currentDocument;
        final originalTarget = window.history[0].document;
        final firstFetchesBeforeBack = gateway.calls
            .where((call) => call['url'] == 'https://gateway.example/first')
            .length;
        gateway.responses.add(response('/first', '<title>Late first</title>'));
        gateway.block('https://gateway.example/first');

        final back = window.traverseHistory(0);
        await gateway.entered!.future;

        expect(window.index, 1);
        expect(window.historyCursor, 0);
        expect(window.canForward, isTrue);
        expect(window.currentDocument, same(visible));

        expect(
          await window.traverseHistory(window.historyCursor + 1),
          NativeDocumentLoadResult.retained,
        );
        expect(window.historyCursor, 1);
        expect(window.index, 1);
        expect(window.currentDocument, same(visible));

        gateway.release!.complete();
        expect(await back, NativeDocumentLoadResult.stale);
        expect(window.currentDocument, same(visible));
        expect(window.history[0].document, same(originalTarget));
        expect(
          gateway.calls.where(
            (call) => call['url'] == 'https://gateway.example/first',
          ),
          hasLength(firstFetchesBeforeBack + 1),
        );
      },
    );

    testWidgets('a late host refetch commits without stealing selection', (
      tester,
    ) async {
      final gateway = _GateDocumentGateway();
      final fixture = await _createNamedHistory(gateway);
      addTearDown(fixture.windows.dispose);
      final other = fixture.windows.target(
        'other',
        fixture.opener,
        sourceUrl: fixture.opener.current!.url,
      );
      gateway.responses.addAll([
        response('/other', '<title>Other window</title>'),
        response('/first', '<title>Returned first</title>'),
      ]);
      await other.load(_get('/other'), baseUrl: fixture.opener.current!.url);
      final window = fixture.window;
      fixture.windows.select(window);
      final hostKey = GlobalKey<NativeDocumentHostState>();
      await tester.pumpWidget(_hostedApp(fixture.windows, hostKey: hostKey));
      fixture.windows.select(window);
      await tester.pumpAndSettle();
      gateway.block('https://gateway.example/first');

      final traversal = hostKey.currentState!.back();
      await gateway.entered!.future;
      await hostKey.currentState!.selectWindow(other);
      await tester.pumpAndSettle();
      gateway.release!.complete();
      await traversal;
      await tester.pumpAndSettle();

      expect(fixture.windows.active, same(other));
      expect(window.index, 0);
      expect(window.currentDocument!.content.title, 'Returned first');
      expect(tester.takeException(), isNull);
    });
  });
}
