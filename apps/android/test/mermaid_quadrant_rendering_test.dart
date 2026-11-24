import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import 'package:pirc_render/src/mermaid/quadrant_parser.dart';
import 'package:pirc_render/src/mermaid/quadrant_rendering.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'live_test.dart' show theme;

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/mermaid-quadrant-xy.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final expected =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/mermaid-quadrant-xy-expected.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final fixtureCases = fixture['cases'] as List<dynamic>;
  final source =
      (fixtureCases.first as Map<String, dynamic>)['source'] as String;
  final diagram = parseNativeMermaidQuadrant(source);

  group('layoutNativeMermaidQuadrant', () {
    test(
      'matches pinned Chrome user-unit rectangles and point coordinates',
      () {
        final layout = layoutNativeMermaidQuadrant(
          diagram,
          width: 332,
          dark: false,
        );
        final webCase = _webCase(expected, 'light', 'quadrant-labeled-styled');
        final shapes =
            _sharedGeometry(expected, webCase)['shapes'] as List<dynamic>;
        final webRects = shapes
            .where((shape) => shape['tag'] == 'rect')
            .take(4)
            .toList();

        expect(layout.viewBoxSize, const Size(470, 340));
        expect(layout.quadrants, hasLength(4));
        for (var i = 0; i < webRects.length; i++) {
          final attrs = webRects[i]['attrs'] as Map<String, dynamic>;
          expect(
            layout.quadrants[i].left,
            closeTo(double.parse(attrs['x']), .001),
          );
          expect(
            layout.quadrants[i].top,
            closeTo(double.parse(attrs['y']), .001),
          );
          expect(
            layout.quadrants[i].width,
            closeTo(double.parse(attrs['width']), .001),
          );
          expect(
            layout.quadrants[i].height,
            closeTo(double.parse(attrs['height']), .001),
          );
        }
        final webCircles = shapes
            .where((shape) => shape['tag'] == 'circle')
            .toList();
        for (var i = 0; i < webCircles.length; i++) {
          final circle = webCircles[i];
          final actual = layout.points[i];
          final label = actual.point.label;
          final attrs = circle['attrs'] as Map<String, dynamic>;
          expect(
            actual.center.dx,
            closeTo(double.parse(attrs['cx']), .001),
            reason: label,
          );
          expect(
            actual.center.dy,
            closeTo(double.parse(attrs['cy']), .001),
            reason: label,
          );
          expect(
            actual.radius,
            closeTo(double.parse(attrs['r']), .001),
            reason: label,
          );
        }
        final market = layout.points.singleWhere(
          (point) => point.point.label == 'Market, east',
        );
        expect(market.fill, const Color(0xff123456));
        expect(market.stroke, const Color(0xff31572c));
        expect(market.strokeWidth, 2);
        expect(layout.axisLabels.map((label) => label.text), [
          'Low reach',
          'High reach',
          'Low effort',
          'High effort',
        ]);
        expect(layout.axisLabels.first.position.dy, closeTo(319, .001));
        expect(layout.title?.position, const Offset(235, 10));
        expect(
          layout.points
              .singleWhere((p) => p.point.label == 'Inline style')
              .radius,
          9,
        );
      },
    );

    test(
      'uses responsive square-proportional SVG sizing without changing user units',
      () {
        final narrow = layoutNativeMermaidQuadrant(
          diagram,
          width: 332,
          dark: false,
        );
        final wide = layoutNativeMermaidQuadrant(
          diagram,
          width: 1024,
          dark: false,
        );
        expect(narrow.size.width, 332);
        expect(narrow.scale, closeTo(332 / 470, .000001));
        expect(narrow.size.height, closeTo(340 * 332 / 470, .001));
        expect(wide.size, const Size(470, 340));
        expect(wide.scale, 1);
        expect(narrow.quadrants, wide.quadrants);
      },
    );

    test('matches the light and dark Mermaid theme colors', () {
      final light = layoutNativeMermaidQuadrant(
        diagram,
        width: 470,
        dark: false,
      );
      final dark = layoutNativeMermaidQuadrant(diagram, width: 470, dark: true);
      expect(light.quadrantFills, const [
        Color(0xffedf3fe),
        Color(0xfff2f8ff),
        Color(0xfff7fdff),
        Color(0xfffcffff),
      ]);
      expect(dark.quadrantFills, const [
        Color(0xff1f2020),
        Color(0xff242525),
        Color(0xff292a2a),
        Color(0xff2e2f2f),
      ]);
      expect(light.borders.first.color, const Color(0xff4176e6));
      expect(dark.borders.first.color, const Color(0xffcccccc));
    });
  });

  testWidgets(
    'scales the fixed-pixel SVG labels independently of UI text scale',
    (tester) async {
      final semantics = tester.ensureSemantics();
      for (final width in [390.0, 650.0, 1024.0]) {
        for (final scale in [1.0, 2.0]) {
          for (final dark in [false, true]) {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 900);
            await tester.pumpWidget(
              MaterialApp(
                theme: dark ? ThemeData.dark() : ThemeData.light(),
                home: Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: Scaffold(
                      body: SizedBox(
                        width: width,
                        child: NativeMermaidQuadrant(
                          diagram: diagram,
                          dark: dark,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            expect(tester.takeException(), isNull);
            final paint = find.descendant(
              of: find.byType(NativeMermaidQuadrant),
              matching: find.byType(CustomPaint),
            );
            final size = tester.getSize(paint);
            expect(size.width, closeTo(width < 470 ? width : 470, .01));
            expect(size.height, closeTo(size.width * 340 / 470, .01));
            expect(
              find.bySemanticsLabel(diagram.semanticsLabel),
              findsOneWidget,
            );
          }
        }
      }
      semantics.dispose();
    },
  );

  testWidgets('Markdown dispatch waits for the complete quadrant source', (
    tester,
  ) async {
    const body = '''
quadrantChart
title Streaming chart
quadrant-1 Grow
quadrant-2 Keep
quadrant-3 Drop
quadrant-4 Try
''';
    final markdown = '```mermaid\n$body```';
    final appTheme = theme.build(Brightness.light);

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(body: NativeMarkdown(source: markdown, streaming: true)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NativeMermaidQuadrant), findsNothing);
    expect(find.textContaining('quadrantChart'), findsOneWidget);
    expect(find.textContaining('Mermaid:'), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(body: NativeMarkdown(source: markdown)),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(NativeMermaid), findsOneWidget);
    expect(find.byType(NativeMermaidQuadrant), findsOneWidget);
    expect(find.textContaining('Mermaid:'), findsNothing);
  });
}

Map<String, dynamic> _webCase(
  Map<String, dynamic> expected,
  String theme,
  String id,
) {
  final widths = expected['themes'][theme]['widths'] as List<dynamic>;
  final scales = widths.first['scales'] as List<dynamic>;
  final cases = scales.first['cases'] as List<dynamic>;
  return cases.cast<Map<String, dynamic>>().singleWhere(
    (value) => value['id'] == id,
  );
}

Map<String, dynamic> _sharedGeometry(
  Map<String, dynamic> expected,
  Map<String, dynamic> webCase,
) =>
    expected['geometryCatalog'][webCase['svg']['geometryId']]['shared']
        as Map<String, dynamic>;
