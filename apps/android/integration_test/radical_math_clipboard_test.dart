// Generated case strings from the independent Chrome keyboard clipboard oracle.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_mobile/theme.dart';

// Oracle SHA-256: d7dfadf8528856665e067e784654af76f2074c9dd7b3b0958e9a49f6085ed643
const cases = <Map<String, String>>[
  {
    'id': "sqrt-2",
    'source': "Before \$\\sqrt{2}\$ after.",
    'expected': "Before \n2\n2\n​\n  after.",
  },
  {
    'id': "sqrt-x",
    'source': "Before \$\\sqrt{x}\$ after.",
    'expected': "Before \nx\nx\n​\n  after.",
  },
  {
    'id': "sqrt-a-plus-b",
    'source': "Before \$\\sqrt{a+b}\$ after.",
    'expected': "Before \na\n+\nb\na+b\n​\n  after.",
  },
  {
    'id': "a-plus-sqrt-b-plus-c",
    'source': "Before \$a+\\sqrt{b}+c\$ after.",
    'expected': "Before \na\n+\nb\n+\nc\na+ \nb\n​\n +c after.",
  },
  {
    'id': "adjacent-square-roots",
    'source': "Before \$\\sqrt{a}\\sqrt{b}\$ after.",
    'expected': "Before \na\nb\na\n​\n  \nb\n​\n  after.",
  },
  {
    'id': "nested-square-roots",
    'source': "Before \$\\sqrt{\\sqrt{x}}\$ after.",
    'expected': "Before \nx\nx\n​\n \n​\n  after.",
  },
  {
    'id': "sqrt-fraction",
    'source': "Before \$\\sqrt{\\frac{a}{b}}\$ after.",
    'expected': "Before \na\nb\nb\na\n​\n \n​\n  after.",
  },
  {
    'id': "fraction-of-square-roots",
    'source': "Before \$\\frac{\\sqrt{a}}{\\sqrt{b}}\$ after.",
    'expected': "Before \na\nb\nb\n​\n \na\n​\n \n​\n  after.",
  },
  {
    'id': "sqrt-scripted-sum",
    'source': "Before \$\\sqrt{x_1+y^2}\$ after.",
    'expected': "Before \nx\n1\n+\ny\n2\nx \n1\n​\n +y \n2\n \n​\n  after.",
  },
  {
    'id': "cube-root-x",
    'source': "Before \$\\sqrt[3]{x}\$ after.",
    'expected': "Before \nx\n3\n3\n  \nx\n​\n  after.",
  },
  {
    'id': "nth-root-x",
    'source': "Before \$\\sqrt[n]{x}\$ after.",
    'expected': "Before \nx\nn\nn\n  \nx\n​\n  after.",
  },
  {
    'id': "n-plus-one-root-x",
    'source': "Before \$\\sqrt[n+1]{x}\$ after.",
    'expected': "Before \nx\nn\n+\n1\nn+1\n  \nx\n​\n  after.",
  },
  {
    'id': "cube-root-fraction",
    'source': "Before \$\\sqrt[3]{\\frac{a}{b}}\$ after.",
    'expected': "Before \na\nb\n3\n3\n  \nb\na\n​\n \n​\n  after.",
  },
  {
    'id': "empty-square-root",
    'source': "Before \$\\sqrt{}\$ after.",
    'expected': "Before \n​\n  after.",
  },
  {
    'id': "square-root-squared",
    'source': "Before \$\\sqrt{x}^2\$ after.",
    'expected': "Before \nx\n2\nx\n​\n  \n2\n  after.",
  },
  {
    'id': "reciprocal-sqrt-quadratic",
    'source': "Before \$\\frac{1}{\\sqrt{1+x^2}}\$ after.",
    'expected': "Before \n1\n1\n+\nx\n2\n1+x \n2\n \n​\n \n1\n​\n  after.",
  },
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android clipboard matches Chrome radical math in both themes', (
    t,
  ) async {
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
  });
}
