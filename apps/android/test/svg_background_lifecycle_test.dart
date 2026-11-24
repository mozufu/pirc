import 'package:pirc_mobile/live/render_host_adapter.dart';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/rendering/document_background_image.dart';
import 'package:pirc_mobile/rendering/html_image_background_decoration.dart';
import 'live_test.dart' show FakeGateway;

const key = ValueKey('svg-lifecycle');
Future<List<int>> pixel(WidgetTester t, int x, int y) async =>
    (await t.runAsync(() async {
      final image = await t
          .renderObject<RenderRepaintBoundary>(find.byKey(key))
          .toImage(pixelRatio: 1);
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        return bytes.sublist(
          (y * image.width + x) * 4,
          (y * image.width + x) * 4 + 4,
        );
      } finally {
        image.dispose();
      }
    }))!;
Future<void> color(WidgetTester t, int x, int y, List<int> expected) async {
  List<int> actual = [];
  for (var i = 0; i < 100; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await t.pump();
    actual = await pixel(t, x, y);
    if (actual.toString() == expected.toString()) break;
  }
  expect(actual, expected);
}

Widget host(Decoration decoration, double width, double height) => MaterialApp(
  home: Scaffold(
    body: RepaintBoundary(
      key: key,
      child: SizedBox(
        width: width,
        height: height,
        child: DecoratedBox(decoration: decoration),
      ),
    ),
  ),
);
void main() {
  testWidgets(
    'SVG uses one authenticated representation and stops painting after invalidation',
    (t) async {
      var current = true;
      final g = FakeGateway();
      g.handler = (method, args) async => {
        'bytes': utf8.encode(
          '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20" viewBox="0 0 40 20"><rect width="40" height="20" fill="red"/></svg>',
        ),
        'mimeType': 'image/svg+xml; charset=utf-8',
      };
      final image = NativeDocumentBackgroundImage(
        source: Uri.parse('relative.svg'),
        fetcher: gatewayImageFetcher(g),
        baseUrl: 'https://gateway.example/docs/',
        accountIdentity: 'a',
        owner: 'document',
        isCurrent: () => current,
      );
      final decoration = NativeHtmlImageBackgroundDecoration(
        BoxDecoration(
          color: Colors.white,
          image: DecorationImage(
            image: image,
            alignment: Alignment.topLeft,
            fit: BoxFit.none,
          ),
        ),
      );
      await t.pumpWidget(host(decoration, 100, 50));
      await color(t, 5, 5, [255, 0, 0, 255]);
      expect(g.calls.where((c) => c.$1 == 'image'), hasLength(1));
      expect(g.calls.single.$2['baseUrl'], 'https://gateway.example/docs/');
      current = false;
      t
          .renderObject<RenderDecoratedBox>(find.byType(DecoratedBox).first)
          .markNeedsPaint();
      await t.pump();
      expect(await pixel(t, 5, 5), [255, 255, 255, 255]);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'SVG viewport resize keeps absolute graphics and reveals clipped content without refetch',
    (t) async {
      final g = FakeGateway();
      g.handler = (method, args) async => {
        'bytes': utf8.encode(
          '<svg xmlns="http://www.w3.org/2000/svg"><rect width="100%" height="100%" fill="red"/><rect x="20" width="10" height="10" fill="blue"/><rect x="140" width="20" height="10" fill="lime"/></svg>',
        ),
        'mimeType': 'image/svg+xml',
      };
      final image = NativeDocumentBackgroundImage(
        source: Uri.parse('/resize.svg'),
        fetcher: gatewayImageFetcher(g),
        accountIdentity: 'a',
        owner: 'document',
        isCurrent: () => true,
      );
      final decoration = NativeHtmlImageBackgroundDecoration(
        BoxDecoration(
          color: Colors.white,
          image: DecorationImage(
            image: image,
            alignment: Alignment.topLeft,
            fit: BoxFit.none,
          ),
        ),
      );
      await t.pumpWidget(host(decoration, 120, 80));
      await color(t, 25, 5, [0, 0, 255, 255]);
      await t.pumpWidget(host(decoration, 240, 160));
      await color(t, 25, 5, [0, 0, 255, 255]);
      await color(t, 145, 5, [0, 255, 0, 255]);
      expect(g.calls.where((c) => c.$1 == 'image'), hasLength(1));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
