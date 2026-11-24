import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_form_submission.dart';

class _StylesGateway extends Gateway {
  final urls = <String>[];
  final started = Completer<void>();
  final css = Completer<Json>();
  bool delay = true;
  final unpairStarted = Completer<void>();
  final finishUnpair = Completer<void>();
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'documentPrepareRequest') {
      return {
        'nativeCookieRequestKey':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      };
    }
    if (method == 'boot') {
      return {'origin': 'https://example.test', 'pairingStamp': 'stamp'};
    }
    if (method == 'resolveDocumentUrl') {
      return Uri.parse(
        args['baseUrl'] as String,
      ).resolve(args['reference'] as String).toString();
    }
    if (method == 'unpair') {
      unpairStarted.complete();
      await finishUnpair.future;
      return null;
    }
    if (method == 'document') {
      final url = args['url'] as String;
      urls.add(url);
      if (url.endsWith('/one.css')) {
        if (!started.isCompleted) started.complete();
        return delay
            ? await css.future
            : _reply(url, 'text/css', '', status: 404);
      }
      if (url.endsWith('/two.css')) {
        return _reply(url, 'text/css', 'p{color:rgb(7,8,9)}');
      }
      return _reply(url, 'text/html', '''<!doctype html><html><head>
        <link rel="stylesheet" href="one.css"><link rel="stylesheet" href="two.css">
        </head><body><p>Keep document</p></body></html>''');
    }
    return {};
  }
}

Json _reply(String url, String mime, String text, {int status = 200}) => {
  'status': status,
  'finalUrl': url,
  'finalMethod': 'GET',
  'mimeType': mime,
  'charset': 'UTF-8',
  'bytes': Uint8List.fromList(utf8.encode(text)),
  'headersRelevant': {},
};

void main() {
  test(
    'stopping a pending stylesheet suppresses publication and further loads',
    () async {
      final gateway = _StylesGateway();
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = windows.target(
        '',
        null,
        sourceUrl: 'https://example.test/source',
      );
      final loading = window.load(
        const NativeHtmlFormRequest(url: '/page', method: 'GET', target: ''),
        baseUrl: 'https://example.test/source',
      );
      await gateway.started.future;
      window.stop();
      gateway.css.complete(
        _reply('https://example.test/one.css', 'text/css', 'p{color:red}'),
      );
      expect(await loading, NativeDocumentLoadResult.stale);
      expect(window.history, isEmpty);
      expect(gateway.urls, [
        'https://example.test/page',
        'https://example.test/one.css',
      ]);
      expect(window.loading, isFalse);
    },
  );

  test(
    'CSS HTTP failure leaves HTML available and later styles are loaded',
    () async {
      final gateway = _StylesGateway()..delay = false;
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = windows.target(
        '',
        null,
        sourceUrl: 'https://example.test/source',
      );
      expect(
        await window.load(
          const NativeHtmlFormRequest(url: '/page', method: 'GET', target: ''),
          baseUrl: 'https://example.test/source',
        ),
        NativeDocumentLoadResult.committed,
      );
      final document = window.current!.document!;
      expect(document.content.bodyInnerHtml, contains('Keep document'));
      expect(document.styleDiagnostics.single, contains('404'));
      expect(document.stylesheets, hasLength(1));
      expect(gateway.urls, hasLength(3));
      expect(window.error, isNull);
    },
  );
  test(
    'account change during CSS fetch clears the old document context',
    () async {
      final gateway = _StylesGateway();
      final owner = LiveController(gateway)
        ..origin = 'https://example.test'
        ..pairingStamp = 'stamp';
      final windows = NativeDocumentWindows(gateway, owner: owner);
      addTearDown(() {
        windows.dispose();
        owner.dispose();
      });
      final window = windows.target(
        '',
        null,
        sourceUrl: 'https://example.test/source',
      );
      final loading = window.load(
        const NativeHtmlFormRequest(url: '/page', method: 'GET', target: ''),
        baseUrl: 'https://example.test/source',
      );
      await gateway.started.future;
      owner.origin = 'https://another-account.test';
      owner.changed();
      gateway.css.complete(
        _reply('https://example.test/one.css', 'text/css', 'p{color:red}'),
      );
      expect(await loading, NativeDocumentLoadResult.stale);
      expect(window.disposed, isTrue);
      expect(windows.windows, isEmpty);
      expect(gateway.urls, [
        'https://example.test/page',
        'https://example.test/one.css',
      ]);
    },
  );
  test(
    'owner revision changes invalidate CSS before listener notification',
    () async {
      final gateway = _StylesGateway();
      final owner = LiveController(gateway)
        ..origin = 'https://example.test'
        ..pairingStamp = 'stamp';
      final windows = NativeDocumentWindows(gateway, owner: owner);
      addTearDown(() {
        windows.dispose();
        owner.dispose();
      });
      final window = windows.target(
        '',
        null,
        sourceUrl: 'https://example.test/source',
      );
      final loading = window.load(
        const NativeHtmlFormRequest(url: '/page', method: 'GET', target: ''),
        baseUrl: 'https://example.test/source',
      );
      await gateway.started.future;
      final unpairing = owner.unpair();
      await gateway.unpairStarted.future;
      // unpair() increments accountRevision before awaiting native work and
      // before changed() is emitted. A cached-only identity misses this interval.
      gateway.css.complete(
        _reply('https://example.test/one.css', 'text/css', 'p{color:red}'),
      );
      expect(await loading, NativeDocumentLoadResult.stale);
      expect(window.history, isEmpty);
      expect(gateway.urls, hasLength(2));
      gateway.finishUnpair.complete();
      await unpairing;
    },
  );

  test(
    'native pairing error during CSS is fatal even without an owner',
    () async {
      final gateway = _StylesGateway();
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = windows.target(
        '',
        null,
        sourceUrl: 'https://example.test/source',
      );
      final loading = window.load(
        const NativeHtmlFormRequest(url: '/page', method: 'GET', target: ''),
        baseUrl: 'https://example.test/source',
      );
      await gateway.started.future;
      gateway.css.completeError(
        PlatformException(
          code: 'HTTP_409',
          message: 'Pairing changed',
          details: {'code': 'account_changed'},
        ),
      );
      expect(await loading, NativeDocumentLoadResult.stale);
      expect(window.disposed, isTrue);
      expect(windows.windows, isEmpty);
      expect(gateway.urls, hasLength(2));
    },
  );
}
