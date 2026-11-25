@Tags(['tier3'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render_document/src/document_computed_styles.dart';
import 'package:pirc_render/src/document_element_scroll.dart';
import 'package:pirc_render/src/document_layout.dart';

void main() {
  test(
    'scroll geometry proof excludes sticky and unknown positioning ancestry',
    () {
      final doc = html.parse(
        '<!doctype html><html><body><div id="sticky" data-pirc-script-id="sticky"><div data-pirc-script-id="child"></div></div><div data-pirc-script-id="normal"></div></body></html>',
      );
      final specs = nativeDocumentComputedStyleSpecs(
        document: doc,
        stylesByElement: {
          doc.getElementById('sticky')!: {'position': 'sticky'},
        },
        viewportWidth: 390,
        viewportHeight: 844,
      );
      expect(specs['sticky']!.scrollTranslationSupported, isFalse);
      expect(specs['child']!.scrollTranslationSupported, isFalse);
      expect(specs['normal']!.scrollTranslationSupported, isTrue);
    },
  );
  for (final scale in [1.0, 1.5]) {
    testWidgets(
      'serialized native scroll matrices predict actual nested boxes at scale $scale',
      (tester) async {
        final layout = NativeDocumentLayoutController(),
            elements = NativeDocumentElementScrollController(),
            scroll = ScrollController();
        try {
          Widget box(String id, Widget child) => NativeDocumentLayoutElement(
            controller: layout,
            revision: 1,
            id: id,
            child: child,
          );
          Widget port(String id, double width, double height, Widget child) =>
              box(
                id,
                SizedBox(
                  width: width,
                  height: height,
                  child: NativeDocumentElementScroll(
                    controller: elements,
                    id: id,
                    revision: 1,
                    overflowX: NativeDocumentOverflow.auto,
                    overflowY: NativeDocumentOverflow.auto,
                    child: OverflowBox(
                      fit: OverflowBoxFit.deferToChild,
                      alignment: Alignment.topLeft,
                      minWidth: id == 'outer' ? 800 : 600,
                      maxWidth: id == 'outer' ? 800 : 600,
                      child: SizedBox(
                        width: id == 'outer' ? 800 : 600,
                        height: id == 'outer' ? 1000 : 700,
                        child: Padding(
                          padding: EdgeInsets.only(
                            left: id == 'outer' ? 40 : 60,
                            top: id == 'outer' ? 30 : 80,
                          ),
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: child,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
          await tester.pumpWidget(
            MaterialApp(
              home: SingleChildScrollView(
                controller: scroll,
                child: NativeDocumentLayoutRoot(
                  controller: layout,
                  revision: 1,
                  knownIds: const {'outer', 'inner', 'target', 'outside'},
                  computedStyles: {
                    for (final id in ['outer', 'inner', 'target', 'outside'])
                      id: NativeDocumentComputedStyleSpec(
                        values: const {
                          'position': 'static',
                          'display': 'block',
                        },
                        lengths: const {},
                        fontSize: 16,
                        rootFontSize: 16,
                        scrollTranslationSupported: true,
                      ),
                  },
                  child: SizedBox(
                    height: 2400,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Transform.scale(
                          scale: scale,
                          alignment: Alignment.topLeft,
                          child: port(
                            'outer',
                            220,
                            160,
                            port(
                              'inner',
                              180,
                              120,
                              box(
                                'target',
                                const SizedBox(width: 80, height: 40),
                              ),
                            ),
                          ),
                        ),
                        box('outside', const SizedBox(width: 80, height: 40)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          Map capture(int generation) => layout.capture(
            revision: 1,
            generation: generation,
            viewport: const Size(800, 600),
            scrollOffset: Offset(0, scroll.offset),
            elementScrollMetrics: elements.metricsFor,
            elementScrollRanges: elements.scrollRangeFor,
            elementScrollSurfaces: elements.scrollGeometrySurfaces,
          )!;
          final before = capture(1),
              boxes = {for (final b in before['boxes'] as List) b['id']: b};
          expect(boxes['target']['scrollGeometry']['ancestors'], hasLength(2));
          expect(boxes['outer']['scrollGeometry']['ancestors'], isEmpty);
          expect(boxes['outside']['scrollGeometry']['ancestors'], isEmpty);
          scroll.jumpTo(40);
          elements.applyActions([
            {'id': 'outer', 'op': 'to', 'left': 20, 'top': 30},
            {'id': 'inner', 'op': 'to', 'left': 10, 'top': 15},
          ]);
          await tester.pumpAndSettle();
          final after = {
            for (final b in capture(2)['boxes'] as List) b['id']: b,
          };
          for (final id in boxes.keys) {
            final b = boxes[id], proof = b['scrollGeometry'];
            var dx = 0.0, dy = -40.0;
            for (final d in proof['ancestors'] as List) {
              final metrics = elements.metricsFor(d['id'])!,
                  axes = d['axes'] as List;
              dx -=
                  (axes[0] as num) * metrics['left']! +
                  (axes[2] as num) * metrics['top']!;
              dy -=
                  (axes[1] as num) * metrics['left']! +
                  (axes[3] as num) * metrics['top']!;
            }
            expect(
              after[id]['x'],
              closeTo((b['x'] as num) + dx, .001),
              reason: '$id x',
            );
            expect(
              (after[id]['y'] as num) - scroll.offset,
              closeTo((b['y'] as num) + dy, .001),
              reason: '$id y',
            );
            expect(after[id]['width'], b['width']);
            expect(after[id]['height'], b['height']);
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          layout.dispose();
          elements.dispose();
          scroll.dispose();
        }
      },
    );
  }
}
