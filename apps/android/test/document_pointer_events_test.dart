import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/document_layout.dart';
import 'live_test.dart' show theme;
import 'native_html_document_layout_test.dart' show prepareNativeLayoutDocument;

final fixture =
    jsonDecode(
          File(
            'tool/parity/fixtures/document-pointer-events-chromium153.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;
void main() {
  for (final row in fixture['cases'] as List) {
    testWidgets(
      'pointer-events ${row['name']} ${row['viewport']['width']} dpr${row['dpr']} ${row['theme']}',
      (tester) async {
        final width = (row['viewport']['width'] as num).toDouble(),
            height = (row['viewport']['height'] as num).toDouble(),
            dpr = (row['dpr'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(width * dpr, height * dpr);
        addTearDown(tester.view.reset);
        final key = GlobalKey(), identity = Object();
        final hits = <String>[];
        final controller = NativeDocumentLayoutController();
        addTearDown(controller.dispose);
        var revision = 0;
        for (final step in row['steps'] as List) {
          if (step['action'] != 'tap') continue;
          final document = html.parse(step['html'] as String), ids = <String>{};
          for (final element in document.querySelectorAll('[id]')) {
            ids.add(element.id);
            element.attributes['data-pirc-script-click'] = '';
          }
          final prepared = prepareNativeLayoutDocument({
            'html': document.outerHtml,
            'targets': ids.toList(),
            'viewportWidth': width,
          });
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
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
                        fontFamily: 'monospace',
                        fontSize: 16,
                        height: 1.25,
                        color: Colors.black,
                        letterSpacing: 0,
                      ),
                      styles: fm.MarkdownStyleSheet(),
                      builders: const {},
                      markdownStyles: false,
                      scriptDocument: identity,
                      imageViewport: Size(width, height),
                      onScriptClick: (id, controls) async {
                        hits.add(id);
                        return true;
                      },
                      authorStylesBuilder: (e) =>
                          prepared.stylesByKey[e
                              .attributes['data-pirc-document-style']],
                      layoutController: controller,
                      layoutRevision: ++revision,
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
          if (row['name'] == 'button_restore') {
            final button = find.byWidgetPredicate(
              (w) => w is NativeHtmlButtonWidget && w.button.label == 'Tap',
            );
            expect(tester.getRect(button), const Rect.fromLTWH(20, 20, 90, 40));
          }
          hits.clear();
          final point = step['point'];
          await tester.tapAt(
            Offset(
              (point['x'] as num).toDouble(),
              (point['y'] as num).toDouble(),
            ),
          );
          await tester.pumpAndSettle();
          expect(hits, [
            step['target'],
          ], reason: '${row['name']} ${step['point']}');
        }
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = (await tester.runAsync(
          () => boundary.toImage(pixelRatio: dpr),
        ))!;
        try {
          final data = (await tester.runAsync(
            () => image.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
          ))!;
          final probe = row['paint'];
          final x = ((probe['x'] as num) * dpr).floor(),
              y = ((probe['y'] as num) * dpr).floor(),
              offset = (y * image.width + x) * 4;
          expect(
            data.buffer.asUint8List().sublist(offset, offset + 4),
            probe['rgba'],
            reason: 'pointer-events must not hide painted overlay',
          );
        } finally {
          image.dispose();
        }
      },
    );
  }
}
