import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:pirc_render_document/src/document_canvas.dart';
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

import 'document_chart_types_test.dart' show verifyPaint, captureCanvasLayer;

const _fixtureOrigin = String.fromEnvironment('PIRC_CHART_FIXTURE_ORIGIN');
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native default Chart.js animations render moving frames and complete',
    (tester) async {
      final fixtureOrigin = Uri.parse(_fixtureOrigin);
      expect(fixtureOrigin.scheme, 'http');
      expect(fixtureOrigin.host, '127.0.0.1');
      final client = HttpClient();
      late Json fixture;
      try {
        final request = await client.getUrl(
          fixtureOrigin.resolve('/chart-animation.json'),
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        fixture = obj(jsonDecode(await utf8.decoder.bind(response).join()));
      } finally {
        client.close(force: true);
      }
      final libraryClient = HttpClient();
      late String chartSource;
      try {
        final request = await libraryClient.getUrl(
          fixtureOrigin.resolve('/chart.js'),
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        chartSource = await utf8.decoder.bind(response).join();
      } finally {
        libraryClient.close(force: true);
      }
      final profiles = <String>{};
      for (final raw in fixture['cases'] as List) {
        final row = obj(raw);
        profiles.add(
          '${row['type']}_${obj(row['viewport'])['width']}_${row['dpr']}_${row['theme']}',
        );
        expect((row['steps'] as List).map((s) => s['name']).toList(), [
          'initial',
          'touchFirst',
          'touchSecond',
          'outside',
          'legendHide',
          'legendShow',
          'updated',
          'resized',
        ]);
      }
      expect(profiles, {
        for (final type in [
          'bar',
          'line',
          'pie',
          'doughnut',
          'scatter',
          'bubble',
          'radar',
          'polarArea',
        ])
          for (final width in [390, 768])
            for (final dpr in [1, 3])
              for (final theme in ['light', 'dark'])
                '${type}_${width}_${dpr}_$theme',
      });
      final gateway = Gateway();
      final theme = await PircTheme.load();
      final accepted = <Json>[];
      // Exercise newly exposed radial cases first for fast failure feedback;
      // the complete eight-type/profile set above remains mandatory.
      final orderedCases = [
        for (final type in [
          'radar',
          'polarArea',
          'bar',
          'line',
          'pie',
          'doughnut',
          'scatter',
          'bubble',
        ])
          ...(fixture['cases'] as List).where((row) => row['type'] == type),
      ];
      for (final raw in orderedCases) {
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
            } else if (request.uri.path == '/chart.js') {
              request.response.headers.contentType = ContentType(
                'text',
                'javascript',
                charset: 'utf-8',
              );
              request.response.write(chartSource);
            } else if (request.uri.path == '/chart-types-driver.js') {
              request.response.headers.contentType = ContentType(
                'text',
                'javascript',
                charset: 'utf-8',
              );
              request.response.write(fixture['driverSource']);
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
          final observedMotion = <String, List<Json>>{};
          Future<Json> ready({
            int after = -1,
            String? phase,
            required String stage,
          }) async {
            final motion = observedMotion.putIfAbsent(stage, () => []);
            var lastIndex = -1, lastStep = -1000.0;
            for (var i = 0; i < 600; i++) {
              await tester.pump(const Duration(milliseconds: 50));
              final page = html.parse(document!.scripts?.content?.text ?? '');
              final liveText = page.getElementById('live')?.text ?? '';
              if (liveText.startsWith('{') && motion.length < 2) {
                final live = obj(jsonDecode(liveText));
                final step = (live['step'] as num).toDouble(),
                    total = (live['total'] as num).toDouble();
                final index = live['index'] as int;
                if (index != lastIndex &&
                    total > 0 &&
                    step > 0 &&
                    step < total &&
                    step - lastStep >= 150) {
                  lastIndex = index;
                  lastStep = step;
                  motion.add({...live, ...await renderedFrame(tester)});
                }
              }
              final text = page.getElementById('probe')?.text ?? '';
              if (!text.startsWith('{')) continue;
              final result = obj(jsonDecode(text));
              expect(
                result['error'],
                isNull,
                reason:
                    '${reference['caseId']}: $result ${document.scripts?.diagnostics}',
              );
              if ((result['serial'] as num) > after &&
                  (phase == null || result['phase'] == phase)) {
                return result;
              }
            }
            fail(
              '${reference['caseId']} timed out: ${document!.scripts?.diagnostics}',
            );
          }

          var current = await ready(stage: 'initial');
          final reports = <Json>[];
          var maxGeometryDelta = 0.0;
          var maxAngleDelta = 0.0;
          final fontGeometryDeltas = <Json>[];
          for (final rawStep in reference['steps'] as List) {
            final step = obj(rawStep), name = step['name'] as String;
            final serial = current['serial'] as int;
            final origin = tester.getTopLeft(find.byType(NativeDocumentCanvas));
            if (name == 'touchFirst' || name == 'touchSecond') {
              final item = obj(
                (current['items'] as List)[name == 'touchFirst' ? 0 : 1],
              );
              final center = obj(item['center']);
              await tester.tapAt(
                origin +
                    Offset(
                      (center['x'] as num).toDouble(),
                      (center['y'] as num).toDouble(),
                    ),
              );
            } else if (name == 'outside') {
              await tester.tapAt(Offset(width - 5, origin.dy + 120));
            } else if (name == 'legendHide' || name == 'legendShow') {
              final box = obj((current['legend'] as List).first);
              await tester.tapAt(
                origin +
                    Offset(
                      (box['left'] as num) + (box['width'] as num) / 2,
                      (box['top'] as num) + (box['height'] as num) / 2,
                    ),
              );
            } else if (name == 'updated' || name == 'resized') {
              await tester.tap(
                find.text(
                  name == 'updated' ? 'Update data' : 'Resize container',
                  findRichText: true,
                ),
              );
            }
            if (name != 'initial') {
              current = await ready(
                stage: name,
                after: serial,
                phase: name == 'updated' || name == 'resized' ? name : null,
              );
            }
            void compare(dynamic actual, dynamic expected, String path) {
              if (actual is Map && expected is Map) {
                expect(
                  actual.keys.toSet(),
                  expected.keys.toSet(),
                  reason: path,
                );
                for (final key in expected.keys) {
                  compare(actual[key], expected[key], '$path.$key');
                }
              } else if (actual is List && expected is List) {
                expect(actual.length, expected.length, reason: path);
                for (var i = 0; i < expected.length; i++) {
                  compare(actual[i], expected[i], '$path[$i]');
                }
              } else if (actual is num &&
                  expected is num &&
                  (path.contains('.geometry.') ||
                      path.contains('.center.') ||
                      path.contains('.area.') ||
                      path.contains('.bounds.') ||
                      path.contains('.legend[') ||
                      path.contains('.paintPoints[') ||
                      path.contains('.strokePoints[')) &&
                  const {
                    'x',
                    'y',
                    'base',
                    'width',
                    'height',
                    'left',
                    'top',
                    'right',
                    'bottom',
                    'innerRadius',
                    'outerRadius',
                  }.contains(path.split('.').last)) {
                final delta = (actual - expected).abs().toDouble();
                if (delta > maxGeometryDelta) maxGeometryDelta = delta;
                if (delta > .1) {
                  fontGeometryDeltas.add({
                    'path': path,
                    'native': actual,
                    'browser': expected,
                    'delta': delta,
                  });
                }
                // Match the existing stock-font bar gate: Android and desktop
                // Helvetica/Arial aliases differ. Record pixel differences;
                // keep angles, values, visibility, hits and paints independent.
                expect(delta, lessThanOrEqualTo(2), reason: path);
              } else if (actual is num &&
                  expected is num &&
                  path.contains('.geometry.') &&
                  const {
                    'startAngle',
                    'endAngle',
                    'circumference',
                  }.contains(path.split('.').last)) {
                final delta = (actual - expected).abs().toDouble();
                if (delta > maxAngleDelta) maxAngleDelta = delta;
                expect(delta, lessThanOrEqualTo(1e-12), reason: path);
              } else {
                expect(actual, expected, reason: path);
              }
            }

            final expectedState = obj(step['state']);
            final actualState = Map<String, dynamic>.of(current)
              ..remove('animation')
              ..remove('serial');
            final stableExpected = Map<String, dynamic>.of(expectedState)
              ..remove('animation')
              ..remove('serial');
            compare(
              actualState,
              stableExpected,
              '${reference['caseId']} $name',
            );
            final animation = obj(current['animation']),
                expectedAnimation = obj(expectedState['animation']);
            expect(animation['duration'], 1000);
            expect(animation['easing'], 'easeOutQuart');
            expect(
              animation['completeCount'],
              expectedAnimation['completeCount'],
              reason: '${reference['caseId']} $name completion callbacks',
            );
            final motion = observedMotion[name] ?? <Json>[];
            if ((expectedAnimation['progressCount'] as num) > 1) {
              expect(animation['progressCount'], greaterThan(1));
              expect(animation['completeCount'], greaterThan(0));
              expect(
                motion,
                isNotEmpty,
                reason:
                    '${reference['caseId']} $name must render an intermediate frame',
              );
              final finalFrame = await renderedFrame(tester);
              final hashes = {
                for (final item in motion) item['paintHash'],
                finalFrame['paintHash'],
              };
              expect(
                hashes.length,
                greaterThan(1),
                reason: '${reference['caseId']} $name must change native paint',
              );
            }
            if (name == 'initial' || name == 'updated') {
              expect(animation['monotone'], isTrue);
              // The first point can equal the reset baseline (line/scatter/
              // radar). Match that browser fact; full native paint must move.
              if ((expectedAnimation['distinctPoses'] as num) > 1) {
                expect(animation['distinctPoses'], greaterThan(1));
              } else {
                expect(animation['distinctPoses'], 1);
              }
              expect(animation['elapsed'], inInclusiveRange(900, 5000));
              final samples = animation['samples'] as List;
              expect(samples, isNotEmpty);
              expect(samples.last['step'], samples.last['total']);
            }
            final pixels = await verifyPaint(tester, current, step);
            expect(
              document.scripts?.diagnostics,
              isEmpty,
              reason: '${reference['caseId']} $name',
            );
            expect(tester.takeException(), isNull);
            reports.add({
              'name': name,
              'state': current,
              'pixels': pixels,
              'motion': motion,
            });
          }
          accepted.add({
            'caseId': reference['caseId'],
            'type': reference['type'],
            'maxGeometryDelta': maxGeometryDelta,
            'maxAngleDelta': maxAngleDelta,
            'fontGeometryDeltas': fontGeometryDeltas,
            'steps': reports,
            'diagnostics': document.scripts?.diagnostics,
          });
          debugPrintSynchronously(
            'PIRC_CHART_ANIMATION_PROGRESS ${accepted.length}/64 ${reference['caseId']}',
          );
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
      expect(accepted, hasLength(64));
      debugPrintSynchronously(
        'PIRC_NATIVE_CHART_ANIMATION_ACCEPTANCE ${jsonEncode(accepted)}',
      );
    },
    skip: _fixtureOrigin.isEmpty,
  );
}

Future<Json> renderedFrame(WidgetTester tester) async {
  final snapshot = tester
      .widget<NativeDocumentCanvas>(find.byType(NativeDocumentCanvas))
      .snapshot;
  expect(snapshot.commands, isNotEmpty);
  final image = await captureCanvasLayer(tester);
  try {
    final data = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    final words = data.buffer.asUint32List(
      data.offsetInBytes,
      data.lengthInBytes ~/ 4,
    );
    var hash = 2166136261;
    for (var i = 0; i < words.length; i += 16) {
      hash = ((hash ^ words[i]) * 16777619) & 0xffffffff;
    }
    return {
      'paintHash': hash,
      'revision': snapshot.revision,
      'commands': snapshot.commands.length,
    };
  } finally {
    image.dispose();
  }
}
