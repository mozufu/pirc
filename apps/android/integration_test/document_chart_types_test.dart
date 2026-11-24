import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:pirc_render_document/src/document_canvas.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
    'native stock Chart.js types match browser paint and interactions',
    (tester) async {
      final fixtureOrigin = Uri.parse(_fixtureOrigin);
      expect(fixtureOrigin.scheme, 'http');
      expect(fixtureOrigin.host, '127.0.0.1');
      final client = HttpClient();
      late Json fixture;
      try {
        final request = await client.getUrl(
          fixtureOrigin.resolve('/chart-types.json'),
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
          Future<Json> ready({int after = -1, String? phase}) async {
            for (var i = 0; i < 400; i++) {
              await tester.pump(const Duration(milliseconds: 50));
              final text =
                  html
                      .parse(document!.scripts?.content?.text ?? '')
                      .getElementById('probe')
                      ?.text ??
                  '';
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

          var current = await ready();
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

            compare(current, step['state'], '${reference['caseId']} $name');
            final pixels = await verifyPaint(tester, current, step);
            expect(
              document.scripts?.diagnostics,
              isEmpty,
              reason: '${reference['caseId']} $name',
            );
            expect(tester.takeException(), isNull);
            reports.add({'name': name, 'state': current, 'pixels': pixels});
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
            'PIRC_CHART_TYPES_PROGRESS ${accepted.length}/64 ${reference['caseId']}',
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
        'PIRC_NATIVE_CHART_TYPES_ACCEPTANCE ${jsonEncode(accepted)}',
      );
    },
    skip: _fixtureOrigin.isEmpty,
  );
}

Future<List<Json>> verifyPaint(
  WidgetTester tester,
  Json state,
  Json expected,
) async {
  final widget = tester.widget<NativeDocumentCanvas>(
    find.byType(NativeDocumentCanvas),
  );
  final snapshot = widget.snapshot;
  expect(snapshot.width, obj(state['canvas'])['width']);
  expect(snapshot.height, obj(state['canvas'])['height']);
  expect(snapshot.commands, isNotEmpty);
  final tooltip = obj(state['tooltip']);
  if ((tooltip['opacity'] as num) > 0) {
    final text = [
      ...(tooltip['title'] as List),
      for (final raw in tooltip['body'] as List) ...(obj(raw)['lines'] as List),
    ];
    for (final line in text) {
      expect(
        snapshot.commands.any(
          (command) => command.op == 'fillText' && command.args.first == line,
        ),
        isTrue,
        reason: 'Native tooltip must paint $line',
      );
    }
  }
  final image = await captureCanvasLayer(tester);
  try {
    final data = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
    ))!;
    final bytes = data.buffer.asUint8List();
    final results = <Json>[];
    for (final raw in expected['pixels'] as List) {
      final point = obj(raw);
      final native = obj(
        (state['paintPoints'] as List).singleWhere(
          (p) => p['name'] == point['name'],
        ),
      );
      final dpr = obj(state['chart'])['dpr'] as num;
      final x = ((native['x'] as num) * dpr).floor(),
          y = ((native['y'] as num) * dpr).floor();
      expect(x, inInclusiveRange(0, snapshot.width.toInt() - 1));
      expect(y, inInclusiveRange(0, snapshot.height.toInt() - 1));
      final offset = (y * snapshot.width.toInt() + x) * 4;
      final rgba = bytes.sublist(offset, offset + 4).toList();
      final expectedRgba = (point['rgba'] as List).cast<num>();
      final delta = List.generate(
        4,
        (i) => (rgba[i] - expectedRgba[i]).abs().toInt(),
      ).reduce((a, b) => a > b ? a : b);
      final neutralRadarGrid =
          state['type'] == 'radar' &&
          expected['name'] == 'legendHide' &&
          point['name'] == 'initial-first';
      final expectedTooltip = obj(obj(expected['state'])['tooltip']);
      final tooltipBounds = obj(expectedTooltip['bounds']);
      final compositedInterior =
          (expectedTooltip['opacity'] as num) > 0 &&
          (point['x'] as num) >= (tooltipBounds['x'] as num) + 8 &&
          (point['x'] as num) <=
              (tooltipBounds['x'] as num) +
                  (tooltipBounds['width'] as num) -
                  8 &&
          (point['y'] as num) >= (tooltipBounds['y'] as num) + 8 &&
          (point['y'] as num) <=
              (tooltipBounds['y'] as num) +
                  (tooltipBounds['height'] as num) -
                  8;
      if (neutralRadarGrid) {
        // The retained point now crosses a neutral tick/grid backdrop. Desktop
        // and Android rasterization differs by 4/255 at DPR 1, 10/255 at
        // DPR 3. Bound this one edge in proportion to device-pixel density.
        expect(rgba[0], rgba[1]);
        expect(rgba[1], rgba[2]);
        expect(expectedRgba[0], expectedRgba[1]);
        expect(expectedRgba[1], expectedRgba[2]);
        expect(
          delta,
          lessThanOrEqualTo(8 * dpr),
          reason:
              'Neutral radar edge DPR $dpr native=$rgba browser=$expectedRgba',
        );
      } else if (compositedInterior) {
        // Source-over tooltip/data mixing differs by one 8-bit rounding unit.
        expect(
          delta,
          lessThanOrEqualTo(1),
          reason:
              'Tooltip compositing rounding: ${state['type']} ${expected['name']} ${point['name']}',
        );
      } else {
        expect(
          rgba,
          expectedRgba,
          reason:
              '${state['type']} ${expected['name']} ${point['name']} native=$x,$y',
        );
      }
      results.add({
        'name': point['name'],
        'x': x,
        'y': y,
        'rgba': rgba,
        'browserRgba': expectedRgba,
        'maxChannelDelta': delta,
        'deferredNeutralGrid': neutralRadarGrid,
        'compositedInterior': compositedInterior,
      });
    }
    for (final raw in expected['strokes'] as List) {
      final stroke = obj(raw);
      final native = obj(
        (state['strokePoints'] as List).singleWhere(
          (p) => p['name'] == stroke['name'],
        ),
      );
      final dpr = obj(state['chart'])['dpr'] as num;
      final x = ((native['x'] as num) * dpr).floor(),
          y = ((native['y'] as num) * dpr).floor();
      var found = false;
      for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          final px = x + dx, py = y + dy;
          if (px < 0 ||
              py < 0 ||
              px >= snapshot.width ||
              py >= snapshot.height) {
            continue;
          }
          final offset = (py * snapshot.width.toInt() + px) * 4;
          if ((bytes[offset] - 37).abs() <= 2 &&
              (bytes[offset + 1] - 99).abs() <= 2 &&
              (bytes[offset + 2] - 235).abs() <= 2 &&
              bytes[offset + 3] > 100) {
            found = true;
          }
        }
      }
      expect(
        found,
        stroke['present'],
        reason: 'Line must connect points: ${expected['name']}',
      );
      results.add({'kind': 'stroke', 'name': stroke['name'], 'present': found});
    }
    return results;
  } finally {
    image.dispose();
  }
}

/// Captures the widget's already painted layer at its real backing density.
Future<ui.Image> captureCanvasLayer(WidgetTester tester) async {
  await tester.pump();
  final canvas = find.byType(NativeDocumentCanvas);
  final finder = find.descendant(
    of: canvas,
    matching: find.byType(RepaintBoundary),
  );
  expect(finder, findsOneWidget);
  var boundary = tester.renderObject<RenderRepaintBoundary>(finder);
  for (var i = 0; i < 6 && boundary.debugNeedsPaint; i++) {
    await tester.pump();
    boundary = tester.renderObject<RenderRepaintBoundary>(finder);
  }
  expect(
    boundary.debugNeedsPaint,
    isFalse,
    reason: 'Canvas layer must be painted before capture',
  );
  final snapshot = tester.widget<NativeDocumentCanvas>(canvas).snapshot;
  final ratio = snapshot.width / boundary.size.width;
  expect(ratio, greaterThan(0));
  final image = await tester.runAsync(
    () => boundary.toImage(pixelRatio: ratio),
  );
  final result = image!;
  expect(result.width, snapshot.width);
  expect(result.height, snapshot.height);
  return result;
}
