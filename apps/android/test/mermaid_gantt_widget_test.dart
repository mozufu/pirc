import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/gantt_parser.dart';
import 'package:pirc_render/src/mermaid/gantt_rendering.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../tool/parity/capture_fonts.dart';
import 'live_test.dart' show theme;

const _fixturePath = '../../fixtures/mobile-parity/mermaid-gantt.json';

Map<String, dynamic> _object(Object? value) =>
    (value as Map).cast<String, dynamic>();

List<Map<String, dynamic>> _objects(Object? value) =>
    (value as List).map(_object).toList();

String _unfence(String source) => source
    .replaceFirst(RegExp(r'^```mermaid\s*'), '')
    .replaceFirst(RegExp(r'\s*```$'), '');

ThemeData _theme(Brightness brightness) {
  final base = theme.build(brightness);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'Mermaid reference'),
  );
}

Widget _markdownApp(
  String source, {
  required Brightness brightness,
  bool streaming = false,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: _theme(brightness),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: NativeMarkdown(
        source: source,
        streaming: streaming,
        lineHeight: 1.65,
      ),
    ),
  ),
);

bool _hasGanttPainter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .any((widget) => widget.painter is NativeGanttPainter);

Future<void> _loadFonts(WidgetTester tester) async {
  await tester.runAsync(loadParityFonts);
  await tester.runAsync(() async {
    final pingFang = pingFangFont()!;
    await (FontLoader(
      'sans-serif',
    )..addFont(pingFang.readAsBytes().then(ByteData.sublistView))).load();
    await (FontLoader('Mermaid reference')..addFont(
          File(
            '/System/Library/Fonts/SFNS.ttf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });
}

void main() {
  final fixture = _object(jsonDecode(File(_fixturePath).readAsStringSync()));
  final cases = _objects(fixture['cases']);
  final widths = (fixture['widths'] as List).cast<int>();
  final scales = (fixture['textScales'] as List)
      .map((value) => (value as num).toDouble())
      .toList();
  final fixedNow = DateTime.parse(fixture['fixedNow'] as String).toUtc();

  testWidgets(
    'NativeMarkdown draws each supported Gantt fixture at both themes and text scales',
    (tester) async {
      await _loadFonts(tester);
      final semantics = tester.ensureSemantics();
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      try {
        for (final width in widths) {
          for (final brightness in Brightness.values) {
            for (final textScale in scales) {
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(
                width.toDouble(),
                (fixture['height'] as num).toDouble(),
              );
              tester.platformDispatcher.textScaleFactorTestValue = textScale;

              for (final item in cases) {
                final id = item['id'] as String;
                final source = item['source'] as String;
                final expectedDiagram = parseNativeMermaidGantt(
                  _unfence(source),
                  clock: fixedNow,
                );
                await tester.pumpWidget(
                  _markdownApp(source, brightness: brightness),
                );
                await tester.pumpAndSettle();

                expect(tester.takeException(), isNull, reason: id);
                expect(find.byType(NativeMermaid), findsOneWidget, reason: id);
                expect(
                  find.byType(NativeMermaidGantt),
                  findsOneWidget,
                  reason: '$id should draw its chart, not code fallback',
                );
                expect(
                  find.textContaining('Mermaid:'),
                  findsNothing,
                  reason: '$id unexpectedly fell back to source text',
                );

                final painter = tester
                    .widgetList<CustomPaint>(find.byType(CustomPaint))
                    .map((widget) => widget.painter)
                    .whereType<NativeGanttPainter>()
                    .single;
                expect(
                  painter.layout.tasks,
                  hasLength(expectedDiagram.tasks.length),
                );
                expect(painter.layout.ticks, isNotEmpty);
                expect(
                  painter.layout.size.width,
                  width.toDouble(),
                  reason: 'layout uses MediaQuery width at scale $textScale',
                );
                final semanticsNode = tester.getSemantics(
                  find
                      .bySemanticsLabel(
                        RegExp(RegExp.escape(expectedDiagram.title!)),
                      )
                      .first,
                );
                expect(
                  semanticsNode.label,
                  contains(expectedDiagram.title ?? 'Gantt chart'),
                );
                expect(
                  semanticsNode.label,
                  contains(expectedDiagram.sections.first.name),
                );
                for (final task in expectedDiagram.tasks) {
                  expect(
                    semanticsNode.label,
                    contains(task.label.trim()),
                    reason:
                        'task label is available to assistive technology: $id',
                  );
                }
              }
            }
          }
        }
      } finally {
        // Dispose semantics before the binding performs end-of-test checks.
        semantics.dispose();
      }
    },
    skip: noPingFang,
  );

  testWidgets(
    'streaming Gantt remains literal until the document completes',
    (tester) async {
      await _loadFonts(tester);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 900);
      addTearDown(tester.view.reset);
      const source = '''```mermaid
gantt
title Streamed plan
todayMarker off
section Work
Ship : 2026-07-06, 1d
```''';

      await tester.pumpWidget(
        _markdownApp(source, brightness: Brightness.light, streaming: true),
      );
      expect(find.byType(NativeMermaid), findsOneWidget);
      expect(
        tester.widget<NativeMermaid>(find.byType(NativeMermaid)).ready,
        isFalse,
      );
      expect(_hasGanttPainter(tester), isFalse);
      final literal = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
          .join('\n');
      expect(literal, contains('title Streamed plan'));
      expect(literal, contains('Ship : 2026-07-06, 1d'));

      await tester.pumpWidget(
        _markdownApp(source, brightness: Brightness.light, streaming: false),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<NativeMermaid>(find.byType(NativeMermaid)).ready,
        isTrue,
      );
      expect(find.byType(NativeMermaidGantt), findsOneWidget);
      expect(_hasGanttPainter(tester), isTrue);
    },
    skip: noPingFang,
  );

  testWidgets(
    'unsupported Gantt syntax preserves source and reports fallback',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 900);
      addTearDown(tester.view.reset);
      const source = '''```mermaid
gantt
weekday monday
section Work
Task : 2026-07-06, 1d
```''';

      await tester.pumpWidget(
        _markdownApp(source, brightness: Brightness.dark),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(NativeMermaid), findsOneWidget);
      expect(find.textContaining('Mermaid:'), findsOneWidget);
      expect(find.byType(NativeMermaidGantt), findsNothing);
      expect(_hasGanttPainter(tester), isFalse);
      final literal = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
          .join('\n');
      expect(literal, contains('weekday monday'));
      expect(literal, contains('Task : 2026-07-06, 1d'));
    },
  );
}
