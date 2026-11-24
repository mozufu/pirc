import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_render/src/document_background_image.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_background_layers.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/html_image_background_decoration.dart';
import 'package:pirc_mobile/theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android real Gateway paints raster background size pixels in light and dark',
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
        '/parity-documents/raster-background-sizes-expected',
      );
      final coverage = Map<String, dynamic>.from(oracle['coverage'] as Map);
      final cases = (oracle['cases'] as List)
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList();
      final assets = (oracle['assets'] as List)
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList();
      expect(cases, hasLength(13));
      expect(coverage['caseCount'], 13);
      expect(coverage['samplesPerCase'], 96);
      expect(coverage['totalPixelSamples'], 1248);
      final rasterAsset = assets.singleWhere(
        (asset) => asset['id'] == 'png-red-blue-40x20',
      );
      expect(rasterAsset['mimeType'], 'image/png');
      expect(rasterAsset['width'], 40);
      expect(rasterAsset['height'], 20);
      final caseById = {
        for (final testCase in cases) '${testCase['id']}': testCase,
      };
      expect(caseById, hasLength(cases.length));
      expect(caseById.containsKey('zero-width-zero-px-40px'), isTrue);
      expect(caseById.containsKey('tiny-repeat-quarter-pixel'), isTrue);
      expect(
        caseById.containsKey('raster-with-alpha-gradient-right-top'),
        isTrue,
      );
      expect(
        caseById['raster-with-alpha-gradient-right-top']!['layerCount'],
        2,
      );
      for (final testCase in cases) {
        expect(
          testCase['pixelSamples'],
          hasLength(96),
          reason: '${testCase['id']} golden sample count',
        );
      }

      final windows = NativeDocumentWindows(gateway);
      final window = windows.target(
        '',
        null,
        sourceUrl: '$origin/raster-background-sizes',
      );
      final pircTheme = await PircTheme.load();
      const boundaryKey = ValueKey('raster-background-sizes-android');

      Finder backgroundDecoration() => find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            (widget.decoration is NativeHtmlImageBackgroundDecoration ||
                widget.decoration is NativeHtmlLayeredBackgroundDecoration),
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
        bool remotePng = false,
      }) async {
        final query = Uri(
          queryParameters: {'case': id, if (remotePng) 'remotePng': '1'},
        ).query;
        expect(
          await window.load(
            NativeHtmlFormRequest(
              url: '/parity-documents/raster-background-sizes?$query',
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

      List<NativeDocumentBackgroundImage> imageProviders(
        Decoration decoration,
      ) {
        if (decoration is NativeHtmlImageBackgroundDecoration) {
          final provider = decoration.image?.image;
          return provider is NativeDocumentBackgroundImage
              ? [provider]
              : <NativeDocumentBackgroundImage>[];
        }
        if (decoration is NativeHtmlLayeredBackgroundDecoration) {
          return decoration.images
              .whereType<NativeDocumentBackgroundImage>()
              .toList();
        }
        return <NativeDocumentBackgroundImage>[];
      }

      Future<List<String>> captureMismatches(
        Map<String, dynamic> testCase,
      ) async {
        final finder = backgroundDecoration();
        expect(finder, findsOneWidget, reason: '${testCase['id']} decoration');
        final decoration = t.widget<DecoratedBox>(finder).decoration;
        final layerCount = decoration is NativeHtmlLayeredBackgroundDecoration
            ? decoration.layers.length
            : decoration is NativeHtmlImageBackgroundDecoration
            ? 1
            : 0;
        expect(
          layerCount,
          testCase['layerCount'],
          reason: '${testCase['id']} image layer count',
        );
        expect(
          imageProviders(decoration),
          hasLength(1),
          reason: '${testCase['id']} raster provider',
        );

        final box = t.getRect(finder);
        expect(box.width, closeTo(120, .01), reason: '${testCase['id']} width');
        expect(
          box.height,
          closeTo(80, .01),
          reason: '${testCase['id']} height',
        );
        final samples = (testCase['pixelSamples'] as List)
            .map((value) => Map<String, dynamic>.from(value as Map))
            .toList();
        expect(
          samples,
          hasLength(96),
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
            final point = Offset(box.left + x, box.top + y) - boundaryOrigin;
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

        const remotePngPath =
            '/parity-documents/assets/raster-background-size.png';
        final remoteCase = caseById['size-60px-40px']!;
        await loadCase(
          '${remoteCase['id']}',
          Brightness.light,
          remotePng: true,
        );
        final remoteDecoration = t
            .widget<DecoratedBox>(backgroundDecoration())
            .decoration;
        final remoteProviders = imageProviders(remoteDecoration);
        expect(remoteProviders, hasLength(1));
        expect(
          remoteProviders.single.source.toString(),
          '$origin$remotePngPath',
        );
        await verifyCase(remoteCase);
        var imageRequests = (await requests())
            .where((request) => request['path'] == remotePngPath)
            .toList();
        expect(imageRequests, hasLength(1));
        expect(imageRequests.single['authenticated'], isTrue);
        expect(imageRequests.single['method'], 'GET');

        await t.pumpWidget(host(Brightness.dark));
        await t.pump();
        await verifyCase(remoteCase);
        imageRequests = (await requests())
            .where((request) => request['path'] == remotePngPath)
            .toList();
        expect(
          imageRequests,
          hasLength(1),
          reason: 'theme rebuild reuses the authenticated PNG image',
        );
        expect(imageRequests.single['authenticated'], isTrue);
        expect(t.takeException(), isNull);
        debugPrint(
          'RASTER_BACKGROUND_SIZES_ANDROID:13 cases x 96 samples x light/dark; remote PNG fetched once',
        );
      } finally {
        await t.pumpWidget(const SizedBox());
        windows.dispose();
        await gateway.call('unpair');
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
