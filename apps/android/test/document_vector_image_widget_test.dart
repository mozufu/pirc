import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_html_image.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_render/src/native_image_frame.dart';
import 'live_test.dart' show theme;

void main() {
  testWidgets('owned SVG stays vector sharp when enlarged beyond the Canvas bitmap', (
    t,
  ) async {
    final paintKey = GlobalKey();
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final source = Uint8List.fromList(
      utf8.encode(
        '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2" viewBox="0 0 2 2"><path d="M0 0H2L0 2Z" fill="red"/><path d="M2 0V2H0Z" fill="blue"/></svg>',
      ),
    ).asUnmodifiableView();
    var fetches = 0;
    await t.pumpWidget(
      RepaintBoundary(
        key: paintKey,
        child: MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: NativeHtmlDocument(
              nodes: [
                NativeHtmlRaw(
                  '<img data-pirc-script-id="pirc-1" src="/vector.svg" alt="Diagonal" title="Vector" style="display:block;width:128px;height:128px">',
                ),
              ],
              style: const TextStyle(fontSize: 16),
              styles: MarkdownStyleSheet(),
              builders: const {},
              markdownStyles: false,
              htmlImages: const {
                'pirc-1': NativeDocumentHtmlImage(
                  status: 'loaded',
                  imageId: 'owned',
                  vector: true,
                ),
              },
              vectorImageSources: {'owned': source},
              imageBuilder: (_, _, _) {
                fetches++;
                return const Text('unexpected fetch');
              },
            ),
          ),
        ),
      ),
    );
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await t.pumpAndSettle();
    expect(fetches, 0);
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
    final rect = t.getRect(find.byType(NativeImageFrame));
    expect(rect.size, const Size(128, 128));
    final image = (await t.runAsync(
      () =>
          t.renderObject<RenderRepaintBoundary>(find.byKey(paintKey)).toImage(),
    ))!;
    try {
      final pixels = (await t.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
      ))!;
      List<int> pixel(int x, int y) {
        final start =
            ((rect.top.toInt() + y) * image.width + rect.left.toInt() + x) * 4;
        return [for (var c = 0; c < 4; c++) pixels.getUint8(start + c)];
      }

      // These locations lie inside the same source bitmap texel. Distinct colors
      // prove the enlarged HTML image was painted as a vector, not a 2x2 bitmap.
      expect(pixel(8, 72), [255, 0, 0, 255]);
      expect(pixel(56, 120), [0, 0, 255, 255]);
    } finally {
      image.dispose();
    }
    expect(t.takeException(), isNull);
  });
}
