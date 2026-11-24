// Generated case strings from the independent Chrome keyboard clipboard oracle.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_mobile/theme.dart';

const cases = <Map<String, String>>[
  {
    'id': "fraction-a-over-b",
    'source': "Before \$\\frac{a}{b}\$ after.",
    'expected': "Before \na\nb\nb\na\n​\n  after.",
  },
  {
    'id': "fraction-sums",
    'source': "Before \$\\frac{a+b}{c+d}\$ after.",
    'expected': "Before \na\n+\nb\nc\n+\nd\nc+d\na+b\n​\n  after.",
  },
  {
    'id': "subscript-x-one",
    'source': "Before \$x_1\$ after.",
    'expected': "Before \nx\n1\nx \n1\n​\n  after.",
  },
  {
    'id': "superscript-x-two",
    'source': "Before \$x^2\$ after.",
    'expected': "Before \nx\n2\nx \n2\n  after.",
  },
  {
    'id': "subscript-superscript-x",
    'source': "Before \$x_1^2\$ after.",
    'expected': "Before \nx\n1\n2\nx \n1\n2\n​\n  after.",
  },
  {
    'id': "superscript-subscript-expression",
    'source': "Before \$x^{a+b}_{i_0}\$ after.",
    'expected': "Before \nx\ni\n0\na\n+\nb\nx \ni \n0\n​\n \na+b\n​\n  after.",
  },
  {
    'id': "sum-fraction",
    'source': "Before \$a+\\frac{b}{c}+d\$ after.",
    'expected': "Before \na\n+\nb\nc\n+\nd\na+ \nc\nb\n​\n +d after.",
  },
  {
    'id': "nested-fraction",
    'source': "Before \$\\frac{\\frac{a}{b}}{c}\$ after.",
    'expected': "Before \na\nb\nc\nc\nb\na\n​\n \n​\n  after.",
  },
  {
    'id': "fractional-script",
    'source': "Before \$x^{\\frac{a+b}{c+d}}_{i_0}\$ after.",
    'expected':
        "Before \nx\ni\n0\na\n+\nb\nc\n+\nd\nx \ni \n0\n​\n \nc+d\na+b\n​\n \n​\n  after.",
  },
  {
    'id': "two-fractions-plus",
    'source': "Before \$\\frac{a}{b}+\\frac{c}{d}\$ after.",
    'expected': "Before \na\nb\n+\nc\nd\nb\na\n​\n + \nd\nc\n​\n  after.",
  },
  {
    'id': "adjacent-fractions",
    'source': "Before \$\\frac{a}{b}\\frac{c}{d}\$ after.",
    'expected': "Before \na\nb\nc\nd\nb\na\n​\n  \nd\nc\n​\n  after.",
  },
  {
    'id': "sum-with-scripts",
    'source': "Before \$a+x_1+y^2\$ after.",
    'expected': "Before \na\n+\nx\n1\n+\ny\n2\na+x \n1\n​\n +y \n2\n  after.",
  },
  {
    'id': "fraction-with-scripts",
    'source': "Before \$\\frac{a_1+b^2}{c+d}\$ after.",
    'expected':
        "Before \na\n1\n+\nb\n2\nc\n+\nd\nc+d\na \n1\n​\n +b \n2\n \n​\n  after.",
  },
  {
    'id': "x-subscript-10-superscript-20",
    'source': "Before \$x_{10}^{20}\$ after.",
    'expected': "Before \nx\n10\n20\nx \n10\n20\n​\n  after.",
  },
  {
    'id': "x-superscript-2-subscript-1",
    'source': "Before \$x^2_1\$ after.",
    'expected': "Before \nx\n1\n2\nx \n1\n2\n​\n  after.",
  },
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android clipboard matches Chrome structural math in both themes',
    (t) async {
      final theme = await PircTheme.load();
      for (final brightness in Brightness.values) {
        for (final input in cases) {
          await t.pumpWidget(
            MaterialApp(
              theme: theme.build(brightness),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableRegion(
                    selectionControls: materialTextSelectionHandleControls,
                    contextMenuBuilder: (context, state) =>
                        AdaptiveTextSelectionToolbar.selectableRegion(
                          selectableRegionState: state,
                        ),
                    child: NativeMarkdown(
                      source: input['source']!,
                      fontSize: 15,
                      lineHeight: 1.65,
                    ),
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          final region = t.state<SelectableRegionState>(
            find.byType(SelectableRegion),
          );
          region.selectAll(SelectionChangedCause.toolbar);
          await t.pump();
          region.contextMenuButtonItems
              .singleWhere((item) => item.type == ContextMenuButtonType.copy)
              .onPressed!();
          await t.pumpAndSettle();
          final actual = await Clipboard.getData(Clipboard.kTextPlain);
          expect(
            actual?.text,
            input['expected'],
            reason:
                '${brightness.name}/${input['id']}: actual Android OS clipboard',
          );
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
        }
      }
    },
  );
}
