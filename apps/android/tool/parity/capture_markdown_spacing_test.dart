// Run capture_markdown_spacing_web.mjs first to generate the pinned DOM oracle.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

void main() {
  testWidgets('native top-level margins match measured pinned web blocks', (
    t,
  ) async {
    final web = jsonDecode(
      File('build/parity/markdown-spacing/web.json').readAsStringSync(),
    );
    await t.runAsync(loadParityFonts);
    addTearDown(t.view.reset);
    final output = <Object>[];
    for (final configuration in web['configurations']) {
      final width = (configuration['viewport']['width'] as num).toDouble();
      final scale = (configuration['textScale'] as num).toDouble();
      final brightness = configuration['theme'] == 'dark'
          ? Brightness.dark
          : Brightness.light;
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = Size(width, 1500);
      final data = theme.build(brightness);
      for (final row in configuration['cases']) {
        final blocks = row['blocks'] as List;
        if (blocks.any(
          (block) =>
              !['p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'].contains(block['tag']),
        )) {
          continue;
        }
        await t.pumpWidget(
          MaterialApp(
            theme: data.copyWith(
              textTheme: data.textTheme.apply(fontFamily: 'Arial'),
            ),
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 1500),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: NativeMarkdown(
                      source: row['source'],
                      lineHeight: 1.65,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        final rects = blocks
            .map(
              (block) => t.getRect(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is RichText &&
                      widget.text.toPlainText() == block['text'],
                ),
              ),
            )
            .toList();
        expect(rects.first.top, 16, reason: row['id']);
        expect(
          t.getRect(find.byType(NativeMarkdown)).bottom,
          rects.last.bottom,
          reason: 'No final block margin: ${row['id']}',
        );
        final gaps = <Object>[];
        for (var i = 1; i < rects.length; i++) {
          final actual = rects[i].top - rects[i - 1].bottom;
          final expected = (blocks[i]['gapBefore'] as num).toDouble();
          expect(
            actual,
            closeTo(expected, .035),
            reason: '${row['id']} width=$width scale=$scale block=$i',
          );
          gaps.add({
            'native': actual,
            'web': expected,
            'delta': actual - expected,
          });
        }
        output.add({
          'id': row['id'],
          'width': width,
          'scale': scale,
          'theme': configuration['theme'],
          'gaps': gaps,
          'blockHeights': [
            for (var i = 0; i < rects.length; i++)
              {'native': rects[i].height, 'web': blocks[i]['rect']['height']},
          ],
        });
        expect(t.takeException(), isNull);
      }
    }
    t.view.reset();
    File(
      'build/parity/markdown-spacing/native.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(output));
    expect(output.length, 40);
  });
}
