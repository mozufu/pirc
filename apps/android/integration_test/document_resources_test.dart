import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_mobile/theme.dart';
import 'document_resource_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real Android script resources and CORS fetch paint native Flutter content',
    (t) async {
      final primary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final cross = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${primary.port}';
      final crossOrigin = 'http://127.0.0.1:${cross.port}';
      final requests = <String>[];
      Future<void> serve(HttpRequest request, bool corsServer) async {
        requests.add(
          '${request.method} ${corsServer ? 'cross' : 'same'}${request.uri.path}',
        );
        final response = request.response;
        if (corsServer && request.uri.path == '/cors') {
          response.headers.set('Access-Control-Allow-Origin', origin);
          response.headers.set('Access-Control-Allow-Methods', 'POST');
          response.headers.set(
            'Access-Control-Allow-Headers',
            'content-type, x-pirc-test',
          );
          response.headers.set('Access-Control-Expose-Headers', 'x-result');
          response.headers.set('X-Result', 'visible');
          if (request.method == 'OPTIONS') {
            response.statusCode = 204;
            await response.close();
            return;
          }
          response.headers.contentType = ContentType.json;
          response.write(await utf8.decoder.bind(request).join());
        } else if (request.uri.path == '/empty') {
          response.statusCode = 204;
        } else if (request.uri.path == '/head') {
          response.headers.contentType = ContentType.text;
          response.write('HEAD must hide this');
        } else if (request.uri.path == '/api') {
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode({'message': '原生資料'}));
        } else if (request.uri.path == '/denied') {
          response.write('unreadable');
        } else {
          final script = {
            '/library.js': libraryScript,
            '/defer.js': deferScript,
            '/async.js': asyncScript,
            '/dynamic.js': dynamicScript,
          }[request.uri.path];
          response.headers.contentType = ContentType(
            'application',
            'javascript',
            charset: 'utf-8',
          );
          if (script == null) {
            response.statusCode = 404;
            response.write('not found');
          } else {
            response.write(script);
          }
        }
        await response.close();
      }

      final first = primary.listen(
        (request) => unawaited(serve(request, false)),
      );
      final second = cross.listen((request) => unawaited(serve(request, true)));
      final source = resourceHtml
          .replaceAll('@ORIGIN@', origin)
          .replaceAll('@CROSS@', crossOrigin);
      final bytes = Uint8List.fromList(utf8.encode(source));
      final document = NativeFetchedDocument(
        id: 1,
        url: '$origin/index.html',
        status: 200,
        bytes: bytes,
        mimeType: 'text/html',
        content: NativeHtmlDocumentContent.fromBytes(
          bytes,
          mimeType: 'text/html',
          charset: 'utf-8',
        ),
        headers: {},
      );
      try {
        final theme = await PircTheme.load();
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Scaffold(
              body: NativeFetchedDocumentView(
                document: document,
                gateway: Gateway(),
                onLink: (_) {},
                onSubmit: (_) {},
              ),
            ),
          ),
        );
        Future<void> until(String text) async {
          for (var i = 0; i < 150; i++) {
            await t.pump(const Duration(milliseconds: 100));
            if (document.scripts?.content?.text.contains(text) == true) return;
          }
          fail(
            'Missing $text; diagnostics=${document.scripts?.diagnostics}; content=${document.scripts?.content?.text}; requests=$requests',
          );
        }

        await until(expectedLifecycle);
        expect(
          find.text(expectedLifecycle, findRichText: true),
          findsOneWidget,
        );
        await t.tap(
          find.byWidgetPredicate(
            (w) =>
                w is NativeHtmlButtonWidget &&
                w.button.label == 'Load live data',
          ),
        );
        await until(expectedResult);
        await t.pumpAndSettle();
        expect(find.text(expectedResult, findRichText: true), findsOneWidget);
        expect(
          requests,
          containsAll([
            'GET same/library.js',
            'GET same/dynamic.js',
            'OPTIONS cross/cors',
            'POST cross/cors',
            'GET cross/denied',
          ]),
        );
        expect(t.takeException(), isNull);
        debugPrint('DOCUMENT_RESOURCE_REQUESTS:${jsonEncode(requests)}');
      } finally {
        await t.pumpWidget(const SizedBox());
        document.dispose();
        await first.cancel();
        await second.cancel();
        await primary.close(force: true);
        await cross.close(force: true);
      }
    },
  );
}
