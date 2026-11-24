import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/journey_model.dart';
import 'package:pirc_render/src/mermaid/journey_parser.dart';
import 'package:pirc_render/src/mermaid/journey_rendering.dart';
import 'package:pirc_render/src/native_markdown.dart';

import '../tool/parity/capture_fonts.dart' show loadParityFonts;
import 'live_test.dart' show theme;

const _fixturePath = '../../fixtures/mobile-parity/mermaid-journey.json';

Map<String, dynamic> _object(Object? value) =>
    (value as Map).cast<String, dynamic>();

List<Map<String, dynamic>> _objects(Object? value) =>
    (value as List).map(_object).toList();

ThemeData _theme(Brightness brightness) {
  final base = theme.build(brightness);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'Mermaid reference'),
  );
}

Widget _host(String source, {required Brightness brightness}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: _theme(brightness),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: NativeMarkdown(
        source: '```mermaid\n$source\n```',
        lineHeight: 1.65,
      ),
    ),
  ),
);

String _sections(NativeMermaidJourneyDiagram diagram) =>
    jsonEncode(diagram.sections.map((section) => section.name).toList());

void main() {
  final fixture = _object(jsonDecode(File(_fixturePath).readAsStringSync()));
  final cases = _objects(fixture['cases']);

  test('journey parser agrees with pinned Mermaid Jison/DB oracle', () {
    expect(fixture['webSha'], 'bd3d90981271e1f93cf3d1d1a5bbf9b61136b74c');
    expect(fixture['mermaidVersion'], '11.17.2');
    expect(cases, hasLength(4));
    for (final item in cases) {
      final id = item['id'] as String;
      final source = item['source'] as String;
      final expected = _object(item['expected']);
      final actual = parseNativeMermaidJourney(source);

      expect(actual.title, expected['title'], reason: id);
      expect(actual.accessibleTitle, expected['accessibleTitle'], reason: id);
      expect(
        actual.accessibleDescription,
        expected['accessibleDescription'],
        reason: id,
      );
      expect(
        _sections(actual),
        jsonEncode(expected['sections']),
        reason: '$id section declarations',
      );
      expect(
        actual.actors,
        (expected['actors'] as List).cast<String>(),
        reason: '$id sorted unique actor legend',
      );

      final expectedTasks = _objects(expected['tasks']);
      expect(actual.tasks, hasLength(expectedTasks.length), reason: id);
      for (var index = 0; index < expectedTasks.length; index++) {
        final task = actual.tasks[index];
        final oracle = expectedTasks[index];
        expect(task.index, index, reason: id);
        expect(task.label, oracle['label'], reason: '$id task $index label');
        expect(
          task.sectionName,
          oracle['section'],
          reason: '$id task $index section',
        );
        expect(
          task.score,
          (oracle['score'] as num).toDouble(),
          reason: '$id task $index score',
        );
        expect(
          task.actors,
          (oracle['actors'] as List).cast<String>(),
          reason: '$id task $index actors',
        );
      }
    }
  });

  test('invalid scores and unsupported directives remain explicit', () {
    expect(
      () => parseNativeMermaidJourney('journey\nTask without score'),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidJourney('journey\nTask: not-a-number: User'),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidJourney('journey\ntitle Kept; section Lost'),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidJourney('journey\nsection Kept; task Lost: 3'),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidJourney(
        'journey\n%%{init: {"theme": "dark"}}%%\nsection A\nTask: 3',
      ),
      throwsFormatException,
    );
    final outOfRange = parseNativeMermaidJourney(
      'journey\nsection A\nBelow: -2: User\nAbove: 7.5: User',
    );
    expect(outOfRange.tasks.map((task) => task.score), [-2, 7.5]);
    final layout = layoutNativeMermaidJourney(
      outOfRange,
      width: 390,
      dark: false,
    );
    expect(layout.tasks[0].scoreCenter.dy, 510);
    expect(layout.tasks[1].scoreCenter.dy, 225);
  });

  test('source grid and color mapping retain task group boundaries', () {
    final diagram = parseNativeMermaidJourney(
      'journey\nsection A\nFirst: 5: User\nSecond: 3: User, Sales\n'
      'section B\nThird: 4: Sales',
    );
    final light = layoutNativeMermaidJourney(diagram, width: 1200, dark: false);
    final dark = layoutNativeMermaidJourney(diagram, width: 1200, dark: true);

    expect(light.sections, hasLength(2));
    expect(
      light.sections.first.bounds,
      Rect.fromLTWH(light.leftMargin, 50, 350, 50),
    );
    expect(
      light.sections.last.bounds,
      Rect.fromLTWH(light.leftMargin + 400, 50, 150, 50),
    );
    expect(light.tasks.map((task) => task.bounds.left), [
      light.leftMargin,
      light.leftMargin + 200,
      light.leftMargin + 400,
    ]);
    expect(light.tasks.map((task) => task.scoreCenter.dy), [300, 360, 330]);
    expect(light.tasks[0].fill(false), const Color(0xffedf3fe));
    expect(dark.tasks[0].fill(true), const Color(0xff1f2020));
    expect(light.tasks[1].actorBadges, hasLength(2));
    expect(light.legend.map((entry) => entry.actor), ['Sales', 'User']);
    expect(light.legend.map((entry) => entry.color), [
      const Color(0xff8fbc8f),
      const Color(0xff7cfc00),
    ]);
    expect(light.axisStartX, light.leftMargin);
    expect(light.axisEndX, greaterThan(light.tasks.last.bounds.right));

    final transitioned = layoutNativeMermaidJourney(
      parseNativeMermaidJourney(
        'journey\nBefore section: 3: Visitor\n'
        'section First real section\nInside: 3: Visitor',
      ),
      width: 1200,
      dark: false,
    );
    expect(transitioned.sections, hasLength(1));
    expect(transitioned.tasks.last.colorIndex, 0);
    expect(transitioned.tasks.last.fill(false), const Color(0xffedf3fe));
  });

  testWidgets(
    'journey renders through Markdown at phone/tablet light/dark and 1x/2x',
    (tester) async {
      await tester.runAsync(loadParityFonts);
      final semantics = tester.ensureSemantics();
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final item = cases.firstWhere((value) => value['id'] == 'checkout');
      final source = item['source'] as String;
      for (final width in [390, 768]) {
        for (final brightness in Brightness.values) {
          for (final scale in [1.0, 2.0]) {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width.toDouble(), 900);
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            await tester.pumpWidget(_host(source, brightness: brightness));
            await tester.pumpAndSettle();

            expect(tester.takeException(), isNull);
            expect(find.byType(NativeMermaidJourney), findsOneWidget);
            expect(find.textContaining('Mermaid:'), findsNothing);
            final painter = tester
                .widgetList<CustomPaint>(find.byType(CustomPaint))
                .map((widget) => widget.painter)
                .whereType<NativeMermaidJourneyPainter>()
                .single;
            expect(painter.layout.tasks, hasLength(4));
            expect(painter.layout.sections, hasLength(2));
            expect(painter.layout.legend.map((entry) => entry.actor), [
              'Customer',
              'Sales',
            ]);
            expect(
              painter.layout.size.width,
              lessThanOrEqualTo(width - 32),
              reason: 'journey fits the Markdown content width',
            );
            expect(
              painter.layout.viewBox.width,
              2 * painter.layout.leftMargin + 200 * 4,
            );
            expect(painter.layout.size.height, greaterThan(0));
            final semanticsWidget = tester.widget<Semantics>(
              find.descendant(
                of: find.byType(NativeMermaidJourney),
                matching: find.byType(Semantics),
              ),
            );
            expect(semanticsWidget.properties.label, 'Checkout journey');
            expect(semanticsWidget.properties.value, 'Browser oracle sample');
          }
        }
      }
      semantics.dispose();
    },
  );

  testWidgets('unsupported Journey grammar stays visible with a diagnostic', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    addTearDown(tester.view.reset);
    const source = 'journey\nTask without score';
    await tester.pumpWidget(_host(source, brightness: Brightness.dark));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(NativeMermaidJourney), findsNothing);
    expect(find.textContaining('Mermaid:'), findsOneWidget);
    final visibleText = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
        .join('\n');
    expect(visibleText, contains('Task without score'));
  });
}
