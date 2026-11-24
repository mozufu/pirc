import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/code_block.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

void main() {
  testWidgets('capture native code block geometry', (t) async {
    final fixture = jsonDecode(
      File(
        '../../fixtures/mobile-parity/code-geometry.json',
      ).readAsStringSync(),
    );
    final web = jsonDecode(
      File('build/parity/code-geometry/web.json').readAsStringSync(),
    );
    expect(web['revision'], fixture['webRevision']);
    await t.runAsync(loadParityFonts);
    addTearDown(t.view.reset);
    final cases = <Object>[];
    Map<String, double> rect(Rect r) => {
      'x': r.left,
      'y': r.top,
      'width': r.width,
      'height': r.height,
    };
    for (final width in [390.0, 768.0]) {
      for (final brightness in Brightness.values) {
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = Size(width, 1500);
        final data = theme.build(brightness);
        for (final row in fixture['cases']) {
          await t.pumpWidget(
            MaterialApp(
              theme: data.copyWith(
                textTheme: data.textTheme.apply(fontFamily: 'Arial'),
              ),
              home: Scaffold(
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
          );
          await t.pumpAndSettle();
          final code = find.byType(NativeCodeBlock);
          final pre = find.descendant(
            of: code,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is SingleChildScrollView &&
                  w.scrollDirection == Axis.horizontal,
            ),
          );
          final copy = find.descendant(
            of: code,
            matching: find.byType(TextButton),
          );
          final blockRect = t.getRect(code), preRect = t.getRect(pre);
          final source = t.widget<NativeCodeBlock>(code).source;
          final reference = (web['configurations'] as List).singleWhere(
            (c) =>
                c['viewport']['width'] == width &&
                c['theme'] == brightness.name &&
                c['touch'] == true,
          );
          final expected = (reference['cases'] as List).singleWhere(
            (c) => c['id'] == row['id'],
          );
          expect(source, expected['codeText']);
          expect(
            preRect.top - blockRect.top,
            expected['codeHead']['rect']['height'],
          );
          expect(
            t.getSize(copy).height,
            expected['codeCopy']['rect']['height'],
          );
          final bodyDelta =
              preRect.height - (expected['pre']['rect']['height'] as num);
          final scroll = t.state<ScrollableState>(
            find.descendant(of: pre, matching: find.byType(Scrollable)),
          );
          final scrollWidth =
              scroll.position.viewportDimension +
              scroll.position.maxScrollExtent;
          final tabs = <Object>[];
          if (source.contains('\t')) {
            final paragraph = t.renderObject<RenderParagraph>(
              find.descendant(of: pre, matching: find.byType(RichText)),
            );
            for (final tab in expected['tabs']) {
              final offset = tab['offset'] as int;
              final box = paragraph
                  .getBoxesForSelection(
                    TextSelection(baseOffset: offset, extentOffset: offset + 1),
                  )
                  .single;
              final x =
                  paragraph.localToGlobal(Offset(box.left, box.top)).dx -
                  preRect.left;
              final advance = box.right - box.left;
              expect(
                x,
                closeTo((tab['x'] as num).toDouble(), .04),
                reason: '${row['id']} tab offset=$offset x',
              );
              expect(
                advance,
                closeTo((tab['width'] as num).toDouble(), .04),
                reason: '${row['id']} tab offset=$offset width',
              );
              tabs.add({
                'offset': offset,
                'nativeX': x,
                'webX': tab['x'],
                'nativeWidth': advance,
                'webWidth': tab['width'],
              });
            }
            expect(scrollWidth.round(), expected['pre']['box']['scrollWidth']);
          }
          cases.add({
            'id': row['id'],
            'width': width,
            'theme': brightness.name,
            'source': source,
            'bodyDelta': bodyDelta,
            'tabs': tabs,
            'bodyHeightAccepted': bodyDelta.abs() < .035,
            'nativeScrollWidth': scrollWidth,
            'webScrollWidth': expected['pre']['box']['scrollWidth'],
            'block': rect(blockRect),
            'pre': rect(preRect),
            'copy': rect(t.getRect(copy)),
            'headerHeight': preRect.top - blockRect.top,
          });
          if (source.endsWith('\n')) {
            // The fixture uses Menlo 13 / 1.6: native rounds each line to 21px.
            // Check removal of the phantom line independently of CSS rounding.
            expect(preRect.height, 24 + 21 * (source.split('\n').length - 1));
          }
          if (source.isEmpty) {
            expect(bodyDelta, 0);
          }
          expect(t.takeException(), isNull);
        }
      }
    }
    final directory = Directory('build/parity/code-geometry')
      ..createSync(recursive: true);
    File(
      '${directory.path}/native.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(cases));
  });
}
