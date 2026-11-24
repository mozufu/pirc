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
    'native fixed documents retain viewport position and input through scrolling',
    (tester) async {
      final origin = Uri.parse(fixtureOrigin);
      expect(origin.host, '127.0.0.1');
      expect(origin.scheme, 'http');
      final client = HttpClient();
      late Json fixture;
      try {
        final response = await (await client.getUrl(
          origin.resolve('/fixed.json'),
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
      expect(cases.length, 120);
      for (final raw in cases) {
        final row = obj(raw), dpr = (row['dpr'] as num).toDouble();
        final initialViewport = obj(row['viewport']);
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize =
            Size(
              (initialViewport['width'] as num).toDouble(),
              (initialViewport['height'] as num).toDouble(),
            ) *
            dpr;
        final source = (row['html'] as String).replaceFirst(
          '</body>',
          '<script>${row['driverSource']}</script></body>',
        );
        final bytes = utf8.encode(source);
        final document = NativeFetchedDocument(
          id: 1,
          url: 'https://example.test/fixed',
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
        final clicks = <String>[];
        var maxDelta = 0.0, rawMaxViewportDelta = 0.0;
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
            Json last = {};
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
                last = state;
                if (state['phase'] == expected['phase'] &&
                    state['scrollY'] == expected['scrollY'] &&
                    state['hostScrollTop'] == expected['hostScrollTop'] &&
                    state['viewport'].toString() ==
                        expected['viewport'].toString() &&
                    (state['clicks'] as List).length >= clicks.length) {
                  expect(
                    state['clicks'],
                    clicks,
                    reason: '${row['mode']} duplicate/target',
                  );
                  return state;
                }
              }
            }
            fail(
              '${row['mode']} expected $expected clicks $clicks; got $last; ${document.scripts?.diagnostics}',
            );
          }

          final states = row['states'] as List;
          for (var i = 0; i < states.length; i++) {
            final step = obj(states[i]), expected = obj(step['state']);
            if (i > 0) {
              final previous = obj(states[i - 1]);
              if (obj(previous['state'])['phase'] == expected['phase']) {
                final v = obj(step['viewport']);
                tester.view.physicalSize =
                    Size(
                      (v['width'] as num).toDouble(),
                      (v['height'] as num).toDouble(),
                    ) *
                    dpr;
              } else {
                await tester.tap(find.text('Advance', findRichText: true));
              }
            }
            final actual = await ready(expected);
            expect(
              actual['scrollHeight'],
              closeTo((expected['scrollHeight'] as num).toDouble(), .01),
            );
            for (final entry in obj(expected['boxes']).entries) {
              final box = obj(obj(actual['boxes'])[entry.key]),
                  reference = obj(entry.value);
              for (final axis in ['x', 'y', 'width', 'height']) {
                final rawDelta = ((box[axis] as num) - (reference[axis] as num))
                    .abs()
                    .toDouble();
                if (rawDelta > rawMaxViewportDelta) {
                  rawMaxViewportDelta = rawDelta;
                }
                final referenceValue = reference[axis] as num;
                final delta = ((box[axis] as num) - referenceValue)
                    .abs()
                    .toDouble();
                if (delta > maxDelta) maxDelta = delta;
                expect(
                  delta,
                  lessThanOrEqualTo(row['mode'] == 'percent' ? 1 / 32 : .01),
                  reason:
                      '${row['mode']} phase${expected['phase']} ${entry.key}.$axis',
                );
              }
            }
            final point = obj(step['point']);
            final documentOrigin = tester.getTopLeft(
              find.byType(NativeFetchedDocumentView),
            );
            await tester.tapAt(
              documentOrigin +
                  Offset(
                    (point['x'] as num).toDouble(),
                    (point['y'] as num).toDouble(),
                  ),
            );
            clicks.add(step['target'] as String);
            await ready(expected);
          }
          expect(document.scripts!.diagnostics, isEmpty);
          expect(tester.takeException(), isNull);
          accepted.add({
            'mode': row['mode'],
            'viewport': row['viewport'],
            'dpr': dpr,
            'theme': row['theme'],
            'maxGeometryDelta': maxDelta,
            'rawMaxViewportDelta': rawMaxViewportDelta,
            'clicks': clicks,
          });
          debugPrintSynchronously('PIRC_FIXED_PROGRESS ${accepted.length}/120');
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          document.dispose();
          if (document.scripts != null) await document.scripts!.closed;
          tester.view.reset();
        }
      }
      expect(accepted, hasLength(120));
      debugPrintSynchronously(
        'PIRC_NATIVE_FIXED_ACCEPTANCE ${jsonEncode(accepted)}',
      );
    },
    skip: fixtureOrigin.isEmpty,
  );
}
