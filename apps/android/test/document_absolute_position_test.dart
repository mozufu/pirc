import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/document_layout.dart';
import 'live_test.dart' show theme;
import 'native_html_document_layout_test.dart' show prepareNativeLayoutDocument;

final fixture =
    jsonDecode(
          File(
            'tool/parity/fixtures/document-absolute-chromium153.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;
void main() {
  for (final row in fixture['cases'] as List) {
    testWidgets(
      'native absolute ${row['name']} ${row['width']} dpr${row['dpr']} ${row['theme']}',
      (tester) async {
        final width = (row['width'] as num).toDouble(),
            height = width == 390 ? 844.0 : 1024.0,
            dpr = (row['dpr'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(width * dpr, height * dpr);
        addTearDown(tester.view.reset);
        final observed = Map<String, dynamic>.from(row['observed']);
        final ids = observed.keys.toSet();
        final prepared = prepareNativeLayoutDocument({
          ...Map<String, dynamic>.from(row),
          'targets': ids.toList(),
          'viewportWidth': width,
        });
        final controller = NativeDocumentLayoutController();
        addTearDown(controller.dispose);
        final paintKey = GlobalKey();
        final hits = <String>[];
        await tester.pumpWidget(
          RepaintBoundary(
            key: paintKey,
            child: MaterialApp(
              theme: theme.build(
                row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
              ),
              home: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  height: height,
                  child: NativeHtmlDocument(
                    nodes: [NativeHtmlRaw(prepared.markup)],
                    style: const TextStyle(
                      inherit: false,
                      fontSize: 16,
                      height: 1,
                      color: Colors.black,
                      letterSpacing: 0,
                    ),
                    styles: fm.MarkdownStyleSheet(),
                    builders: const {},
                    markdownStyles: false,
                    onScriptClick: (id, controls) async {
                      hits.add(id);
                      return true;
                    },
                    imageViewport: Size(width, height),
                    authorStylesBuilder: (element) =>
                        prepared.stylesByKey[element
                            .attributes['data-pirc-document-style']],
                    layoutController: controller,
                    layoutRevision: 1,
                    layoutKnownIds: ids,
                    layoutNoBoxIds: prepared.noBoxIds,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final packet = controller.capture(
          revision: 1,
          generation: 1,
          viewport: Size(width, height),
        );
        final boxes = {
          for (final box in packet!['boxes'] as List) box['id']: box,
        };
        final boundary =
            paintKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = (await tester.runAsync(
          () => boundary.toImage(pixelRatio: dpr),
        ))!;
        try {
          final data = (await tester.runAsync(
            () => image.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
          ))!;
          final bytes = data.buffer.asUint8List();
          for (final sample in row['pixels'] as List) {
            final x = ((sample['x'] as num) * dpr).floor(),
                y = ((sample['y'] as num) * dpr).floor();
            final offset = (y * image.width + x) * 4;
            expect(
              bytes.sublist(offset, offset + 4),
              sample['rgba'],
              reason: '${row['name']} ${sample['name']} painted pixel',
            );
          }
        } finally {
          image.dispose();
        }
        for (final sample in row['pixels'] as List) {
          hits.clear();
          await tester.tapAt(
            Offset(
              (sample['x'] as num).toDouble(),
              (sample['y'] as num).toDouble(),
            ),
          );
          await tester.pump();
          expect(
            hits,
            sample['hit'] == null ? isEmpty : [sample['hit']],
            reason: '${row['name']} ${sample['name']} native hit',
          );
        }
        for (final id in ids) {
          expect(boxes.containsKey(id), isTrue, reason: 'missing $id $packet');
          for (final axis in ['x', 'y', 'width', 'height']) {
            expect(
              (boxes[id][axis] as num).toDouble(),
              closeTo(
                (observed[id][axis] as num).toDouble(),
                row['name'] == 'own_content-box'
                    ? 1 / 32
                    : const {'percent', 'margins'}.contains(row['name'])
                    ? 1 / 64
                    : .01,
              ),
              reason: '$id.$axis ${row['name']}',
            );
          }
        }
      },
    );
  }
}
