import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_urls.dart';
import 'package:pirc_render/src/html_form_submission.dart';

class _DocumentGateway extends Gateway {
  final calls = <Json>[];
  final responses = <Json>[];

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
        if (responses.isEmpty) {
          throw StateError('No response queued for ${arguments['url']}');
        }
        return responses.removeAt(0);
      default:
        throw StateError('Unexpected gateway method: $method');
    }
  }

  void respond(
    String url,
    String body, {
    Map<String, String> headers = const <String, String>{
      'Cache-Control': 'max-age=3600',
      'Content-Type': 'text/html; charset=utf-8',
    },
    String mimeType = 'text/html',
    String? charset = 'utf-8',
    int status = 200,
  }) {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    responses.add(<String, dynamic>{
      'bytes': Uint8List.fromList(utf8.encode(body)),
      'status': status,
      'finalUrl': url,
      'finalMethod': 'GET',
      'mimeType': mimeType,
      'charset': charset,
      'headersRelevant': headers,
      'requestSentAt': now,
      'receivedAt': now,
    });
  }

  void respond304(
    String url, {
    Map<String, String> headers = const <String, String>{
      'Cache-Control': 'max-age=3600',
      'ETag': '"current-v1"',
    },
  }) {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    responses.add(<String, dynamic>{
      'status': 304,
      'finalUrl': url,
      'finalMethod': 'GET',
      'headersRelevant': headers,
      'requestSentAt': now,
      'receivedAt': now,
    });
  }
}

NativeHtmlFormRequest _get(String url) =>
    NativeHtmlFormRequest(url: url, method: 'GET', target: '');

NativeDocumentWindow _primary(NativeDocumentWindows windows) =>
    windows.target('', null, sourceUrl: 'https://gateway.example/');

void main() {
  group('NativeDocumentWindow response-cache navigation', () {
    test(
      'a fresh cached GET makes a new history document with clean state',
      () async {
        const url = 'https://gateway.example/cached';
        final gateway = _DocumentGateway()
          ..respond(
            url,
            '<!doctype html><title>Cached</title><input value="initial">',
          );
        final windows = NativeDocumentWindows(gateway);
        addTearDown(windows.dispose);
        final window = _primary(windows);

        expect(
          await window.load(_get('/cached'), baseUrl: window.sourceUrl),
          NativeDocumentLoadResult.committed,
        );
        final first = window.currentDocument!;
        expect(first.content.title, 'Cached');
        expect(gateway.calls, hasLength(1));

        expect(
          await window.load(_get('/cached'), baseUrl: first.url),
          NativeDocumentLoadResult.committed,
        );
        final revisited = window.currentDocument!;
        expect(revisited, isNot(same(first)));
        expect(revisited.id, isNot(first.id));
        expect(revisited.url, first.url);
        expect(revisited.bytes, orderedEquals(first.bytes));
        expect(revisited.content.title, 'Cached');
        expect(gateway.calls, hasLength(1), reason: 'the second GET is fresh');
        expect(window.history, hasLength(2));

        window.back();
        expect(window.currentDocument, same(first));
        window.forward();
        expect(window.currentDocument, same(revisited));
        expect(gateway.calls, hasLength(1));
      },
    );

    test(
      'a conditional 304 reload replaces one history item and keeps its forward branch',
      () async {
        const firstUrl = 'https://gateway.example/first';
        const currentUrl = 'https://gateway.example/current';
        const forwardUrl = 'https://gateway.example/forward';
        final gateway = _DocumentGateway()
          ..respond(firstUrl, '<title>First</title>')
          ..respond(
            currentUrl,
            '<!doctype html><title>Current body</title><input value="initial">',
            headers: const <String, String>{
              'Cache-Control': 'no-cache',
              'Content-Type': 'text/html; charset=utf-8',
              'ETag': '"current-v1"',
            },
          )
          ..respond(forwardUrl, '<title>Forward</title>')
          ..respond304(currentUrl);
        final windows = NativeDocumentWindows(gateway);
        addTearDown(windows.dispose);
        final window = _primary(windows);

        await window.load(_get('/first'), baseUrl: window.sourceUrl);
        await window.load(_get('/current'), baseUrl: window.current!.url);
        final oldCurrent = window.currentDocument!;
        await window.load(_get('/forward'), baseUrl: oldCurrent.url);
        final forwardDocument = window.currentDocument!;
        expect(window.history, hasLength(3));

        window.back();
        expect(window.currentDocument, same(oldCurrent));
        expect(window.canForward, isTrue);
        final historyLength = window.history.length;
        final index = window.index;

        expect(
          await window.load(
            _get('/current'),
            baseUrl: oldCurrent.url,
            revalidate: true,
            replaceCurrent: true,
          ),
          NativeDocumentLoadResult.committed,
        );

        expect(gateway.calls, hasLength(4));
        expect(gateway.calls.last['ifNoneMatch'], '"current-v1"');
        expect(gateway.calls.last['cacheMode'], 'revalidate');
        expect(window.history, hasLength(historyLength));
        expect(window.index, index);
        expect(window.canForward, isTrue);
        final reloaded = window.currentDocument!;
        expect(reloaded, isNot(same(oldCurrent)));
        expect(reloaded.id, isNot(oldCurrent.id));
        expect(reloaded.url, currentUrl);
        expect(reloaded.status, 200);
        expect(reloaded.content.title, 'Current body');
        expect(reloaded.bytes, orderedEquals(oldCurrent.bytes));

        window.forward();
        expect(window.currentDocument, same(forwardDocument));
        expect(gateway.calls, hasLength(4));
      },
    );
  });
}
