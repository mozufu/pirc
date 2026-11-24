// Requires capture_markdown_spacing_web.mjs's pinned DOM measurements.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

void main() {
  testWidgets('nested list and quote spacing follows pinned DOM', (t) async {
    final web = jsonDecode(
      File('build/parity/markdown-spacing/web.json').readAsStringSync(),
    );
    await t.runAsync(loadParityFonts);
    addTearDown(t.view.reset);
    final output = <Object>[];
    for (final config in web['configurations']) {
      final width = (config['viewport']['width'] as num).toDouble();
      final scale = (config['textScale'] as num).toDouble();
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = Size(width, 1500);
      final data = theme.build(
        config['theme'] == 'dark' ? Brightness.dark : Brightness.light,
      );
      for (final row in config['cases']) {
        final id = row['id'];
        if (![
          'tight-list',
          'loose-list',
          'nested-list',
          'blockquote',
          'quote-heading',
          'list-first-heading',
          'list-last-heading',
        ].contains(id)) {
          continue;
        }
        final blocks = row['blocks'] as List;
        final List<dynamic> leaves;
        if (id == 'quote-heading') {
          leaves = blocks.first['children'];
        } else if (id == 'list-first-heading' || id == 'list-last-heading') {
          final li = blocks.first['children'].first;
          leaves = [...li['children']];
          if (id == 'list-first-heading') {
            // Marked emits this fixture's final text as an anonymous line,
            // rather than a p element. It is one unwrapped line at all widths.
            final tail = Map<String, dynamic>.from(li['rect']);
            tail['top'] =
                (tail['bottom'] as num) -
                double.parse((li['lineHeight'] as String).replaceAll('px', ''));
            leaves.add({'text': 'Tail paragraph', 'rect': tail});
          }
        } else if (id == 'tight-list') {
          leaves = blocks.first['children'];
        } else if (id == 'loose-list') {
          leaves = [
            for (final li in blocks.first['children']) li['children'].first,
          ];
        } else if (id == 'nested-list') {
          final outer = blocks.first['children'];
          final first = outer.first;
          // The fixture's outer item starts with one unwrapped anonymous line.
          final rect = Map<String, dynamic>.from(first['rect']);
          rect['bottom'] =
              (rect['top'] as num) +
              double.parse(
                (first['lineHeight'] as String).replaceAll('px', ''),
              );
          leaves = [
            {'text': 'Outer item one', 'rect': rect},
            ...first['children'].first['children'],
            outer.last,
          ];
        } else {
          leaves = [blocks.first, ...blocks[1]['children'], blocks.last];
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
        final rects = leaves
            .map(
              (leaf) => t.getRect(
                find.byWidgetPredicate(
                  (w) => w is RichText && w.text.toPlainText() == leaf['text'],
                ),
              ),
            )
            .toList();
        final nativeBox = t.getRect(find.byType(NativeMarkdown));
        final startEdge = rects.first.top - nativeBox.top;
        final endEdge = nativeBox.bottom - rects.last.bottom;
        final webStart =
            (leaves.first['rect']['top'] as num) -
            (row['rect']['top'] as num) -
            16;
        final webEnd =
            (row['rect']['bottom'] as num) -
            16 -
            (leaves.last['rect']['bottom'] as num);
        expect(
          startEdge,
          closeTo(webStart.toDouble(), .035),
          reason: '$id $width/$scale first descendant margin',
        );
        expect(
          endEdge,
          closeTo(webEnd.toDouble(), .035),
          reason: '$id $width/$scale final descendant margin',
        );
        final differences = <Object>[];
        for (var i = 0; i < rects.length; i++) {
          final expected = leaves[i]['rect'];
          expect(
            rects[i].left,
            closeTo((expected['left'] as num).toDouble(), .035),
            reason: '$id $width/$scale indent $i',
          );
          if (i == 0) continue;
          final gap = rects[i].top - rects[i - 1].bottom;
          final webGap =
              (expected['top'] as num) -
              (leaves[i - 1]['rect']['bottom'] as num);
          expect(
            gap,
            closeTo(webGap.toDouble(), .035),
            reason: '$id $width/$scale gap $i',
          );
          differences.add({
            'native': gap,
            'web': webGap,
            'delta': gap - webGap,
          });
        }
        expect(t.takeException(), isNull);
        output.add({
          'id': id,
          'acceptance': 'spacing and indentation accepted',
          'width': width,
          'scale': scale,
          'theme': config['theme'],
          'gaps': differences,
          'edges': {
            'start': startEdge,
            'webStart': webStart,
            'end': endEdge,
            'webEnd': webEnd,
          },
        });
      }
    }
    expect(output.length, 56);
    File(
      'build/parity/markdown-spacing/native-nested.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(output));
  });
}
