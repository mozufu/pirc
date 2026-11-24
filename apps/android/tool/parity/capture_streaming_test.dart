import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../../test/live_test.dart' show FakeGateway, theme;
import 'capture_fonts.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('streaming shared fixture ${brightness.name}', (t) async {
      final fixture = obj(
        jsonDecode(
          File(
            '../../fixtures/mobile-parity/streaming.json',
          ).readAsStringSync(),
        ),
      );
      await t.runAsync(loadParityFonts);
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = Size(
        (fixture['width'] as num).toDouble(),
        (fixture['height'] as num).toDouble(),
      );
      addTearDown(t.view.reset);
      final g = FakeGateway(),
          c = LiveController(g)..state = {'messages': fixture['messages']};
      final key = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.build(brightness),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    NativeMarkdown(
                      source: fixture['source'] as String,
                      streaming: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('markdown-stream-cursor')),
        findsOneWidget,
      );
      await t.runAsync(() async {
        final capture =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await capture.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('build/parity')..createSync(recursive: true);
        File(
          '${dir.path}/streaming-native-${brightness.name}.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
        capture.dispose();
      });
      await t.pumpWidget(const SizedBox());
      c.dispose();
      await g.stream.close();
    });
  }
}
