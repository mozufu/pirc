import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_origin.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_referrer.dart';
import 'package:pirc_mobile/live/document_response_cache.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_urls.dart';
import 'package:pirc_render/src/html_form_submission.dart';

Json _response(
  String url, {
  String method = 'GET',
  String origin = 'https://source.example',
  String cache = 'no-store',
  int status = 200,
}) => {
  'status': status,
  'finalUrl': url,
  'finalMethod': method,
  'mimeType': 'text/html',
  'charset': 'utf-8',
  'bytes': Uint8List.fromList(utf8.encode('<title>Document</title>')),
  'requestReferrer': '',
  'requestReferrerPolicy': 'no-referrer',
  'requestOrigin': method == 'POST' ? 'null' : null,
  'requestOriginSource': origin,
  'headersRelevant': {'cache-control': cache, 'etag': '"origin-v1"'},
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
      return {
        'origin': 'https://gateway.example',
        'pairingStamp': 'synthetic-origin-stamp',
      };
    }
    if (method == 'resolveDocumentUrl') {
      return resolveNativeDocumentUrl(args['reference'], args['baseUrl']);
    }
    if (method == 'document') {
      requests.add(Map.of(args));
      if (failNext) {
        failNext = false;
        throw StateError('synthetic failure');
      }
      return responses.removeAt(0);
    }
    throw StateError('Unexpected synthetic method $method');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const origins = {
    'https://EXAMPLE.com:443/path?secret=1#fragment': 'https://example.com',
    'http://EXAMPLE.com:80/path': 'http://example.com',
    'http://example.com:81/a': 'http://example.com:81',
    'https://user:password@example.com/private': 'https://example.com',
    'http://[::1]:8080/private?secret=1': 'http://[::1]:8080',
    'blob:https://creator.example/owned-nonce#fragment':
        'https://creator.example',
    'blob:http://127.0.0.1:2345/owned-nonce': 'http://127.0.0.1:2345',
    'blob:null/opaque-nonce': 'null',
    'blob:blob:https://creator.example/nonce/nested': 'null',
    'data:text/html,example': 'null',
    'about:blank': 'null',
    'file:///private/local.txt': 'null',
    '/relative': 'null',
    'null': 'null',
    '': 'null',
  };
  for (final entry in origins.entries) {
    test('serializes trusted document origin for ${entry.key}', () {
      expect(nativeDocumentOrigin(entry.key), entry.value);
    });
  }
  test(
    'POST source origin remains available when policy removes all Referer',
    () async {
      final gateway = _Gateway()
        ..responses.add(
          _response('https://destination.example/submit', method: 'POST'),
        );
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = windows.target(
        '',
        null,
        sourceUrl: 'https://source.example/page?private=1#hidden',
      );
      await window.load(
        const NativeHtmlFormRequest(
          url: 'https://destination.example/submit',
          method: 'POST',
          target: '',
          body: 'value=fixed',
        ),
        baseUrl: 'https://unrelated-base.example/',
        referrer: const NativeDocumentReferrer(
          'https://source.example/page?private=1#hidden',
          'no-referrer',
        ),
      );
      expect(gateway.requests.single['originUrl'], 'https://source.example');
      expect(gateway.requests.single['referrerPolicy'], 'no-referrer');
      expect(window.currentDocument!.referrer, '');
      expect(
        window.currentDocument!.navigationOrigin,
        'https://source.example',
      );
    },
  );
  test(
    'explicit initiator origin overrides an already-used target window origin',
    () async {
      final gateway = _Gateway()
        ..responses.addAll([
          _response('https://target.example/old'),
          _response(
            'https://destination.example/submit',
            method: 'POST',
            origin: 'https://opener.example',
          ),
        ]);
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final target = windows.target(
        'report',
        null,
        sourceUrl: 'https://target.example/old',
      );
      await target.load(
        _get('https://target.example/old'),
        baseUrl: 'https://target.example',
      );
      await target.load(
        const NativeHtmlFormRequest(
          url: 'https://destination.example/submit',
          method: 'POST',
          target: 'report',
          body: 'value=fixed',
        ),
        baseUrl: 'https://opener.example',
        origin: 'https://opener.example',
      );
      expect(gateway.requests.last['originUrl'], 'https://opener.example');
      expect(
        target.currentDocument!.navigationOrigin,
        'https://opener.example',
      );
    },
  );
  test(
    'Blob document uses inherited origin while its HTTP Referer is suppressed',
    () async {
      final gateway = _Gateway()
        ..responses.add(
          _response(
            'https://destination.example/submit',
            method: 'POST',
            origin: 'https://creator.example',
          ),
        );
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = windows.target(
        '',
        null,
        sourceUrl: 'blob:https://creator.example/owned-nonce',
      );
      await window.load(
        const NativeHtmlFormRequest(
          url: 'https://destination.example/submit',
          method: 'POST',
          target: '',
          body: 'value=blob',
        ),
        baseUrl: 'blob:https://creator.example/owned-nonce',
      );
      expect(gateway.requests.single['originUrl'], 'https://creator.example');
    },
  );
  test(
    'retry keeps source identity captured before the asynchronous failure',
    () async {
      final gateway = _Gateway()..failNext = true;
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = windows.target(
        '',
        null,
        sourceUrl: 'https://original.example/app',
      );
      expect(
        await window.load(
          _get('https://destination.example/read'),
          baseUrl: 'https://original.example',
        ),
        NativeDocumentLoadResult.failed,
      );
      window.sourceUrl = 'https://different.example/new-context';
      gateway.responses.add(
        _response(
          'https://destination.example/read',
          origin: 'https://original.example',
        ),
      );
      await window.retryRead();
      expect(
        gateway.requests.map((r) => r['originUrl']),
        everyElement('https://original.example'),
      );
    },
  );
  test(
    'cached POST history retains opaque source identity without replaying POST',
    () async {
      final gateway = _Gateway()
        ..responses.addAll([
          _response(
            'https://destination.example/submit',
            method: 'POST',
            origin: 'null',
            cache: 'max-age=60',
          ),
          _response('https://destination.example/after'),
        ]);
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = windows.target(
        '',
        null,
        sourceUrl: 'https://source.example/app',
      );
      await window.load(
        const NativeHtmlFormRequest(
          url: 'https://destination.example/submit',
          method: 'POST',
          target: '',
          body: 'value=fixed',
        ),
        baseUrl: 'https://source.example',
      );
      await window.load(
        _get('https://destination.example/after'),
        baseUrl: 'https://destination.example',
      );
      await window.traverseHistory(0);
      expect(gateway.requests, hasLength(2));
      expect(window.currentDocument!.navigationOrigin, 'null');
      expect(window.currentDocument!.reloadRequest!.method, 'POST');
    },
  );
  test('fresh cached bytes never reuse an earlier Origin identity', () async {
    final cache = NativeDocumentResponseCache(
      fetch: (_) async => _response(
        'https://target.example/body',
        origin: 'https://first.example',
        cache: 'max-age=60',
      ),
    );
    await cache.load({
      'url': 'https://target.example/body',
      'method': 'GET',
      'originUrl': 'https://first.example',
    }, isCurrent: () => true);
    final second = await cache.load({
      'url': 'https://target.example/body',
      'method': 'GET',
      'originUrl': 'https://second.example',
    }, isCurrent: () => true);
    expect(second['cacheSource'], 'fresh');
    expect(second['requestOriginSource'], 'https://second.example');
    expect(second['requestOrigin'], isNull);
  });
  test(
    '304 updates request origin metadata without changing body bytes',
    () async {
      final replies = [
        _response(
          'https://target.example/body',
          origin: 'https://first.example',
          cache: 'no-cache',
        ),
        _response(
          'https://target.example/body',
          origin: 'https://second.example',
          cache: 'no-cache',
          status: 304,
        ),
      ];
      final cache = NativeDocumentResponseCache(
        fetch: (_) async => replies.removeAt(0),
      );
      final first = await cache.load({
        'url': 'https://target.example/body',
        'method': 'GET',
        'originUrl': 'https://first.example',
      }, isCurrent: () => true);
      final second = await cache.load({
        'url': 'https://target.example/body',
        'method': 'GET',
        'originUrl': 'https://second.example',
      }, isCurrent: () => true);
      expect(second['cacheSource'], 'revalidated');
      expect(second['requestOriginSource'], 'https://second.example');
      expect(second['requestOrigin'], isNull);
      expect(second['bytes'], first['bytes']);
    },
  );
  test(
    'non-document cached resources carry no document origin identity',
    () async {
      final cache = NativeDocumentResponseCache(
        fetch: (_) async => _response(
          'https://target.example/style',
          origin: 'null',
          cache: 'max-age=60',
        ),
      );
      final args = {
        'url': 'https://target.example/style',
        'method': 'GET',
        'resourceType': 'stylesheet',
        'originUrl': 'https://source.example',
      };
      await cache.load(args, isCurrent: () => true);
      final fresh = await cache.load(args, isCurrent: () => true);
      expect(fresh['cacheSource'], 'fresh');
      expect(fresh['requestOrigin'], isNull);
      expect(fresh['requestOriginSource'], 'null');
    },
  );
}
