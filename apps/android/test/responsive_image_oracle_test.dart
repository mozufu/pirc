import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/markdown_image.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/html_responsive_image.dart';
import 'package:pirc_render/src/native_image_frame.dart';
import 'live_test.dart' show FakeGateway, theme;
import 'markdown_image_test.dart' show waitImage;

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-responsive-images.json',
            ).readAsStringSync(),
          )
          as Map;
  final assets = {
    for (final a in fixture['assetManifest'] as List)
      a['path'] as String: a as Map,
  };
  for (final c in fixture['fixtures'] as List) {
    final width = (c['viewport']['width'] as num).toDouble();
    final height = (c['viewport']['height'] as num).toDouble();
    final dpr = (c['deviceScaleFactor'] as num).toDouble();
    test('Chrome responsive source and natural size ${c['id']}', () {
      final parsed = html.parse(c['authoredHtml'] as String);
      final choice = selectNativeResponsiveImage(
        parsed.querySelector('img')!,
        viewportWidth: width,
        viewportHeight: height,
        devicePixelRatio: dpr,
      );
      expect(choice.url, c['expectedCurrentSrc']);
      final asset = c['expectedSourceAsset'];
      expect(
        (asset['pixelWidth'] as num) / choice.density,
        closeTo((c['expectedNaturalWidth'] as num).toDouble(), 1),
      );
      expect(
        (asset['pixelHeight'] as num) / choice.density,
        closeTo((c['expectedNaturalHeight'] as num).toDouble(), 1),
      );
    });
    for (final brightness in Brightness.values) {
      testWidgets('Chrome responsive document ${c['id']} $brightness', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, height);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final gateway = FakeGateway();
        final calls = <String>[];
        gateway.handler = (method, args) async {
          if (method != 'image') throw StateError('Unexpected gateway call');
          final path = Uri.parse('${args['source']}').path;
          calls.add(path);
          final asset = assets[path];
          if (asset == null) throw StateError('Missing asset $path');
          return {
            'bytes': Uint8List.fromList(
              Uri.parse(asset['dataUri'] as String).data!.contentAsBytes(),
            ),
            'mimeType': 'image/png',
          };
        };
        final markup = c['authoredHtml'] as String;
        final bytes = Uint8List.fromList(utf8.encode(markup));
        final parsed = html.parse(markup);
        final document = NativeFetchedDocument(
          id: 0,
          url: 'https://image.example/',
          status: 200,
          bytes: bytes,
          mimeType: 'text/html',
          headers: {},
          content: NativeHtmlDocumentContent.fromBytes(
            bytes,
            mimeType: 'text/html',
            charset: 'utf-8',
          ),
          stylesheets: [
            for (final style in parsed.querySelectorAll('style'))
              NativeDocumentStylesheet(
                style.text,
                baseUrl: 'https://image.example/',
              ),
          ],
        );
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(devicePixelRatio: dpr),
                child: child!,
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
          await waitImage(
            tester,
            () => find.byType(Image).evaluate().isNotEmpty,
          );
          expect(find.byType(NativeMarkdownImage), findsOneWidget);
          final widget = tester.widget<NativeMarkdownImage>(
            find.byType(NativeMarkdownImage),
          );
          expect(widget.source.toString(), c['expectedCurrentSrc']);
          final frameFinder = find.byType(NativeImageFrame);
          expect(frameFinder, findsOneWidget);
          final frame = tester.renderObject<RenderNativeImageFrame>(
            frameFinder,
          );
          expect(
            frame.getMaxIntrinsicWidth(double.infinity),
            closeTo((c['expectedNaturalWidth'] as num).toDouble(), 1),
          );
          expect(
            frame.getMaxIntrinsicHeight(double.infinity),
            closeTo((c['expectedNaturalHeight'] as num).toDouble(), 1),
          );
          final size = tester.getSize(find.byType(Image));
          expect(
            size.width,
            closeTo((c['expectedCssRect']['width'] as num).toDouble(), .1),
          );
          expect(
            size.height,
            closeTo((c['expectedCssRect']['height'] as num).toDouble(), .1),
          );
          if (!widget.source.toString().startsWith('data:')) {
            expect(calls, [c['expectedCurrentSrc']]);
          } else {
            expect(calls, isEmpty);
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          document.dispose();
          await gateway.stream.close();
        }
      });
    }
  }
}
