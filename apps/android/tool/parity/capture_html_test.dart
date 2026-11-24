import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/markdown_image.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../../test/live_test.dart' show FakeGateway, theme;
import 'capture_fonts.dart';

void main() {
  final f = obj(
    jsonDecode(
      File('../../fixtures/mobile-parity/html.json').readAsStringSync(),
    ),
  );
  for (final width in f['widths'] as List) {
    for (final brightness in Brightness.values) {
      testWidgets('native HTML $width ${brightness.name}', (t) async {
        await t.runAsync(loadParityFonts);
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = Size(
          (width as num).toDouble(),
          (f['height'] as num).toDouble(),
        );
        addTearDown(t.view.reset);
        final key = GlobalKey(), g = FakeGateway();
        await t.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme.build(brightness),
              home: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final item in rows(f['cases']))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 20),
                          child: NativeMarkdown(
                            source: '${item['source']}',
                            lineHeight: 1.65,
                            imageBuilder: (uri, title, alt) =>
                                NativeMarkdownImage(
                                  gateway: g,
                                  source: uri,
                                  title: title,
                                  alt: alt,
                                ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.runAsync(() async {
          final capture =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await capture.toByteData(
            format: ui.ImageByteFormat.png,
          );
          final file = File(
            'build/parity/html-native-$width-${brightness.name}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          capture.dispose();
        });
        await t.pumpWidget(const SizedBox());
        await g.stream.close();
      });
    }
  }
}
