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
import 'package:pirc_mobile/theme.dart';

const fixtureOrigin = String.fromEnvironment('PIRC_CHART_FIXTURE_ORIGIN');
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'text mutations retain native cascade values before layout',
    (tester) async {
      final origin = Uri.parse(fixtureOrigin);
      expect(origin.host, '127.0.0.1');
      expect(origin.scheme, 'http');
      final client = HttpClient();
      late Json fixture;
      try {
        final response = await (await client.getUrl(
          origin.resolve('/text-style.json'),
        )).close();
        expect(response.statusCode, 200);
        fixture = obj(jsonDecode(await utf8.decoder.bind(response).join()));
      } finally {
        client.close(force: true);
      }
      final gateway = Gateway(),
          theme = await PircTheme.load(),
          accepted = <Json>[];
      final cases = fixture['cases'] as List;
      expect(cases.length, 48);
      for (final raw in cases) {
        final row = obj(raw), viewport = obj(row['viewport']);
        final width = (viewport['width'] as num).toDouble(),
            height = (viewport['height'] as num).toDouble(),
            dpr = (row['dpr'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(width * dpr, height * dpr);
        final source = (row['html'] as String).replaceFirst(
          '</body>',
          '<script>${row['driverSource']}</script></body>',
        );
        final bytes = utf8.encode(source);
        final document = NativeFetchedDocument(
          id: 1,
          url: 'https://example.test/text-style',
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
          Future<Json> ready(String phase) async {
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
                if (state['phase'] == phase) return state;
              }
            }
            fail(
              '${row['mode']} $phase; ${document.scripts?.diagnostics}; ${document.scripts?.content?.text}',
            );
          }

          expect(await ready('ready'), row['initial']);
          await tester.tap(find.text('Change text', findRichText: true));
          final actual = await ready('updated'), expected = obj(row['result']);
          expect(actual['synchronous'], expected['synchronous']);
          expect(actual['settled'], expected['settled']);
          final measured = obj(actual['rect']),
              reference = obj(expected['rect']);
          for (final axis in ['x', 'y', 'width', 'height']) {
            expect(
              measured[axis],
              closeTo((reference[axis] as num).toDouble(), .01),
              reason: '${row['mode']} $axis',
            );
          }
          expect(document.scripts!.diagnostics, isEmpty);
          expect(tester.takeException(), isNull);
          accepted.add({
            'mode': row['mode'],
            'viewport': viewport,
            'dpr': dpr,
            'theme': row['theme'],
            'result': actual,
          });
          debugPrintSynchronously(
            'PIRC_TEXT_STYLE_PROGRESS ${accepted.length}/48',
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          document.dispose();
          if (document.scripts != null) await document.scripts!.closed;
          tester.view.reset();
        }
      }
      expect(accepted, hasLength(48));
      debugPrintSynchronously(
        'PIRC_NATIVE_TEXT_STYLE_ACCEPTANCE ${jsonEncode(accepted)}',
      );
    },
    skip: fixtureOrigin.isEmpty,
  );
}
