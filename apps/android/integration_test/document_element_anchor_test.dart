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
    'element anchoring matches Chromium through native script and control frames',
    (tester) async {
      final origin = Uri.parse(fixtureOrigin);
      expect(origin.host, '127.0.0.1');
      expect(origin.scheme, 'http');
      bool near(Object? a, Object? b) =>
          a is num && b is num && (a - b).abs() <= .01;
      bool scrollMatches(Json actual, Json expected) {
        final values = obj(actual['scroll']);
        return obj(expected['scroll']).entries.every(
          (entry) =>
              near(obj(values[entry.key])['top'], obj(entry.value)['top']),
        );
      }

      final client = HttpClient();
      late Json fixture;
      try {
        final response = await (await client.getUrl(
          origin.resolve('/element-anchor.json'),
        )).close();
        expect(response.statusCode, 200);
        fixture = obj(jsonDecode(await utf8.decoder.bind(response).join()));
      } finally {
        client.close(force: true);
      }
      final gateway = Gateway(),
          theme = await PircTheme.load(),
          accepted = <Json>[];
      expect(fixture['browserVersion'], '153.0.8010.12');
      expect(fixture['cases'], hasLength(168));
      for (final raw in fixture['cases'] as List) {
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
        final bytes = utf8.encode(
          (row['html'] as String).replaceFirst(
            '</body>',
            '<script>${row['driverSource']}</script></body>',
          ),
        );
        final document = NativeFetchedDocument(
          id: 1,
          url: 'https://example.test/element-anchor',
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
        var maxDelta = 0.0;
        final offsets = <num>[];
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
          final states = row['states'] as List;
          for (var index = 0; index < states.length; index++) {
            final expected = obj(obj(states[index])['state']);
            if (index > 0) {
              await tester.tap(find.text('Advance', findRichText: true));
            }
            Json actual = {};
            for (var attempt = 0; attempt < 200; attempt++) {
              await tester.pump(const Duration(milliseconds: 30));
              final source =
                  html
                      .parse(document.scripts?.content?.text ?? '')
                      .getElementById('probe')
                      ?.text ??
                  '';
              if (source.startsWith('{')) actual = obj(jsonDecode(source));
              if (actual['phase'] == expected['phase'] &&
                  near(actual['scrollY'], expected['scrollY']) &&
                  scrollMatches(actual, expected) &&
                  document.scripts?.ready == true) {
                break;
              }
            }
            expect(
              actual['phase'],
              expected['phase'],
              reason: '${row['mode']} ${document.scripts?.diagnostics}',
            );
            expect(
              actual['scrollY'],
              closeTo((expected['scrollY'] as num).toDouble(), .01),
              reason: '${row['mode']} phase$index ${viewport['width']}',
            );
            expect(
              document.scroll.offset,
              closeTo((expected['scrollY'] as num).toDouble(), .01),
            );
            expect(
              actual['scrollHeight'],
              closeTo((expected['scrollHeight'] as num).toDouble(), .01),
            );
            offsets.add(actual['scrollY'] as num);
            expect(
              obj(actual['scroll']).keys.toSet(),
              obj(expected['scroll']).keys.toSet(),
            );
            for (final entry in obj(expected['scroll']).entries) {
              final values = obj(obj(actual['scroll'])[entry.key]),
                  reference = obj(entry.value);
              for (final key in [
                'top',
                'left',
                'width',
                'height',
                'clientWidth',
                'clientHeight',
              ]) {
                expect(
                  values[key],
                  closeTo((reference[key] as num).toDouble(), .01),
                  reason: '${row['mode']} phase$index ${entry.key}.$key',
                );
              }
              expect(values['generation'], reference['generation']);
            }

            expect(
              obj(actual['boxes']).keys.toSet(),
              obj(expected['boxes']).keys.toSet(),
            );
            for (final entry in obj(expected['boxes']).entries) {
              final box = obj(obj(actual['boxes'])[entry.key]),
                  reference = obj(entry.value);
              for (final axis in ['x', 'y', 'width', 'height']) {
                final delta = ((box[axis] as num) - (reference[axis] as num))
                    .abs()
                    .toDouble();
                if (delta > maxDelta) maxDelta = delta;
                expect(
                  delta,
                  lessThanOrEqualTo(.01),
                  reason: '${row['mode']} phase$index ${entry.key}.$axis',
                );
              }
            }
            expect(document.scripts!.diagnostics, isEmpty);
          }
          expect(tester.takeException(), isNull);
          accepted.add({
            'mode': row['mode'],
            'viewport': viewport,
            'dpr': dpr,
            'theme': row['theme'],
            'maxGeometryDelta': maxDelta,
            'scrollY': offsets,
          });
          if (accepted.length % 8 == 0) {
            debugPrintSynchronously(
              'PIRC_ELEMENT_ANCHOR_PROGRESS ${accepted.length}/168',
            );
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          document.dispose();
          if (document.scripts != null) await document.scripts!.closed;
          tester.view.reset();
        }
      }
      expect(accepted, hasLength(168));
      debugPrintSynchronously(
        'PIRC_NATIVE_ELEMENT_ANCHOR_ACCEPTANCE ${jsonEncode(accepted)}',
      );
    },
    skip: fixtureOrigin.isEmpty,
  );
}
