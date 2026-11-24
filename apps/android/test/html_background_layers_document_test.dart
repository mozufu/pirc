import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'document_navigation_widget_test.dart' show DocumentGateway, response;
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/html_background_layers.dart';
import 'package:pirc_render/src/html_gradient_decoration.dart';
import 'package:pirc_render/src/html_image_background_decoration.dart';

import 'live_test.dart' show theme;

const _viewportKey = ValueKey('html-background-document-viewport');

Widget _host(NativeDocumentWindows windows, Brightness brightness) =>
    MaterialApp(
      theme: theme.build(brightness),
      home: RepaintBoundary(
        key: _viewportKey,
        child: NativeDocumentWorkspace(windows: windows, managed: true),
      ),
    );

Future<List<int>> _pixelAt(WidgetTester tester, Offset globalPoint) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_viewportKey),
  );
  final origin = tester.getTopLeft(find.byKey(_viewportKey));
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    final bytes = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    final point = globalPoint - origin;
    final x = point.dx.floor(), y = point.dy.floor();
    expect(x, inInclusiveRange(0, image.width - 1));
    expect(y, inInclusiveRange(0, image.height - 1));
    final offset = (y * image.width + x) * 4;
    return bytes.sublist(offset, offset + 4);
  } finally {
    image.dispose();
  }
}

void main() {
  for (final brightness in Brightness.values) {
    for (final empty in [false, true]) {
      testWidgets(
        'fetched HTML keeps multi-layer CSS dimensions and sibling backgrounds in $brightness empty=$empty',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(390, 844);
          addTearDown(tester.view.reset);

          const rootOnly =
              '<div id="layered" style="width:120px;height:80px;'
              'background-image:linear-gradient(to right,rgba(255,0,0,.5),rgba(255,0,0,.5)),'
              'linear-gradient(to right,#0000ff,#0000ff);'
              'background-repeat:no-repeat,no-repeat">Layered foreground</div>';
          final svg = Uri.dataFromString(
            '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">'
            '<rect width="8" height="8" fill="#16a085"/></svg>',
            mimeType: 'image/svg+xml',
          );
          const comparison =
              '<div id="gradient" style="width:120px;height:80px;'
              'background-image:linear-gradient(to right,red,blue)">'
              'Gradient foreground</div>'
              '<div id="image" style="width:100px;height:60px;'
              'background-image:url(IMAGE_URI);background-repeat:no-repeat">'
              'Image foreground</div>'
              '<div style="width:32px;height:24px;background-color:#e31273">'
              'First sibling</div>'
              '<div style="width:46px;height:28px;background-color:#176de0">'
              'Second sibling</div>';
          final gateway = DocumentGateway()
            ..responses.addAll([
              response(
                '/layered',
                '<!doctype html><html><head><style>html,body{margin:0;padding:0}</style></head><body>${empty ? rootOnly.replaceAll('Layered foreground', '') : rootOnly}</body></html>',
              ),
              response(
                '/comparison',
                comparison.replaceFirst('IMAGE_URI', svg.toString()),
              ),
            ]);
          final windows = NativeDocumentWindows(gateway);
          addTearDown(windows.dispose);
          final window = windows.target(
            '',
            null,
            sourceUrl: 'https://gateway.example/layered',
          );

          Future<void> load(String path) async {
            expect(
              await window.load(
                NativeHtmlFormRequest(url: path, method: 'GET', target: ''),
                baseUrl: 'https://gateway.example/',
              ),
              NativeDocumentLoadResult.committed,
            );
            windows.select(window);
            await tester.pumpWidget(_host(windows, brightness));
            await tester.pumpAndSettle();
          }

          await load('/layered');
          final layered = find.byWidgetPredicate(
            (widget) =>
                widget is Container &&
                widget.decoration is NativeHtmlLayeredBackgroundDecoration,
          );
          expect(layered, findsOneWidget);
          expect(tester.getSize(layered), const Size(120, 80));
          if (!empty) {
            expect(
              find.textContaining('Layered foreground', findRichText: true),
              findsOneWidget,
            );
          }

          final layeredRect = tester.getRect(layered);
          final inside = (await tester.runAsync(
            () => _pixelAt(
              tester,
              Offset(layeredRect.left + 6, layeredRect.top + 64),
            ),
          ))!;
          expect(inside[0], greaterThan(80));
          expect(inside[2], greaterThan(80));
          final outside = (await tester.runAsync(
            () => _pixelAt(
              tester,
              Offset(layeredRect.left + 6, layeredRect.bottom + 12),
            ),
          ))!;
          expect(
            outside,
            [255, 255, 255, 255],
            reason: 'the multi-layer paint must stop at its CSS 80px height',
          );

          await load('/comparison');
          final gradient = find.byWidgetPredicate(
            (widget) =>
                widget is Container &&
                widget.decoration is NativeHtmlGradientBoxDecoration,
          );
          final image = find.byWidgetPredicate(
            (widget) =>
                widget is Container &&
                widget.decoration is NativeHtmlImageBackgroundDecoration,
          );
          expect(gradient, findsOneWidget);
          expect(image, findsOneWidget);
          expect(tester.getSize(gradient), const Size(120, 80));
          expect(tester.getSize(image), const Size(100, 60));
          expect(
            find.textContaining('Gradient foreground', findRichText: true),
            findsOneWidget,
          );
          expect(
            find.textContaining('Image foreground', findRichText: true),
            findsOneWidget,
          );

          final firstSibling = find.byWidgetPredicate(
            (widget) =>
                widget is Container &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).color ==
                    const Color(0xffe31273),
          );
          final secondSibling = find.byWidgetPredicate(
            (widget) =>
                widget is Container &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).color ==
                    const Color(0xff176de0),
          );
          expect(firstSibling, findsOneWidget);
          expect(secondSibling, findsOneWidget);
          expect(tester.getSize(firstSibling), const Size(32, 24));
          expect(tester.getSize(secondSibling), const Size(46, 28));
          expect(
            tester.getRect(firstSibling).bottom,
            lessThanOrEqualTo(tester.getRect(secondSibling).top),
            reason: 'sibling backgrounds remain in their own layout boxes',
          );
          expect(
            find.textContaining('First sibling', findRichText: true),
            findsOneWidget,
          );
          expect(
            find.textContaining('Second sibling', findRichText: true),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
