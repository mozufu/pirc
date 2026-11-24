import 'package:csslib/parser.dart' as css_parser;
import 'package:csslib/visitor.dart' as css;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_document_grid.dart';
import 'package:pirc_render/src/html_grid_template.dart';

NativeGridTemplate _template(String property, String value) {
  final sheet = css_parser.parse('.grid{$property:$value}');
  final rule = sheet.topLevels.single as css.RuleSet;
  final declaration = rule.declarationGroup.declarations
      .whereType<css.Declaration>()
      .single;
  return NativeGridTemplate.parse(declaration.expression)!;
}

void main() {
  test('grid track identity retains fixed-pixel and percentage units', () {
    final zeroPixels = _template('grid-template-rows', '0px').expand(100, 0);
    final zeroPercent = _template('grid-template-rows', '0%').expand(100, 0);
    final positivePercent = _template(
      'grid-template-rows',
      '25%',
    ).expand(100, 0);

    expect(zeroPixels.single.isFixedPixel, isTrue);
    expect(zeroPercent.single.isFixedPixel, isFalse);
    expect(positivePercent.single.isFixedPixel, isFalse);
    expect(NativeGridTrack.pixels(0), isNot(NativeGridTrack.percent(0)));
  });

  testWidgets('auto-height grid honors explicit fixed row tracks', (
    tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 300,
            child: NativeDocumentGrid(
              template: _template('grid-template-columns', '1fr'),
              rowTemplate: _template('grid-template-rows', '60px 40px'),
              spans: const [1, 1],
              stretchRows: const [false, false],
              rowGap: 5,
              children: const [SizedBox(height: 20), SizedBox(height: 10)],
            ),
          ),
        ),
      ),
    );

    final grid = tester.renderObject<RenderBox>(
      find.byType(NativeDocumentGrid),
    );
    expect(grid.size.width, 300);
    expect(grid.size.height, 105);

    final children = <RenderBox>[];
    grid.visitChildren((child) => children.add(child as RenderBox));
    expect(children, hasLength(2));
    expect(children[0].size.height, 20);
    expect(
      children[0].localToGlobal(Offset.zero).dy -
          grid.localToGlobal(Offset.zero).dy,
      0,
    );
    expect(children[1].size.height, 10);
    expect(
      children[1].localToGlobal(Offset.zero).dy -
          grid.localToGlobal(Offset.zero).dy,
      65,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('auto-height zero-percent row remains content-sized', (
    tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 300,
            child: NativeDocumentGrid(
              template: _template('grid-template-columns', '1fr'),
              rowTemplate: _template('grid-template-rows', '0%'),
              spans: const [1],
              stretchRows: const [false],
              children: const [SizedBox(height: 20)],
            ),
          ),
        ),
      ),
    );

    final grid = tester.renderObject<RenderBox>(
      find.byType(NativeDocumentGrid),
    );
    expect(grid.size.height, 20);
    expect(tester.takeException(), isNull);
  });

  testWidgets('auto-height fractional minmax rows keep their floor and grow', (
    tester,
  ) async {
    Widget grid(double childHeight) => Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 300,
          child: NativeDocumentGrid(
            template: _template('grid-template-columns', '1fr'),
            rowTemplate: _template('grid-template-rows', 'minmax(60px, 1fr)'),
            spans: const [1],
            stretchRows: const [false],
            children: [SizedBox(height: childHeight)],
          ),
        ),
      ),
    );

    await tester.pumpWidget(grid(10));
    var renderGrid = tester.renderObject<RenderBox>(
      find.byType(NativeDocumentGrid),
    );
    expect(renderGrid.size.height, 60);
    var children = <RenderBox>[];
    renderGrid.visitChildren((child) => children.add(child as RenderBox));
    expect(children, hasLength(1));
    expect(children.single.size.height, 10);

    await tester.pumpWidget(grid(80));
    renderGrid = tester.renderObject<RenderBox>(
      find.byType(NativeDocumentGrid),
    );
    expect(renderGrid.size.height, 80);
    children = <RenderBox>[];
    renderGrid.visitChildren((child) => children.add(child as RenderBox));
    expect(children, hasLength(1));
    expect(children.single.size.height, 80);
    expect(tester.takeException(), isNull);
  });
}
