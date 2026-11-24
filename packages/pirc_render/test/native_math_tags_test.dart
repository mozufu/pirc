// ignore_for_file: implementation_imports

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_math_fork/src/ast/nodes/equation_array.dart';
import 'package:flutter_math_fork/src/ast/nodes/symbol.dart';
import 'package:flutter_math_fork/src/ast/syntax_tree.dart';
import 'package:flutter_math_fork/src/render/layout/eqn_array.dart';
import 'package:flutter_math_fork/src/render/layout/line.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_math_tags.dart';

void main() {
  group('NativeMathTagAnchor', () {
    testWidgets('anchors actual direct RenderLine children of EqnArray', (
      tester,
    ) async {
      final anchors = <NativeMathTagAnchor>[];
      final math = _mathWithAnchoredGather(anchors);
      await tester.pumpWidget(
        _testApp(
          NativeMathTagViewport(
            width: 320,
            child: NativeTaggedMath(
              math: math,
              tags: [
                NativeMathTag(math: const Text('(1)'), anchor: anchors[0]),
                NativeMathTag(math: const Text('(2)'), anchor: anchors[1]),
              ],
            ),
          ),
        ),
      );

      final array = tester.renderObject<RenderEqnArray>(find.byType(EqnArray));
      expect(anchors, hasLength(2));
      for (final anchor in anchors) {
        final row = anchor.renderBox;
        expect(row, isA<RenderLine>());
        expect(row!.parent, same(array));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('row tags align to their own actual row baselines', (
      tester,
    ) async {
      final anchors = <NativeMathTagAnchor>[];
      final firstTagKey = GlobalKey();
      final secondTagKey = GlobalKey();
      final math = _mathWithAnchoredGather(anchors);
      await tester.pumpWidget(
        _testApp(
          NativeMathTagViewport(
            width: 320,
            child: NativeTaggedMath(
              math: math,
              tags: [
                NativeMathTag(
                  math: Baseline(
                    key: firstTagKey,
                    baseline: 14,
                    baselineType: TextBaseline.alphabetic,
                    child: const Text('(1)'),
                  ),
                  anchor: anchors[0],
                ),
                NativeMathTag(
                  math: Baseline(
                    key: secondTagKey,
                    baseline: 14,
                    baselineType: TextBaseline.alphabetic,
                    child: const Text('(2)'),
                  ),
                  anchor: anchors[1],
                ),
              ],
            ),
          ),
        ),
      );

      for (final (anchor, tagKey) in [
        (anchors[0], firstTagKey),
        (anchors[1], secondTagKey),
      ]) {
        final row = anchor.renderBox! as RenderLine;
        final rowBaseline = row.localToGlobal(
          Offset(0, row.maxHeightAboveBaseline),
        );
        final tag = tester.renderObject<RenderBaseline>(find.byKey(tagKey));
        final tagBaseline = tag.localToGlobal(Offset(0, tag.baseline));
        expect(tagBaseline.dy, closeTo(rowBaseline.dy, 0.01));
      }
      final firstBaseline = anchors[0].renderBox!.localToGlobal(
        Offset(0, (anchors[0].renderBox! as RenderLine).maxHeightAboveBaseline),
      );
      final secondBaseline = anchors[1].renderBox!.localToGlobal(
        Offset(0, (anchors[1].renderBox! as RenderLine).maxHeightAboveBaseline),
      );
      expect(firstBaseline.dy, isNot(closeTo(secondBaseline.dy, 0.01)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('detached row key does not retain a stale render object', (
      tester,
    ) async {
      final anchor = NativeMathTagAnchor(debugLabel: 'detached-equation-row');
      await tester.pumpWidget(
        _testApp(
          NativeMathTagRow(
            anchor: anchor,
            child: const SizedBox(width: 30, height: 20),
          ),
        ),
      );
      expect(anchor.renderBox, isNotNull);

      await tester.pumpWidget(_testApp(const SizedBox.shrink()));
      expect(anchor.renderBox, isNull);
    });
  });

  group('NativeTaggedMath', () {
    testWidgets('centers body independently of tag natural width', (
      tester,
    ) async {
      final narrow = await _captureGatherPositions(tester, tagText: '1');
      final wide = await _captureGatherPositions(
        tester,
        tagText: 'long equation tag',
      );

      expect(wide.bodyLeft, closeTo(narrow.bodyLeft, 0.01));
      expect(wide.tagRight, closeTo(320, 0.01));
      expect(narrow.tagRight, closeTo(320, 0.01));
      expect(wide.tagWidth, greaterThan(narrow.tagWidth));
    });

    testWidgets('centers tags within their shared identity column only', (
      tester,
    ) async {
      final untaggedAnchors = <NativeMathTagAnchor>[];
      await tester.pumpWidget(
        _testApp(
          NativeMathTagViewport(
            width: 320,
            child: NativeTaggedMath(
              math: _mathWithAnchoredGather(untaggedAnchors, rowCount: 3),
              tags: const [],
            ),
          ),
        ),
      );
      final untaggedLayout = tester.renderObject<RenderNativeTaggedMath>(
        find.byType(NativeTaggedMath),
      );
      final untaggedRowLeft =
          untaggedAnchors.first.renderBox!.localToGlobal(Offset.zero).dx -
          untaggedLayout.localToGlobal(Offset.zero).dx;

      final anchors = <NativeMathTagAnchor>[];
      final wideTagKey = GlobalKey();
      final narrowTagKey = GlobalKey();
      final independentTagKey = GlobalKey();
      final sharedColumn = Object();
      final separateColumn = Object();
      Widget tag(String value, GlobalKey key) => Math.tex(
        value,
        key: key,
        mathStyle: MathStyle.text,
        textStyle: const TextStyle(fontSize: 24),
      );

      await tester.pumpWidget(
        _testApp(
          NativeMathTagViewport(
            width: 320,
            child: NativeTaggedMath(
              math: _mathWithAnchoredGather(anchors, rowCount: 3),
              tags: [
                NativeMathTag(
                  math: tag('(M)', wideTagKey),
                  anchor: anchors[0],
                  column: sharedColumn,
                ),
                NativeMathTag(
                  math: tag('(1)', narrowTagKey),
                  anchor: anchors[1],
                  column: sharedColumn,
                ),
                NativeMathTag(
                  math: tag('(solo)', independentTagKey),
                  anchor: anchors[2],
                  column: separateColumn,
                ),
              ],
            ),
          ),
        ),
      );

      final layout = tester.renderObject<RenderNativeTaggedMath>(
        find.byType(NativeTaggedMath),
      );
      final layoutLeft = layout.localToGlobal(Offset.zero).dx;
      final wide = tester.renderObject<RenderBox>(find.byKey(wideTagKey));
      final narrow = tester.renderObject<RenderBox>(find.byKey(narrowTagKey));
      final independent = tester.renderObject<RenderBox>(
        find.byKey(independentTagKey),
      );
      expect(wide.size.width, greaterThan(narrow.size.width));
      final groupLeft = 320 - wide.size.width;
      final narrowLeft = narrow.localToGlobal(Offset.zero).dx - layoutLeft;
      expect(
        narrowLeft + narrow.size.width / 2,
        closeTo(groupLeft + wide.size.width / 2, 0.01),
      );
      expect(
        wide.localToGlobal(Offset(wide.size.width, 0)).dx - layoutLeft,
        closeTo(320, 0.01),
      );
      expect(
        independent.localToGlobal(Offset(independent.size.width, 0)).dx -
            layoutLeft,
        closeTo(320, 0.01),
      );
      final taggedRowLeft =
          anchors.first.renderBox!.localToGlobal(Offset.zero).dx - layoutLeft;
      expect(taggedRowLeft, closeTo(untaggedRowLeft, 0.01));
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps natural math and tag sizes in a narrow viewport', (
      tester,
    ) async {
      final anchors = <NativeMathTagAnchor>[];
      final math = _mathWithAnchoredGather(anchors, long: true);
      final tagKey = GlobalKey();
      await tester.pumpWidget(
        _testApp(
          SizedBox(
            width: 120,
            child: NativeMathTagViewport(
              width: 120,
              child: NativeTaggedMath(
                math: math,
                tags: [NativeMathTag(math: Text('(12)', key: tagKey))],
              ),
            ),
          ),
        ),
      );

      final layout = tester.renderObject<RenderNativeTaggedMath>(
        find.byType(NativeTaggedMath),
      );
      final tag = tester.renderObject<RenderBox>(find.byKey(tagKey));
      final row = anchors.first.renderBox!;
      final layoutLeft = layout.localToGlobal(Offset.zero).dx;
      expect(row.size.width, greaterThan(120));
      expect(tag.size.width, greaterThan(0));
      expect(layout.size.width, 120);
      expect(
        tag.localToGlobal(Offset(tag.size.width, 0)).dx - layoutLeft,
        closeTo(120, 0.01),
      );
      expect(
        layout.getDryLayout(const BoxConstraints(maxWidth: 120)).isFinite,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('math and tag glyph sizes follow the ambient text scale', (
      tester,
    ) async {
      Future<({Size row, Size tag})> capture(double scale) async {
        final anchors = <NativeMathTagAnchor>[];
        final tagKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: Center(
                    child: NativeMathTagViewport(
                      width: 320,
                      child: NativeTaggedMath(
                        math: _mathWithAnchoredGather(anchors),
                        tags: [NativeMathTag(math: Text('(1)', key: tagKey))],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final row = anchors.first.renderBox!;
        final tag = tester.renderObject<RenderBox>(find.byKey(tagKey));
        return (row: row.size, tag: tag.size);
      }

      final one = await capture(1);
      final two = await capture(2);
      expect(two.row.width, closeTo(one.row.width * 2, .02));
      expect(two.row.height, closeTo(one.row.height * 2, .02));
      expect(two.tag.width, closeTo(one.tag.width * 2, .8));
      expect(two.tag.height, closeTo(one.tag.height * 2, .8));
      expect(tester.takeException(), isNull);
    });

    testWidgets('tag remains hit-testable at the right viewport edge', (
      tester,
    ) async {
      final anchors = <NativeMathTagAnchor>[];
      var taps = 0;
      await tester.pumpWidget(
        _testApp(
          NativeMathTagViewport(
            width: 240,
            child: NativeTaggedMath(
              math: _mathWithAnchoredGather(anchors),
              tags: [
                NativeMathTag(
                  math: GestureDetector(
                    onTap: () => taps++,
                    child: const Text('(1)'),
                  ),
                  anchor: anchors.first,
                ),
              ],
            ),
          ),
        ),
      );

      final tag = tester.getRect(
        find.descendant(
          of: find.byType(NativeTaggedMath),
          matching: find.byType(GestureDetector),
        ),
      );
      await tester.tapAt(tag.center);
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });
  });
}

Widget _testApp(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

Future<({double bodyLeft, double tagRight, double tagWidth})>
_captureGatherPositions(WidgetTester tester, {required String tagText}) async {
  final anchors = <NativeMathTagAnchor>[];
  final tagKey = GlobalKey();
  await tester.pumpWidget(
    _testApp(
      NativeMathTagViewport(
        width: 320,
        child: NativeTaggedMath(
          math: KeyedSubtree(
            key: GlobalKey(),
            child: _mathWithAnchoredGather(anchors),
          ),
          tags: [NativeMathTag(math: Text(tagText, key: tagKey))],
        ),
      ),
    ),
  );
  final row = anchors.first.renderBox!;
  final tag = tester.renderObject<RenderBox>(find.byKey(tagKey));
  final bodyGlobal = row.localToGlobal(Offset.zero);
  final layout = tester.renderObject<RenderNativeTaggedMath>(
    find.byType(NativeTaggedMath),
  );
  final layoutLeft = layout.localToGlobal(Offset.zero).dx;
  final tagRect = tag.localToGlobal(Offset.zero) & tag.size;
  return (
    bodyLeft: bodyGlobal.dx,
    tagRight: tagRect.right - layoutLeft,
    tagWidth: tag.size.width,
  );
}

Math _mathWithAnchoredGather(
  List<NativeMathTagAnchor> anchors, {
  bool long = false,
  int rowCount = 2,
}) {
  anchors
    ..clear()
    ..addAll(
      List.generate(
        rowCount,
        (index) => NativeMathTagAnchor(debugLabel: 'equation-row-$index'),
      ),
    );

  final symbols = long ? 'a+b+c+d+e+f+g+h+i+j=k' : 'a=b';
  final rowSymbols = [symbols, 'c=d', 'e=f'];
  final rows = List<EquationRowNode>.generate(
    rowCount,
    (index) => EquationRowNode(
      children: rowSymbols[index]
          .split('')
          .map((symbol) => SymbolNode(symbol: symbol))
          .toList(),
    ),
  );
  final anchored = _AnchoredEquationArrayNode(
    addJot: true,
    body: rows,
    arrayStretch: 1,
    hlines: const [],
    rowSpacings: const [],
    anchors: anchors,
  );
  return Math(
    ast: SyntaxTree(greenRoot: EquationRowNode(children: [anchored])),
    mathStyle: MathStyle.display,
    textStyle: const TextStyle(fontSize: 24),
  );
}

class _AnchoredEquationArrayNode extends EquationArrayNode {
  _AnchoredEquationArrayNode({
    required super.addJot,
    required super.body,
    required super.arrayStretch,
    required super.hlines,
    required super.rowSpacings,
    required this.anchors,
  });

  final List<NativeMathTagAnchor> anchors;

  @override
  BuildResult buildWidget(
    MathOptions options,
    List<BuildResult?> childBuildResults,
  ) {
    final anchoredResults = List.generate(childBuildResults.length, (index) {
      final result = childBuildResults[index]!;
      return BuildResult(
        options: result.options,
        italic: result.italic,
        skew: result.skew,
        results: result.results,
        widget: NativeMathTagRow(anchor: anchors[index], child: result.widget),
      );
    }, growable: false);
    return super.buildWidget(options, anchoredResults);
  }
}
