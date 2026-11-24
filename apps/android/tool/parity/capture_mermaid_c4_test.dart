import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/c4_parser.dart';
import 'package:pirc_render/src/mermaid/c4_rendering.dart';

void main() {
  testWidgets('capture native C4 phone/tablet figures', (t) async {
    await t.runAsync(() async {
      final font = FontLoader('C4 capture Arial')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '/System/Library/Fonts/Supplemental/Arial.ttf',
              ).readAsBytes(),
            ),
          ),
        )
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '/System/Library/Fonts/Supplemental/Arial Bold.ttf',
              ).readAsBytes(),
            ),
          ),
        );
      await font.load();
    });
    final fixture =
        jsonDecode(
              File(
                '../../fixtures/mobile-parity/mermaid-c4-parser-expected.json',
              ).readAsStringSync(),
            )
            as Map;
    final cases = (fixture['cases'] as List).cast<Map>();
    final out = Directory('build/parity/c4-native');
    out.createSync(recursive: true);
    for (final config in [
      (390.0, false, 'context-title-person-system-external'),
      (768.0, true, 'container-db-queue-nested-boundaries'),
    ]) {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = Size(config.$1, 2400);
      final source =
          cases.singleWhere((c) => c['id'] == config.$3)['source'] as String;
      const key = ValueKey('c4-capture');
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: config.$2 ? const Color(0xff16181c) : Colors.white,
            body: SingleChildScrollView(
              child: RepaintBoundary(
                key: key,
                child: Padding(
                  padding: const EdgeInsets.all(29),
                  child: NativeMermaidC4(
                    diagram: parseNativeMermaidC4(source),
                    dark: config.$2,
                    fontFamily: 'C4 capture Arial',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      await t.runAsync(() async {
        final image = await t
            .renderObject<RenderRepaintBoundary>(find.byKey(key))
            .toImage(pixelRatio: 1);
        try {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            '${out.path}/${config.$3}-${config.$1.toInt()}-${config.$2 ? 'dark' : 'light'}.png',
          ).writeAsBytesSync(png!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      expect(t.takeException(), isNull);
    }
    t.view.reset();
  });
}
