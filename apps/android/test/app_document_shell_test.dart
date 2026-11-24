import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/app_document_route.dart';
import 'package:pirc_mobile/live/app_document_shell.dart';
import 'package:pirc_render/src/html_document_content.dart';

const _root = 'https://pirc.example/';
const _description =
    'A calm command surface for persistent coding-agent sessions.';

String _shell(
  String moduleSource, {
  String title = 'pirc',
  String description = _description,
}) =>
    '<!doctype html><html lang="en"><head>'
    '<meta name="description" content="$description">'
    '<meta name="apple-mobile-web-app-title" content="pirc">'
    '<title>$title</title></head><body><div id="app"></div>'
    '<script type="module" src="$moduleSource"></script>'
    '</body></html>';

NativeHtmlDocumentContent _content(
  String source, {
  String mimeType = 'text/html',
}) => NativeHtmlDocumentContent.fromBytes(
  Uint8List.fromList(utf8.encode(source)),
  mimeType: mimeType,
);

NativeAppDocumentRoute? _classify(
  String source, {
  int status = 200,
  String method = 'GET',
  String url = _root,
  String appRoot = _root,
  String mimeType = 'text/html',
}) => nativePircAppDocumentRoute(
  content: _content(source, mimeType: mimeType),
  status: status,
  finalMethod: method,
  canonicalUrl: url,
  appRootUrl: appRoot,
);

void main() {
  group('nativePircAppDocumentRoute', () {
    test(
      'recognizes the dev shell and parses session/workspace query state',
      () {
        final route = _classify(
          _shell('/src/main.ts'),
          url: 'https://pirc.example/?session=s%2B1&workspace=project%3Aone',
        );

        expect(route, isNotNull);
        expect(route!.canonicalUrl, contains('session=s%2B1'));
        expect(route.workspaceId, 'project:one');
        expect(route.target, isA<NativeAppSessionRouteTarget>());
        expect((route.target! as NativeAppSessionRouteTarget).sessionId, 's+1');
      },
    );

    test('recognizes the production module shell and index alias', () {
      final route = _classify(
        _shell('/assets/index-a1b2c3.js'),
        status: 201,
        url: 'https://pirc.example/index.html?open=schedules&schedule=cron-1',
      );

      expect(route, isNotNull);
      expect(route!.isIndexAlias, isTrue);
      expect(route.target, isA<NativeAppSchedulesRouteTarget>());
      expect(
        (route.target! as NativeAppSchedulesRouteTarget).scheduleId,
        'cron-1',
      );
    });

    test(
      'accepts notification memory route and same-origin crossorigin module',
      () {
        const source =
            '''
        <!doctype html><html><head>
          <meta name="description" content="$_description">
          <meta name="apple-mobile-web-app-title" content="pirc">
          <title>pirc</title>
        </head><body><div id="app"></div>
          <script type="module" crossorigin src="/assets/main.js"></script>
        </body></html>
      ''';

        final route = _classify(
          source,
          url: 'https://pirc.example/?open=memory',
        );

        expect(route, isNotNull);
        expect(route!.target, isA<NativeAppMemoryRouteTarget>());
      },
    );

    test('rejects an ordinary page with a generic app mount point', () {
      final source = '''
        <html><head><title>pirc</title></head>
        <body><div id="app"></div><script type="module" src="/src/main.ts"></script></body></html>
      ''';

      expect(_classify(source), isNull);
    });

    test(
      'requires the pinned title, description, and module entry signature',
      () {
        expect(_classify(_shell('/src/main.ts', title: 'Pirc')), isNull);
        expect(
          _classify(_shell('/src/main.ts', description: 'A different app.')),
          isNull,
        );
        expect(_classify(_shell('/src/main.js')), isNull);
        expect(_classify(_shell('/assets/main.css')), isNull);
      },
    );

    test(
      'rejects a foreign module entry even if the rest resembles the shell',
      () {
        expect(_classify(_shell('https://cdn.example/assets/main.js')), isNull);
      },
    );

    test('recognizes root, index alias, and confirmed SPA fallback paths', () {
      final source = _shell('/src/main.ts');

      final fallback = _classify(
        source,
        url: 'https://pirc.example/workspace/project?session=s1',
      );
      expect(
        _classify(source, url: 'https://pirc.example/?session=s1'),
        isNotNull,
      );
      expect(fallback, isNotNull);
      expect(fallback!.isSpaFallbackPath, isTrue);
      expect(
        _classify(source, url: 'https://pirc.example/api/devices'),
        isNull,
      );
      expect(
        _classify(source, url: 'https://other.example/?session=s1'),
        isNull,
      );
    });

    test('does not accept ordinary HTML at an SPA fallback path', () {
      const ordinary = '''
        <html><head><title>Other</title></head>
        <body><div id="app"></div><script type="module" src="/other.js"></script></body></html>
      ''';

      expect(
        _classify(
          ordinary,
          url: 'https://pirc.example/workspace/project?session=s1',
        ),
        isNull,
      );
    });

    test('does not classify unsuccessful, POST, or no-content responses', () {
      final source = _shell('/src/main.ts');

      for (final status in [204, 205, 301, 403, 500]) {
        expect(
          _classify(source, status: status),
          isNull,
          reason: 'status $status',
        );
      }
      expect(_classify(source, method: 'POST'), isNull);
      expect(_classify(source, mimeType: 'text/plain'), isNull);
    });
  });
}
