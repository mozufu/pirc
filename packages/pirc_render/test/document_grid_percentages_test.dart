import 'package:csslib/parser.dart' as css_parser;
import 'package:csslib/visitor.dart' as css;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_document_box.dart';
import 'package:pirc_render/src/html_document_flex.dart';
import 'package:pirc_render/src/html_document_grid.dart';
import 'package:pirc_render/src/html_grid_template.dart';

NativeGridTemplate gridTemplate(String property, String source) {
  final sheet = css_parser.parse('.x{$property:$source}');
  final rule = sheet.topLevels.single as css.RuleSet;
  final declaration = rule.declarationGroup.declarations
      .whereType<css.Declaration>()
      .single;
  return NativeGridTemplate.parse(declaration.expression)!;
}

void main() {
  testWidgets(
    'percentage grid item resolves against its explicit row and column area',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final columns = gridTemplate('grid-template-columns', '200px');
      final rows = gridTemplate('grid-template-rows', '1fr 2fr');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 200,
                height: 100,
                child: NativeDocumentGrid(
                  template: columns,
                  rowTemplate: rows,
                  spans: [1, 1],
                  stretchColumns: [false, true],
                  stretchRows: [false, true],
                  rowGap: 10,
                  children: [
                    NativeDocumentContainingBlock(
                      child: NativeDocumentBox(
                        width: const NativeFlexLength.percent(50),
                        height: const NativeFlexLength.percent(50),
                        child: const SizedBox.expand(
                          key: ValueKey('percentage-item'),
                        ),
                      ),
                    ),
                    const NativeDocumentContainingBlock(
                      child: SizedBox.expand(key: ValueKey('auto-item')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      final grid = tester.renderObject<RenderBox>(
        find.byType(NativeDocumentGrid),
      );
      expect(grid.size, const Size(200, 100));
      expect(
        tester.getSize(find.byKey(const ValueKey('percentage-item'))),
        const Size(100, 15),
      );
      expect(tester.getTopLeft(find.byKey(const ValueKey('auto-item'))).dy, 40);
      expect(
        tester.getSize(find.byKey(const ValueKey('auto-item'))),
        const Size(200, 60),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bounded auto height does not make percentage row items definite',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final columns = gridTemplate('grid-template-columns', '200px');
      final rows = gridTemplate('grid-template-rows', '1fr');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 200,
                  maxHeight: 100,
                ),
                child: NativeDocumentGrid(
                  template: columns,
                  rowTemplate: rows,
                  spans: [1],
                  stretchColumns: [false],
                  stretchRows: [false],
                  children: [
                    NativeDocumentContainingBlock(
                      child: NativeDocumentBox(
                        width: const NativeFlexLength.percent(50),
                        height: const NativeFlexLength.percent(50),
                        child: const SizedBox(
                          key: ValueKey('auto-height-item'),
                          height: 20,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      final grid = tester.renderObject<RenderBox>(
        find.byType(NativeDocumentGrid),
      );
      expect(grid.size.height, 20);
      expect(
        tester.getSize(find.byKey(const ValueKey('auto-height-item'))),
        const Size(100, 20),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
