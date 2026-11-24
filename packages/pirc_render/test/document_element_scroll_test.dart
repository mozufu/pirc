import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_element_scroll.dart';

Widget _page(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: Align(alignment: Alignment.topLeft, child: child),
);

class _SameSizeRelayoutDelegate extends SingleChildLayoutDelegate {
  @override
  Size getSize(BoxConstraints constraints) => Size(constraints.maxWidth, 200);

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset.zero;

  @override
  bool shouldRelayout(_SameSizeRelayoutDelegate oldDelegate) => true;
}

Widget _viewport({
  required NativeDocumentElementScrollController controller,
  required String id,
  required int revision,
  required double width,
  required double height,
  required Widget child,
  Key? key,
  NativeDocumentOverflow overflowX = NativeDocumentOverflow.auto,
  NativeDocumentOverflow overflowY = NativeDocumentOverflow.auto,
}) => SizedBox(
  width: width,
  height: height,
  child: NativeDocumentElementScroll(
    key: key ?? ValueKey<String>('viewport:$id'),
    controller: controller,
    id: id,
    revision: revision,
    overflowX: overflowX,
    overflowY: overflowY,
    child: child,
  ),
);

void main() {
  for (final overflow in [
    NativeDocumentOverflow.auto,
    NativeDocumentOverflow.hidden,
    NativeDocumentOverflow.clip,
    NativeDocumentOverflow.visible,
  ]) {
    testWidgets(
      'native scroll ranges follow measured dimensions and disabled axes: $overflow',
      (tester) async {
        final controller = NativeDocumentElementScrollController();
        try {
          expect(controller.scrollRangeFor('range'), isNull);
          Widget scene(double height) => _page(
            _viewport(
              controller: controller,
              id: 'range',
              revision: 1,
              width: 180,
              height: height,
              overflowX: overflow,
              overflowY: overflow,
              child: const OverflowBox(
                fit: OverflowBoxFit.deferToChild,
                alignment: Alignment.topLeft,
                minWidth: 600,
                maxWidth: 600,
                child: SizedBox(width: 600, height: 800),
              ),
            ),
          );
          await tester.pumpWidget(scene(100));
          final enabled =
              overflow == NativeDocumentOverflow.auto ||
              overflow == NativeDocumentOverflow.hidden;
          expect(controller.scrollRangeFor('range'), {
            'minLeft': 0.0,
            'maxLeft': enabled ? 420.0 : 0.0,
            'minTop': 0.0,
            'maxTop': enabled ? 700.0 : 0.0,
          });
          await tester.pumpWidget(scene(150));
          expect(
            controller.scrollRangeFor('range')!['maxTop'],
            enabled ? 650.0 : 0.0,
          );
        } finally {
          await tester.pumpWidget(const SizedBox());
          controller.dispose();
        }
      },
    );
  }

  testWidgets('keeps the border fixed and scrolls actual padding and content', (
    tester,
  ) async {
    final controller = NativeDocumentElementScrollController();
    addTearDown(controller.dispose);
    const childKey = ValueKey<String>('vertical-content');

    await tester.pumpWidget(
      _page(
        DecoratedBox(
          key: const ValueKey<String>('border'),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFF000000), width: 4),
          ),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: _viewport(
              controller: controller,
              id: 'scroller',
              revision: 1,
              width: 180,
              height: 120,
              overflowX: NativeDocumentOverflow.hidden,
              overflowY: NativeDocumentOverflow.auto,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: SizedBox(key: childKey, width: 120, height: 360),
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byKey(const ValueKey<String>('border'))),
      const Size(188, 128),
    );
    expect(controller.metricsFor('scroller'), <String, double>{
      'left': 0,
      'top': 0,
      'width': 180,
      'height': 380,
    });
    expect(tester.getTopLeft(find.byKey(childKey)), const Offset(14, 14));

    controller.applyActions(<Map<String, dynamic>>[
      <String, dynamic>{'id': 'scroller', 'op': 'scrollTo', 'top': 50},
    ]);
    await tester.pump();

    expect(controller.metricsFor('scroller')?['top'], 50);
    expect(tester.getTopLeft(find.byKey(childKey)).dy, -36);
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('border'))),
      const Size(188, 128),
    );
  });

  testWidgets('includes trailing padding after a real overflowing child', (
    tester,
  ) async {
    final controller = NativeDocumentElementScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _page(
        _viewport(
          controller: controller,
          id: 'horizontal',
          revision: 1,
          width: 158,
          height: 94,
          overflowX: NativeDocumentOverflow.auto,
          overflowY: NativeDocumentOverflow.clip,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: OverflowBox(
              fit: OverflowBoxFit.deferToChild,
              alignment: Alignment.topLeft,
              minWidth: 420,
              maxWidth: 420,
              child: const SizedBox(width: 420, height: 30),
            ),
          ),
        ),
      ),
    );

    expect(controller.metricsFor('horizontal'), <String, double>{
      'left': 0,
      'top': 0,
      'width': 438,
      'height': 94,
    });
  });

  testWidgets('bounds padded siblings independently when measuring overflow', (
    tester,
  ) async {
    final controller = NativeDocumentElementScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _page(
        _viewport(
          controller: controller,
          id: 'siblings',
          revision: 1,
          width: 158,
          height: 60,
          overflowX: NativeDocumentOverflow.auto,
          overflowY: NativeDocumentOverflow.clip,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned(
                left: 0,
                top: 0,
                width: 158,
                child: Padding(
                  padding: const EdgeInsets.only(right: 9),
                  child: OverflowBox(
                    fit: OverflowBoxFit.deferToChild,
                    alignment: Alignment.topLeft,
                    minWidth: 420,
                    maxWidth: 420,
                    child: const SizedBox(width: 420, height: 20),
                  ),
                ),
              ),
              const Positioned(
                left: 0,
                top: 30,
                child: Padding(
                  padding: EdgeInsets.only(right: 30),
                  child: SizedBox(width: 10, height: 20),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(controller.metricsFor('siblings')?['width'], 429);
  });

  testWidgets('retains wrapping width when horizontal overflow is enabled', (
    tester,
  ) async {
    final controller = NativeDocumentElementScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _page(
        _viewport(
          controller: controller,
          id: 'wrapped-text',
          revision: 1,
          width: 100,
          height: 40,
          overflowX: NativeDocumentOverflow.auto,
          overflowY: NativeDocumentOverflow.auto,
          child: const Text(
            'a long line of ordinary text that should wrap to the next line',
          ),
        ),
      ),
    );

    final metrics = controller.metricsFor('wrapped-text')!;
    expect(metrics['width'], 100);
    expect(metrics['height']!, greaterThan(40));
  });

  testWidgets(
    'applies actions in order, preserves omitted axes, and clamps both axes',
    (tester) async {
      final controller = NativeDocumentElementScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _page(
          _viewport(
            controller: controller,
            id: 'both',
            revision: 1,
            width: 156,
            height: 116,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: OverflowBox(
                fit: OverflowBoxFit.deferToChild,
                alignment: Alignment.topLeft,
                minWidth: 420,
                maxWidth: 420,
                minHeight: 260,
                maxHeight: 260,
                child: const SizedBox(width: 420, height: 260),
              ),
            ),
          ),
        ),
      );

      expect(controller.metricsFor('both'), <String, double>{
        'left': 0,
        'top': 0,
        'width': 436,
        'height': 276,
      });

      controller.applyActions(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'both',
          'op': 'scrollTo',
          'left': 23,
          'top': 31,
        },
        <String, dynamic>{'id': 'both', 'op': 'scrollBy', 'left': 45},
        <String, dynamic>{'id': 'both', 'op': 'scrollTo', 'left': 9999},
        <String, dynamic>{'id': 'both', 'op': 'scrollBy', 'left': -10},
        <String, dynamic>{'id': 'both', 'op': 'scrollTo', 'top': -100},
        <String, dynamic>{'id': 'both', 'op': 'scrollBy', 'top': 20},
      ]);
      await tester.pump();

      expect(controller.metricsFor('both'), <String, double>{
        'left': 270,
        'top': 20,
        'width': 436,
        'height': 276,
      });
    },
  );

  testWidgets(
    'user drag scrolls auto axes, while hidden scrolls only by script',
    (tester) async {
      final controller = NativeDocumentElementScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _page(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _viewport(
                controller: controller,
                id: 'drag',
                revision: 1,
                width: 120,
                height: 70,
                child: OverflowBox(
                  fit: OverflowBoxFit.deferToChild,
                  alignment: Alignment.topLeft,
                  minWidth: 300,
                  maxWidth: 300,
                  child: const SizedBox(width: 300, height: 200),
                ),
              ),
              _viewport(
                controller: controller,
                id: 'hidden',
                revision: 1,
                width: 120,
                height: 70,
                overflowX: NativeDocumentOverflow.hidden,
                overflowY: NativeDocumentOverflow.hidden,
                child: OverflowBox(
                  fit: OverflowBoxFit.deferToChild,
                  alignment: Alignment.topLeft,
                  minWidth: 200,
                  maxWidth: 200,
                  minHeight: 200,
                  maxHeight: 200,
                  child: const SizedBox(width: 200, height: 200),
                ),
              ),
            ],
          ),
        ),
      );

      await tester.drag(
        find.byKey(const ValueKey<String>('viewport:drag')),
        const Offset(0, -35),
      );
      await tester.pump();
      await tester.drag(
        find.byKey(const ValueKey<String>('viewport:drag')),
        const Offset(-30, 0),
      );
      await tester.pump();

      expect(controller.metricsFor('drag')!['top'], greaterThan(0));
      expect(controller.metricsFor('drag')!['left'], greaterThan(0));

      await tester.drag(
        find.byKey(const ValueKey<String>('viewport:hidden')),
        const Offset(0, -50),
      );
      await tester.pump();
      expect(controller.metricsFor('hidden')!['top'], 0);

      controller.applyActions(<Map<String, dynamic>>[
        <String, dynamic>{'id': 'hidden', 'op': 'scrollTo', 'top': 120},
      ]);
      await tester.pump();
      expect(controller.metricsFor('hidden')!['top'], 120);
    },
  );

  testWidgets('clip does not scroll by script or by user input', (
    tester,
  ) async {
    final controller = NativeDocumentElementScrollController();
    addTearDown(controller.dispose);
    var pointerDown = false;

    await tester.pumpWidget(
      _page(
        _viewport(
          controller: controller,
          id: 'clip',
          revision: 1,
          width: 120,
          height: 70,
          overflowX: NativeDocumentOverflow.clip,
          overflowY: NativeDocumentOverflow.clip,
          child: OverflowBox(
            fit: OverflowBoxFit.deferToChild,
            alignment: Alignment.topLeft,
            minWidth: 200,
            maxWidth: 200,
            minHeight: 200,
            maxHeight: 200,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => pointerDown = true,
              child: const SizedBox(width: 200, height: 200),
            ),
          ),
        ),
      ),
    );

    await tester.drag(
      find.byKey(const ValueKey<String>('viewport:clip')),
      const Offset(-40, -40),
    );
    await tester.pump();
    expect(pointerDown, isTrue);
    controller.applyActions(<Map<String, dynamic>>[
      <String, dynamic>{'id': 'clip', 'op': 'scrollTo', 'left': 30, 'top': 40},
    ]);
    await tester.pump();

    expect(controller.metricsFor('clip'), <String, double>{
      'left': 0,
      'top': 0,
      'width': 200,
      'height': 200,
    });
  });

  testWidgets('duplicate live IDs have no metrics and ignore commands', (
    tester,
  ) async {
    final controller = NativeDocumentElementScrollController();
    addTearDown(controller.dispose);

    Widget content(bool includeSecond) => _page(
      Row(
        children: <Widget>[
          _viewport(
            controller: controller,
            id: 'duplicate',
            revision: 1,
            width: 120,
            height: 70,
            key: const ValueKey<String>('duplicate:first'),
            child: const SizedBox(width: 120, height: 200),
          ),
          if (includeSecond)
            _viewport(
              controller: controller,
              id: 'duplicate',
              revision: 1,
              width: 120,
              height: 70,
              key: const ValueKey<String>('duplicate:second'),
              child: const SizedBox(width: 120, height: 200),
            ),
        ],
      ),
    );

    await tester.pumpWidget(content(true));
    expect(controller.metricsFor('duplicate'), isNull);
    controller.applyActions(<Map<String, dynamic>>[
      <String, dynamic>{'id': 'duplicate', 'op': 'scrollTo', 'top': 40},
    ]);
    await tester.pump();

    await tester.pumpWidget(content(false));
    await tester.pump();
    expect(controller.metricsFor('duplicate')?['top'], 0);
  });

  testWidgets(
    'retains offsets across detach but resets them for a new document',
    (tester) async {
      final controller = NativeDocumentElementScrollController();
      addTearDown(controller.dispose);

      Widget content({required bool include, required int revision}) => _page(
        include
            ? _viewport(
                controller: controller,
                id: 'retained',
                revision: revision,
                width: 120,
                height: 70,
                child: const SizedBox(width: 120, height: 200),
              )
            : const SizedBox.shrink(),
      );

      await tester.pumpWidget(content(include: true, revision: 1));
      controller.applyActions(<Map<String, dynamic>>[
        <String, dynamic>{'id': 'retained', 'op': 'scrollTo', 'top': 40},
      ]);
      await tester.pump();
      expect(controller.metricsFor('retained')?['top'], 40);

      await tester.pumpWidget(content(include: false, revision: 1));
      await tester.pump();
      await tester.pumpWidget(content(include: true, revision: 2));
      await tester.pump();
      expect(controller.metricsFor('retained')?['top'], 40);

      controller.beginDocument(Object());
      await tester.pumpWidget(content(include: true, revision: 3));
      await tester.pump();
      expect(controller.metricsFor('retained')?['top'], 0);
    },
  );

  testWidgets('overflow axis changes report fixed offsets and restore scroll', (
    tester,
  ) async {
    final controller = NativeDocumentElementScrollController();
    addTearDown(controller.dispose);

    Widget content({
      required NativeDocumentOverflow overflowX,
      required NativeDocumentOverflow overflowY,
    }) => _page(
      _viewport(
        controller: controller,
        id: 'overflow-transition',
        revision: 1,
        width: 120,
        height: 70,
        overflowX: overflowX,
        overflowY: overflowY,
        child: OverflowBox(
          fit: OverflowBoxFit.deferToChild,
          alignment: Alignment.topLeft,
          minWidth: 200,
          maxWidth: 200,
          minHeight: 200,
          maxHeight: 200,
          child: const SizedBox(width: 200, height: 200),
        ),
      ),
    );

    await tester.pumpWidget(
      content(
        overflowX: NativeDocumentOverflow.auto,
        overflowY: NativeDocumentOverflow.auto,
      ),
    );
    controller.applyActions(<Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'overflow-transition',
        'op': 'scrollTo',
        'left': 20,
        'top': 40,
      },
    ]);
    await tester.pump();
    expect(controller.metricsFor('overflow-transition'), <String, double>{
      'left': 20,
      'top': 40,
      'width': 200,
      'height': 200,
    });

    await tester.pumpWidget(
      content(
        overflowX: NativeDocumentOverflow.clip,
        overflowY: NativeDocumentOverflow.visible,
      ),
    );
    await tester.pump();
    expect(controller.metricsFor('overflow-transition'), <String, double>{
      'left': 0,
      'top': 0,
      'width': 200,
      'height': 200,
    });

    await tester.pumpWidget(
      content(
        overflowX: NativeDocumentOverflow.auto,
        overflowY: NativeDocumentOverflow.auto,
      ),
    );
    await tester.pump();
    expect(controller.metricsFor('overflow-transition'), <String, double>{
      'left': 20,
      'top': 40,
      'width': 200,
      'height': 200,
    });
  });

  testWidgets('same-props rebuild keeps current scroll metrics available', (
    tester,
  ) async {
    final controller = NativeDocumentElementScrollController();
    addTearDown(controller.dispose);

    Widget content() => _page(
      _viewport(
        controller: controller,
        id: 'same-props',
        revision: 1,
        width: 120,
        height: 70,
        child: const SizedBox(width: 120, height: 200),
      ),
    );

    await tester.pumpWidget(content());
    final before = controller.metricsFor('same-props');
    expect(before, isNotNull);

    await tester.pumpWidget(content());
    expect(controller.metricsFor('same-props'), before);
  });

  testWidgets('unchanged layout metrics do not keep notifying listeners', (
    tester,
  ) async {
    final controller = NativeDocumentElementScrollController();
    addTearDown(controller.dispose);
    var notifications = 0;
    void onChanged() => notifications++;
    controller.addListener(onChanged);
    addTearDown(() => controller.removeListener(onChanged));

    Widget content() => _page(
      _viewport(
        controller: controller,
        id: 'settled-layout',
        revision: 1,
        width: 120,
        height: 70,
        child: CustomSingleChildLayout(
          delegate: _SameSizeRelayoutDelegate(),
          child: const SizedBox(width: 120, height: 200),
        ),
      ),
    );

    await tester.pumpWidget(content());
    await tester.pump();
    final settledNotifications = notifications;
    expect(settledNotifications, greaterThan(0));

    // Replacing the delegate forces another layout pass with the same
    // revision and extents. It must not restart the listener/rebuild loop.
    await tester.pumpWidget(content());
    await tester.pump();
    expect(notifications, settledNotifications);
  });

  testWidgets('hit testing follows the painted position after scrolling', (
    tester,
  ) async {
    final controller = NativeDocumentElementScrollController();
    addTearDown(controller.dispose);
    var tapped = false;
    Offset? tappedLocalPosition;
    const targetKey = ValueKey<String>('scrolled-hit-target');

    await tester.pumpWidget(
      _page(
        _viewport(
          controller: controller,
          id: 'hit-test',
          revision: 1,
          width: 100,
          height: 80,
          child: OverflowBox(
            fit: OverflowBoxFit.deferToChild,
            alignment: Alignment.topLeft,
            minWidth: 260,
            maxWidth: 260,
            minHeight: 240,
            maxHeight: 240,
            child: SizedBox(
              width: 260,
              height: 240,
              child: Stack(
                children: <Widget>[
                  Positioned(
                    left: 180,
                    top: 160,
                    child: GestureDetector(
                      key: targetKey,
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) =>
                          tappedLocalPosition = details.localPosition,
                      onTap: () => tapped = true,
                      child: const SizedBox(width: 60, height: 40),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    controller.applyActions(<Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'hit-test',
        'op': 'scrollTo',
        'left': 160,
        'top': 140,
      },
    ]);
    await tester.pump();

    expect(tester.getCenter(find.byKey(targetKey)), const Offset(50, 40));
    await tester.tap(find.byKey(targetKey));
    expect(tapped, isTrue);
    expect(tappedLocalPosition, const Offset(30, 20));
  });

  testWidgets('overflow hit testing respects pointer suppression', (
    tester,
  ) async {
    final controller = NativeDocumentElementScrollController();
    addTearDown(controller.dispose);

    for (final mode in <String>['ignore', 'absorb', 'offstage']) {
      var tapped = false;
      Widget button() => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => tapped = true,
        child: const SizedBox(width: 60, height: 40),
      );
      final Widget protected = switch (mode) {
        'ignore' => IgnorePointer(ignoring: true, child: button()),
        'absorb' => AbsorbPointer(absorbing: true, child: button()),
        _ => Offstage(offstage: true, child: button()),
      };

      await tester.pumpWidget(
        _page(
          _viewport(
            controller: controller,
            id: 'suppressed-$mode',
            revision: 1,
            width: 100,
            height: 80,
            child: OverflowBox(
              fit: OverflowBoxFit.deferToChild,
              alignment: Alignment.topLeft,
              minWidth: 260,
              maxWidth: 260,
              minHeight: 240,
              maxHeight: 240,
              child: SizedBox(
                width: 260,
                height: 240,
                child: Stack(
                  children: <Widget>[
                    Positioned(left: 180, top: 160, child: protected),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      controller.applyActions(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'suppressed-$mode',
          'op': 'scrollTo',
          'left': 160,
          'top': 140,
        },
      ]);
      await tester.pump();
      await tester.tapAt(const Offset(50, 40));
      await tester.pump();
      expect(tapped, isFalse, reason: '$mode suppresses the overflow target');
    }
  });

  testWidgets('overflow fallback respects a nested CSS clip viewport', (
    tester,
  ) async {
    final controller = NativeDocumentElementScrollController();
    addTearDown(controller.dispose);
    var tapped = false;

    await tester.pumpWidget(
      _page(
        _viewport(
          controller: controller,
          id: 'outer-clip-test',
          revision: 1,
          width: 100,
          height: 80,
          child: SizedBox(
            width: 260,
            height: 240,
            child: Stack(
              children: <Widget>[
                Positioned(
                  left: 0,
                  top: 0,
                  child: _viewport(
                    controller: controller,
                    id: 'inner-clip-test',
                    revision: 1,
                    width: 100,
                    height: 80,
                    overflowX: NativeDocumentOverflow.clip,
                    overflowY: NativeDocumentOverflow.clip,
                    child: OverflowBox(
                      fit: OverflowBoxFit.deferToChild,
                      alignment: Alignment.topLeft,
                      minWidth: 260,
                      maxWidth: 260,
                      minHeight: 240,
                      maxHeight: 240,
                      child: SizedBox(
                        width: 260,
                        height: 240,
                        child: Stack(
                          children: <Widget>[
                            Positioned(
                              left: 180,
                              top: 160,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => tapped = true,
                                child: const SizedBox(width: 60, height: 40),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    controller.applyActions(<Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'outer-clip-test',
        'op': 'scrollTo',
        'left': 160,
        'top': 140,
      },
    ]);
    await tester.pump();
    await tester.tapAt(const Offset(50, 40));
    await tester.pump();
    expect(tapped, isFalse);
  });

  testWidgets('layout metric changes do not enqueue scroll events', (
    tester,
  ) async {
    final controller = NativeDocumentElementScrollController();
    addTearDown(controller.dispose);
    double contentHeight = 100;

    Widget content() => _page(
      _viewport(
        controller: controller,
        id: 'layout-only',
        revision: 1,
        width: 120,
        height: 70,
        child: SizedBox(width: 120, height: contentHeight),
      ),
    );

    await tester.pumpWidget(content());
    expect(controller.pendingScrollEvents, isEmpty);
    contentHeight = 240;
    await tester.pumpWidget(content());
    await tester.pump();
    expect(controller.metricsFor('layout-only')?['height'], 240);
    expect(controller.pendingScrollEvents, isEmpty);
  });

  testWidgets(
    'queues nested scroll events in first-change order and acknowledges them',
    (tester) async {
      final controller = NativeDocumentElementScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _page(
          _viewport(
            controller: controller,
            id: 'outer',
            revision: 1,
            width: 192,
            height: 122,
            overflowX: NativeDocumentOverflow.hidden,
            overflowY: NativeDocumentOverflow.auto,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _viewport(
                    controller: controller,
                    id: 'inner',
                    revision: 1,
                    width: 148,
                    height: 78,
                    overflowX: NativeDocumentOverflow.hidden,
                    overflowY: NativeDocumentOverflow.auto,
                    child: const SizedBox(width: 100, height: 288),
                  ),
                  const SizedBox(width: 100, height: 190),
                ],
              ),
            ),
          ),
        ),
      );

      controller.applyActions(<Map<String, dynamic>>[
        <String, dynamic>{'id': 'inner', 'op': 'scrollTo', 'top': 25},
        <String, dynamic>{'id': 'outer', 'op': 'scrollTo', 'top': 60},
      ]);
      await tester.pump();

      expect(controller.pendingScrollEvents, <Map<String, dynamic>>[
        <String, dynamic>{'id': 'inner', 'sequence': 1},
        <String, dynamic>{'id': 'outer', 'sequence': 2},
      ]);
      expect(controller.metricsFor('inner')?['top'], 25);
      expect(controller.metricsFor('outer')?['top'], 60);

      controller.acknowledgeScrollEvents(1);
      expect(controller.pendingScrollEvents, <Map<String, dynamic>>[
        <String, dynamic>{'id': 'outer', 'sequence': 2},
      ]);
    },
  );
}
