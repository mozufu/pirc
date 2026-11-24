// flutter test tool/parity/capture_markdown_links_test.dart
// Uses the same fixture and installed typeface as capture_web.mjs.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'capture_fonts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../../test/live_test.dart' show theme;

void main() {
  final fixture = jsonDecode(
    File('../../fixtures/mobile-parity/markdown-links.json').readAsStringSync(),
  );
  for (final width in fixture['widths']) {
    for (final brightness in Brightness.values) {
      testWidgets('markdown links $width ${brightness.name}', (t) async {
        await t.runAsync(loadParityFonts);
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = Size(
          (width as num).toDouble(),
          (fixture['height'] as num).toDouble(),
        );
        addTearDown(t.view.reset);
        final key = GlobalKey();
        final data = theme.build(brightness);
        await t.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: data.copyWith(
                textTheme: data.textTheme.apply(fontFamily: 'Arial'),
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: EdgeInsets.all(
                      (fixture['padding'] as num).toDouble(),
                    ),
                    child: NativeMarkdown(source: fixture['source']),
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.runAsync(() async {
          final capture =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final bytes = await capture.toByteData(
            format: ui.ImageByteFormat.png,
          );
          final dir = Directory('build/parity')..createSync(recursive: true);
          File(
            '${dir.path}/markdown-links-native-$width-${brightness.name}.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
          capture.dispose();
        });
      });
    }
  }
}
