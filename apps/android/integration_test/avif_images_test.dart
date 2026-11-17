// Static AVIF Chrome pixel oracle; Android 12+ native decode, Flutter UI.
import 'package:pirc_mobile/live/remote_content_gate.dart';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/rendering/native_raster_images.dart';
import 'package:pirc_mobile/rendering/native_html.dart';
import 'package:pirc_mobile/rendering/html_syntax.dart';
import 'package:pirc_mobile/live/markdown_image.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as md;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // These suites exercise the image/media loaders themselves, not the hold-back.
  setUpAll(() => NativeRemoteContentPolicy.debugOpenForTests = true);
  tearDownAll(() => NativeRemoteContentPolicy.debugOpenForTests = false);
  final fixture =
      jsonDecode(r'''{
  "browser": "155.0.8059.40",
  "encoder": "libavif 1.4.1/aom 3.13.3; q100; speed8; 8/10-bit; synthetic RGBA32x16",
  "fixtures": [
    {
      "id": "opaque-8",
      "dataUri": "data:image/avif;base64,AAAAIGZ0eXBhdmlmAAAAAGF2aWZtaWYxbWlhZk1BMUEAAADrbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAcGljdAAAAAAAAAAAAAAAAAAAAAAOcGl0bQAAAAAAAQAAAB5pbG9jAAAAAEQAAAEAAQAAAAEAAAETAAAAIgAAAChpaW5mAAAAAAABAAAAGmluZmUCAAAAAAEAAGF2MDFDb2xvcgAAAABqaXBycAAAAEtpcGNvAAAAFGlzcGUAAAAAAAAAIAAAABAAAAAQcGl4aQAAAAADCAgIAAAADGF2MUOBIAAAAAAAE2NvbHJuY2x4AAEADQAGgAAAABdpcG1hAAAAAAAAAAEAAQQBAoMEAAAAKm1kYXQSAAoIOBD/7CAhoNIyFBAAAMXAMFftRDmKhuOm7pfxmOBA",
      "sha256": "ff54d9ee2968c424488ddf31d461ffe0d0bdc741bb173c2c86fb7540d113c01b",
      "expected": {
        "width": 32,
        "height": 16,
        "center": [
          45,
          149,
          210,
          255
        ]
      }
    },
    {
      "id": "alpha-8",
      "dataUri": "data:image/avif;base64,AAAAIGZ0eXBhdmlmAAAAAGF2aWZtaWYxbWlhZk1BMUEAAAGGbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAcGljdAAAAAAAAAAAAAAAAAAAAAAOcGl0bQAAAAAAAQAAACxpbG9jAAAAAEQAAAIAAQAAAAEAAAG9AAAAIgACAAAAAQAAAa4AAAAPAAAAQmlpbmYAAAAAAAIAAAAaaW5mZQIAAAAAAQAAYXYwMUNvbG9yAAAAABppbmZlAgAAAAACAABhdjAxQWxwaGEAAAAAGmlyZWYAAAAAAAAADmF1eGwAAgABAAEAAADDaXBycAAAAJ1pcGNvAAAAFGlzcGUAAAAAAAAAIAAAABAAAAAQcGl4aQAAAAADCAgIAAAADGF2MUOBIAAAAAAAE2NvbHJuY2x4AAEADQAGgAAAAA5waXhpAAAAAAEIAAAADGF2MUOBABwAAAAAOGF1eEMAAAAAdXJuOm1wZWc6bXBlZ0I6Y2ljcDpzeXN0ZW1zOmF1eGlsaWFyeTphbHBoYQAAAAAeaXBtYQAAAAAAAAACAAEEAQKDBAACBAEFhgcAAAA5bWRhdBIACgUYEP/sKjIEEAAfgBIACgg4EP/sICGg0jIUEAAAxcAwV+1EOYqG46bul/GY4EA=",
      "sha256": "cf539548d0534f93784fa3503f0743a4dda94ba2d112e5a7cedbe8b0e833beb7",
      "expected": {
        "width": 32,
        "height": 16,
        "center": [
          46,
          149,
          209,
          128
        ]
      }
    },
    {
      "id": "opaque-10",
      "dataUri": "data:image/avif;base64,AAAAIGZ0eXBhdmlmAAAAAGF2aWZtaWYxbWlhZk1BMUEAAADrbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAcGljdAAAAAAAAAAAAAAAAAAAAAAOcGl0bQAAAAAAAQAAAB5pbG9jAAAAAEQAAAEAAQAAAAEAAAETAAAAJAAAAChpaW5mAAAAAAABAAAAGmluZmUCAAAAAAEAAGF2MDFDb2xvcgAAAABqaXBycAAAAEtpcGNvAAAAFGlzcGUAAAAAAAAAIAAAABAAAAAQcGl4aQAAAAADCgoKAAAADGF2MUOBIEAAAAAAE2NvbHJuY2x4AAEADQAGgAAAABdpcG1hAAAAAAAAAAEAAQQBAoMEAAAALG1kYXQSAAoIOBD/7GAhoNIyFhAAAMXAMOiMoy7uefUANr29gi+rpog=",
      "sha256": "b5b1c53b9de774131222661165de9a0aa570fff6ead9503332681757cff1505c",
      "expected": {
        "width": 32,
        "height": 16,
        "center": [
          44,
          150,
          209,
          255
        ]
      }
    }
  ]
}''')
          as Map;
  for (final c in fixture['fixtures'] as List) {
    testWidgets('AVIF normalized Flutter pixels ${c['id']}', (tester) async {
      await NativeRasterImages.loadCapabilities();
      expect(NativeRasterImages.avifSupported, isTrue);
      bool matches = false;
      ui.Codec? codec;
      try {
        final bytes = await NativeRasterImages.prepare(
          Uri.parse(c['dataUri'] as String).data!.contentAsBytes(),
          'image/avif',
        );
        codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        try {
          final key = GlobalKey();
          await tester.pumpWidget(
            Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: 32,
                  height: 16,
                  child: RawImage(image: frame.image, fit: BoxFit.fill),
                ),
              ),
            ),
          );
          await tester.pump();
          final raster =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final data = (await raster.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          ))!;
          final pixels = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
          raster.dispose();
          final offset = (8 * frame.image.width + 16) * 4;
          final actual = pixels.sublist(offset, offset + 4);
          debugPrint(
            jsonEncode({
              'id': c['id'],
              'supported': true,
              'width': frame.image.width,
              'height': frame.image.height,
              'center': actual,
            }),
          );
          expect(frame.image.width, c['expected']['width']);
          expect(frame.image.height, c['expected']['height']);
          matches = List.generate(
            4,
            (i) => (actual[i] - (c['expected']['center'][i] as num)).abs() <= 3,
          ).every((v) => v);
          debugPrint(
            jsonEncode({
              'id': c['id'],
              'chromeCenter': c['expected']['center'],
              'matches': matches,
            }),
          );
          await tester.pumpWidget(const SizedBox.shrink());
        } finally {
          frame.image.dispose();
        }
      } catch (error) {
        debugPrint(
          jsonEncode({
            'id': c['id'],
            'supported': false,
            'error': error.toString(),
          }),
        );
      } finally {
        codec?.dispose();
      }
      expect(matches, isTrue);
    });
    testWidgets('HTML picture selects and paints AVIF ${c['id']}', (
      tester,
    ) async {
      await NativeRasterImages.loadCapabilities();
      expect(NativeRasterImages.avifSupported, isTrue);
      final theme = await PircTheme.load();
      final key = GlobalKey();
      final dataUri = c['dataUri'] as String;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: NativeHtmlDocument(
              nodes: [
                NativeHtmlRaw(
                  '<picture><source type="image/avif" srcset="$dataUri"><img src="data:image/png;base64,INVALID" width="32" height="16"></picture>',
                ),
              ],
              style: const TextStyle(fontSize: 16),
              styles: md.MarkdownStyleSheet(),
              builders: const {},
              markdownStyles: false,
              imageBuilder: (uri, title, alt) => RepaintBoundary(
                key: key,
                child: NativeMarkdownImage(
                  gateway: Gateway(),
                  source: uri,
                  borderRadius: 0,
                ),
              ),
            ),
          ),
        ),
      );
      for (
        var i = 0;
        i < 100 &&
            !find
                .byType(RawImage)
                .evaluate()
                .any((e) => (e.widget as RawImage).image != null);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      expect(find.byType(Image), findsOneWidget);
      expect(
        tester
            .widget<NativeMarkdownImage>(find.byType(NativeMarkdownImage))
            .source
            .toString(),
        dataUri,
      );
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      try {
        expect(image.width, 32);
        expect(image.height, 16);
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        ))!;
        final pixels = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        final offset = (8 * 32 + 16) * 4;
        for (var i = 0; i < 4; i++) {
          expect(
            pixels[offset + i],
            closeTo(c['expected']['center'][i] as num, 3),
          );
        }
      } finally {
        image.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }
}
