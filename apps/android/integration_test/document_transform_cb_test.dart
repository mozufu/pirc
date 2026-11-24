import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
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
void expectTransformCBValues(dynamic actual, dynamic expected, String path) {
  if (expected is num) {
    expect(actual, closeTo(expected.toDouble(), 1 / 32), reason: path);
  } else if (expected is List) {
    expect(actual, isA<List>(), reason: path);
    expect((actual as List).length, expected.length, reason: path);
    for (var i = 0; i < expected.length; i++) {
      expectTransformCBValues(actual[i], expected[i], '$path[$i]');
    }
  } else if (expected is Map) {
    expect(actual, isA<Map>(), reason: path);
    expect((actual as Map).keys.toSet(), expected.keys.toSet(), reason: path);
    for (final key in expected.keys) {
      expectTransformCBValues(actual[key], expected[key], '$path.$key');
    }
  } else {
    expect(actual, expected, reason: path);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native transformed containing blocks match Chromium geometry paint and clicks',
    (tester) async {
      final origin = Uri.parse(fixtureOrigin);
      expect(origin.host, '127.0.0.1');
      expect(origin.scheme, 'http');
      final client = HttpClient();
      final cases = <Json>[];
      try {
        for (final entry in {'/transform-cb.json': 136}.entries) {
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
      expect(cases, hasLength(136));
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
        final source = (row['html'] as String).replaceFirst(
              '</body>',
              '<script>${row['driverSource']}</script></body>',
            ),
            bytes = utf8.encode(source);
        final document = NativeFetchedDocument(
          id: 1,
          url: 'https://example.test/transform-cb',
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
        final paintKey = GlobalKey();
        final painted = <String, dynamic>{};
        Future<void> checkPaint(String phase) async {
          final sample = obj(obj(row['pixels'])[phase]);
          final boundary =
              paintKey.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: dpr);
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawStraightRgba,
            ))!.buffer.asUint8List();
            final offset =
                (((sample['y'] as num) * dpr).floor() * image.width +
                    ((sample['x'] as num) * dpr).floor()) *
                4;
            final rgba = bytes.sublist(offset, offset + 4);
            if (row['mode'] == 'opacity') {
              final browser = sample['rgba'] as List;
              expect(rgba[3], browser[3], reason: '$phase alpha');
              for (var channel = 0; channel < 3; channel++) {
                expect(
                  (rgba[channel] - (browser[channel] as num)).abs(),
                  lessThanOrEqualTo(1),
                  reason: '$phase opacity channel $channel',
                );
              }
            } else {
              expect(
                rgba,
                sample['rgba'],
                reason: '$phase native paint ${row['mode']}',
              );
            }
            painted[phase] = rgba;
          } finally {
            image.dispose();
          }
        }

        try {
          await tester.pumpWidget(
            RepaintBoundary(
              key: paintKey,
              child: MaterialApp(
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
          await checkPaint('before');
          if (row['tap'] is Map) {
            final point = obj(row['tap']);
            await tester.tapAt(
              Offset(
                (point['x'] as num).toDouble(),
                (point['y'] as num).toDouble(),
              ),
            );
          }
          await tester.pump(const Duration(milliseconds: 30));
          await tester.tap(find.text('Run', findRichText: true));
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
          expectTransformCBValues(
            report,
            row['result'],
            '${row['mode']} ${row['viewport']} ${row['dpr']} ${row['theme']}',
          );
          await checkPaint('changed');
          expect(document.scripts!.diagnostics, isEmpty);
          expect(tester.takeException(), isNull);
          accepted.add({
            'mode': row['mode'],
            'viewport': viewport,
            'dpr': dpr,
            'theme': row['theme'],
            'report': report,
            'paint': painted,
          });
          if (accepted.length % 32 == 0) {
            debugPrintSynchronously(
              'PIRC_TRANSFORM_CB_PROGRESS ${accepted.length}/136',
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
      expect(accepted, hasLength(136));
      debugPrintSynchronously(
        'PIRC_NATIVE_TRANSFORM_CB_ACCEPTANCE ${jsonEncode(accepted)}',
      );
    },
    skip: fixtureOrigin.isEmpty,
  );
}
