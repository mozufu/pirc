import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_mobile/theme.dart';
import 'document_xhr_fixture.dart';

Map<String, dynamic>? probe(NativeFetchedDocument document) {
  final text =
      html
          .parse(document.scripts?.content?.text ?? '')
          .querySelector('#xhr-result')
          ?.text ??
      '';
  return text.startsWith('{')
      ? Map<String, dynamic>.from(jsonDecode(text) as Map)
      : null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native XHR uses real HTTP, binary bodies, CORS, cancellation and reentry',
    (t) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final requests = <Map<String, dynamic>>[];
      final serverErrors = <String>[];
      Future<void> serve(HttpRequest req) async {
        final res = req.response;
        final path = req.uri.path;
        final entry = <String, dynamic>{
          'method': req.method,
          'path': path,
          'query': req.uri.query,
          'origin': req.headers.value('origin'),
          'authorization': req.headers.value('authorization'),
          'xTrace': req.headers.value('x-trace'),
          'preflightMethod': req.headers.value('access-control-request-method'),
          'preflightHeaders': req.headers.value(
            'access-control-request-headers',
          ),
        };
        requests.add(entry);
        res.headers.set('cache-control', 'no-store');
        void text(
          String body, {
          String type = 'text/plain; charset=utf-8',
          int status = 200,
        }) {
          res.statusCode = status;
          res.headers.set('content-type', type);
          res.write(body);
        }

        switch (path) {
          case '/text':
            text('XHR 中文 text');
            break;
          case '/post-json':
            final body = await utf8.decoder.bind(req).join();
            entry['body'] = body;
            text(
              jsonEncode({
                'method': req.method,
                'bodyText': body,
                'contentType': req.headers.value('content-type'),
                'xTrace': req.headers.value('x-trace'),
                'cookie': req.headers.value('cookie'),
                'host': req.headers.value('host'),
              }),
              type: 'application/json; charset=utf-8',
            );
            break;
          case '/status404':
            text('Missing 雪', status: 404);
            break;
          case '/json-valid':
            text(
              jsonEncode({'city': '台北', 'ok': true}),
              type: 'application/json; charset=utf-8',
            );
            break;
          case '/json-invalid':
            text('{invalid json', type: 'application/json; charset=utf-8');
            break;
          case '/arraybuffer':
            res.headers.set('content-type', 'application/octet-stream');
            res.add([0, 127, 128, 255, 13, 10]);
            break;
          case '/blob':
            text('blob 雪');
            break;
          case '/document-response':
            text(
              '<!doctype html><title>XHR document 雪</title><p>document response text</p>',
              type: 'text/html; charset=utf-8',
            );
            break;
          case '/windows-1252':
            res.headers.set('content-type', 'text/plain; charset=utf-8');
            res.add([0x63, 0x61, 0x66, 0xe9]);
            break;
          case '/redirect-text':
            res.statusCode = 302;
            res.headers.set('location', '/redirect-final?redirected=1');
            break;
          case '/redirect-final':
            text('final redirected ✓', status: 201);
            break;
          case '/empty204':
            res.statusCode = 204;
            break;
          case '/head':
            res.headers.set('content-type', 'text/plain; charset=utf-8');
            res.headers.set('content-length', '13');
            break;
          case '/cors-allow':
            res.headers.set('access-control-allow-origin', '*');
            text('cors allowed');
            break;
          case '/cors-deny':
            text('cors denied');
            break;
          case '/cors-preflight':
            res.headers.set('access-control-allow-origin', origin);
            if (req.method == 'OPTIONS') {
              res.statusCode = 204;
              res.headers.set('access-control-allow-methods', 'GET');
              res.headers.set('access-control-allow-headers', 'x-trace');
            } else {
              text('listener preflight ok');
            }
            break;
          case '/upload-simple':
            res.headers.set('access-control-allow-origin', origin);
            if (req.method == 'OPTIONS') {
              res.statusCode = 204;
            } else {
              entry['body'] = await utf8.decoder.bind(req).join();
              text('upload body received: ${entry['body']}');
            }
            break;
          case '/delay':
            await Future<void>.delayed(
              Duration(
                milliseconds:
                    int.tryParse(req.uri.queryParameters['ms'] ?? '') ?? 100,
              ),
            );
            text('delayed response');
            break;
          case '/slow-stream':
            res.headers.set('content-type', 'text/plain; charset=utf-8');
            res.write('partial');
            await res.flush();
            await Future<void>.delayed(
              Duration(
                milliseconds:
                    int.tryParse(req.uri.queryParameters['delay'] ?? '') ?? 350,
              ),
            );
            res.write(' tail');
            break;
          default:
            throw StateError('Unexpected local request ${req.method} $path');
        }
        await res.close();
      }

      final serving = server.listen((req) {
        unawaited(
          serve(req).catchError((Object e) {
            serverErrors.add('$e');
          }),
        );
      });
      final theme = await PircTheme.load();
      final gateway = Gateway();
      try {
        for (final width in [390.0, 860.0]) {
          for (final brightness in [Brightness.light, Brightness.dark]) {
            for (final scale in [1.0, 2.0]) {
              t.view.physicalSize = Size(width, 600);
              t.view.devicePixelRatio = 1;
              final bytes = Uint8List.fromList(utf8.encode(documentXhrHtml));
              final document = NativeFetchedDocument(
                id: 1,
                url: '$origin/fixture',
                status: 200,
                bytes: bytes,
                mimeType: 'text/html',
                headers: {},
                content: NativeHtmlDocumentContent.fromBytes(
                  bytes,
                  mimeType: 'text/html',
                  charset: 'utf-8',
                ),
              );
              try {
                await t.pumpWidget(
                  MaterialApp(
                    theme: theme.build(brightness),
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(scale)),
                      child: child!,
                    ),
                    home: Scaffold(
                      body: NativeFetchedDocumentView(
                        document: document,
                        gateway: gateway,
                        onLink: (_) {},
                        onSubmit: (_) {},
                      ),
                    ),
                  ),
                );
                for (var i = 0; i < 1500 && probe(document) == null; i++) {
                  await t.pump(const Duration(milliseconds: 25));
                }
                final result = probe(document);
                expect(
                  result,
                  isNotNull,
                  reason:
                      '$width/$brightness/$scale ${document.scripts?.diagnostics}',
                );
                expect(
                  result!['fixtureError'],
                  isNull,
                  reason: jsonEncode(result),
                );
                expect(document.scripts!.ready, true);
                expect(document.scripts!.diagnostics, isEmpty);
                final responses = result['requests'] as Map;
                final cases = result['cases'] as Map;
                expect(responses['getText']['value']['text'], 'XHR 中文 text');
                final getTerminal = (responses['getText']['events'] as List)
                    .where(
                      (e) => e['type'] == 'load' || e['type'] == 'loadend',
                    );
                expect(getTerminal.length, 2);
                expect(getTerminal.every((e) => e['loaded'] == 15), true);
                final headTerminal = (responses['head']['events'] as List)
                    .where(
                      (e) => e['type'] == 'load' || e['type'] == 'loadend',
                    );
                expect(
                  headTerminal.every(
                    (e) => e['loaded'] == 0 && e['total'] == 13,
                  ),
                  true,
                );

                final post = responses['postJson']['value']['value'];
                expect(jsonDecode(post['bodyText'] as String), {
                  'city': '台北',
                  'count': 2,
                });
                expect(post['xTrace'], 'first, second');
                expect(post['cookie'], isNull);
                expect(post['host'], isNot(contains('forbidden.invalid')));
                expect(responses['status404']['terminal'], 'load');
                expect(responses['status404']['final']['status'], 404);
                expect(responses['status404']['value']['text'], 'Missing 雪');
                expect(responses['validJson']['value']['value'], {
                  'city': '台北',
                  'ok': true,
                });
                expect(responses['invalidJson']['value']['value'], isNull);
                expect(responses['arrayBuffer']['value']['bytes'], [
                  0,
                  127,
                  128,
                  255,
                  13,
                  10,
                ]);
                expect(responses['arrayBuffer']['value']['sameIdentity'], true);
                expect(responses['blob']['value']['text']['text'], 'blob 雪');
                expect(responses['blob']['value']['type'], 'text/plain');
                expect(responses['blob']['value']['sameIdentity'], true);
                expect(
                  responses['document']['value']['title'],
                  'XHR document 雪',
                );
                expect(
                  responses['document']['value']['bodyText'],
                  'document response text',
                );
                expect(
                  responses['document']['value']['responseXmlSameIdentity'],
                  true,
                );
                expect(
                  responses['document']['value']['url'],
                  '$origin/document-response',
                );
                expect(responses['overrideMimeType']['value']['text'], 'café');
                expect(
                  responses['redirect']['final']['responseURL'],
                  '$origin/redirect-final?redirected=1',
                );
                expect(responses['redirect']['final']['status'], 201);
                expect(responses['empty204']['value']['text'], '');
                expect(responses['head']['value']['text'], '');
                expect(responses['corsAllow']['terminal'], 'load');
                expect(responses['corsDeny']['terminal'], 'error');
                expect(responses['corsDeny']['final']['status'], 0);
                expect(
                  responses['listenerTriggeredPreflight']['responseText'],
                  'listener preflight ok',
                );
                expect(responses['uploadSimplePreflight']['terminal'], 'load');
                expect(
                  responses['uploadSimplePreflight']['responseText'],
                  'upload body received: upload body',
                );
                final uploadEvents =
                    responses['uploadSimplePreflight']['uploadEvents'] as List;
                expect(uploadEvents.map((e) => e['type']).toList(), [
                  'progress',
                ]);
                expect(uploadEvents.single['loaded'], 11);
                expect(uploadEvents.single['total'], 11);
                expect(cases['abortDuringLoadstart']['terminal'], 'abort');
                expect(cases['abortDuringLoadstart']['final']['readyState'], 0);
                expect(cases['abortDuringLoading']['terminal'], 'abort');
                expect(cases['abortDuringLoading']['final']['readyState'], 0);
                expect(
                  cases['repeatedSend']['secondSend']['errorName'],
                  'InvalidStateError',
                );
                expect(cases['timeout']['terminal'], 'timeout');
                expect(cases['timeoutShortThenLong']['terminal'], 'load');
                expect(cases['timeoutLongThenShort']['terminal'], 'timeout');
                expect(
                  cases['reopenWhileLoading']['responseText'],
                  'XHR 中文 text',
                );
                for (final phase in ['readystatechange', 'load', 'loadend']) {
                  expect(result['reentry'][phase]['reentryError'], isNull);
                  expect(
                    result['reentry'][phase]['responseText'],
                    'XHR 中文 text',
                  );
                }
                for (final method in ['TRACE', 'TRACK', 'CONNECT']) {
                  expect(
                    result['errors']['openForbiddenMethods'][method]['errorName'],
                    'SecurityError',
                  );
                }
                expect(
                  find.text(
                    'XMLHttpRequest parity probes complete.',
                    findRichText: true,
                  ),
                  findsOneWidget,
                );
                expect(t.takeException(), isNull);
                debugPrint(
                  'NATIVE_XHR ${jsonEncode({'width': width, 'theme': brightness.name, 'scale': scale, 'requests': responses.keys.toList(), 'abortState': cases['abortDuringLoading']['final']['readyState'], 'timeout': cases['timeout']['terminal'], 'reentry': (result['reentry'] as Map).keys.toList(), 'post': post, 'document': responses['document']['value']})}',
                );
              } finally {
                await t.pumpWidget(const SizedBox());
                document.dispose();
                await t.pump();
              }
            }
          }
        }
        expect(serverErrors, isEmpty);
        expect(
          requests.where(
            (r) => r['path'] == '/cors-preflight' && r['method'] == 'OPTIONS',
          ),
          isNotEmpty,
        );
        expect(
          requests
              .where(
                (r) =>
                    r['path'] == '/upload-simple' && r['method'] == 'OPTIONS',
              )
              .length,
          8,
        );
        expect(
          requests
              .where(
                (r) => r['path'] == '/upload-simple' && r['method'] == 'POST',
              )
              .length,
          8,
        );
        expect(
          requests
              .where(
                (r) => r['path'] == '/upload-simple' && r['method'] == 'POST',
              )
              .every((r) => r['body'] == 'upload body'),
          true,
        );
        expect(requests.every((r) => r['authorization'] == null), true);
      } finally {
        await serving.cancel();
        await server.close(force: true);
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
      }
    },
  );
}
