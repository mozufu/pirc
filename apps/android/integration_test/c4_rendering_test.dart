import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_render/src/mermaid/c4_layout.dart';
import 'package:pirc_render/src/mermaid/c4_rendering.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_mobile/theme.dart';

import 'c4_android_cases.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late PircTheme theme;
  setUpAll(() async {
    theme = await PircTheme.load();
    expect(c4AndroidCases, hasLength(8));
    expect(c4AndroidParserFixtureSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  for (final fixture in c4AndroidCases) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets(
        '${fixture.id} renders through NativeMarkdown in ${brightness.name}',
        (tester) async {
          final controller = ScrollController();
          addTearDown(controller.dispose);
          final captureKey = ValueKey('c4-capture-${fixture.id}');
          final viewportKey = ValueKey('c4-viewport-${fixture.id}');
          final source = '~~~mermaid\n${fixture.source}\n~~~';

          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(brightness),
              home: Scaffold(
                body: SizedBox.expand(
                  key: viewportKey,
                  child: SingleChildScrollView(
                    controller: controller,
                    child: RepaintBoundary(
                      key: captureKey,
                      child: NativeMarkdown(source: source),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull, reason: fixture.id);
          expect(
            find.byType(NativeMermaid),
            findsOneWidget,
            reason: fixture.id,
          );
          expect(
            find.byType(NativeMermaidC4),
            findsOneWidget,
            reason: fixture.id,
          );
          expect(
            find.textContaining('Mermaid:'),
            findsNothing,
            reason: fixture.id,
          );
          expect(find.text(fixture.source), findsNothing, reason: fixture.id);

          final chart = find.byType(NativeMermaidC4);
          final paintFinder = find.descendant(
            of: chart,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is CustomPaint && widget.painter is NativeC4Painter,
            ),
          );
          expect(paintFinder, findsOneWidget, reason: fixture.id);
          final layout =
              (tester.widget<CustomPaint>(paintFinder).painter!
                      as NativeC4Painter)
                  .layout;
          _expectFigureContent(fixture, layout);
          debugPrint('C4_ANDROID_CONTENT:${fixture.id}:${brightness.name}');
          await _expectRealPainterPixels(
            tester,
            paintFinder,
            captureKey,
            layout,
            fixture.id,
          );
          debugPrint('C4_ANDROID_PIXELS:${fixture.id}:${brightness.name}');
          await _scrollToLastNode(
            tester,
            controller,
            viewportKey,
            paintFinder,
            layout,
            fixture.id,
          );
          expect(tester.takeException(), isNull, reason: fixture.id);
          debugPrint(
            'C4_ANDROID_ACCEPTED:${fixture.id}:${brightness.name}:'
            '$c4AndroidParserFixtureSha256',
          );
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  }
}

void _expectFigureContent(C4AndroidCase fixture, NativeC4Layout layout) {
  final diagram = layout.diagram;
  expect(diagram.kind, fixture.kind, reason: fixture.id);
  expect(diagram.title, fixture.title, reason: fixture.id);
  expect(diagram.shapes, hasLength(fixture.expectedNodes.length));
  expect(diagram.boundaries, hasLength(fixture.expectedBoundaries.length));
  expect(diagram.relations, hasLength(fixture.expectedRelations.length));
  expect(layout.nodes.keys.toSet(), fixture.expectedNodeAliases.toSet());
  expect(layout.nodes, hasLength(fixture.expectedNodes.length));
  expect(layout.relations, hasLength(fixture.expectedRelations.length));

  for (final expected in fixture.expectedNodes) {
    final node = layout.nodes[expected.alias];
    expect(node, isNotNull, reason: '${fixture.id} ${expected.alias}');
    expect(node!.sections.first.text, nativeC4PlainText(expected.label));
    expect(node.shape.kind, expected.kind);
    expect(node.shape.technology ?? '', expected.technology);
    if (expected.description.isNotEmpty) {
      expect(
        node.sections.map((section) => section.text),
        contains(nativeC4PlainText(expected.description)),
      );
    }
  }

  for (final expected in fixture.expectedBoundaries) {
    final boundary = layout.boundaries[expected.alias];
    expect(boundary, isNotNull, reason: '${fixture.id} ${expected.alias}');
    if (expected.alias == 'global') continue;
    expect(boundary!.label.text, nativeC4PlainText(expected.label));
    expect(boundary.type.text, '[${nativeC4PlainText(expected.type)}]');
    if (expected.description.isNotEmpty) {
      expect(
        boundary.description?.text,
        nativeC4PlainText(expected.description),
      );
    }
  }

  for (var i = 0; i < fixture.expectedRelations.length; i++) {
    final expected = fixture.expectedRelations[i];
    final relation = layout.relations[i];
    final sequence = fixture.kind == 'C4Dynamic' ? '${i + 1}: ' : '';
    expect(relation.relation.from, expected.from);
    expect(relation.relation.to, expected.to);
    expect(
      relation.label.text,
      '$sequence${nativeC4PlainText(expected.label)}',
    );
    expect(
      relation.technology?.text ?? '',
      expected.technology.isEmpty
          ? ''
          : '[${nativeC4PlainText(expected.technology)}]',
    );
  }
}

Future<void> _expectRealPainterPixels(
  WidgetTester tester,
  Finder paintFinder,
  Key captureKey,
  NativeC4Layout layout,
  String reason,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(captureKey),
  );
  final painterBox = tester.renderObject<RenderBox>(paintFinder);
  final topLeft = boundary.globalToLocal(painterBox.localToGlobal(Offset.zero));
  final bottomRight = boundary.globalToLocal(
    painterBox.localToGlobal(
      Offset(painterBox.size.width, painterBox.size.height),
    ),
  );
  final nodeFills = layout.nodes.values
      .map((node) => _rgb(nativeC4Fill(node.shape)))
      .toSet();
  final relationColors = layout.relations
      .map(
        (relation) => _rgb(
          nativeC4Color(relation.relation.lineColor, const Color(0xff444444)),
        ),
      )
      .toSet();

  final pixels = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) return null;
      final left = topLeft.dx.floor().clamp(0, image.width).toInt();
      final top = topLeft.dy.floor().clamp(0, image.height).toInt();
      final right = bottomRight.dx.ceil().clamp(0, image.width).toInt();
      final bottom = bottomRight.dy.ceil().clamp(0, image.height).toInt();
      var visible = 0, filled = 0, linked = 0;
      final colors = <int>{};
      for (var y = top; y < bottom; y++) {
        for (var x = left; x < right; x++) {
          final offset = (y * image.width + x) * 4;
          final red = rgba.getUint8(offset);
          final green = rgba.getUint8(offset + 1);
          final blue = rgba.getUint8(offset + 2);
          if (rgba.getUint8(offset + 3) == 0) continue;
          visible++;
          final color = (red << 16) | (green << 8) | blue;
          colors.add(color);
          if (nodeFills.contains(color)) filled++;
          if (relationColors.contains(color)) linked++;
        }
      }
      return (
        width: right - left,
        height: bottom - top,
        visible: visible,
        filled: filled,
        linked: linked,
        colors: colors.length,
      );
    } finally {
      image.dispose();
    }
  });
  expect(pixels, isNotNull, reason: '$reason painter image');
  expect(pixels!.width, greaterThan(0), reason: reason);
  expect(pixels.height, greaterThan(0), reason: reason);
  expect(pixels.visible, greaterThan(0), reason: reason);
  expect(pixels.colors, greaterThan(1), reason: reason);
  expect(
    pixels.filled,
    greaterThan(0),
    reason: '$reason node fill was painted',
  );
  if (layout.relations.isNotEmpty) {
    expect(
      pixels.linked,
      greaterThan(0),
      reason: '$reason relation was painted',
    );
  }
}

Future<void> _scrollToLastNode(
  WidgetTester tester,
  ScrollController controller,
  Key viewportKey,
  Finder paintFinder,
  NativeC4Layout layout,
  String reason,
) async {
  final scrolling = controller.animateTo(
    controller.position.maxScrollExtent,
    duration: const Duration(milliseconds: 250),
    curve: Curves.easeOut,
  );
  await tester.pumpAndSettle();
  await scrolling;
  expect(
    controller.position.pixels,
    closeTo(controller.position.maxScrollExtent, .5),
    reason: '$reason reached scroll end',
  );
  final lastNode = layout.nodes.values.reduce(
    (a, b) => a.bounds.bottom >= b.bounds.bottom ? a : b,
  );
  final painterBox = tester.renderObject<RenderBox>(paintFinder);
  final viewportBox = tester.renderObject<RenderBox>(find.byKey(viewportKey));
  final nodeRect = Rect.fromPoints(
    painterBox.localToGlobal(lastNode.bounds.topLeft + layout.viewBoxOffset),
    painterBox.localToGlobal(
      lastNode.bounds.bottomRight + layout.viewBoxOffset,
    ),
  );
  final viewportRect = Rect.fromPoints(
    viewportBox.localToGlobal(Offset.zero),
    viewportBox.localToGlobal(
      Offset(viewportBox.size.width, viewportBox.size.height),
    ),
  );
  expect(
    viewportRect.contains(nodeRect.topLeft) &&
        viewportRect.contains(nodeRect.bottomRight),
    isTrue,
    reason: '$reason last node ${lastNode.shape.alias} visible at scroll end',
  );
}

int _rgb(Color color) => color.toARGB32() & 0xffffff;
