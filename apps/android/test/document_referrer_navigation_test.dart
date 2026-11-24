import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_referrer.dart';
import 'package:pirc_mobile/live/document_response_cache.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_urls.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_form_submission.dart';

const _origin = 'https://gateway.example';
const _target = '$_origin/target';
Json _response(
  String url, {
  String source = '<title>Document</title>',
  String referrer = '',
  String policy = 'strict-origin-when-cross-origin',
  String cache = 'max-age=60',
  String? vary,
  String method = 'GET',
  int status = 200,
}) => {
  'status': status,
  'bytes': Uint8List.fromList(utf8.encode(source)),
  'mimeType': 'text/html',
  'charset': 'utf-8',
  'finalUrl': url,
  'finalMethod': method,
  'requestReferrer': referrer,
  'requestReferrerPolicy': policy,
  'headersRelevant': {
    'cache-control': cache,
    'etag': '"stable"',
    'vary': ?vary,
  },
};
Json _request(
  String from, {
  String policy = 'unsafe-url',
  String url = _target,
}) => {
  'url': url,
  'method': 'GET',
  'referrerUrl': from,
  'referrerPolicy': policy,
};
NativeHtmlFormRequest _get(String url) =>
    NativeHtmlFormRequest(url: url, method: 'GET', target: '');

class _Gateway extends Gateway {
  final requests = <Json>[];
  final responses = <Json>[];
  bool failNext = false;
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'documentPrepareRequest') {
      return {
        'nativeCookieRequestKey':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      };
    }
    if (method == 'boot') {
      return {'origin': _origin, 'pairingStamp': 'synthetic-stamp'};
    }
    if (method == 'resolveDocumentUrl') {
      return resolveNativeDocumentUrl(args['reference'], args['baseUrl']);
    }
    if (method == 'document') {
      requests.add(Map.of(args));
      if (failNext) {
        failNext = false;
        throw StateError('synthetic network failure');
      }
      return responses.removeAt(0);
    }
    throw StateError('Unexpected fixture call $method');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'fresh body reuse has request-specific referrer and never leaks previous metadata',
    () async {
      final requests = <Json>[];
      final cache = NativeDocumentResponseCache(
        fetch: (args) async {
          requests.add(args);
          return _response(_target, referrer: '$_origin/first?private=one');
        },
      );
      final first = await cache.load(
        _request('$_origin/first?private=one'),
        isCurrent: () => true,
      );
      expect(first['requestReferrer'], '$_origin/first?private=one');
      final second = await cache.load(
        _request('$_origin/second?private=two#hidden'),
        isCurrent: () => true,
      );
      expect(second['cacheSource'], 'fresh');
      expect(second['requestReferrer'], '$_origin/second?private=two');
      final none = await cache.load(
        _request('$_origin/third', policy: 'no-referrer'),
        isCurrent: () => true,
      );
      expect(none['requestReferrer'], '');
      expect(none['requestReferrerPolicy'], 'no-referrer');
      expect(requests, hasLength(1));
      expect(
        utf8.decode(second['bytes'] as Uint8List),
        '<title>Document</title>',
      );
    },
  );

  test(
    '304 replaces old request metadata and subsequent fresh hit derives a new value',
    () async {
      var now = DateTime.utc(2026, 10, 16);
      final replies = [
        _response(_target, referrer: '$_origin/first', cache: 'no-cache'),
        _response(
          _target,
          referrer: '$_origin/second',
          policy: 'same-origin',
          status: 304,
        ),
      ];
      final wire = <Json>[];
      final cache = NativeDocumentResponseCache(
        now: () => now,
        fetch: (args) async {
          wire.add(args);
          return replies.removeAt(0);
        },
      );
      await cache.load(_request('$_origin/first'), isCurrent: () => true);
      now = now.add(const Duration(seconds: 1));
      final validated = await cache.load(
        _request('$_origin/second', policy: 'same-origin'),
        isCurrent: () => true,
      );
      expect(wire.last['ifNoneMatch'], '"stable"');
      expect(validated['networkStatus'], 304);
      expect(validated['requestReferrer'], '$_origin/second');
      expect(validated['requestReferrerPolicy'], 'same-origin');
      final fresh = await cache.load(
        _request('$_origin/third'),
        isCurrent: () => true,
      );
      expect(fresh['cacheSource'], 'fresh');
      expect(fresh['requestReferrer'], '$_origin/third');
      expect(wire, hasLength(2));
    },
  );

  test(
    'Vary Referer matches the actual wire value including a known absent header',
    () async {
      final wire = <Json>[];
      final replies = [
        _response(_target, referrer: '$_origin/first', vary: 'Referer'),
        _response(_target, referrer: '', vary: 'Referer'),
      ];
      final cache = NativeDocumentResponseCache(
        fetch: (args) async {
          wire.add(args);
          return replies.removeAt(0);
        },
      );
      await cache.load(_request('$_origin/first'), isCurrent: () => true);
      expect(
        (await cache.load(
          _request('$_origin/first#other'),
          isCurrent: () => true,
        ))['cacheSource'],
        'fresh',
      );
      expect(
        (await cache.load(
          _request('$_origin/no', policy: 'no-referrer'),
          isCurrent: () => true,
        ))['cacheSource'],
        'network',
      );
      expect(
        (await cache.load(
          _request('$_origin/another', policy: 'no-referrer'),
          isCurrent: () => true,
        ))['cacheSource'],
        'fresh',
      );
      expect(wire, hasLength(2));
    },
  );

  test('redirect representation Vary uses the final reduced Referer', () async {
    final replies = [
      _response(
        _target,
        referrer: '$_origin/',
        policy: 'origin',
        vary: 'referer',
      ),
      _response(_target, referrer: '$_origin/source?secret=1', vary: 'referer'),
    ];
    final wire = <Json>[];
    final cache = NativeDocumentResponseCache(
      fetch: (args) async {
        wire.add(args);
        return replies.removeAt(0);
      },
    );
    await cache.load(
      _request('$_origin/source?secret=1', url: '$_origin/redirect'),
      isCurrent: () => true,
    );
    expect(
      (await cache.load(
        _request('$_origin/source?secret=2', policy: 'origin'),
        isCurrent: () => true,
      ))['cacheSource'],
      'fresh',
    );
    expect(
      (await cache.load(
        _request('$_origin/source?secret=1'),
        isCurrent: () => true,
      ))['cacheSource'],
      'network',
    );
    expect(wire, hasLength(2));
  });

  test(
    'stylesheet cache does not turn document source context into a Referer',
    () async {
      final cache = NativeDocumentResponseCache(
        fetch: (_) async => _response(_target),
      );
      final args = {
        ..._request('$_origin/private'),
        'resourceType': 'stylesheet',
      };
      await cache.load(args, isCurrent: () => true);
      final result = await cache.load(args, isCurrent: () => true);
      expect(result['requestReferrer'], '');
      expect(result['requestReferrerPolicy'], 'no-referrer');
    },
  );

  test(
    'host keeps final wire referrer separately from destination outgoing policy and base URL',
    () async {
      final gateway = _Gateway()
        ..responses.add(
          _response(
            _target,
            source:
                '<meta name="referrer" content="no-referrer"><base href="https://other.example/base/">',
            referrer: '$_origin/source?query=1',
            policy: 'unsafe-url',
          ),
        );
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = windows.target(
        '',
        null,
        sourceUrl: '$_origin/source?query=1#fragment',
      );
      expect(
        await window.load(
          _get(_target),
          baseUrl: _origin,
          referrer: const NativeDocumentReferrer(
            '$_origin/source?query=1#fragment',
            'unsafe-url',
          ),
        ),
        NativeDocumentLoadResult.committed,
      );
      final document = window.currentDocument!;
      expect(document.referrer, '$_origin/source?query=1');
      expect(document.navigationReferrer.url, '$_origin/source?query=1');
      expect(document.navigationReferrer.policy, 'unsafe-url');
      expect(
        gateway.requests.single['referrerUrl'],
        '$_origin/source?query=1#fragment',
      );
      expect(
        nativeDocumentReferrer(
          document,
          url: '$_origin/current?history=2',
        ).policy,
        'no-referrer',
      );
      expect(
        nativeDocumentReferrer(
          document,
          url: '$_origin/current?history=2',
          elementPolicy: 'unsafe-url',
        ).forTarget('https://other.example/'),
        '$_origin/current?history=2',
      );
      expect(
        nativeDocumentReferrer(
          document,
          url: document.url,
          elementPolicy: 'unsafe-url',
          noreferrer: true,
        ).forTarget(_target),
        '',
      );
    },
  );

  test(
    'initial App document navigation uses its actual URL and default browser policy',
    () async {
      final gateway = _Gateway()..responses.add(_response(_target));
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = windows.target(
        '',
        null,
        sourceUrl: '$_origin/?session=synthetic#private',
      );
      await window.load(_get(_target), baseUrl: _origin);
      expect(
        gateway.requests.single['referrerUrl'],
        '$_origin/?session=synthetic#private',
      );
      expect(
        gateway.requests.single['referrerPolicy'],
        'strict-origin-when-cross-origin',
      );
    },
  );

  test(
    'history GET refetch uses the target original request context, not outgoing page',
    () async {
      final gateway = _Gateway()
        ..responses.addAll([
          _response('$_origin/first', cache: 'no-store'),
          _response(
            '$_origin/second',
            referrer: '$_origin/first',
            policy: 'unsafe-url',
            cache: 'no-store',
          ),
          _response('$_origin/first', cache: 'no-store'),
          _response(
            '$_origin/second',
            referrer: '$_origin/first',
            policy: 'unsafe-url',
            cache: 'no-store',
          ),
        ]);
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = windows.target('', null, sourceUrl: '$_origin/app');
      await window.load(
        _get('/first'),
        baseUrl: _origin,
        referrer: const NativeDocumentReferrer('', 'no-referrer'),
      );
      await window.load(
        _get('/second'),
        baseUrl: _origin,
        referrer: const NativeDocumentReferrer('$_origin/first', 'unsafe-url'),
      );
      expect(window.history[0].requiresHistoryRefetch, isTrue);
      await window.traverseHistory(0);
      expect(gateway.requests.last['referrerUrl'], '');
      expect(window.history[1].requiresHistoryRefetch, isTrue);
      await window.traverseHistory(1);
      expect(gateway.requests.last['referrerUrl'], '$_origin/first');
      expect(gateway.requests.last['referrerPolicy'], 'unsafe-url');
      expect(window.currentDocument!.referrer, '$_origin/first');
    },
  );

  test(
    'no-store history refetch updates same-document fragment siblings',
    () async {
      final gateway = _Gateway()
        ..responses.addAll([
          _response(
            '$_origin/page#one',
            source: '<p>old body</p>',
            cache: 'no-store',
          ),
          _response('$_origin/other', cache: 'no-store'),
          _response(
            '$_origin/page#two',
            source: '<p>new body</p>',
            cache: 'no-store',
          ),
        ]);
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = windows.target('', null, sourceUrl: '$_origin/app');
      await window.load(
        _get('/page#one'),
        baseUrl: _origin,
        referrer: const NativeDocumentReferrer('', 'no-referrer'),
      );
      await window.load(
        _get('#two'),
        baseUrl: window.current!.url,
        fragmentAllowed: true,
      );
      expect(gateway.requests, hasLength(1));
      await window.load(_get('/other'), baseUrl: _origin);
      expect(
        window.history.take(2).every((item) => item.requiresHistoryRefetch),
        isTrue,
      );
      await window.traverseHistory(1);
      final fresh = window.currentDocument!;
      expect(fresh.content.text, '<p>new body</p>');
      await window.traverseHistory(0);
      expect(window.current!.url, '$_origin/page#one');
      expect(window.currentDocument, same(fresh));
      expect(window.currentDocument!.content.text, '<p>new body</p>');
      expect(window.currentDocument!.referrer, '');
      await window.traverseHistory(1);
      expect(window.currentDocument, same(fresh));
      expect(gateway.requests, hasLength(3));
    },
  );

  test(
    'cached POST restoration preserves referrer without replaying the POST',
    () async {
      final gateway = _Gateway()
        ..responses.addAll([
          _response(
            '$_origin/post',
            method: 'POST',
            referrer: '$_origin/source',
            policy: 'unsafe-url',
          ),
          _response('$_origin/after', cache: 'no-store'),
        ]);
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = windows.target('', null, sourceUrl: '$_origin/source');
      await window.load(
        const NativeHtmlFormRequest(
          url: '$_origin/post',
          method: 'POST',
          target: '',
          body: 'value=synthetic',
        ),
        baseUrl: _origin,
      );
      await window.load(_get('/after'), baseUrl: _origin);
      expect(
        await window.traverseHistory(0),
        NativeDocumentLoadResult.committed,
      );
      expect(window.currentDocument!.referrer, '$_origin/source');
      expect(window.currentDocument!.navigationReferrer.policy, 'unsafe-url');
      expect(gateway.requests, hasLength(2));
    },
  );

  test(
    'GET retry preserves source context captured before the failure',
    () async {
      final gateway = _Gateway()..responses.add(_response('$_origin/source'));
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = windows.target('', null, sourceUrl: '$_origin/app');
      await window.load(_get('/source'), baseUrl: _origin);
      gateway.failNext = true;
      expect(
        await window.load(
          _get('/target'),
          baseUrl: _origin,
          referrer: const NativeDocumentReferrer(
            '$_origin/source?old=1',
            'origin',
          ),
        ),
        NativeDocumentLoadResult.failed,
      );
      window.current!.url = '$_origin/source?new=2';
      gateway.responses.add(
        _response(_target, referrer: '$_origin/', policy: 'origin'),
      );
      expect(await window.retryRead(), NativeDocumentLoadResult.committed);
      expect(gateway.requests.last['referrerUrl'], '$_origin/source?old=1');
      expect(gateway.requests.last['referrerPolicy'], 'origin');
    },
  );

  test('text document examples cannot become HTML referrer meta policies', () {
    final bytes = Uint8List.fromList(
      utf8.encode('<meta name="referrer" content="unsafe-url">'),
    );
    final document = NativeFetchedDocument(
      id: 1,
      url: _target,
      status: 200,
      bytes: bytes,
      mimeType: 'text/plain',
      content: NativeHtmlDocumentContent.fromBytes(
        bytes,
        mimeType: 'text/plain',
        charset: 'utf-8',
      ),
      headers: {'referrer-policy': 'no-referrer'},
    );
    addTearDown(document.dispose);
    final context = nativeDocumentReferrer(document, url: _target);
    expect(context.policy, 'no-referrer');
    expect(context.forTarget('https://other.example/'), '');
  });
}
