import 'dart:ui' as ui;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/common.dart';
import 'live_test.dart' show FakeGateway, theme;

Future<List<int>> pixel(WidgetTester t, int x, int y) async {
  final boundary = t.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('gradient')),
  );
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    final bytes = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    return bytes.sublist(
      (y * image.width + x) * 4,
      (y * image.width + x) * 4 + 4,
    );
  } finally {
    image.dispose();
  }
}

void main() {
  for (final normalized in [false, true]) {
    testWidgets('alpha gradient paints exactly once normalized=$normalized', (
      t,
    ) async {
      var markup =
          '<div id="alpha" style="width:100px;height:100px;background:linear-gradient(rgba(255,0,0,0),rgba(0,0,255,.5)) white"></div>';
      if (normalized) {
        final document = html.parse(markup);
        NativeDocumentStyleEngine(
          stylesheets: const [],
          viewportWidth: 390,
          dark: false,
          documentBaseUrl: 'https://gateway.example/',
        ).apply(document);
        markup = document.querySelector('#alpha')!.outerHtml;
      }
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('gradient'),
              child: SizedBox(
                width: 100,
                height: 100,
                child: RichTextBody(markup, gateway: FakeGateway()),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      final gradient = find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).gradient != null,
      );
      expect(gradient, findsOneWidget);
      final center = (await t.runAsync(() => pixel(t, 50, 50)))!;
      // CSS midpoint is roughly 25% opaque blue composited over white.
      expect(center[0], inInclusiveRange(188, 195));
      expect(center[1], inInclusiveRange(188, 195));
      expect(center[2], 255);
      expect(center[3], 255);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets(
    'transparent gradient retains its independently painted fallback color',
    (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('gradient'),
              child: SizedBox(
                width: 100,
                height: 100,
                child: RichTextBody(
                  '<div style="width:100px;height:100px;background:linear-gradient(transparent,transparent) #00ff00"></div>',
                  gateway: FakeGateway(),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      final center = (await t.runAsync(() => pixel(t, 50, 50)))!;
      expect(center, [0, 255, 0, 255]);
      expect(t.takeException(), isNull);
    },
  );

  for (final normalized in [false, true]) {
    testWidgets('radial gradient paints through HTML normalized=$normalized', (
      t,
    ) async {
      var markup =
          '<div id="radial" style="width:100px;height:100px;background:radial-gradient(circle at center,#00ff00 0%,#000000 100%)"></div>';
      if (normalized) {
        final document = html.parse(markup);
        NativeDocumentStyleEngine(
          stylesheets: const [],
          viewportWidth: 390,
          dark: false,
          documentBaseUrl: 'https://gateway.example/',
        ).apply(document);
        markup = document.querySelector('#radial')!.outerHtml;
      }
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('gradient'),
              child: SizedBox(
                width: 100,
                height: 100,
                child: RichTextBody(markup, gateway: FakeGateway()),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      final center = (await t.runAsync(() => pixel(t, 50, 50)))!;
      final edge = (await t.runAsync(() => pixel(t, 5, 5)))!;
      expect(center[1], greaterThan(200));
      expect(center[0], lessThan(40));
      expect(center[2], lessThan(40));
      expect(edge.take(3), everyElement(lessThan(40)));
      expect(t.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'normal Markdown HTML paints directional gradient in $brightness',
      (t) async {
        final g = FakeGateway();
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(brightness),
            home: Scaffold(
              body: RepaintBoundary(
                key: const ValueKey('gradient'),
                child: SizedBox(
                  width: 100,
                  height: 100,
                  child: RichTextBody(
                    '<div style="width:100px;height:100px;background:linear-gradient(to right,red,blue)"></div>',
                    gateway: g,
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pump();
        final left = (await t.runAsync(() => pixel(t, 2, 50)))!;
        final right = (await t.runAsync(() => pixel(t, 97, 50)))!;
        expect(left[0], greaterThan(240));
        expect(left[2], lessThan(15));
        expect(right[2], greaterThan(240));
        expect(right[0], lessThan(15));
        expect(t.takeException(), isNull);
        expect(g.calls.where((c) => c.$1 == 'image'), isEmpty);
      },
    );
  }
  testWidgets(
    'border and radius remain present beside gradient; none resets image',
    (t) async {
      Widget body(String background) => MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: RichTextBody(
            '<div style="width:100px;height:100px;border:4px solid green;border-radius:12px;background:$background">Text</div>',
            gateway: FakeGateway(),
          ),
        ),
      );
      await t.pumpWidget(body('linear-gradient(red,blue) white'));
      await t.pump();
      final decorated = find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).gradient != null,
      );
      expect(decorated, findsOneWidget);
      final decoration =
          (t.widget<Container>(decorated).decoration as BoxDecoration);
      expect(decoration.border, isNotNull);
      expect(decoration.borderRadius, isNotNull);
      expect(find.text('Text', findRichText: true), findsOneWidget);
      await t.pumpWidget(body('white; background-image:none'));
      await t.pump();
      expect(decorated, findsNothing);
      expect(t.takeException(), isNull);
    },
  );
}
