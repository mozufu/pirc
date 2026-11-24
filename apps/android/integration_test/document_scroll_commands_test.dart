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
void expectScrollRectValues(dynamic actual, dynamic expected, String path) {
  if (expected is num) {
    expect(actual, closeTo(expected.toDouble(), .001), reason: path);
  } else if (expected is List) {
    expect(actual, isA<List>(), reason: path);
    expect((actual as List).length, expected.length, reason: path);
    for (var i = 0; i < expected.length; i++) {
      expectScrollRectValues(actual[i], expected[i], '$path[$i]');
    }
  } else if (expected is Map) {
    expect(actual, isA<Map>(), reason: path);
    expect((actual as Map).keys.toSet(), expected.keys.toSet(), reason: path);
    for (final key in expected.keys) {
      expectScrollRectValues(actual[key], expected[key], '$path.$key');
    }
  } else {
    expect(actual, expected, reason: path);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native immediate and settled scroll feedback matches Chromium',
    (tester) async {
      final origin = Uri.parse(fixtureOrigin);
      expect(origin.host, '127.0.0.1');
      expect(origin.scheme, 'http');
      final client = HttpClient();
      final cases = <Json>[];
      try {
        for (final entry in {
          '/scroll-rect.json': 128,
          '/scroll-commands.json': 160,
          '/scroll-feedback.json': 96,
          '/scrolling-element.json': 88,
        }.entries) {
          final response = await (await client.getUrl(
            origin.resolve(entry.key),
          )).close();
          expect(response.statusCode, 200);
          final fixture = obj(
            jsonDecode(await utf8.decoder.bind(response).join()),
          );
          expect(fixture['browserVersion'], '153.0.8010.12');
          expect(fixture['cases'], hasLength(entry.value));
          for (final raw in fixture['cases'] as List) {
            cases.add({
              ...obj(raw),
              'fixtureHTML': obj(raw)['html'] ?? fixture['html'],
            });
          }
        }
      } finally {
        client.close(force: true);
      }
      expect(cases, hasLength(472));
      final gateway = Gateway(),
          theme = await PircTheme.load(),
          accepted = <Json>[];
      for (final raw in cases) {
        final row = obj(raw),
            viewport = obj(row['viewport']),
            dpr = (row['dpr'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize =
            Size(
              (viewport['width'] as num).toDouble(),
              (viewport['height'] as num).toDouble(),
            ) *
            dpr;
        final source = (row['fixtureHTML'] as String).replaceFirst(
              '</body>',
              '<script>${row['driverSource']}</script></body>',
            ),
            bytes = utf8.encode(source);
        final document = NativeFetchedDocument(
          id: 1,
          url: 'https://example.test/scroll-commands',
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
          for (var attempt = 0; attempt < 200; attempt++) {
            await tester.pump(const Duration(milliseconds: 30));
            if (document.scripts?.ready == true) {
              break;
            }
          }
          expect(
            document.scripts?.ready,
            isTrue,
            reason: '${document.scripts?.diagnostics}',
          );
          await tester.pump(const Duration(milliseconds: 30));
          if (row['tap'] is Map) {
            final point = obj(row['tap']);
            await tester.tapAt(
              Offset(
                (point['x'] as num).toDouble(),
                (point['y'] as num).toDouble(),
              ),
            );
          } else {
            await tester.tap(find.text('Run', findRichText: true));
          }
          Json report = {};
          for (var attempt = 0; attempt < 250; attempt++) {
            await tester.pump(const Duration(milliseconds: 30));
            final text =
                html
                    .parse(document.scripts?.content?.text ?? '')
                    .getElementById('probe')
                    ?.text ??
                '';
            if (text.startsWith('{')) {
              report = obj(jsonDecode(text));
              break;
            }
          }
          expect(
            report,
            isNotEmpty,
            reason:
                '${row['mode']} ${row['target']} ${document.scripts?.diagnostics}',
          );
          if (row['target'] == 'scrollRect') {
            expectScrollRectValues(
              report,
              row['result'],
              '${row['mode']} ${row['viewport']} ${row['dpr']} ${row['theme']}',
            );
          } else {
            expect(
              report,
              equals(row['result']),
              reason:
                  '${row['mode']} ${row['target']} ${row['viewport']} ${row['dpr']} ${row['theme']}',
            );
          }
          expect(document.scripts!.diagnostics, isEmpty);
          expect(tester.takeException(), isNull);
          accepted.add({
            'mode': row['mode'],
            'target': row['target'],
            'viewport': viewport,
            'dpr': dpr,
            'theme': row['theme'],
            'report': report,
          });
          if (accepted.length % 32 == 0) {
            debugPrintSynchronously(
              'PIRC_SCROLL_FEEDBACK_PROGRESS ${accepted.length}/472',
            );
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          document.dispose();
          if (document.scripts != null) {
            await document.scripts!.closed;
          }
          tester.view.reset();
        }
      }
      expect(accepted, hasLength(472));
      debugPrintSynchronously(
        'PIRC_NATIVE_SCROLL_FEEDBACK_ACCEPTANCE ${jsonEncode(accepted)}',
      );
    },
    skip: fixtureOrigin.isEmpty,
  );
}
