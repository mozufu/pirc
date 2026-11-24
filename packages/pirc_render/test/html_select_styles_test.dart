import 'package:csslib/parser.dart' as css_parser;
import 'package:csslib/visitor.dart' as css;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_control_box_style.dart';
import 'package:pirc_render/src/html_control_border_painter.dart';
import 'package:pirc_render/src/html_select.dart';

List<css.Declaration> _declarations(String source) {
  final sheet = css_parser.parse('select { $source }');
  final rule = sheet.topLevels.single as css.RuleSet;
  return rule.declarationGroup.declarations
      .whereType<css.Declaration>()
      .toList();
}

void main() {
  testWidgets(
    'select uses prepared typography and CSS box styles while retaining state',
    (tester) async {
      const source =
          '<select name="choice" multiple size="3">'
          '<option selected value="a">Alpha</option>'
          '<option disabled value="b">Blocked</option>'
          '<option value="c">Charlie</option>'
          '</select>';
      final state = NativeHtmlSelectState.fromHtml(source);
      addTearDown(state.dispose);
      final fragment = html.parseFragment(state.annotateHtml(source));
      final control = state.resolveControl(fragment.querySelector('select')!)!;
      final preparedStyle = const TextStyle(
        fontFamily: 'serif',
        fontSize: 20,
        height: 1.5,
        letterSpacing: 1.25,
        wordSpacing: 2,
        color: Color(0xff123456),
      );
      final boxStyle = NativeHtmlControlBoxStyle.fromDeclarations(
        _declarations('''
          width: 180px;
          height: 48px;
          padding: 4px 8px;
          border: 2px solid #123456;
          border-radius: 6px;
          background-color: #abcdef;
        '''),
        fontSize: preparedStyle.fontSize!,
        dark: false,
        multiline: false,
        uaPreset: NativeHtmlControlBoxUaPreset.select,
        currentColor: preparedStyle.color,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: Center(
                child: MediaQuery.withNoTextScaling(
                  child: NativeHtmlSelectWidget(
                    state: state,
                    control: control,
                    textStyle: preparedStyle,
                    boxStyle: boxStyle,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final selectFinder = find.byKey(
        ValueKey('native-html-select-${control.key}'),
      );
      expect(tester.getSize(selectFinder), const Size(180, 48));
      final alpha = tester.widget<Text>(find.text('Alpha'));
      expect(alpha.style!.fontFamily, 'serif');
      expect(alpha.style!.fontSize, 20);
      expect(alpha.style!.height, 1.5);
      expect(alpha.style!.letterSpacing, 1.25);
      expect(alpha.style!.wordSpacing, 2);
      expect(
        tester.getTopLeft(find.text('Alpha')).dx -
            tester.getTopLeft(selectFinder).dx,
        10,
      );

      final decoration = tester.widget<DecoratedBox>(
        find.descendant(of: selectFinder, matching: find.byType(DecoratedBox)),
      );
      final box = decoration.decoration as BoxDecoration;
      expect(box.color, const Color(0xffabcdef));
      expect(box.borderRadius, BorderRadius.circular(6));
      final paintedBorder = tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: selectFinder,
              matching: find.byType(CustomPaint),
            ),
          )
          .map((w) => w.foregroundPainter)
          .whereType<NativeHtmlControlBorderPainter>()
          .single;
      expect(paintedBorder.border.top.width, 2);
      expect(paintedBorder.border.top.color, const Color(0xff123456));
      expect(state.selectedIndices(control.key), [0]);
      expect(control.name, 'choice');

      await tester.ensureVisible(find.text('Blocked'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Blocked'));
      await tester.pumpAndSettle();
      expect(state.selectedIndices(control.key), [0]);

      await tester.ensureVisible(find.text('Charlie'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Charlie'));
      await tester.pumpAndSettle();
      expect(state.selectedIndices(control.key), [0, 2]);
      state.resetDefaults([control.key]);
      await tester.pump();
      expect(state.selectedIndices(control.key), [0]);
      expect(tester.takeException(), isNull);
    },
  );
}
