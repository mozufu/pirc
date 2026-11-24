import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_html_image.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'live_test.dart' show theme;

void main() {
  final cases = {
    'owned raster': (
      '<img data-pirc-script-id="pirc-1" src="/base.png">',
      null,
    ),
    'responsive srcset': (
      '<img data-pirc-script-id="pirc-1" src="/base.png" srcset="/selected.png 2x">',
      '/selected.png',
    ),
    'picture selection': (
      '<picture><source srcset="/picture.png 2x"><img data-pirc-script-id="pirc-1" src="/base.png"></picture>',
      '/picture.png',
    ),
    'animated image': (
      '<img data-pirc-script-id="pirc-1" src="/animated.gif">',
      '/animated.gif',
    ),
    'script image error': (
      '<img data-pirc-script-id="pirc-1" src="/image-error.png">',
      '/image-error.png',
    ),
    'SVG vector': (
      '<img data-pirc-script-id="pirc-1" src="/base.svg">',
      '/base.svg',
    ),
  };
  for (final entry in cases.entries) {
    testWidgets('managed image preserves ${entry.key}', (t) async {
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final image = (await t.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawRect(
          const ui.Rect.fromLTWH(0, 0, 2, 2),
          ui.Paint()..color = const ui.Color(0xffff0000),
        );
        final picture = recorder.endRecording();
        try {
          return await picture.toImage(2, 2);
        } finally {
          picture.dispose();
        }
      }))!;
      try {
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Scaffold(
              body: NativeHtmlDocument(
                nodes: [NativeHtmlRaw(entry.value.$1)],
                style: const TextStyle(fontSize: 16),
                styles: MarkdownStyleSheet(),
                builders: const {},
                markdownStyles: false,
                htmlImages: {
                  'pirc-1': NativeDocumentHtmlImage(
                    status: entry.key == 'script image error'
                        ? 'error'
                        : 'loaded',
                    imageId: entry.key == 'script image error' ? null : 'owned',
                    vector: entry.key == 'SVG vector',
                    animated: entry.key == 'animated image',
                  ),
                },
                canvasImages: {'owned': image},
                imageBuilder: (uri, title, alt) => Text(uri.path),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        if (entry.value.$2 == null) {
          expect(find.byType(RawImage), findsOneWidget);
          expect(find.text('/base.png'), findsNothing);
        } else {
          expect(find.text(entry.value.$2!), findsOneWidget);
          expect(find.byType(RawImage), findsNothing);
        }
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        image.dispose();
      }
    });
  }
}
