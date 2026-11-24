import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_mobile/theme.dart';
import 'document_text_encoding_fixture.dart';

Json? _result(NativeFetchedDocument document) {
  final text =
      html
          .parse(document.scripts?.content?.text ?? '')
          .querySelector('#result')
          ?.text ??
      '';
  return text.startsWith('{')
      ? Map<String, dynamic>.from(jsonDecode(text) as Map)
      : null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native text encoders, Big5 FileReader/XHR and UTF-8 HTTP bytes match browser core',
    (t) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      const big5 = [0xa5, 0x78, 0xa5, 0x5f];
      final requests = <Json>[];
      final errors = <Object>[];
      final listener = server.listen((request) {
        unawaited(() async {
          try {
            final bytes = await request.fold<List<int>>(
              [],
              (all, chunk) => all..addAll(chunk),
            );
            requests.add({
              'method': request.method,
              'path': request.uri.path,
              'bytes': bytes,
            });
            if (request.method == 'GET' && request.uri.path == '/big5.txt') {
              request.response.headers.set(
                'content-type',
                'text/plain;charset=Big5',
              );
              request.response.add(big5);
            } else if (request.method == 'GET' &&
                request.uri.path == '/utf8.json') {
              request.response.headers.set(
                'content-type',
                'application/json; charset=Big5',
              );
              request.response.add(
                utf8.encode(
                  jsonEncode({
                    'status': 'OK',
                    'message': 'UTF-8 JSON 中文 🐈',
                    'charset': 'big5',
                  }),
                ),
              );
            } else if (request.method == 'POST' &&
                request.uri.path == '/encoded-body') {
              request.response.headers.contentType = ContentType.json;
              request.response.write(
                jsonEncode({
                  'bytesBase64': base64Encode(bytes),
                  'bodyText': utf8.decode(bytes),
                }),
              );
            } else {
              throw StateError(
                'Unexpected request ${request.method} ${request.uri}',
              );
            }
            await request.response.close();
          } catch (error) {
            errors.add(error);
            request.response.statusCode = 500;
            await request.response.close();
          }
        }());
      });
      final theme = await PircTheme.load();
      final gateway = Gateway();
      try {
        for (final width in [390.0, 860.0]) {
          for (final brightness in [Brightness.light, Brightness.dark]) {
            for (final scale in [1.0, 2.0]) {
              final previousCount = requests.length;
              t.view.physicalSize = Size(width, 844);
              t.view.devicePixelRatio = 1;
              final bytes = Uint8List.fromList(
                utf8.encode(documentTextEncodingFixture),
              );
              final document = NativeFetchedDocument(
                id: previousCount + 1,
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
                for (var i = 0; i < 600 && _result(document) == null; i++) {
                  await t.pump(const Duration(milliseconds: 50));
                }
                final result = _result(document);
                expect(
                  result,
                  isNotNull,
                  reason: '${document.scripts?.diagnostics}',
                );
                expect(result!['status'], 'DONE', reason: '$result');
                expect(result['pageErrors'], isEmpty);
                expect(result['blockedExternalRequests'], isEmpty);
                expect(document.scripts!.ready, isTrue);
                expect(document.scripts!.diagnostics, isEmpty);
                expect(t.takeException(), isNull);
                expect(
                  find.text('中文文字編碼驗收完成', findRichText: true),
                  findsOneWidget,
                );
                final encoder = result['textEncoder'] as Map;
                expect(encoder['encoding'], 'utf-8');
                expect(
                  encoder['encodeBytes'],
                  utf8.encode('台北🐈\uD800X\uDC00'),
                );
                expect(encoder['encodeInto']['partial']['read'], 1);
                expect(encoder['encodeInto']['partial']['written'], 3);
                expect(encoder['encodeInto']['complete']['read'], 4);
                expect(encoder['encodeInto']['complete']['written'], 8);
                final decoder = result['textDecoder'] as Map;
                expect(decoder['utf8']['text'], 'A尾🐈');
                expect(decoder['utf16le']['text'], 'A🐈');
                expect(decoder['utf16be']['text'], 'A🐈');
                expect(decoder['windows1252']['text'], '€“A”\u0081Ÿé');
                expect(decoder['streams']['utf8']['parts'], ['', '🐈']);
                expect(decoder['streams']['big5']['parts'], ['', '台']);
                expect(decoder['streams']['utf16le']['parts'], ['', 'A', '🐈']);
                expect(decoder['dataViewOffset']['text'], '台');
                expect(decoder['typedArrayOffset']['text'], '台');
                expect(decoder['errors']['invalidLabel'], 'RangeError');
                for (final key in [
                  'fatalUtf8',
                  'fatalBig5',
                  'wrongSourceType',
                ]) {
                  expect(decoder['errors'][key], 'TypeError', reason: key);
                }
                final integrations = result['integrations'] as Map;
                for (final name in [
                  'fetchArrayBufferBig5',
                  'fileReaderReadAsTextBig5',
                  'xhrResponseTextBig5',
                ]) {
                  expect(integrations[name]['text'], '台北', reason: name);
                }
                for (final name in [
                  'fetchTextUtf8Control',
                  'blobTextUtf8Control',
                ]) {
                  expect(
                    integrations[name]['text'],
                    utf8.decode(big5, allowMalformed: true),
                    reason: name,
                  );
                }
                expect(
                  integrations['fetchJson'],
                  integrations['xhrResponseTypeJson'],
                );
                final upload = integrations['encodedBody'] as Map;
                expect(upload['response']['bodyText'], '城市 台北 🐈');
                expect(
                  upload['response']['bytesBase64'],
                  base64Encode(utf8.encode('城市 台北 🐈')),
                );
                for (final special
                    in result['big5SpecialObservations'] as List) {
                  expect(
                    special['actual']['codePoints'],
                    special['expectedCodePoints'],
                    reason: special['name'] as String,
                  );
                }
                // Explicit known difference: fatal UTF-16 errors reset this
                // bounded decoder; Chrome may retain an incomplete tail.
                final fatalCalls =
                    result['fatalUtf16RecoveryObservation']['calls'] as List;
                expect(fatalCalls[1]['errorName'], 'TypeError');
                expect(fatalCalls[2]['value']['codePoints'], [0x4241]);
                expect(requests.length - previousCount, 6);
                expect(errors, isEmpty);
                debugPrintSynchronously(
                  'NATIVE_TEXT_ENCODING ${jsonEncode({'width': width, 'theme': brightness.name, 'scale': scale, 'result': result, 'requests': requests.sublist(previousCount)})}',
                );
              } finally {
                await t.pumpWidget(const SizedBox());
                document.dispose();
                await document.scripts?.closed;
              }
            }
          }
        }
      } finally {
        t.view.reset();
        await listener.cancel();
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
