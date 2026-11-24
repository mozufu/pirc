import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import 'package:pirc_render/src/mermaid/xy_rendering.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'live_test.dart' show theme;

const _fixturePath = '../../fixtures/mobile-parity/mermaid-xy.json';

Map<String, dynamic> _map(Object? value) =>
    (value as Map).cast<String, dynamic>();

List<Map<String, dynamic>> _maps(Object? value) =>
    (value as List).map(_map).toList();

Widget _app(
  String source, {
  required Brightness brightness,
  bool streaming = false,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: theme.build(brightness),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: NativeMarkdown(source: source, streaming: streaming),
    ),
  ),
);

void main() {
  final fixture = _map(jsonDecode(File(_fixturePath).readAsStringSync()));
  final cases = _maps(fixture['cases']);

  testWidgets(
    'NativeMarkdown dispatches XY charts at mobile and tablet widths',
    (tester) async {
      final semantics = tester.ensureSemantics();
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      try {
        for (final width in [390, 768]) {
          for (final brightness in Brightness.values) {
            for (final scale in [1.0, 2.0]) {
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(width.toDouble(), 900);
              tester.platformDispatcher.textScaleFactorTestValue = scale;
              for (final id in [
                'xy-category-derived-y',
                'xy-horizontal-numeric-bars',
                'xy-fixed-size-responsive',
              ]) {
                final source =
                    cases.singleWhere((row) => row['id'] == id)['source']
                        as String;
                await tester.pumpWidget(_app(source, brightness: brightness));
                await tester.pumpAndSettle();

                expect(
                  tester.takeException(),
                  isNull,
                  reason: '$id $width $scale',
                );
                expect(find.byType(NativeMermaid), findsOneWidget, reason: id);
                expect(
                  find.byType(NativeMermaidXYChart),
                  findsOneWidget,
                  reason: '$id should draw a native chart',
                );
                expect(
                  find.textContaining('Mermaid:'),
                  findsNothing,
                  reason: id,
                );
                final semanticsNode = tester.getSemantics(
                  find.bySemanticsLabel(
                    RegExp(
                      RegExp.escape(
                        id == 'xy-category-derived-y'
                            ? 'Category defaults'
                            : id == 'xy-horizontal-numeric-bars'
                            ? 'Horizontal numeric'
                            : 'Fixed canvas',
                      ),
                    ),
                  ),
                );
                expect(semanticsNode.label, contains('XY chart'));
                expect(semanticsNode.label, contains('series'));
              }
            }
          }
        }
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('streaming XY charts stay literal until completion', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    const source = '''~~~mermaid
xychart-beta
title "Streaming"
x-axis [A, B]
bar "Values" [2, 5]
~~~''';

    await tester.pumpWidget(
      _app(source, brightness: Brightness.light, streaming: true),
    );
    expect(find.byType(NativeMermaid), findsOneWidget);
    expect(
      tester.widget<NativeMermaid>(find.byType(NativeMermaid)).ready,
      isFalse,
    );
    expect(find.byType(NativeMermaidXYChart), findsNothing);
    final literal = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
        .join('\n');
    expect(literal, contains('bar "Values" [2, 5]'));

    await tester.pumpWidget(_app(source, brightness: Brightness.light));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.widget<NativeMermaid>(find.byType(NativeMermaid)).ready,
      isTrue,
    );
    expect(find.byType(NativeMermaidXYChart), findsOneWidget);
  });

  testWidgets('unsupported XY input preserves source and shows the fallback', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    const source = '''~~~mermaid
xychart-beta
title "Missing plot"
x-axis [A, B]
~~~''';

    await tester.pumpWidget(_app(source, brightness: Brightness.dark));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(NativeMermaidXYChart), findsNothing);
    expect(find.textContaining('Mermaid:'), findsOneWidget);
    final literal = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
        .join('\n');
    expect(literal, contains('title "Missing plot"'));
  });
}
