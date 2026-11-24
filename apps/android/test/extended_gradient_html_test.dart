import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'live_test.dart' show FakeGateway, theme;

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-extended-background-gradients.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final input in [
    ...(fixture['cases'] as List),
    ...(fixture['layers'] as List),
  ]) {
    for (final normalized in [false, true]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'HTML ${input['id']} normalized=$normalized ${brightness.name}',
          (t) async {
            final width = (input['width'] as num).toDouble(),
                height = (input['height'] as num).toDouble();
            final g = FakeGateway();
            var source =
                '<div id="gradient" style="width:${width}px;height:${height}px;background-image:${input['css']}"></div>';
            if (normalized) {
              final document = html.parse(source);
              final result = NativeDocumentStyleEngine(
                stylesheets: [],
                viewportWidth: 390,
                dark: brightness == Brightness.dark,
              ).apply(document);
              expect(result.diagnostics, isEmpty);
              source = document.querySelector('#gradient')!.outerHtml;
            }
            await t.pumpWidget(
              MaterialApp(
                theme: theme.build(brightness),
                home: Scaffold(
                  body: RepaintBoundary(
                    key: const ValueKey('gradient-capture'),
                    child: SizedBox(
                      width: width,
                      height: height,
                      child: RichTextBody(source, gateway: g),
                    ),
                  ),
                ),
              ),
            );
            await t.pumpAndSettle();
            final pixels = await t.runAsync(() async {
              final image = await t
                  .renderObject<RenderRepaintBoundary>(
                    find.byKey(const ValueKey('gradient-capture')),
                  )
                  .toImage(pixelRatio: 1);
              try {
                final bytes = (await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                ))!.buffer.asUint8List();
                return [
                  for (final p in input['samples'] as List)
                    _rgba(
                      bytes,
                      ((p['y'] as int) * image.width + (p['x'] as int)) * 4,
                    ),
                ];
              } finally {
                image.dispose();
              }
            });
            final samples = input['samples'] as List;
            for (var i = 0; i < samples.length; i++) {
              final expected = samples[i]['rgba'] as List;
              for (var channel = 0; channel < 4; channel++) {
                expect(
                  (pixels![i][channel] - expected[channel]).abs(),
                  lessThanOrEqualTo(4),
                  reason:
                      '${input['id']} point $i channel $channel: ${pixels[i]} vs $expected',
                );
              }
            }
            expect(t.takeException(), isNull);
            await t.pumpWidget(const SizedBox());
            await g.stream.close();
          },
        );
      }
    }
  }
}

List<int> _rgba(List<int> bytes, int offset) {
  final alpha = bytes[offset + 3];
  if (alpha == 0) return [0, 0, 0, 0];
  return [
    for (var i = 0; i < 3; i++)
      ((bytes[offset + i] * 255 + alpha / 2) / alpha).round().clamp(0, 255),
    alpha,
  ];
}
