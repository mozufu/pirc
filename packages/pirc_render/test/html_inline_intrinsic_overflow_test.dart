import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_inline_intrinsic_overflow.dart';

void main() {
  testWidgets(
    'overflow host widens only marked descendants and keeps its own constraints',
    (tester) async {
      const hostKey = ValueKey('overflow-host');
      const markerKey = ValueKey('overflow-marker');
      const markedChildKey = ValueKey('marked-child');
      const ordinaryChildKey = ValueKey('ordinary-child');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 100,
                    height: 60,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: NativeHtmlInlineOverflowHost(
                        key: hostKey,
                        child: NativeHtmlInlineIntrinsicOverflow(
                          key: markerKey,
                          intrinsicSize: const Size(240, 40),
                          baselineFromTop: 30,
                          child: const SizedBox(
                            key: markedChildKey,
                            width: 240,
                            height: 40,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 100,
                    height: 60,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: NativeHtmlInlineOverflowHost(
                        child: const SizedBox(
                          key: ordinaryChildKey,
                          width: 240,
                          height: 40,
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
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(tester.getSize(find.byKey(hostKey)), const Size(100, 40));
      expect(tester.getSize(find.byKey(markerKey)), const Size(240, 40));
      expect(tester.getSize(find.byKey(markedChildKey)), const Size(240, 40));
      expect(tester.getSize(find.byKey(ordinaryChildKey)).width, 100);
    },
  );

  testWidgets(
    'visible overflow root forwards taps past nested bounds but not past a clip or its own bounds',
    (tester) async {
      var visibleTaps = 0;
      var clippedTaps = 0;
      const rootKey = ValueKey('visible-overflow-root');
      const visibleMarkerKey = ValueKey('visible-marker');
      const clippedMarkerKey = ValueKey('clipped-marker');

      Widget control({required Key key, required VoidCallback onTap}) =>
          NativeHtmlInlineOverflowHost(
            child: NativeHtmlInlineIntrinsicOverflow(
              key: key,
              intrinsicSize: const Size(240, 40),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: const SizedBox(width: 240, height: 40),
              ),
            ),
          );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                height: 120,
                child: NativeHtmlVisibleInlineOverflowRoot(
                  key: rootKey,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 100,
                          height: 50,
                          child: control(
                            key: visibleMarkerKey,
                            onTap: () => visibleTaps++,
                          ),
                        ),
                        SizedBox(
                          width: 100,
                          height: 50,
                          child: ClipRect(
                            child: control(
                              key: clippedMarkerKey,
                              onTap: () => clippedTaps++,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final rootRect = tester.getRect(find.byKey(rootKey));
      final visibleRect = tester.getRect(find.byKey(visibleMarkerKey));
      final clippedRect = tester.getRect(find.byKey(clippedMarkerKey));
      final visiblePoint = Offset(
        visibleRect.left + 160,
        visibleRect.center.dy,
      );
      final clippedPoint = Offset(
        clippedRect.left + 160,
        clippedRect.center.dy,
      );
      expect(visiblePoint.dx, greaterThan(rootRect.left + 100));
      expect(visiblePoint.dx, lessThan(rootRect.right));
      expect(clippedPoint.dx, greaterThan(rootRect.left + 100));

      await tester.tapAt(visiblePoint);
      await tester.pump();
      expect(visibleTaps, 1);

      await tester.tapAt(clippedPoint);
      await tester.pump();
      expect(clippedTaps, 0);

      await tester.tapAt(Offset(rootRect.right + 8, visiblePoint.dy));
      await tester.pump();
      expect(visibleTaps, 1);
    },
  );

  testWidgets(
    'inline replaced box retains intrinsic width, surrounding text wraps, and hit testing survives',
    (tester) async {
      var taps = 0;
      const paragraphKey = ValueKey('paragraph');
      const hostKey = ValueKey('file-host');
      const childKey = ValueKey('file-child');
      const boundaryKey = ValueKey('paint-boundary');
      const intrinsic = Size(240, 40);
      const intrinsicWidth = 240.0;
      const intrinsicHeight = 40.0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: boundaryKey,
                child: SizedBox(
                  width: 300,
                  height: 140,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minWidth: 100,
                      maxWidth: 100,
                      child: NativeHtmlInlineOverflowRichText.fromRichText(
                        RichText(
                          key: paragraphKey,
                          softWrap: true,
                          // The source defaults to clip. The host HTML tree
                          // opts into visible overflow only when no authored
                          // clipping rule applies.
                          text: TextSpan(
                            style: const TextStyle(
                              fontSize: 16,
                              color: Colors.black,
                            ),
                            children: [
                              const TextSpan(text: 'before '),
                              WidgetSpan(
                                alignment: PlaceholderAlignment.baseline,
                                baseline: TextBaseline.alphabetic,
                                child: NativeHtmlInlineIntrinsicOverflow(
                                  key: hostKey,
                                  intrinsicSize: intrinsic,
                                  baselineFromTop: 30,
                                  child: Semantics(
                                    label: 'File upload',
                                    button: true,
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () => taps++,
                                      child: const SizedBox(
                                        key: childKey,
                                        width: intrinsicWidth,
                                        height: intrinsicHeight,
                                        child: ColoredBox(color: Colors.blue),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const TextSpan(text: ' after'),
                            ],
                          ),
                        ),
                        overflow: TextOverflow.visible,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final paragraphRect = tester.getRect(find.byKey(paragraphKey));
      final hostRect = tester.getRect(find.byKey(hostKey));
      expect(paragraphRect.width, 100);
      expect(hostRect.width, intrinsic.width);
      expect(hostRect.right, greaterThan(paragraphRect.right));
      expect(hostRect.right, lessThan(300));
      expect(tester.getSize(find.byKey(paragraphKey)).height, greaterThan(40));
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == 'File upload',
        ),
        findsOneWidget,
      );

      // Verify the portion painted beyond the paragraph's right edge is
      // visible inside its ancestor and can activate the native action.
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      final childRect = tester.getRect(find.byKey(childKey));
      final pixels = await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final boundaryRect = tester.getRect(find.byKey(boundaryKey));
          List<int> rgbAt(Offset point) {
            final pixelX = (point.dx - boundaryRect.left).floor();
            final pixelY = (point.dy - boundaryRect.top).floor();
            final offset = (pixelY * image.width + pixelX) * 4;
            return <int>[
              data.getUint8(offset),
              data.getUint8(offset + 1),
              data.getUint8(offset + 2),
            ];
          }

          return <List<int>>[
            rgbAt(childRect.center),
            rgbAt(Offset(hostRect.right - 8, hostRect.center.dy)),
            <int>[image.width, image.height],
          ];
        } finally {
          image.dispose();
        }
      });
      expect(pixels, isNotNull);
      for (final pixel in pixels!.take(2)) {
        expect(pixel[0], inInclusiveRange(20, 40), reason: '$pixels');
        expect(pixel[1], inInclusiveRange(140, 160), reason: '$pixels');
        expect(pixel[2], greaterThan(230), reason: '$pixels');
      }

      await tester.tapAt(Offset(hostRect.right - 8, hostRect.center.dy));
      await tester.pump();
      expect(taps, 1);
    },
  );

  testWidgets('RichText replacement retains selection registration', (
    tester,
  ) async {
    NativeHtmlInlineOverflowRichText? replacement;
    const selectionColor = Color(0x663366ff);

    await tester.pumpWidget(
      MaterialApp(
        home: SelectionArea(
          child: Builder(
            builder: (context) {
              final source = RichText(
                text: const TextSpan(text: 'selectable text'),
                selectionRegistrar: SelectionContainer.maybeOf(context),
                selectionColor: selectionColor,
                textScaler: TextScaler.linear(1.25),
              );
              replacement = NativeHtmlInlineOverflowRichText.fromRichText(
                source,
              );
              return replacement!;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(replacement!.selectionRegistrar, isNotNull);
    expect(replacement!.selectionColor, selectionColor);
    expect(replacement!.textScaler.scale(10), 12.5);
    expect(
      tester.renderObject(find.byWidget(replacement!)),
      isA<RenderNativeHtmlInlineOverflowParagraph>(),
    );
  });

  testWidgets('dry layout and baseline use the uncapped inline box width', (
    tester,
  ) async {
    final key = GlobalKey();
    const boundedKey = ValueKey('ordinary-inline-child');
    const intrinsic = Size(320, 48);
    const ordinaryWidth = 250.0;
    final source = RichText(
      textAlign: TextAlign.center,
      softWrap: true,
      overflow: TextOverflow.clip,
      textScaler: TextScaler.linear(1.5),
      maxLines: 3,
      text: TextSpan(
        style: const TextStyle(fontSize: 16),
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: NativeHtmlInlineIntrinsicOverflow(
              key: key,
              intrinsicSize: intrinsic,
              baselineFromTop: 34,
              child: const SizedBox(width: 320, height: 48),
            ),
          ),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: const SizedBox(
              key: boundedKey,
              width: ordinaryWidth,
              height: 20,
            ),
          ),
        ],
      ),
    );
    final paragraph = NativeHtmlInlineOverflowRichText.fromRichText(source);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SizedBox(width: 90, child: paragraph)),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(key)), intrinsic);
    final ordinaryChildWidth = tester.getSize(find.byKey(boundedKey)).width;
    expect(ordinaryChildWidth, greaterThan(0));
    expect(ordinaryChildWidth, lessThanOrEqualTo(90));
    expect(paragraph.textAlign, TextAlign.center);
    expect(paragraph.overflow, TextOverflow.clip);
    expect(paragraph.textScaler.scale(10), 15);
    expect(paragraph.maxLines, 3);
    final widget = tester.widget<NativeHtmlInlineIntrinsicOverflow>(
      find.byKey(key),
    );
    expect(widget.baselineFromTop, 34);
  });

  test('RichText replacement can override overflow and defaults to source', () {
    final source = RichText(
      text: const TextSpan(text: 'source'),
      overflow: TextOverflow.clip,
    );
    final same = NativeHtmlInlineOverflowRichText.fromRichText(source);
    final visible = NativeHtmlInlineOverflowRichText.fromRichText(
      source,
      overflow: TextOverflow.visible,
    );
    expect(same.overflow, TextOverflow.clip);
    expect(visible.overflow, TextOverflow.visible);
  });
}
