import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/c4_layout.dart';
import 'package:pirc_render/src/mermaid/c4_rendering.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_mobile/theme.dart';

final _parserFixture = _readJson([
  '../../fixtures/mobile-parity/mermaid-c4-parser-expected.json',
  'fixtures/mobile-parity/mermaid-c4-parser-expected.json',
]);
final _validCases = (_parserFixture['cases'] as List)
    .map(_map)
    .toList(growable: false);

late PircTheme _theme;

void main() {
  setUpAll(() {
    _theme = PircTheme(
      _readJson([
        'assets/design-tokens.json',
        'apps/android/assets/design-tokens.json',
      ]),
    );
    expect(_validCases, hasLength(8));
  });

  for (final fixtureCase in _validCases) {
    final id = fixtureCase['id'] as String;
    for (final width in [390.0, 768.0]) {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        for (final textScale in [1.0, 2.0]) {
          testWidgets('$id renders through Markdown at ${width.toInt()}px, '
              '${brightness.name}, text scale $textScale', (tester) async {
            final source = fixtureCase['source'] as String;
            final fencedSource = '~~~mermaid\n$source\n~~~';
            final captureKey = ValueKey('c4-capture-$id');
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 900);
            addTearDown(tester.view.reset);

            await tester.pumpWidget(
              MaterialApp(
                theme: _theme.build(brightness),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 900),
                    devicePixelRatio: 1,
                    platformBrightness: brightness,
                    textScaler: TextScaler.linear(textScale),
                  ),
                  child: Scaffold(
                    body: SingleChildScrollView(
                      child: RepaintBoundary(
                        key: captureKey,
                        child: NativeMarkdown(source: fencedSource),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();

            expect(tester.takeException(), isNull, reason: id);
            expect(find.byType(NativeMermaid), findsOneWidget);
            expect(find.byType(NativeMermaidC4), findsOneWidget);
            expect(
              find.byKey(const ValueKey('native-mermaid-c4-chart')),
              findsOneWidget,
            );
            expect(find.text(source), findsNothing);
            expect(find.textContaining('Mermaid:'), findsNothing);

            final chart = find.byType(NativeMermaidC4);
            final customPaint = find
                .descendant(of: chart, matching: find.byType(CustomPaint))
                .first;
            final painter = tester.widget<CustomPaint>(customPaint).painter;
            expect(painter, isA<NativeC4Painter>());
            final layout = (painter! as NativeC4Painter).layout;
            _expectAllVisibleTextInLayout(layout, id);
            _expectNodeLabelsInsideTheirGeometry(layout, id);
            _expectPaintedLabelsInsideLayout(layout, id);
            _expectSemanticsContainsEveryVisibleText(tester, chart, layout);

            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(captureKey),
            );
            final pixels = await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 1);
              try {
                final rgba = await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                );
                if (rgba == null) return null;
                var visiblePixels = 0;
                final colors = <int>{};
                for (
                  var offset = 0;
                  offset + 3 < rgba.lengthInBytes;
                  offset += 4 * 64
                ) {
                  final alpha = rgba.getUint8(offset + 3);
                  if (alpha == 0) continue;
                  visiblePixels++;
                  colors.add(
                    (rgba.getUint8(offset) << 16) |
                        (rgba.getUint8(offset + 1) << 8) |
                        rgba.getUint8(offset + 2),
                  );
                }
                return (
                  width: image.width,
                  height: image.height,
                  byteLength: rgba.lengthInBytes,
                  visiblePixels: visiblePixels,
                  distinctColors: colors.length,
                );
              } finally {
                image.dispose();
              }
            });
            expect(pixels, isNotNull, reason: '$id produced no image bytes');
            expect(pixels!.width, greaterThan(0), reason: id);
            expect(pixels.height, greaterThan(0), reason: id);
            expect(pixels.byteLength, greaterThan(0), reason: id);
            expect(pixels.visiblePixels, greaterThan(0), reason: id);
            expect(
              pixels.distinctColors,
              greaterThan(1),
              reason: '$id painted an empty or uniform image',
            );
            expect(tester.takeException(), isNull, reason: id);
          });
        }
      }
    }
  }

  testWidgets('unsupported C4 and streaming retain their source and status', (
    tester,
  ) async {
    const unsupported =
        'C4Component\nComponent(api, "Checkout API", "Go", "Description", "sprite-name")';
    const streamed = 'C4Context\nPerson(user, "User")';
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    addTearDown(tester.view.reset);

    Widget host(String source, {bool streaming = false}) => MaterialApp(
      theme: _theme.build(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: NativeMarkdown(
            source: '~~~mermaid\n$source\n~~~',
            streaming: streaming,
          ),
        ),
      ),
    );

    await tester.pumpWidget(host(unsupported));
    await tester.pumpAndSettle();
    expect(find.byType(NativeMermaid), findsOneWidget);
    expect(find.byType(NativeMermaidC4), findsNothing);
    expect(find.text(unsupported), findsOneWidget);
    expect(find.textContaining('Mermaid:'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(host(streamed, streaming: true));
    await tester.pumpAndSettle();
    expect(find.byType(NativeMermaid), findsOneWidget);
    expect(find.byType(NativeMermaidC4), findsNothing);
    expect(find.text(streamed), findsOneWidget);
    expect(find.textContaining('Mermaid:'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(host(unsupported, streaming: true));
    await tester.pumpAndSettle();
    expect(find.text(unsupported), findsOneWidget);
    expect(find.textContaining('Mermaid:'), findsNothing);

    await tester.pumpWidget(host(unsupported));
    await tester.pumpAndSettle();
    expect(find.text(unsupported), findsOneWidget);
    expect(find.textContaining('Mermaid:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

void _expectAllVisibleTextInLayout(NativeC4Layout layout, String reason) {
  for (final shape in layout.diagram.shapes) {
    final node = layout.nodes[shape.alias];
    expect(node, isNotNull, reason: '$reason node ${shape.alias} missing');
    expect(node!.sections, isNotEmpty, reason: '$reason ${shape.alias}');
    expect(node.sections.first.text, nativeC4PlainText(shape.label));
    expect(
      node.sections[1].text,
      nativeC4PlainText(nativeC4Stereotype(shape)),
      reason: '$reason ${shape.alias} stereotype/type/technology',
    );
    if (shape.type?.isNotEmpty == true) {
      expect(
        node.sections.any((section) => section.text.contains(shape.type!)),
        isTrue,
        reason: '$reason ${shape.alias} custom type',
      );
    }
    if (shape.description?.isNotEmpty == true) {
      expect(
        node.sections.any(
          (section) => section.text == nativeC4PlainText(shape.description!),
        ),
        isTrue,
        reason: '$reason ${shape.alias} description',
      );
    }
  }

  for (final boundary in layout.diagram.boundaries) {
    final rendered = layout.boundaries[boundary.alias];
    expect(rendered, isNotNull, reason: '$reason boundary ${boundary.alias}');
    expect(rendered!.label.text, nativeC4PlainText(boundary.label));
    expect(
      rendered.type.text,
      boundary.type.isEmpty ? '' : '[${nativeC4PlainText(boundary.type)}]',
    );
    if (boundary.description?.isNotEmpty == true) {
      expect(
        rendered.description?.text,
        nativeC4PlainText(boundary.description!),
        reason: '$reason boundary description ${boundary.alias}',
      );
    }
  }

  expect(layout.relations, hasLength(layout.diagram.relations.length));
  for (var index = 0; index < layout.relations.length; index++) {
    final relation = layout.relations[index];
    final source = layout.diagram.relations[index];
    final prefix = layout.diagram.kind == 'C4Dynamic' ? '${index + 1}: ' : '';
    expect(
      relation.label.text,
      nativeC4PlainText('$prefix${source.label}'),
      reason: '$reason relation[$index] label/sequence number',
    );
    expect(
      relation.technology?.text ?? '',
      source.technology.isEmpty
          ? ''
          : '[${nativeC4PlainText(source.technology)}]',
      reason: '$reason relation[$index] technology',
    );
  }

  if (layout.title != null) {
    expect(layout.title!.text, nativeC4PlainText(layout.diagram.title!));
  }
}

void _expectSemanticsContainsEveryVisibleText(
  WidgetTester tester,
  Finder chart,
  NativeC4Layout layout,
) {
  final semanticsFinder = find.descendant(
    of: chart,
    matching: find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.image == true,
    ),
  );
  expect(semanticsFinder, findsOneWidget);
  final semantics = tester.widget<Semantics>(semanticsFinder);
  final label = semantics.properties.label ?? '';

  void expectSemanticText(String value, String reason) {
    if (value.isEmpty) return;
    expect(label, contains(value), reason: reason);
  }

  expectSemanticText(layout.diagram.kind, 'diagram type');
  if (layout.title != null) {
    expectSemanticText(layout.title!.text, 'diagram title');
  }
  for (final node in layout.nodes.values) {
    for (final section in node.sections) {
      expectSemanticText(section.text, 'shape ${node.shape.alias}');
    }
  }
  for (final boundary in layout.boundaries.values) {
    if (boundary.boundary.alias == 'global') continue;
    expectSemanticText(
      boundary.label.text,
      'boundary ${boundary.boundary.alias} label',
    );
    expectSemanticText(
      boundary.type.text,
      'boundary ${boundary.boundary.alias} type',
    );
    if (boundary.description != null) {
      expectSemanticText(
        boundary.description!.text,
        'boundary ${boundary.boundary.alias} description',
      );
    }
  }
  for (final relation in layout.relations) {
    expectSemanticText(
      '${relation.relation.from} → ${relation.relation.to}: '
          '${relation.label.text}',
      'relationship ${relation.relation.from} to ${relation.relation.to}',
    );
    if (relation.technology != null) {
      expectSemanticText(relation.technology!.text, 'relationship technology');
    }
  }
}

void _expectNodeLabelsInsideTheirGeometry(
  NativeC4Layout layout,
  String reason,
) {
  for (final node in layout.nodes.values) {
    final labelRect = node.geometry.labelRect;
    final outlineBounds = node.geometry.outline.getBounds();
    _expectRectWithin(labelRect, outlineBounds, '$reason ${node.shape.alias}');
    expect(
      labelRect.height + .01,
      greaterThanOrEqualTo(node.labelSize.height),
      reason: '$reason ${node.shape.alias} label height',
    );

    var y = labelRect.top;
    for (final section in node.sections) {
      final sectionBounds = Rect.fromLTWH(
        labelRect.center.dx - section.size.width / 2,
        y,
        section.size.width,
        section.size.height,
      );
      _expectRectWithin(
        sectionBounds,
        Offset.zero & node.geometry.size,
        '$reason ${node.shape.alias} section ${section.text}',
      );
      y += section.size.height + 3;
    }
  }
}

void _expectPaintedLabelsInsideLayout(NativeC4Layout layout, String reason) {
  final chartBounds = Offset.zero & layout.size;
  for (final node in layout.nodes.values) {
    final rect = Rect.fromLTWH(
      node.bounds.left + layout.viewBoxOffset.dx + node.geometry.labelRect.left,
      node.bounds.top + layout.viewBoxOffset.dy + node.geometry.labelRect.top,
      node.geometry.labelRect.width,
      node.geometry.labelRect.height,
    );
    _expectRectWithin(rect, chartBounds, '$reason ${node.shape.alias}');
  }
}

void _expectRectWithin(Rect actual, Rect bounds, String reason) {
  expect(actual.left, greaterThanOrEqualTo(bounds.left - .02), reason: reason);
  expect(actual.top, greaterThanOrEqualTo(bounds.top - .02), reason: reason);
  expect(actual.right, lessThanOrEqualTo(bounds.right + .02), reason: reason);
  expect(actual.bottom, lessThanOrEqualTo(bounds.bottom + .02), reason: reason);
}

Map<String, dynamic> _readJson(List<String> candidates) {
  final file = candidates
      .map(File.new)
      .where((file) => file.existsSync())
      .firstOrNull;
  if (file == null) {
    throw FileSystemException('Could not find a C4 rendering test fixture');
  }
  return _map(jsonDecode(file.readAsStringSync()));
}

Map<String, dynamic> _map(Object? value) =>
    Map<String, dynamic>.from(value as Map);
