import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/document_absolute_position.dart';
import 'live_test.dart' show theme;
import 'native_html_document_layout_test.dart' show prepareNativeLayoutDocument;

void main() {
  for (final short in [false, true]) {
    testWidgets('fixed stays in viewport and receives taps; short=$short', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final scroll = ScrollController(),
          layout = NativeDocumentLayoutController(),
          hits = <String>[];
      addTearDown(scroll.dispose);
      addTearDown(layout.dispose);
      final prepared = prepareNativeLayoutDocument(
        {
          'html':
              '<html><head><style>html,body{margin:0;padding:0}</style></head><body><div id="flow" style="height:${short ? 40 : 1800}px"></div><div id="fixed" data-pirc-script-click="" style="position:fixed;left:17px;${short ? 'bottom:20px' : 'top:23px'};width:60px;height:40px;background:#3b82f6"></div></body></html>',
          'targets': ['flow', 'fixed'],
          'viewportWidth': 390,
        },
        viewportHeight: 844,
        devicePixelRatio: 1,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: NativeDocumentPositioningViewport(
              scrollChanges: scroll,
              child: SingleChildScrollView(
                controller: scroll,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 844),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      NativeHtmlDocument(
                        nodes: [NativeHtmlRaw(prepared.markup)],
                        style: const TextStyle(fontSize: 16),
                        styles: fm.MarkdownStyleSheet(),
                        builders: const {},
                        markdownStyles: false,
                        imageViewport: const Size(390, 844),
                        authorStylesBuilder: (e) =>
                            prepared.stylesByKey[e
                                .attributes['data-pirc-document-style']],
                        layoutController: layout,
                        layoutRevision: 1,
                        layoutKnownIds: const {'flow', 'fixed'},
                        layoutNoBoxIds: prepared.noBoxIds,
                        onScriptClick: (id, controls) async {
                          hits.add(id);
                          return true;
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final y = short ? 784.0 : 23.0;
      Future<void> check() async {
        final packet = layout.capture(
          revision: 1,
          generation: 1,
          viewport: const Size(390, 844),
          scrollOffset: Offset(0, scroll.offset),
        )!;
        final fixed = (packet['boxes'] as List).cast<Map>().singleWhere(
          (b) => b['id'] == 'fixed',
        );
        expect(fixed['kind'], 'box');
        expect(fixed['x'], 17);
        expect((fixed['y'] as num) - scroll.offset, y);
        expect(fixed['width'], 60);
        expect(fixed['height'], 40);
        expect(
          layout.hitTestDocument(Offset(30, y + 10), revision: 1)?.elementId,
          'fixed',
        );
        await tester.tapAt(Offset(30, y + 10));
        await tester.pumpAndSettle();
        expect(hits.last, 'fixed');
      }

      expect(scroll.position.maxScrollExtent, short ? 0 : 956);
      await check();
      if (!short) {
        scroll.jumpTo(180);
        await tester.pumpAndSettle();
        await check();
      }
      expect(tester.takeException(), isNull);
    });
  }
}
