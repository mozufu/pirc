import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/rendering/document_background_image.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/rendering/html_background_layers.dart';
import 'package:pirc_mobile/rendering/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android real Gateway paints all pinned multi-layer background pixels in light and dark',
    (t) async {
      expect(const bool.fromEnvironment('PIRC_DOCUMENTS'), isTrue);
      final gateway = Gateway();
      await gateway.call('pair', {
        'link': const String.fromEnvironment('PIRC_PAIR_LINK'),
      });
      await gateway.call('completeOnboarding');
      final boot = obj(await gateway.call('boot'));
      final origin = boot['origin'] as String;
      final pairingStamp = boot['pairingStamp'];

      Future<Map<String, dynamic>> documentJson(String path) async {
        final reply = obj(
          await gateway.call('document', {
            'url': '$origin$path',
            'method': 'GET',
            'pairingStamp': pairingStamp,
          }),
        );
        expect(reply['status'], 200, reason: path);
        return Map<String, dynamic>.from(
          jsonDecode(utf8.decode(List<int>.from(reply['bytes'] as List)))
              as Map,
        );
      }

      final oracle = await documentJson(
        '/parity-documents/background-layers-expected',
      );
      final cases = (oracle['cases'] as List)
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList();
      expect(cases, hasLength(8));
      final caseById = {
        for (final testCase in cases) '${testCase['id']}': testCase,
      };
      final windows = NativeDocumentWindows(gateway);
      final window = windows.target(
        '',
        null,
        sourceUrl: '$origin/background-layers',
      );
      final pircTheme = await PircTheme.load();
      const boundaryKey = ValueKey('background-layers-android');
      const remoteSvgPath =
          '/parity-documents/assets/background-layers/svg-red-blue.svg';

      Finder layeredDecoration() => find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is NativeHtmlLayeredBackgroundDecoration,
      );

      Widget host(Brightness brightness) => MaterialApp(
        theme: pircTheme.build(brightness),
        home: RepaintBoundary(
          key: boundaryKey,
          child: NativeDocumentWorkspace(windows: windows, managed: true),
        ),
      );

      Future<void> loadCase(
        String id,
        Brightness brightness, {
        bool remoteSvg = false,
      }) async {
        final query = Uri(
          queryParameters: {'case': id, if (remoteSvg) 'remoteSvg': '1'},
        ).query;
        expect(
          await window.load(
            NativeHtmlFormRequest(
              url: '/parity-documents/background-layers?$query',
              method: 'GET',
              target: '',
            ),
            baseUrl: '$origin/',
          ),
          NativeDocumentLoadResult.committed,
          reason: id,
        );
        windows.select(window);
        await t.pumpWidget(host(brightness));
        await t.pump();
        await t.pump();
      }

      Future<List<String>> captureMismatches(
        Map<String, dynamic> testCase,
      ) async {
        final layer = layeredDecoration();
        expect(layer, findsOneWidget, reason: '${testCase['id']} layer');
        final decorated =
            t.widget<DecoratedBox>(layer).decoration
                as NativeHtmlLayeredBackgroundDecoration;
        expect(
          decorated.layers,
          hasLength(testCase['layerCount'] as int),
          reason: '${testCase['id']} layer count',
        );
        final layerRect = t.getRect(layer);
        expect(
          layerRect.width,
          closeTo(120, .01),
          reason: '${testCase['id']} width',
        );
        expect(
          layerRect.height,
          closeTo(80, .01),
          reason: '${testCase['id']} height',
        );

        final samples = (testCase['pixelSamples'] as List)
            .map((value) => Map<String, dynamic>.from(value as Map))
            .toList();
        expect(
          samples,
          hasLength(81),
          reason: '${testCase['id']} sample count',
        );
        final boundary = t.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        final boundaryOrigin = t.getTopLeft(find.byKey(boundaryKey));
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final bytes = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
          final mismatches = <String>[];
          for (final sample in samples) {
            final x = (sample['x'] as num).toInt();
            final y = (sample['y'] as num).toInt();
            final point =
                Offset(layerRect.left + x, layerRect.top + y) - boundaryOrigin;
            expect(
              point.dx >= 0 &&
                  point.dy >= 0 &&
                  point.dx < image.width &&
                  point.dy < image.height,
              isTrue,
              reason: '${testCase['id']} sample ($x,$y) is within screenshot',
            );
            final pixelX = point.dx.floor(), pixelY = point.dy.floor();
            final offset = (pixelY * image.width + pixelX) * 4;
            final actual = bytes.sublist(offset, offset + 4);
            final expected = (sample['rgba'] as List)
                .cast<num>()
                .map((channel) => channel.toInt())
                .toList();
            for (var channel = 0; channel < 4; channel++) {
              final delta = (actual[channel] - expected[channel]).abs();
              if (delta > 3) {
                mismatches.add(
                  '($x,$y) rgba[$channel] expected ${expected[channel]}, '
                  'actual ${actual[channel]} (Δ$delta)',
                );
              }
            }
          }
          return mismatches;
        } finally {
          image.dispose();
        }
      }

      Future<void> verifyCase(Map<String, dynamic> testCase) async {
        final timer = Stopwatch()..start();
        var mismatches = <String>[];
        while (timer.elapsed < const Duration(seconds: 10)) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await t.pump();
          mismatches = await captureMismatches(testCase);
          if (mismatches.isEmpty) return;
        }
        expect(
          mismatches,
          isEmpty,
          reason:
              '${testCase['id']} differs from Chrome samples: ${mismatches.take(12).join('; ')}',
        );
      }

      Future<List<Map<String, dynamic>>> requests() async {
        final receipt = await documentJson('/parity-documents/receipt');
        return (receipt['requests'] as List)
            .map((value) => Map<String, dynamic>.from(value as Map))
            .toList();
      }

      try {
        for (final brightness in Brightness.values) {
          for (final testCase in cases) {
            await loadCase('${testCase['id']}', brightness);
            await verifyCase(testCase);
          }
        }

        final remoteCase = caseById['svg-over-transparent-stop-gradient']!;
        await loadCase(
          '${remoteCase['id']}',
          Brightness.light,
          remoteSvg: true,
        );
        final remoteLayer = layeredDecoration();
        expect(remoteLayer, findsOneWidget);
        final remoteDecoration =
            t.widget<DecoratedBox>(remoteLayer).decoration
                as NativeHtmlLayeredBackgroundDecoration;
        final remoteProviders = remoteDecoration.images
            .whereType<NativeDocumentBackgroundImage>()
            .toList();
        expect(remoteProviders, hasLength(1));
        expect(
          remoteProviders.single.source.toString(),
          '$origin$remoteSvgPath',
        );
        await verifyCase(remoteCase);
        var imageRequests = (await requests())
            .where((request) => request['path'] == remoteSvgPath)
            .length;
        expect(
          imageRequests,
          1,
          reason: 'the same fixture SVG is fetched once',
        );

        await t.pumpWidget(host(Brightness.dark));
        await t.pump();
        await verifyCase(remoteCase);
        imageRequests = (await requests())
            .where((request) => request['path'] == remoteSvgPath)
            .length;
        expect(
          imageRequests,
          1,
          reason: 'theme rebuild reuses the authenticated SVG image',
        );
        expect(t.takeException(), isNull);
        debugPrint(
          'BACKGROUND_LAYERS_ANDROID:8 cases x 81 samples x light/dark; remote SVG fetched once',
        );
      } finally {
        await t.pumpWidget(const SizedBox());
        windows.dispose();
        await gateway.call('unpair');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
