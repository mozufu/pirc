import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_inline_math.dart'
    show RenderNativeInlineMath;
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/native_math_paragraph.dart';

import '../tool/parity/capture_fonts.dart' show loadParityFonts;
import 'live_test.dart' show theme;

void main() {
  testWidgets(
    'auto table sizing shares min-to-max space without wrapping inline math',
    (tester) async {
      await tester.runAsync(loadParityFonts);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 900);
      addTearDown(tester.view.reset);

      final baseTheme = theme.build(Brightness.light);
      final appTheme = baseTheme.copyWith(
        textTheme: baseTheme.textTheme.apply(fontFamily: 'Arial'),
      );
      for (final (scale, firstColumn, secondColumn) in [
        (1.0, 177.516, 178.484),
        (2.0, 172.078, 183.922),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: NativeMarkdown(
                    source:
                        '| Left cell | Right cell |\n'
                        '| --- | --- |\n'
                        r'| before $a+b$ after | second $c+d$ end |',
                    fontSize: 15,
                    lineHeight: 1.65,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final table = tester.renderObject<RenderTable>(find.byType(Table));
        expect(table.size.width, closeTo(356, .1));
        expect(table.columns, 2);
        // Pinned Chrome gives the widths below. The native algorithm derives
        // its result from cell min/max-content metrics and stays within one
        // pixel at both scales.
        expect(table.column(0).first.size.width, closeTo(firstColumn, 1));
        expect(table.column(1).first.size.width, closeTo(secondColumn, 1));

        final firstCellContent = tester
            .widgetList<NativeMathParagraphContent>(
              find.byType(NativeMathParagraphContent),
            )
            .singleWhere(
              (content) => content.formulas.any(
                (formula) => formula.source.expression == 'a+b',
              ),
            );
        final cellContent = find.byWidget(firstCellContent);
        final parts = find.descendant(
          of: cellContent,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is NativeMathPart &&
                widget.formulaIndex == 0 &&
                widget.partIndex < 2,
          ),
        );
        expect(parts, findsNWidgets(2));
        final baselines = [
          for (final finder in [
            find.descendant(
              of: cellContent,
              matching: find.byWidgetPredicate(
                (widget) => widget is NativeMathPart && widget.partIndex == 0,
              ),
            ),
            find.descendant(
              of: cellContent,
              matching: find.byWidgetPredicate(
                (widget) => widget is NativeMathPart && widget.partIndex == 1,
              ),
            ),
          ])
            (tester.element(finder).findRenderObject()!
                    as RenderNativeInlineMath)
                .localToGlobal(
                  Offset(
                    0,
                    (tester.element(finder).findRenderObject()!
                            as RenderNativeInlineMath)
                        .baseline,
                  ),
                )
                .dy,
        ];
        expect(
          (baselines[0] - baselines[1]).abs(),
          lessThan(1),
          reason:
              'The split a+ and b placeholders should share one text row at ${scale}x.',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets('uneven columns use their measured content bounds', (
    tester,
  ) async {
    await tester.runAsync(loadParityFonts);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 700);
    addTearDown(tester.view.reset);

    final baseTheme = theme.build(Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: baseTheme.copyWith(
          textTheme: baseTheme.textTheme.apply(fontFamily: 'Arial'),
        ),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: NativeMarkdown(
                source:
                    '| ID | Medium heading | Notes |\n'
                    '| --- | --- | --- |\n'
                    '| A | medium phrase | a long description with several words to stretch this column |\n'
                    '| B | short | brief |',
                fontSize: 15,
                lineHeight: 1.65,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.renderObject<RenderTable>(find.byType(Table));
    expect(table.size.width, closeTo(356, .1));
    final widths = [
      for (var i = 0; i < table.columns; i++) table.column(i).first.size.width,
    ];
    // Pinned Chrome measured 33.8125/128.875/193.3125px at 390px and 1x.
    // This source has unequal content bounds, so this guards against reverting
    // to equal columns or RenderTable's order-dependent flex shrink.
    expect(widths, [
      closeTo(33.8125, .1),
      closeTo(128.875, .1),
      closeTo(193.3125, .1),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scaled header keeps its max-content width without wrapping', (
    tester,
  ) async {
    await tester.runAsync(loadParityFonts);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    addTearDown(tester.view.reset);

    final baseTheme = theme.build(Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: baseTheme.copyWith(
          textTheme: baseTheme.textTheme.apply(fontFamily: 'Arial'),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: NativeMarkdown(
                source:
                    '| ID | Medium heading | Notes |\n'
                    '| --- | --- | --- |\n'
                    '| A | medium phrase | a long description with several words to stretch this column |\n'
                    '| B | short | brief |',
                fontSize: 15,
                lineHeight: 1.65,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.renderObject<RenderTable>(find.byType(Table));
    final header = table.column(1).first;
    final naturalHeaderWidth = header.getMaxIntrinsicWidth(double.infinity);

    // The pinned header is nowrap. Its column minimum therefore needs to fit
    // its natural width even when text scaling makes the table overflow.
    expect(header.size.width, closeTo(naturalHeaderWidth, .1));
    expect(
      table.row(0).elementAt(1).size.height,
      closeTo(table.row(0).elementAt(0).size.height, .1),
    );
    expect(table.size.width, greaterThan(356));

    // Body prose can wrap at grapheme boundaries inside its resolved width;
    // the selected and copied source remains the original text.
    final bodyDescription = table.column(2).elementAt(1);
    expect(
      bodyDescription.size.width,
      greaterThanOrEqualTo(
        bodyDescription.getMinIntrinsicWidth(double.infinity) - .1,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('body prose uses anywhere min-content at both text scales', (
    tester,
  ) async {
    await tester.runAsync(loadParityFonts);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1100);
    addTearDown(tester.view.reset);

    final baseTheme = theme.build(Brightness.light);
    final appTheme = baseTheme.copyWith(
      textTheme: baseTheme.textTheme.apply(fontFamily: 'Arial'),
    );
    for (final scale in [1.0, 2.0]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: NativeMarkdown(
                  source:
                      '| ID | Medium heading | Notes |\n'
                      '| --- | --- | --- |\n'
                      '| A | medium phrase | a long description with several words to stretch this column |\n'
                      '| B | short | brief |',
                  fontSize: 15,
                  lineHeight: 1.65,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final table = tester.renderObject<RenderTable>(find.byType(Table));
      final widths = [
        for (var column = 0; column < table.columns; column++)
          table.column(column).first.size.width,
      ];
      // At 1x the body fits and the natural measured bounds remain the source
      // values. At 2x, pinned Chrome wraps the body word inside its column and
      // the table's natural width is 382.047px; the source also keeps its
      // nowrap header widths.
      if (scale == 1) {
        expect(table.size.width, closeTo(356, .1));
        expect(widths, [
          closeTo(33.8125, .1),
          closeTo(128.875, .1),
          closeTo(193.3125, .1),
        ]);
      } else {
        expect(table.size.width, closeTo(382.047, 1));
        expect(widths, [
          closeTo(47.609, 1),
          closeTo(237.75, 1),
          closeTo(96.688, 1),
        ]);
        final notesCell = table.row(1).elementAt(2);
        expect(
          notesCell.size.height,
          greaterThan(300),
          reason:
              'The 2x body text should wrap inside the narrow Notes column, '
              'rather than widening the table to fit “description”.',
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('inline code follows body anywhere wrapping', (tester) async {
    await tester.runAsync(loadParityFonts);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);

    final baseTheme = theme.build(Brightness.light);
    final token = List.filled(60, 'unbreakable').join();
    await tester.pumpWidget(
      MaterialApp(
        theme: baseTheme.copyWith(
          textTheme: baseTheme.textTheme.apply(fontFamily: 'Arial'),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: NativeMarkdown(
                source:
                    '| ID | Medium heading | Notes |\n'
                    '| --- | --- | --- |\n'
                    '| A | medium phrase | `$token` |',
                fontSize: 15,
                lineHeight: 1.65,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.renderObject<RenderTable>(find.byType(Table));
    expect(table.size.width, closeTo(382.047, 1));
    expect(
      table.row(1).elementAt(2).size.height,
      greaterThan(48),
      reason:
          'Inline code shares the pinned anywhere wrapping rule for body prose.',
    );
    expect(tester.takeException(), isNull);
  });
}
