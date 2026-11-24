// Generated case strings from the independent Chrome keyboard clipboard oracle.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_mobile/theme.dart';

const cases = <Map<String, String>>[
  {
    'id': "a-plus-b",
    'source': "Before \$a+b\$ after.",
    'expected': "Before \na\n+\nb\na+b after.",
  },
  {
    'id': "x-plus-y",
    'source': "Before \$x+y\$ after.",
    'expected': "Before \nx\n+\ny\nx+y after.",
  },
  {
    'id': "12-plus-34",
    'source': "Before \$12+34\$ after.",
    'expected': "Before \n12\n+\n34\n12+34 after.",
  },
  {
    'id': "a-minus-b",
    'source': "Before \$a-b\$ after.",
    'expected': "Before \na\n−\nb\na−b after.",
  },
  {
    'id': "x-equals-y",
    'source': "Before \$x=y\$ after.",
    'expected': "Before \nx\n=\ny\nx=y after.",
  },
  {
    'id': "ab",
    'source': "Before \$ab\$ after.",
    'expected': "Before \na\nb\nab after.",
  },
  {
    'id': "parenthesized-a-plus-b",
    'source': "Before \$(a+b)\$ after.",
    'expected': "Before \n(\na\n+\nb\n)\n(a+b) after.",
  },
  {
    'id': "a-plus-b-plus-c",
    'source': "Before \$a+b+c\$ after.",
    'expected': "Before \na\n+\nb\n+\nc\na+b+c after.",
  },
  {
    'id': "alpha-plus-beta",
    'source': "Before \$\\alpha+\\beta\$ after.",
    'expected': "Before \nα\n+\nβ\nα+β after.",
  },
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android clipboard matches Chrome linear math in both themes', (
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
