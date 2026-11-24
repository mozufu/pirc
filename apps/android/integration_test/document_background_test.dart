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
import 'package:pirc_mobile/rendering/html_background_gradient.dart';
import 'package:pirc_mobile/rendering/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android document CSS backgrounds authenticate, resolve URLs, animate, and render gradients and SVGs',
    (t) async {
      expect(const bool.fromEnvironment('PIRC_DOCUMENTS'), isTrue);
      final g = Gateway();
      await g.call('pair', {
        'link': const String.fromEnvironment('PIRC_PAIR_LINK'),
      });
      await g.call('completeOnboarding');
      final boot = obj(await g.call('boot'));
      final origin = boot['origin'] as String;
      Future<List<dynamic>> receipts() async {
        final reply = obj(
          await g.call('document', {
            'url': '$origin/parity-documents/receipt',
            'method': 'GET',
            'pairingStamp': boot['pairingStamp'],
          }),
        );
        expect(reply['status'], 200);
        final payload = jsonDecode(utf8.decode(reply['bytes'] as List<int>));
        return (payload as Map<String, dynamic>)['requests'] as List<dynamic>;
      }

      final windows = NativeDocumentWindows(g);
      final w = windows.target('', null, sourceUrl: '$origin/source');
      const key = ValueKey('document-background-android');
      try {
        expect(
          await w.load(
            const NativeHtmlFormRequest(
              url: '/parity-documents/background-source',
              method: 'GET',
              target: '',
            ),
            baseUrl: '$origin/',
          ),
          NativeDocumentLoadResult.committed,
        );
        windows.select(w);
        await t.pumpWidget(
          MaterialApp(
            theme: (await PircTheme.load()).build(Brightness.light),
            home: RepaintBoundary(
              key: key,
              child: NativeDocumentWorkspace(windows: windows, managed: true),
            ),
          ),
        );
        await t.pump();
        final seen = <String, Set<String>>{'gif': {}, 'webp': {}};
        for (var i = 0; i < 160 && seen.values.any((v) => v.length < 2); i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump();
          final boundary = t.renderObject<RenderRepaintBoundary>(
            find.byKey(key),
          );
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            final originPoint = t.getTopLeft(find.byKey(key));
            for (final kind in ['gif', 'webp']) {
              final finder = find.byWidgetPredicate(
                (widget) =>
                    widget is DecoratedBox &&
                    widget.decoration is BoxDecoration &&
                    (widget.decoration as BoxDecoration).image?.image
                        is NativeDocumentBackgroundImage &&
                    ((widget.decoration as BoxDecoration).image!.image
                            as NativeDocumentBackgroundImage)
                        .source
                        .path
                        .endsWith('animated.$kind'),
              );
              expect(finder, findsOneWidget);
              final decoration =
                  (t.widget<DecoratedBox>(finder).decoration as BoxDecoration);
              final provider =
                  decoration.image!.image as NativeDocumentBackgroundImage;
              final rect = t.getRect(finder);
              expect(
                provider.source.toString(),
                '$origin/parity-documents/assets/animated.$kind',
              );
              expect(rect.width, 100);
              expect(rect.height, 100);
              final point = rect.bottomRight - originPoint - const Offset(2, 2);
              final offset =
                  (point.dy.toInt() * image.width + point.dx.toInt()) * 4;
              final pixel = bytes.sublist(offset, offset + 4);
              if (pixel[0] > 200 && pixel[1] < 20 && pixel[2] < 20) {
                seen[kind]!.add('red');
              }
              if (pixel[2] > 200 && pixel[0] < 20 && pixel[1] < 20) {
                seen[kind]!.add('blue');
              }
            }
          } finally {
            image.dispose();
          }
        }
        expect(seen, {
          'gif': {'red', 'blue'},
          'webp': {'red', 'blue'},
        });

        final linear = find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).gradient
                  is NativeHtmlLinearGradient,
        );
        final radial = find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).gradient
                  is NativeHtmlRadialGradient,
        );
        expect(linear, findsOneWidget);
        expect(radial, findsOneWidget);
        for (final gradient in [linear, radial]) {
          expect(t.getRect(gradient).width, 100);
          expect(t.getRect(gradient).height, 100);
        }
        bool isSvgBackground(Widget widget, {required bool data}) {
          if (widget is! DecoratedBox || widget.decoration is! BoxDecoration) {
            return false;
          }
          final provider = (widget.decoration as BoxDecoration).image?.image;
          if (provider is! NativeDocumentBackgroundImage) return false;
          return data
              ? provider.source.scheme == 'data'
              : provider.source.path.endsWith('/split.svg');
        }

        final remoteSvg = find.byWidgetPredicate(
          (widget) => isSvgBackground(widget, data: false),
        );
        final dataSvg = find.byWidgetPredicate(
          (widget) => isSvgBackground(widget, data: true),
        );
        expect(remoteSvg, findsOneWidget);
        expect(dataSvg, findsOneWidget);
        final remoteSvgDecoration =
            t.widget<DecoratedBox>(remoteSvg).decoration as BoxDecoration;
        final remoteSvgProvider =
            remoteSvgDecoration.image!.image as NativeDocumentBackgroundImage;
        expect(
          remoteSvgProvider.source.toString(),
          '$origin/parity-documents/assets/split.svg',
        );
        final dataSvgDecoration =
            t.widget<DecoratedBox>(dataSvg).decoration as BoxDecoration;
        final dataSvgProvider =
            dataSvgDecoration.image!.image as NativeDocumentBackgroundImage;
        expect(dataSvgProvider.source.scheme, 'data');
        expect(dataSvgProvider.source.data!.mimeType, 'image/svg+xml');
        final remoteSvgRect = t.getRect(remoteSvg);
        final dataSvgRect = t.getRect(dataSvg);
        for (final rect in [remoteSvgRect, dataSvgRect]) {
          expect(rect.width, 100);
          expect(rect.height, 50);
        }

        Future<Map<String, List<int>>> sampleRects(
          Map<String, ({Rect rect, double x, double y})> probes, {
          bool logGeometry = false,
        }) async {
          final boundary = t.renderObject<RenderRepaintBoundary>(
            find.byKey(key),
          );
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            final originPoint = t.getTopLeft(find.byKey(key));
            final pixels = <String, List<int>>{};
            for (final entry in probes.entries) {
              final rect = entry.value.rect;
              final point =
                  Offset(rect.left + entry.value.x, rect.top + entry.value.y) -
                  originPoint;
              if (logGeometry) {
                debugPrint(
                  'DOCUMENT_BACKGROUND_GEOMETRY:${entry.key} rect=$rect origin=$originPoint image=${image.width}x${image.height} point=$point',
                );
              }
              expect(
                point.dx >= 0 &&
                    point.dy >= 0 &&
                    point.dx < image.width &&
                    point.dy < image.height,
                isTrue,
                reason:
                    '${entry.key} sample must be inside the captured viewport',
              );
              final px = point.dx.floor();
              final py = point.dy.floor();
              final offset = (py * image.width + px) * 4;
              pixels[entry.key] = bytes.sublist(offset, offset + 4);
            }
            return pixels;
          } finally {
            image.dispose();
          }
        }

        Future<List<int>> sampleRect(
          Rect rect,
          double x,
          double y,
          String label,
        ) async => (await sampleRects({
          label: (rect: rect, x: x, y: y),
        }, logGeometry: true))[label]!;

        await t.ensureVisible(linear);
        await t.pump();
        final linearPixels = {
          'left': await sampleRect(t.getRect(linear), 5, 50, 'linear-left'),
          'right': await sampleRect(t.getRect(linear), 95, 50, 'linear-right'),
        };
        await t.ensureVisible(radial);
        await t.pump();
        final radialPixels = {
          'center': await sampleRect(
            t.getRect(radial),
            50,
            50,
            'radial-center',
          ),
          'edge': await sampleRect(t.getRect(radial), 5, 5, 'radial-edge'),
        };
        debugPrint(
          'DOCUMENT_BACKGROUND_SVG_DECORATION_TYPES:remote=${remoteSvgDecoration.runtimeType} data=${dataSvgDecoration.runtimeType}',
        );
        await t.ensureVisible(remoteSvg);
        await t.ensureVisible(dataSvg);
        await t.pump();
        final svgProbes = <String, ({Rect rect, double x, double y})>{
          'svg-remote-left': (rect: remoteSvgRect, x: 25, y: 25),
          'svg-remote-right': (rect: remoteSvgRect, x: 75, y: 25),
          'svg-data-left': (rect: dataSvgRect, x: 25, y: 25),
          'svg-data-right': (rect: dataSvgRect, x: 75, y: 25),
        };
        bool isRed(List<int> pixel) =>
            pixel[0] > 200 && pixel[1] < 50 && pixel[2] < 50;
        bool isBlue(List<int> pixel) =>
            pixel[2] > 200 && pixel[0] < 50 && pixel[1] < 50;
        bool hasAllSvgColors(Map<String, List<int>> pixels) =>
            isRed(pixels['svg-remote-left']!) &&
            isBlue(pixels['svg-remote-right']!) &&
            isRed(pixels['svg-data-left']!) &&
            isBlue(pixels['svg-data-right']!);
        final svgWait = Stopwatch()..start();
        var svgAttempts = 0;
        var svgSamples = <String, List<int>>{};
        while (svgWait.elapsed < const Duration(seconds: 10)) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await t.pump();
          svgAttempts++;
          svgSamples = await sampleRects(svgProbes);
          if (hasAllSvgColors(svgSamples)) break;
        }
        svgWait.stop();
        svgSamples = await sampleRects(svgProbes, logGeometry: true);
        debugPrint(
          'DOCUMENT_BACKGROUND_SVG_READINESS:attempts=$svgAttempts elapsedMs=${svgWait.elapsedMilliseconds} ready=${hasAllSvgColors(svgSamples)} pixels=$svgSamples',
        );
        final remoteSvgPixels = {
          'left': svgSamples['svg-remote-left']!,
          'right': svgSamples['svg-remote-right']!,
        };
        final dataSvgPixels = {
          'left': svgSamples['svg-data-left']!,
          'right': svgSamples['svg-data-right']!,
        };
        final requests = await receipts();
        expect(
          requests.any(
            (request) =>
                (request as Map<String, dynamic>)['path'] ==
                '/parity-documents/assets/split.svg',
          ),
          isTrue,
          reason:
              'the SVG background URL must use the authenticated document transport',
        );
        final pixels = {
          'linear': linearPixels,
          'radial': radialPixels,
          'svgRemote': remoteSvgPixels,
          'svgData': dataSvgPixels,
        };
        debugPrint('DOCUMENT_BACKGROUND_PIXELS:$pixels');
        expect(linearPixels['left']![0] > 200, isTrue);
        expect(linearPixels['left']![2] < 60, isTrue);
        expect(linearPixels['right']![2] > 200, isTrue);
        expect(linearPixels['right']![0] < 60, isTrue);
        expect(radialPixels['center']![1] > 200, isTrue);
        expect(radialPixels['center']![0] < 40, isTrue);
        expect(radialPixels['center']![2] < 40, isTrue);
        expect(
          radialPixels['edge']!.take(3).every((channel) => channel < 40),
          isTrue,
        );
        for (final sample in [
          remoteSvgPixels['left']!,
          dataSvgPixels['left']!,
        ]) {
          expect(sample[0] > 200, isTrue);
          expect(sample[1] < 50, isTrue);
          expect(sample[2] < 50, isTrue);
        }
        for (final sample in [
          remoteSvgPixels['right']!,
          dataSvgPixels['right']!,
        ]) {
          expect(sample[2] > 200, isTrue);
          expect(sample[0] < 50, isTrue);
          expect(sample[1] < 50, isTrue);
        }
        expect(t.takeException(), isNull);
        debugPrint(
          'DOCUMENT_BACKGROUND:accepted-linear-radial-gradient-and-svg-pixels',
        );
        debugPrint(
          'DOCUMENT_BACKGROUND:accepted-authenticated-gif-webp-red-blue',
        );
      } finally {
        await t.pumpWidget(const SizedBox());
        windows.dispose();
        await g.call('unpair');
      }
    },
  );
}
