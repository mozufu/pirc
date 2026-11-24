import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

void main() {
  final f = obj(
    jsonDecode(
      File(
        '../../fixtures/mobile-parity/syntax-highlighting.json',
      ).readAsStringSync(),
    ),
  );
  for (final width in f['widths'] as List) {
    for (final brightness in Brightness.values) {
      testWidgets('native syntax highlighting $width ${brightness.name}', (
        t,
      ) async {
        await t.runAsync(loadParityFonts);
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = Size(
          (width as num).toDouble(),
          (f['height'] as num).toDouble(),
        );
        addTearDown(t.view.reset);
        final key = GlobalKey();
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
                      for (final item in rows(
                        f['cases'],
                      ).where((e) => e['visual'] == true))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 20),
                          child: NativeMarkdown(
                            source:
                                '~~~${item['language']}\n${item['code']}\n~~~',
                            lineHeight: 1.65,
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
            'build/parity/syntax-highlighting-native-$width-${brightness.name}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          capture.dispose();
        });
        await t.pumpWidget(const SizedBox());
      });
    }
  }
}
