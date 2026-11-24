import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/document_style_loading.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_styles.dart';

Json cssReply(
  String url,
  String text, {
  String mime = 'text/css',
  int status = 200,
}) => {
  'status': status,
  'finalUrl': url,
  'mimeType': mime,
  'charset': 'UTF-8',
  'bytes': Uint8List.fromList(utf8.encode(text)),
};

void main() {
  test(
    'document order, imported response base and media reach actual cascade',
    () async {
      final paths = <String>[];
      final replies = {
        'https://example.test/page/css/base.css': cssReply(
          'https://example.test/page/css/base.css',
          '#probe {color:rgb(1,2,3)}',
        ),
        'https://example.test/page/css/late.css': cssReply(
          'https://example.test/cdn/late.css',
          '@import "nested/import.css" (prefers-color-scheme: dark); #probe {color:rgb(7,8,9)}',
        ),
        'https://example.test/cdn/nested/import.css': cssReply(
          'https://example.test/cdn/nested/import.css',
          '#probe {color:rgb(4,5,6); padding-left:13px}',
        ),
      };
      final loader = NativeDocumentStyleLoader(
        isCurrent: () => true,
        resolve: (href, base) async => Uri.parse(base).resolve(href).toString(),
        fetch: (url, base) async {
          paths.add(url);
          return replies[url]!;
        },
      );
      final loaded = await loader.load(
        '''<!doctype html><html><head>
      <link rel="stylesheet" href="css/base.css">
      <style>#probe {color:rgb(2,3,4)}</style>
      <link rel="stylesheet" href="css/late.css" media="(min-width:600px)">
      </head><body><p id="probe">Probe</p></body></html>''',
        baseUrl: 'https://example.test/page/current',
        documentEncoding: 'utf-8',
      );
      expect(paths, replies.keys.toList());
      expect(loaded.diagnostics, isEmpty);
      for (final config in [
        (390.0, false),
        (390.0, true),
        (768.0, false),
        (768.0, true),
      ]) {
        final (width, dark) = config;
        final document = html.parse('<p id="probe">Probe</p>');
        final result = NativeDocumentStyleEngine(
          stylesheets: loaded.stylesheets,
          viewportWidth: width,
          dark: dark,
        ).apply(document);
        final style = result.stylesByElement[document.querySelector('#probe')]!;
        expect(
          style['color']!.replaceAll(' ', ''),
          width < 600 ? 'rgb(2,3,4)' : 'rgb(7,8,9)',
        );
        expect(style['padding-left'], width < 600 || !dark ? null : '13px');
      }
    },
  );

  test(
    'failed or non-CSS replies do not suppress a later valid source',
    () async {
      final loader = NativeDocumentStyleLoader(
        isCurrent: () => true,
        resolve: (href, base) async => Uri.parse(base).resolve(href).toString(),
        fetch: (url, base) async => url.endsWith('bad.css')
            ? cssReply(url, '<html>Not CSS</html>', mime: 'text/html')
            : cssReply(url, 'p{padding:3px}'),
      );
      final loaded = await loader.load(
        '''<link rel="stylesheet" href="bad.css">
      <link rel="stylesheet" href="good.css">
      <link rel="alternate stylesheet" href="inactive.css">
      <link rel="stylesheet" disabled href="disabled.css">''',
        baseUrl: 'https://example.test/',
        documentEncoding: 'utf-8',
      );
      expect(loaded.diagnostics.single, contains('MIME'));
      expect(loaded.stylesheets, hasLength(1));
    },
  );

  test(
    'cyclic imports are bounded and no resource starts after invalidation',
    () async {
      var current = true;
      final paths = <String>[];
      final loader = NativeDocumentStyleLoader(
        isCurrent: () => current,
        resolve: (href, base) async => Uri.parse(base).resolve(href).toString(),
        fetch: (url, base) async {
          paths.add(url);
          return cssReply(url, '@import "loop.css";p{color:red}');
        },
      );
      final loaded = await loader.load(
        '<link rel="stylesheet" href="loop.css">',
        baseUrl: 'https://example.test/',
        documentEncoding: 'utf-8',
      );
      expect(paths, hasLength(1));
      expect(loaded.diagnostics.single, contains('Cyclic'));
      current = false;
      await expectLater(
        loader.load(
          '<link rel="stylesheet" href="next.css">',
          baseUrl: 'https://example.test/',
          documentEncoding: 'utf-8',
        ),
        throwsStateError,
      );
      expect(paths, hasLength(1));
    },
  );
  test(
    'stylesheet credentials, SRI and response policy stay with the correct owner/import',
    () async {
      final requests = <(String, NativeStylesheetRequestOptions)>[];
      final loader = NativeDocumentStyleLoader(
        isCurrent: () => true,
        resolve: (href, base) async => Uri.parse(base).resolve(href).toString(),
        fetch: (_, _) async => throw StateError('legacy transport used'),
        fetchWithOptions: (url, base, options) async {
          requests.add((url, options));
          return {
            ...cssReply(
              url,
              url.endsWith('main.css')
                  ? '@import "child.css";p{color:red}'
                  : 'p{width:19px}',
            ),
            'stylesheetReferrerPolicy': 'no-referrer',
          };
        },
      );
      final result = await loader.load(
        '<base href="https://cdn.example/assets/"><link rel="stylesheet" href="main.css" crossorigin="use-credentials" integrity="sha256-root" media="print">',
        baseUrl: 'https://cdn.example/assets/',
        documentUrl: 'https://page.example/private?query=1',
        documentEncoding: 'utf-8',
        referrerPolicy: 'origin',
      );
      expect(requests, hasLength(2));
      expect(requests[0].$2.integrity, 'sha256-root');
      expect(
        requests[0].$2.referrerUrl,
        'https://page.example/private?query=1',
      );
      expect(requests[0].$2.referrerPolicy, 'origin');
      expect(requests[1].$2.integrity, isNull);
      expect(requests[1].$2.crossOrigin, 'use-credentials');
      expect(requests[1].$2.referrerUrl, 'https://cdn.example/assets/main.css');
      expect(requests[1].$2.referrerPolicy, 'no-referrer');
      expect(result.prepared.single.media, 'print');
      expect(
        result.prepared.single.unwrappedStylesheets.every(
          (sheet) => !sheet.cssText.startsWith('@media print'),
        ),
        true,
      );
      expect(result.loaded, true);
    },
  );

  test(
    'failed imports preserve parent declarations and report a failed load',
    () async {
      final loader = NativeDocumentStyleLoader(
        isCurrent: () => true,
        resolve: (href, base) async => Uri.parse(base).resolve(href).toString(),
        fetch: (url, base) async => cssReply(url, '', status: 404),
      );
      final result = await loader.loadInline(
        '@import "missing.css";p{height:23px}',
        baseUrl: 'https://example.test/',
        documentEncoding: 'utf-8',
        options: const NativeStylesheetRequestOptions(
          referrerUrl: 'https://example.test/page',
        ),
      );
      expect(result.loaded, false);
      expect(result.diagnostics.single, contains('HTTP 404'));
      expect(result.stylesheets.single.cssText, contains('height:23px'));
    },
  );

  test(
    'invalid URLs do not prevent later author styles from loading',
    () async {
      final loader = NativeDocumentStyleLoader(
        isCurrent: () => true,
        resolve: (href, base) async {
          if (href == 'bad') throw const FormatException('invalid URL');
          return Uri.parse(base).resolve(href).toString();
        },
        fetch: (url, base) async => cssReply(url, 'p{color:blue}'),
      );
      final result = await loader.load(
        '<link rel="stylesheet" href="bad"><style>p{width:9px}</style>',
        baseUrl: 'https://example.test/',
        documentEncoding: 'utf-8',
      );
      expect(result.loaded, false);
      expect(result.stylesheets.single.cssText, contains('width:9px'));
      expect(result.diagnostics.single, contains('could not resolve'));
    },
  );

  test(
    'native stylesheet wire validates bytes without producing script source',
    () {
      final response = nativeStylesheetResponse({
        'status': 200,
        'url': 'https://example.test/style.css',
        'mimeType': 'text/css',
        'bodyBytes': utf8.encode('p{color:red}'),
      });
      expect(utf8.decode(response['bytes'] as List<int>), 'p{color:red}');
      expect(response.containsKey('source'), false);
      expect(
        () => nativeStylesheetResponse({
          'status': 200,
          'url': 'https://example.test/',
          'mimeType': 'text/css',
          'bodyBytes': [256],
        }),
        throwsFormatException,
      );
    },
  );
}
