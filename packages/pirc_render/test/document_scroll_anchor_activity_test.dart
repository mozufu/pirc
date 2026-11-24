import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_scroll_anchor.dart';

void main() {
  for (final ballistic in [false, true]) {
    testWidgets(
      'anchor correction preserves ${ballistic ? 'inertial' : 'active drag'} scrolling',
      (tester) async {
        final scroll = NativeDocumentScrollController();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                controller: scroll,
                physics: const ClampingScrollPhysics(),
                child: const SizedBox(width: 390, height: 6000),
              ),
            ),
          ),
        );
        scroll.jumpTo(240);
        await tester.pump();
        final viewport = find.byType(SingleChildScrollView);
        final gesture = ballistic
            ? null
            : await tester.startGesture(tester.getCenter(viewport));
        if (ballistic) {
          await tester.fling(viewport, const Offset(0, -240), 1200);
        } else {
          await gesture!.moveBy(const Offset(0, -120));
        }
        await tester.pump(const Duration(milliseconds: 16));
        expect(scroll.position.isScrollingNotifier.value, isTrue);
        final before = scroll.offset;
        scroll.correctAnchorOffset(before + 120);
        expect(scroll.position.isScrollingNotifier.value, isTrue);
        if (!ballistic) await gesture!.moveBy(const Offset(0, -50));
        await tester.pump(const Duration(milliseconds: 16));
        // The resumed ballistic ticker establishes its timestamp on the first
        // frame; the following frame must continue moving in the same direction.
        if (ballistic) await tester.pump(const Duration(milliseconds: 16));
        expect(
          scroll.offset,
          greaterThan(before + 120),
          reason:
              'Reading-position compensation must not stop the user’s ongoing scroll.',
        );
        if (!ballistic) await gesture!.up();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        scroll.dispose();
      },
    );
  }
  for (final keep in [true, false]) {
    testWidgets(
      'document root remount respects keepScrollOffset=$keep and new extents',
      (tester) async {
        final scroll = NativeDocumentScrollController(
          initialScrollOffset: 17,
          keepScrollOffset: keep,
        );
        Widget page(double height) => MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              height: 200,
              child: SingleChildScrollView(
                controller: scroll,
                child: SizedBox(height: height),
              ),
            ),
          ),
        );
        try {
          await tester.pumpWidget(page(1600));
          await tester.pumpAndSettle();
          scroll.jumpTo(360);
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await tester.pumpWidget(page(1600));
          await tester.pumpAndSettle();
          expect(scroll.offset, keep ? 360 : 17);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await tester.pumpWidget(page(240));
          await tester.pumpAndSettle();
          expect(scroll.position.maxScrollExtent, 40);
          expect(scroll.offset, keep ? 40 : 17);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          scroll.dispose();
        }
      },
    );
  }
}
