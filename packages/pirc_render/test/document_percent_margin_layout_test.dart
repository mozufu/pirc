import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_element_scroll.dart';
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/document_margin_collapse.dart';
import 'package:pirc_render/src/html_document_box.dart';
import 'package:pirc_render/src/html_document_flex.dart';

const _rootKey = ValueKey('settler');
const _parentKey = ValueKey('margin-parent');
const _group = NativeDocumentTopMarginGroup([
  NativeDocumentTopMarginContribution(
    originId: 'parent',
    value: 5,
    percentage: true,
  ),
  NativeDocumentTopMarginContribution(
    originId: 'child',
    value: 10,
    percentage: true,
  ),
]);

Widget _host(
  double width, {
  int passes = 8,
  NativeDocumentLayoutController? layout,
  bool missingBasis = false,
}) {
  Widget content = NativeDocumentContainingBlock(
    width: width,
    height: 400,
    child: NativeDocumentMarginCollapseRoot(
      key: _rootKey,
      maximumPasses: passes,
      child: NativeDocumentBox(
        width: NativeFlexLength.pixels(width),
        child: Align(
          alignment: Alignment.topLeft,
          widthFactor: 1,
          heightFactor: 1,
          child: NativeDocumentPercentageMargin(
            fractions: EdgeInsets.zero,
            collapsedTop: _group,
            child: NativeDocumentBox(
              key: _parentKey,
              geometryOwnerId: 'parent',
              width: const NativeFlexLength.pixels(200),
              horizontalEdges: 42,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 21),
                child: Align(
                  alignment: Alignment.topLeft,
                  widthFactor: 1,
                  heightFactor: 1,
                  child: NativeDocumentBox(
                    geometryOwnerId: missingBasis ? null : 'child',
                    width: const NativeFlexLength.pixels(30),
                    height: const NativeFlexLength.pixels(10),
                    child: _BaselineLeaf(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  if (layout != null) {
    content = NativeDocumentLayoutRoot(
      controller: layout,
      revision: 1,
      knownIds: const {},
      child: content,
    );
  }
  return MaterialApp(
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        height: 400,
        child: SingleChildScrollView(child: content),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'settles using distinct actual widths and clears hypothetical dry probe caches',
    (t) async {
      for (final width in [400.0, 300.0, 600.0, 300.0]) {
        await t.pumpWidget(_host(width));
        await t.pumpAndSettle();
        final root = t.renderObject<RenderBox>(find.byKey(_rootKey));
        final parent = find.byKey(_parentKey);
        final top = width == 300 ? 15.8 : width * .05;
        expect(nativeDocumentMarginsAreSettled(root), isTrue);
        expect(t.getTopLeft(parent).dy, closeTo(top, .0001));
        expect(t.getSize(parent).width, 200);
        expect(root.size.height, closeTo(top + 10, .0001));
        final constraints = BoxConstraints(maxWidth: width);
        expect(
          root.getDryLayout(constraints).height,
          closeTo(root.size.height, .0001),
        );
        expect(
          root.getDryBaseline(constraints, TextBaseline.alphabetic),
          closeTo(top + 5, .0001),
        );
        // These are hypothetical native queries, not a new document viewport.
        root.getDryLayout(const BoxConstraints(maxWidth: 250));
        root.getDryLayout(const BoxConstraints(maxWidth: 500));
        root.markNeedsLayout();
        await t.pump();
        expect(t.getTopLeft(parent).dy, closeTo(top, .0001));
        expect(nativeDocumentMarginsAreSettled(root), isTrue);
        expect(t.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'a capped or missing-basis pass does not publish layout packets',
    (t) async {
      final layout = NativeDocumentLayoutController();
      addTearDown(layout.dispose);
      await t.pumpWidget(_host(400, passes: 1, layout: layout));
      await t.pumpAndSettle();
      Map<String, dynamic>? capture() => layout.capture(
        revision: 1,
        generation: 1,
        viewport: const Size(400, 400),
        scrollOffset: Offset.zero,
      );
      expect(capture(), isNull);
      await t.pumpWidget(_host(400, passes: 8, layout: layout));
      await t.pumpAndSettle();
      expect(capture(), isNotNull);
      await t.pumpWidget(_host(400, layout: layout, missingBasis: true));
      await t.pumpAndSettle();
      expect(capture(), isNull);
      await t.pumpWidget(_host(400, layout: layout));
      await t.pumpAndSettle();
      expect(capture(), isNotNull);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final outside in [false, true]) {
    testWidgets(
      'scroll offsets survive provisional replacement (outer viewport: $outside)',
      (t) async {
        final scroll = NativeDocumentElementScrollController();
        addTearDown(scroll.dispose);
        Widget host(
          int generation, {
          int passes = 8,
          bool missingBasis = false,
        }) => MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              height: 200,
              child: NativeDocumentContainingBlock(
                width: 300,
                height: 200,
                child: NativeDocumentMarginCollapseRoot(
                  maximumPasses: passes,
                  child: NativeDocumentBox(
                    width: const NativeFlexLength.pixels(300),
                    height: const NativeFlexLength.pixels(100),
                    child: NativeDocumentElementScroll(
                      controller: scroll,
                      id: 'scroller',
                      revision: 1,
                      overflowX: NativeDocumentOverflow.visible,
                      overflowY: NativeDocumentOverflow.auto,
                      child: NativeDocumentPercentageMargin(
                        key: ValueKey(generation),
                        fractions: EdgeInsets.zero,
                        collapsedTop: const NativeDocumentTopMarginGroup([
                          NativeDocumentTopMarginContribution(
                            originId: 'target',
                            value: 200,
                            percentage: true,
                          ),
                        ]),
                        child: NativeDocumentBox(
                          geometryOwnerId: 'content',
                          height: const NativeFlexLength.pixels(1000),
                          child: Align(
                            alignment: Alignment.topLeft,
                            widthFactor: 1,
                            heightFactor: 1,
                            child: NativeDocumentBox(
                              geometryOwnerId: missingBasis ? null : 'target',
                              width: const NativeFlexLength.pixels(30),
                              height: const NativeFlexLength.pixels(10),
                              child: const SizedBox.shrink(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        Widget outerHost(Widget original) {
          if (!outside) return original;
          final material = original as MaterialApp;
          final align = material.home! as Align;
          final sized = align.child! as SizedBox;
          final containing = sized.child! as NativeDocumentContainingBlock;
          final root = containing.child! as NativeDocumentMarginCollapseRoot;
          final box = root.child! as NativeDocumentBox;
          final viewport = box.child! as NativeDocumentElementScroll;
          return MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                height: 200,
                child: NativeDocumentContainingBlock(
                  width: 300,
                  height: 200,
                  child: NativeDocumentBox(
                    width: const NativeFlexLength.pixels(300),
                    height: const NativeFlexLength.pixels(100),
                    child: NativeDocumentElementScroll(
                      controller: scroll,
                      id: 'scroller',
                      revision: 1,
                      overflowX: NativeDocumentOverflow.visible,
                      overflowY: NativeDocumentOverflow.auto,
                      child: NativeDocumentMarginCollapseRoot(
                        maximumPasses: root.maximumPasses,
                        child: viewport.child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        await t.pumpWidget(outerHost(host(0)));
        await t.pumpAndSettle();
        expect(scroll.metricsFor('scroller')!['height'], 1600);
        scroll.applyActions([
          {'id': 'scroller', 'op': 'scrollTo', 'top': 1400},
        ]);
        await t.pumpAndSettle();
        expect(scroll.metricsFor('scroller')!['top'], 1400);
        final events = scroll.pendingScrollEvents;
        if (events.isNotEmpty) {
          scroll.acknowledgeScrollEvents(events.last['sequence'] as int);
        }
        // A replacement starts with zero applied margin. A failed or capped
        // pass must retain the previous dimensions instead of clamping to 900.
        for (final missing in [false, true]) {
          await t.pumpWidget(
            outerHost(host(1, passes: missing ? 8 : 1, missingBasis: missing)),
          );
          await t.pumpAndSettle();
          expect(scroll.metricsFor('scroller')!['height'], 1600);
          expect(scroll.metricsFor('scroller')!['top'], 1400);
          expect(scroll.pendingScrollEvents, isEmpty);
          expect(
            nativeDocumentMarginsAreSettled(
              t.renderObject(find.byType(NativeDocumentMarginCollapseRoot)),
            ),
            isFalse,
          );
          await t.pumpWidget(outerHost(host(1)));
          await t.pumpAndSettle();
          expect(
            nativeDocumentMarginsAreSettled(
              t.renderObject(find.byType(NativeDocumentMarginCollapseRoot)),
            ),
            isTrue,
          );
        }
        await t.pumpWidget(outerHost(host(2)));
        await t.pumpAndSettle();
        expect(scroll.metricsFor('scroller')!['height'], 1600);
        expect(scroll.metricsFor('scroller')!['top'], 1400);
        expect(scroll.pendingScrollEvents, isEmpty);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

class _BaselineLeaf extends LeafRenderObjectWidget {
  @override
  RenderObject createRenderObject(BuildContext context) => _BaselineBox();
}

class _BaselineBox extends RenderBox {
  @override
  void performLayout() {
    size = constraints.constrain(const Size(30, 10));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(const Size(30, 10));
  @override
  double computeDistanceToActualBaseline(TextBaseline baseline) => 5;
  @override
  double computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => 5;
}
