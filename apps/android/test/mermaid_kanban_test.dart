import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/kanban_model.dart';
import 'package:pirc_render/src/mermaid/kanban_parser.dart';
import 'package:pirc_render/src/mermaid/kanban_rendering.dart';

import '../tool/parity/capture_fonts.dart' show loadParityFonts;
import 'live_test.dart' show theme;

const _fixturePath = '../../fixtures/mobile-parity/mermaid-kanban.json';

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

Future<void> _loadKanbanFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    await loadParityFonts();
    await (FontLoader('Mermaid reference')..addFont(
          File(
            '/System/Library/Fonts/SFNS.ttf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });
}

List<Map<String, Object?>> _dbNodes(NativeMermaidKanbanBoard board) => [
  for (final column in board.columns) ...[
    {
      'id': column.id,
      'label': column.label,
      'labelType': 'markdown',
      'isGroup': true,
      'shape': 'kanbanSection',
      'level': column.sourceLevel,
      'look': 'classic',
      if (column.ticket != null) 'ticket': column.ticket,
    },
    for (final card in column.cards)
      {
        'id': card.id,
        'parentId': column.id,
        'label': card.label,
        'labelType': 'markdown',
        'isGroup': false,
        'shape': 'kanbanItem',
        'level': card.sourceLevel,
        'rx': 5,
        'ry': 5,
        if (card.ticket != null) 'ticket': card.ticket,
        if (card.assigned != null) 'assigned': card.assigned,
        if (card.priority != null) 'priority': card.priority,
      },
  ],
];

bool _hasSpanStyle(InlineSpan span, bool Function(TextStyle?) matches) {
  if (span is! TextSpan) return false;
  if (matches(span.style)) return true;
  return span.children?.any((child) => _hasSpanStyle(child, matches)) ?? false;
}

void main() {
  final fixture = _object(jsonDecode(File(_fixturePath).readAsStringSync()));
  final cases = _objects(fixture['cases']);

  test('Kanban model matches the pinned Mermaid parser and database', () {
    expect(fixture['webSha'], 'bd3d90981271e1f93cf3d1d1a5bbf9b61136b74c');
    expect(fixture['mermaidVersion'], '11.17.2');
    expect(cases, hasLength(5));

    for (final item in cases) {
      final id = item['id'] as String;
      final board = parseNativeMermaidKanban(item['source'] as String);
      final expectedNodes = _objects(item['expectedNodes']);
      final actualNodes = _dbNodes(board);
      expect(actualNodes, hasLength(expectedNodes.length), reason: id);

      for (var index = 0; index < expectedNodes.length; index++) {
        final expected = expectedNodes[index];
        final actual = actualNodes[index];
        for (final key in [
          'id',
          'parentId',
          'label',
          'labelType',
          'isGroup',
          'shape',
          'level',
          'look',
          'rx',
          'ry',
          'ticket',
          'assigned',
          'priority',
        ]) {
          if (expected.containsKey(key)) {
            expect(actual[key], expected[key], reason: '$id node $index $key');
          } else {
            expect(
              actual.containsKey(key),
              isFalse,
              reason: '$id node $index unexpectedly has $key',
            );
          }
        }
      }
    }
  });

  test('Kanban preserves shape syntax and rejects unsupported metadata', () {
    final board = parseNativeMermaidKanban(
      cases.firstWhere(
            (item) => item['id'] == 'card-shape-delimiters',
          )['source']
          as String,
    );
    expect(board.columns.single.cards.map((card) => card.sourceShape), [
      'rounded-rect',
      'circle',
      'hexagon',
      'rect',
    ]);

    for (final source in [
      'flowchart TD\nA --> B',
      'kanban\nTodo\n  card[Icon]@{icon: fa fa-user}',
      'kanban\nTodo\n  card[Class]:::urgent',
      'kanban\nTodo\n  card[Unknown]@{state: blocked}',
      'kanban\nTodo\n  card[Unclosed',
      'kanban\nTodo\n  card[Broken]@{ticket: APP-1',
    ]) {
      expect(
        () => parseNativeMermaidKanban(source),
        throwsFormatException,
        reason: source,
      );
    }
  });

  test('Kanban layout fits the SVG board without horizontal scrolling', () {
    for (final item in cases) {
      final board = parseNativeMermaidKanban(item['source'] as String);
      for (final width in [390.0, 768.0]) {
        for (final dark in [false, true]) {
          final layout = layoutNativeMermaidKanban(
            board,
            width: width,
            dark: dark,
          );
          expect(layout.size.width, lessThanOrEqualTo(width));
          expect(layout.scale, inInclusiveRange(0, 1));
          expect(layout.columns, hasLength(board.columns.length));
          for (var index = 0; index < layout.columns.length; index++) {
            final column = layout.columns[index];
            expect(column.column.id, board.columns[index].id);
            expect(column.bounds.width, 200);
            for (
              var cardIndex = 0;
              cardIndex < column.cards.length;
              cardIndex++
            ) {
              final card = column.cards[cardIndex];
              expect(card.card.id, column.column.cards[cardIndex].id);
              expect(card.bounds.width, 185);
              expect(layout.viewBox.contains(card.bounds.topLeft), isTrue);
              expect(layout.viewBox.contains(card.bounds.bottomRight), isTrue);
            }
          }
        }
      }
    }

    final priorities = parseNativeMermaidKanban(
      'kanban\nDoing\n'
      '  very-high[Critical]@{priority: Very High}\n'
      '  high[Urgent]@{priority: High}\n'
      '  medium[Normal]@{priority: Medium}\n'
      '  low[Later]@{priority: Low}\n'
      '  very-low[Someday]@{priority: Very Low}',
    );
    final cards = layoutNativeMermaidKanban(
      priorities,
      width: 390,
      dark: false,
    ).columns.single.cards;
    expect(cards.map((card) => card.priorityColor), [
      const Color(0xffff0000),
      const Color(0xffffa500),
      null,
      const Color(0xff0000ff),
      const Color(0xffadd8e6),
    ]);

    expect(
      () => layoutNativeMermaidKanban(
        parseNativeMermaidKanban(
          'kanban\nTodo\n  image[![alt](https://example.test/a.png)]',
        ),
        width: 390,
        dark: false,
      ),
      throwsFormatException,
      reason: 'unsupported Markdown image markup must be explicit',
    );
  });

  test(
    'Kanban rich labels wrap without truncation and preserve raw source',
    () {
      final item = cases.firstWhere(
        (value) => value['id'] == 'multiline-description',
      );
      final board = parseNativeMermaidKanban(item['source'] as String);
      final expectedNodes = _objects(item['expectedNodes']);
      final expectedLabel =
          expectedNodes.firstWhere((node) => node['id'] == 'long')['label']
              as String;
      expect(board.columns.single.cards.first.label, expectedLabel);

      final layout = layoutNativeMermaidKanban(board, width: 390, dark: false);
      final title = layout.columns.single.cards.first;
      final renderedText = title.titleSpan.toPlainText();
      expect(title.titleLineCount, greaterThanOrEqualTo(4));
      expect(renderedText, contains('bold'));
      expect(renderedText, contains('code'));
      expect(renderedText, isNot(contains('**')));
      expect(renderedText, isNot(contains('`')));
      expect(
        _hasSpanStyle(
          title.titleSpan,
          (style) => style?.fontWeight == FontWeight.w700,
        ),
        isTrue,
      );
      expect(
        _hasSpanStyle(
          title.titleSpan,
          (style) => style?.fontFamily == 'monospace',
        ),
        isTrue,
      );

      final wrappedHeading = parseNativeMermaidKanban(
        cases.firstWhere(
              (value) => value['id'] == 'empty-column-and-deep-item-indent',
            )['source']
            as String,
      );
      final wrappedLayout = layoutNativeMermaidKanban(
        wrappedHeading,
        width: 390,
        dark: false,
      );
      expect(wrappedLayout.columns.first.labelHeight, greaterThan(16));
      expect(
        wrappedLayout.columns.last.cards.first.bounds.top,
        closeTo(-300 + wrappedLayout.columns.first.labelHeight, 1e-6),
      );
    },
  );

  testWidgets('Kanban renders at phone/tablet light/dark 1x and 2x', (
    tester,
  ) async {
    await _loadKanbanFonts(tester);
    final semantics = tester.ensureSemantics();
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final board = parseNativeMermaidKanban(
      cases.firstWhere((item) => item['id'] == 'columns-and-cards')['source']
          as String,
    );
    double? priorScale;
    for (final width in [390, 768]) {
      for (final brightness in Brightness.values) {
        for (final textScale in [1.0, 2.0]) {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width.toDouble(), 900);
          tester.platformDispatcher.textScaleFactorTestValue = textScale;
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: _theme(brightness),
              home: Scaffold(
                body: Center(
                  child: NativeMermaidKanban(
                    board: board,
                    dark: brightness == Brightness.dark,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(find.byType(NativeMermaidKanban), findsOneWidget);
          final painter = tester
              .widgetList<CustomPaint>(find.byType(CustomPaint))
              .map((widget) => widget.painter)
              .whereType<NativeMermaidKanbanPainter>()
              .single;
          expect(painter.layout.columns, hasLength(3));
          expect(painter.layout.columns.first.cards, hasLength(2));
          expect(painter.layout.size.width, lessThanOrEqualTo(width));
          final semanticsNode = tester.getSemantics(
            find.bySemanticsLabel('Kanban board'),
          );
          expect(semanticsNode.label, 'Kanban board');
          expect(semanticsNode.value, contains('Write parser tests'));

          if (textScale == 1) {
            priorScale = painter.layout.scale;
          } else {
            expect(painter.layout.scale, priorScale);
          }
        }
      }
    }
    semantics.dispose();
  });

  testWidgets('Kanban rich card and wrapped heading paint every label line', (
    tester,
  ) async {
    await _loadKanbanFonts(tester);
    final handle = tester.ensureSemantics();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    final board = parseNativeMermaidKanban(
      cases.firstWhere(
            (value) => value['id'] == 'multiline-description',
          )['source']
          as String,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(Brightness.light),
        home: Scaffold(body: NativeMermaidKanban(board: board, dark: false)),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<NativeMermaidKanbanPainter>()
        .single;
    final card = painter.layout.columns.single.cards.first;
    final column = painter.layout.columns.single;
    expect(column.labelTop, closeTo(column.bounds.top, .1));
    expect(
      column.labelTop + column.labelHeight,
      lessThanOrEqualTo(card.bounds.top + .1),
      reason: 'header text must end before the first card starts',
    );
    expect(card.titleLineCount, 5);
    // Pinned Chrome measures the source label div at 13px / 19.5px with five
    // visible lines. Flutter's host font line metrics leave a small 1.5px
    // aggregate residual; the source card adds 10px padding on each side.
    expect(card.titleHeight, closeTo(97.5, 2));
    expect(card.bounds.height, closeTo(117.5, 2));
    expect(card.bounds.height, greaterThanOrEqualTo(card.titleHeight + 20));
    expect(painter.layout.columns.single.labelHeight, closeTo(39, 2));
    handle.dispose();
  });
}
