import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/document_object_urls.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_urls.dart';
import 'package:pirc_render/src/html_form_submission.dart';

class _RecordedCall {
  const _RecordedCall(this.method, this.arguments);

  final String method;
  final Json arguments;
}

class _FakeGateway extends Gateway {
  final calls = <_RecordedCall>[];

  List<_RecordedCall> get documentCalls =>
      calls.where((call) => call.method == 'document').toList();

  List<_RecordedCall> get resolverCalls =>
      calls.where((call) => call.method == 'resolveDocumentUrl').toList();

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
      case 'boot':
        return <String, dynamic>{
          'origin': 'https://gateway.example',
          'pairingStamp': 'stamp',
        };
      case 'resolveDocumentUrl':
        return resolveNativeDocumentUrl(
          arguments['reference'] as String,
          arguments['baseUrl'] as String,
        );
      case 'saveDocument':
        return {'saved': true};
      case 'document':
        return _response(arguments, '<html><body>HTTP source</body></html>');
      default:
        throw StateError('Unexpected gateway call: $method');
    }
  }
}

Json _response(Json arguments, String html) => <String, dynamic>{
  'bytes': Uint8List.fromList(utf8.encode(html)),
  'mimeType': 'text/html',
  'charset': 'utf-8',
  'status': 200,
  'finalUrl': arguments['url'],
  'finalMethod': arguments['method'],
  'headersRelevant': <String, dynamic>{
    'content-type': 'text/html; charset=utf-8',
  },
};

NativeHtmlFormRequest _get(String url, {String target = ''}) =>
    NativeHtmlFormRequest(url: url, method: 'GET', target: target);

NativeDocumentWindow _rootWindow(NativeDocumentWindows windows) =>
    windows.target('', null, sourceUrl: 'https://site.example/source.html');

const _creatorUrl = 'https://site.example/creator/page.html';
const _blobUrl = 'blob:https://site.example/object-token';
const _blobUrlWithFragment = '$_blobUrl#section';
const _blobHtml =
    '<!doctype html><html><head><title>Blob page</title>'
    '<style>body { color: rgb(1, 2, 3); }</style></head>'
    '<body><p class="inline">blob body</p></body></html>';

class _FakeBlobSource {
  _FakeBlobSource({String creatorUrl = _creatorUrl}) {
    source = NativeDocumentBlobNavigationSource(
      creatorUrl: creatorUrl,
      binding: NativeDocumentObjectUrlBinding(
        owner: Object(),
        isCurrent: () => current,
        readBytes: _read,
      ),
    );
  }

  late final NativeDocumentBlobNavigationSource source;
  final reads = <String>[];
  bool current = true;
  bool available = true;
  String mimeType = 'text/html;charset=utf-8';
  Uint8List bytes = Uint8List.fromList(utf8.encode(_blobHtml));
  Completer<Json>? pendingRead;
  Completer<void>? readStarted;

  Future<Json> _read(String requestedUrl) async {
    reads.add(requestedUrl);
    final started = readStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    final pending = pendingRead;
    if (pending != null) return pending.future;
    return _bridgeValue(requestedUrl);
  }

  Json _bridgeValue(String requestedUrl) => <String, dynamic>{
    'ok': available,
    'url': requestedUrl.split('#').first,
    'type': mimeType,
    'size': available ? bytes.length : 0,
    'bytesBase64': base64Encode(available ? bytes : Uint8List(0)),
  };
}

void main() {
  group('blob document navigation', () {
    test(
      'empty MIME displays text and octet-stream downloads without replacing the page',
      () async {
        final gateway = _FakeGateway();
        final windows = NativeDocumentWindows(gateway);
        addTearDown(windows.dispose);
        final window = _rootWindow(windows);
        final reader = _FakeBlobSource()..mimeType = '';
        expect(
          await window.load(
            _get(_blobUrl),
            baseUrl: _creatorUrl,
            blobSource: reader.source,
          ),
          NativeDocumentLoadResult.committed,
        );
        final document = window.currentDocument!;
        expect(document.mimeType, 'text/plain');
        expect(document.content.isHtml, isFalse);
        expect(document.content.text, contains('<body>'));
        reader.mimeType = 'application/octet-stream';
        expect(
          await window.load(
            _get(_blobUrl),
            baseUrl: _creatorUrl,
            blobSource: reader.source,
          ),
          NativeDocumentLoadResult.retained,
        );
        expect(window.currentDocument, same(document));
        final save = gateway.calls.singleWhere(
          (call) => call.method == 'saveDocument',
        );
        expect(save.arguments['bytes'], reader.bytes);
        expect(save.arguments['mimeType'], 'application/octet-stream');
        expect(gateway.documentCalls, isEmpty);
      },
    );

    for (final targetName in ['_self', '_blank', 'named']) {
      test('$targetName loads blob HTML without HTTP document fetch', () async {
        final gateway = _FakeGateway();
        final windows = NativeDocumentWindows(gateway);
        addTearDown(windows.dispose);
        final sourceWindow = _rootWindow(windows);
        expect(
          await sourceWindow.load(_get(_creatorUrl), baseUrl: _creatorUrl),
          NativeDocumentLoadResult.committed,
        );

        final target = switch (targetName) {
          '_self' => windows.target(
            '_self',
            sourceWindow,
            sourceUrl: _creatorUrl,
          ),
          '_blank' => windows.target(
            '_blank',
            sourceWindow,
            sourceUrl: _creatorUrl,
          ),
          _ => windows.target('named', sourceWindow, sourceUrl: _creatorUrl),
        };
        if (targetName == '_self') {
          expect(target, same(sourceWindow));
        } else if (targetName == '_blank') {
          expect(target, isNot(same(sourceWindow)));
        } else {
          expect(
            windows.target('named', sourceWindow, sourceUrl: _creatorUrl),
            same(target),
          );
        }

        gateway.calls.clear();
        final blobSource = _FakeBlobSource();
        expect(
          await target.load(
            _get(_blobUrlWithFragment),
            baseUrl: _creatorUrl,
            blobSource: blobSource.source,
          ),
          NativeDocumentLoadResult.committed,
        );

        final document = target.currentDocument!;
        expect(target.current!.url, _blobUrlWithFragment);
        expect(document.url, _blobUrlWithFragment);
        expect(document.content.title, 'Blob page');
        expect(document.content.bodyInnerHtml, contains('blob body'));
        expect(document.content.inlineStyles, [
          'body { color: rgb(1, 2, 3); }',
        ]);
        expect(document.blobSource, same(blobSource.source));
        expect(document.blobCreatorUrl, _creatorUrl);
        expect(blobSource.reads, [_blobUrlWithFragment]);
        expect(gateway.documentCalls, isEmpty);
        expect(gateway.resolverCalls, isEmpty);
      });
    }

    test(
      'reload and retry re-read a revoked blob and retain the old document',
      () async {
        final gateway = _FakeGateway();
        final windows = NativeDocumentWindows(gateway);
        addTearDown(windows.dispose);
        final window = _rootWindow(windows);
        final reader = _FakeBlobSource();
        expect(
          await window.load(
            _get(_blobUrl),
            baseUrl: _creatorUrl,
            blobSource: reader.source,
          ),
          NativeDocumentLoadResult.committed,
        );
        final originalDocument = window.currentDocument;
        reader.available = false;

        expect(
          await window.load(
            originalDocument!.reloadRequest!,
            baseUrl: originalDocument.url,
            replaceCurrent: true,
          ),
          NativeDocumentLoadResult.failed,
        );
        expect(window.currentDocument, same(originalDocument));
        expect(reader.reads, [_blobUrl, _blobUrl]);

        expect(await window.retryRead(), NativeDocumentLoadResult.failed);
        expect(window.currentDocument, same(originalDocument));
        expect(reader.reads, [_blobUrl, _blobUrl, _blobUrl]);
      },
    );

    test('history refetch reads the retained blob source again', () async {
      final gateway = _FakeGateway();
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final window = _rootWindow(windows);
      final reader = _FakeBlobSource();
      expect(
        await window.load(
          _get(_blobUrl),
          baseUrl: _creatorUrl,
          blobSource: reader.source,
        ),
        NativeDocumentLoadResult.committed,
      );
      final blobEntry = window.history.first;
      expect(
        await window.load(
          _get('https://site.example/next.html'),
          baseUrl: _creatorUrl,
        ),
        NativeDocumentLoadResult.committed,
      );
      blobEntry.requiresHistoryRefetch = true;
      gateway.calls.clear();
      final readCount = reader.reads.length;

      expect(
        await window.traverseHistory(0),
        NativeDocumentLoadResult.committed,
      );

      expect(window.current!.url, _blobUrl);
      expect(window.currentDocument!.blobSource, same(reader.source));
      expect(reader.reads, hasLength(readCount + 1));
      expect(reader.reads.last, _blobUrl);
      expect(gateway.documentCalls, isEmpty);
      expect(gateway.resolverCalls, isEmpty);
    });

    test(
      'same-document fragment navigation reuses the blob document',
      () async {
        final gateway = _FakeGateway();
        final windows = NativeDocumentWindows(gateway);
        addTearDown(windows.dispose);
        final window = _rootWindow(windows);
        final reader = _FakeBlobSource();
        expect(
          await window.load(
            _get(_blobUrlWithFragment),
            baseUrl: _creatorUrl,
            blobSource: reader.source,
          ),
          NativeDocumentLoadResult.committed,
        );
        final document = window.currentDocument;
        final readCount = reader.reads.length;

        expect(
          await window.load(
            _get('#next'),
            baseUrl: _blobUrlWithFragment,
            fragmentAllowed: true,
          ),
          NativeDocumentLoadResult.committed,
        );

        expect(window.current!.url, '$_blobUrl#next');
        expect(window.currentDocument, same(document));
        expect(reader.reads, hasLength(readCount));
      },
    );

    test(
      'a stale creator response cannot replace the current document',
      () async {
        final gateway = _FakeGateway();
        final windows = NativeDocumentWindows(gateway);
        addTearDown(windows.dispose);
        final window = _rootWindow(windows);
        expect(
          await window.load(_get(_creatorUrl), baseUrl: _creatorUrl),
          NativeDocumentLoadResult.committed,
        );
        final currentDocument = window.currentDocument;
        final reader = _FakeBlobSource()
          ..pendingRead = Completer<Json>()
          ..readStarted = Completer<void>();
        final pending = window.load(
          _get(_blobUrl),
          baseUrl: _creatorUrl,
          blobSource: reader.source,
        );
        await reader.readStarted!.future;
        reader.current = false;
        reader.pendingRead!.complete(reader._bridgeValue(_blobUrl));

        expect(await pending, NativeDocumentLoadResult.failed);
        expect(window.currentDocument, same(currentDocument));
        expect(reader.reads, [_blobUrl]);
      },
    );

    test(
      'rejects a cross-origin blob before calling the creator reader',
      () async {
        final gateway = _FakeGateway();
        final windows = NativeDocumentWindows(gateway);
        addTearDown(windows.dispose);
        final window = _rootWindow(windows);
        final reader = _FakeBlobSource();

        expect(
          await window.load(
            _get('blob:https://other.example/foreign-token'),
            baseUrl: _creatorUrl,
            blobSource: reader.source,
          ),
          NativeDocumentLoadResult.failed,
        );
        expect(reader.reads, isEmpty);
        expect(gateway.documentCalls, isEmpty);
        expect(gateway.resolverCalls, isEmpty);
      },
    );

    test(
      'blob documents accept GET and reject POST before reading bytes',
      () async {
        final gateway = _FakeGateway();
        final windows = NativeDocumentWindows(gateway);
        addTearDown(windows.dispose);
        final window = _rootWindow(windows);
        final reader = _FakeBlobSource();

        expect(
          await window.load(
            _get(_blobUrl),
            baseUrl: _creatorUrl,
            blobSource: reader.source,
          ),
          NativeDocumentLoadResult.committed,
        );
        final document = window.currentDocument;
        final readCount = reader.reads.length;
        expect(
          await window.load(
            NativeHtmlFormRequest(
              url: _blobUrl,
              method: 'POST',
              target: '',
              body: 'data=value',
              contentType: 'application/x-www-form-urlencoded',
            ),
            baseUrl: _creatorUrl,
            blobSource: reader.source,
          ),
          NativeDocumentLoadResult.failed,
        );

        expect(window.currentDocument, same(document));
        expect(reader.reads, hasLength(readCount));
        expect(gateway.documentCalls, isEmpty);
      },
    );
  });
}
