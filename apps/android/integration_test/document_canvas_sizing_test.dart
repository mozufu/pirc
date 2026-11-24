import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

const _fixtureOrigin = String.fromEnvironment('PIRC_CHART_FIXTURE_ORIGIN');
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native intrinsic and changing Canvas sizes match browser checkpoints',
    (tester) async {
      final fixtureOrigin = Uri.parse(_fixtureOrigin);
      expect(fixtureOrigin.scheme, 'http');
      expect(fixtureOrigin.host, '127.0.0.1');
      final client = HttpClient();
      late Json fixture;
      try {
        final request = await client.getUrl(
          fixtureOrigin.resolve('/canvas-sizing.json'),
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        fixture = obj(jsonDecode(await utf8.decoder.bind(response).join()));
      } finally {
        client.close(force: true);
      }
      final gateway = Gateway();
      final theme = await PircTheme.load();
      final accepted = <Json>[];
      for (final raw in fixture['cases'] as List) {
        final reference = obj(raw), viewport = obj(reference['viewport']);
        final dpr = (reference['dpr'] as num).toDouble();
        final width = (viewport['width'] as num).toDouble(),
            height = (viewport['height'] as num).toDouble();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final origin = 'http://127.0.0.1:${server.port}';
        final token = 'pirc_dev_${List.filled(43, 'F').join()}';
        final failures = <String>[];
        final listener = server.listen((request) async {
          try {
            await request.drain<void>();
            if (request.headers.value('authorization') != 'Bearer $token') {
              failures.add('Missing synthetic bearer');
            }
            if (request.uri.path == '/api/sessions') {
              request.response.headers.contentType = ContentType.json;
              request.response.write('{"sessions":[]}');
            } else if (request.uri.path == '/page') {
              request.response.headers.contentType = ContentType(
                'text',
                'html',
                charset: 'utf-8',
              );
              request.response.write(reference['html']);
            } else {
              request.response.statusCode = 404;
              failures.add('Unexpected path ${request.uri.path}');
            }
            await request.response.close();
          } catch (error) {
            failures.add('$error');
          }
        });
        NativeDocumentWindows? windows;
        NativeFetchedDocument? document;
        try {
          await gateway.call('pair', {
            'link': Uri(
              scheme: 'pirc',
              host: 'pair',
              queryParameters: {'url': origin, 'token': token},
            ).toString(),
          });
          windows = NativeDocumentWindows(gateway);
          final window = windows.target('', null, sourceUrl: '$origin/page');
          expect(
            await window.load(
              NativeHtmlFormRequest(
                url: '$origin/page',
                method: 'GET',
                target: '',
              ),
              baseUrl: origin,
            ),
            NativeDocumentLoadResult.committed,
          );
          windows.select(window);
          document = window.currentDocument!;
          tester.view.devicePixelRatio = dpr;
          tester.view.physicalSize = Size(width * dpr, height * dpr);
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(
                reference['theme'] == 'dark'
                    ? Brightness.dark
                    : Brightness.light,
              ),
              home: Scaffold(
                body: NativeDocumentScope(
                  documentUrl: '$origin/page',
                  windows: windows,
                  window: window,
                  child: NativeFetchedDocumentView(
                    document: document,
                    gateway: gateway,
                    onLink: (_) {},
                    onSubmit: (_) {},
                  ),
                ),
              ),
            ),
          );
          for (var i = 0; i < 200 && document.scripts?.ready != true; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(document.scripts?.ready, isTrue);
          await tester.tap(find.text('Resize Canvas', findRichText: true));
          Json? result;
          for (var i = 0; i < 600; i++) {
            await tester.pump(const Duration(milliseconds: 50));
            final text =
                html
                    .parse(document.scripts?.content?.text ?? '')
                    .getElementById('probe')
                    ?.text ??
                '';
            if (text.startsWith('{')) {
              result = obj(jsonDecode(text));
              break;
            }
          }
          expect(
            result,
            isNotNull,
            reason: '${reference['mode']}: ${document.scripts?.diagnostics}',
          );
          var maxFractionalDelta = 0.0;
          void compare(dynamic actual, dynamic expected, String path) {
            final fractional = reference['mode'] == 'fractional_ratio';
            if (fractional &&
                actual is String &&
                expected is String &&
                path.contains('.style.') &&
                (path.endsWith('.width') || path.endsWith('.height'))) {
              expect(actual, endsWith('px'));
              expect(expected, endsWith('px'));
              final delta =
                  (double.parse(actual.substring(0, actual.length - 2)) -
                          double.parse(
                            expected.substring(0, expected.length - 2),
                          ))
                      .abs();
              expect(delta, lessThanOrEqualTo(.02), reason: path);
              if (delta > maxFractionalDelta) maxFractionalDelta = delta;
            } else if (fractional &&
                actual is num &&
                expected is num &&
                (path.endsWith('.childRect.width') ||
                    path.endsWith('.childRect.height'))) {
              final delta = (actual - expected).abs().toDouble();
              expect(delta, lessThanOrEqualTo(.02), reason: path);
              if (delta > maxFractionalDelta) maxFractionalDelta = delta;
            } else if (expected is Map) {
              expect(actual, isA<Map>(), reason: path);
              expect(
                (actual as Map).keys.toSet(),
                expected.keys.toSet(),
                reason: path,
              );
              for (final key in expected.keys) {
                compare(actual[key], expected[key], '$path.$key');
              }
            } else if (expected is List) {
              expect(actual, isA<List>(), reason: path);
              expect((actual as List).length, expected.length, reason: path);
              for (var i = 0; i < expected.length; i++) {
                compare(actual[i], expected[i], '$path[$i]');
              }
            } else {
              expect(actual, expected, reason: path);
            }
          }

          compare(
            result,
            reference['result'],
            '${reference['mode']} $viewport DPR $dpr ${reference['theme']}',
          );
          expect(document.scripts?.diagnostics, isEmpty);
          expect(tester.takeException(), isNull);
          accepted.add({
            'mode': reference['mode'],
            'viewport': viewport,
            'dpr': dpr,
            'theme': reference['theme'],
            'result': result,
            'maxFractionalDelta': maxFractionalDelta,
            'diagnostics': document.scripts?.diagnostics,
          });
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          windows?.dispose();
          if (document?.scripts != null) await document!.scripts!.closed;
          tester.view.reset();
          await listener.cancel();
          await server.close(force: true);
          expect(failures, isEmpty);
        }
      }
      expect(accepted, hasLength(72));
      debugPrintSynchronously(
        'PIRC_NATIVE_CANVAS_SIZING_ACCEPTANCE ${jsonEncode(accepted)}',
      );
    },
    skip: _fixtureOrigin.isEmpty,
  );
}
