import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_mobile/theme.dart';

const fixtureOrigin = String.fromEnvironment('PIRC_CHART_FIXTURE_ORIGIN');
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native pointer policy preserves script activation and bubbling',
    (tester) async {
      final uri = Uri.parse(fixtureOrigin);
      expect(uri.host, '127.0.0.1');
      expect(uri.scheme, 'http');
      final client = HttpClient();
      late Json fixture;
      try {
        final response = await (await client.getUrl(
          uri.resolve('/pointer-events.json'),
        )).close();
        expect(response.statusCode, 200);
        fixture = obj(jsonDecode(await utf8.decoder.bind(response).join()));
      } finally {
        client.close(force: true);
      }
      final gateway = Gateway(), theme = await PircTheme.load();
      final accepted = <Json>[];
      final cases = (fixture['cases'] as List).where(
        (r) => const {
          'none',
          'restore_block',
          'restore_inline',
          'inline_none',
          'clipped_restore',
          'overflow_restore',
          'button_restore',
          'canvas_none',
          'canvas_restore',
          'dynamic',
          'programmatic',
        }.contains(r['name']),
      );
      expect(cases.length, 88);
      for (final raw in cases) {
        final row = obj(raw), viewport = obj(row['viewport']);
        final width = (viewport['width'] as num).toDouble(),
            height = (viewport['height'] as num).toDouble(),
            dpr = (row['dpr'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(width * dpr, height * dpr);
        final source = (row['html'] as String).replaceFirst(
          '</body>',
          '<script>${fixture['driverSource']}</script></body>',
        );
        final bytes = utf8.encode(source);
        final document = NativeFetchedDocument(
          id: 1,
          url: 'https://example.test/pointer-events',
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
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(
                row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
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
          Future<Json> ready(Json expected) async {
            for (var i = 0; i < 200; i++) {
              await tester.pump(const Duration(milliseconds: 30));
              final text =
                  html
                      .parse(document.scripts?.content?.text ?? '')
                      .getElementById('probe')
                      ?.text ??
                  '';
              if (text.startsWith('{')) {
                final state = obj(jsonDecode(text));
                if (state['phase'] == expected['phase'] &&
                    (state['trace'] as List).length >=
                        (expected['trace'] as List).length) {
                  expect(
                    state,
                    expected,
                    reason: '${row['name']} script state',
                  );
                  return state;
                }
              }
            }
            fail(
              '${row['name']} expected $expected; content ${document.scripts?.content?.text}; diagnostics ${document.scripts?.diagnostics}',
            );
          }

          await ready(obj(row['initial']));
          if (row['name'] == 'button_restore') {
            final origin = tester.getTopLeft(find.byType(NativeHtmlDocument));
            final button = find.byWidgetPredicate(
              (w) => w is NativeHtmlButtonWidget && w.button.label == 'Tap',
            );
            expect(
              tester.getRect(button),
              Rect.fromLTWH(origin.dx + 20, origin.dy + 20, 90, 40),
            );
          }
          for (final rawStep in row['steps'] as List) {
            final step = obj(rawStep);
            if (step['action'] == 'tap') {
              final point = obj(step['point']);
              await tester.tapAt(
                tester.getTopLeft(find.byType(NativeHtmlDocument)) +
                    Offset(
                      (point['x'] as num).toDouble(),
                      (point['y'] as num).toDouble(),
                    ),
              );
            } else {
              await tester.tap(
                find.text(
                  step['action'] == 'toggle'
                      ? 'Toggle policy'
                      : 'Programmatic click',
                  findRichText: true,
                ),
              );
            }
            await ready(obj(step['state']));
          }
          expect(document.scripts!.diagnostics, isEmpty);
          expect(tester.takeException(), isNull);
          accepted.add({
            'name': row['name'],
            'viewport': viewport,
            'dpr': dpr,
            'theme': row['theme'],
            'steps': (row['steps'] as List).length,
          });
          debugPrintSynchronously(
            'PIRC_POINTER_PROGRESS ${accepted.length}/88',
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          document.dispose();
          if (document.scripts != null) await document.scripts!.closed;
          tester.view.reset();
        }
      }
      expect(accepted, hasLength(88));
      debugPrintSynchronously(
        'PIRC_NATIVE_POINTER_ACCEPTANCE ${jsonEncode(accepted)}',
      );
    },
    skip: fixtureOrigin.isEmpty,
  );
}
