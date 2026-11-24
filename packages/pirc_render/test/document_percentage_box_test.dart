import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_document_box.dart';
import 'package:pirc_render/src/html_document_flex.dart';

Widget _host(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: SizedBox.expand(
    child: Align(alignment: Alignment.topLeft, child: child),
  ),
);

RenderBox _box(WidgetTester tester, Key key) =>
    tester.renderObject<RenderBox>(find.byKey(key));

void main() {
  testWidgets(
    'nested percentages use ancestor content boxes before own edges',
    (tester) async {
      const outerKey = ValueKey('outer');
      const middleKey = ValueKey('middle');
      const innerKey = ValueKey('inner');

      await tester.pumpWidget(
        _host(
          NativeDocumentBox(
            key: outerKey,
            width: const NativeFlexLength.pixels(240),
            height: const NativeFlexLength.pixels(150),
            lengthsAreContentBox: true,
            horizontalEdges: 28,
            verticalEdges: 24,
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Align(
                alignment: Alignment.topLeft,
                child: NativeDocumentBox(
                  key: middleKey,
                  width: const NativeFlexLength.percent(50),
                  height: const NativeFlexLength.percent(50),
                  lengthsAreContentBox: true,
                  horizontalEdges: 10,
                  verticalEdges: 10,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: NativeDocumentBox(
                      key: innerKey,
                      width: const NativeFlexLength.percent(25),
                      height: const NativeFlexLength.pixels(20),
                      lengthsAreContentBox: true,
                      horizontalEdges: 6,
                      verticalEdges: 6,
                      child: const SizedBox(width: 1, height: 1),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      expect(_box(tester, outerKey).size, const Size(268, 174));
      expect(_box(tester, middleKey).size, const Size(130, 85));
      expect(_box(tester, innerKey).size, const Size(36, 26));
      expect(tester.getTopLeft(find.byKey(middleKey)), const Offset(3, 3));
    },
  );

  testWidgets('percentage padding resolves all sides from containing width', (
    tester,
  ) async {
    const outerKey = ValueKey('padding-outer');
    const innerKey = ValueKey('padding-inner');

    await tester.pumpWidget(
      _host(
        NativeDocumentBox(
          key: outerKey,
          width: const NativeFlexLength.pixels(200),
          child: Align(
            alignment: Alignment.topLeft,
            child: NativeDocumentBox(
              key: innerKey,
              width: const NativeFlexLength.pixels(100),
              lengthsAreContentBox: true,
              percentagePadding: const EdgeInsets.all(.1),
              child: const NativeDocumentPercentagePadding(
                fractions: EdgeInsets.all(.1),
                child: SizedBox(width: 10, height: 10),
              ),
            ),
          ),
        ),
      ),
    );

    expect(_box(tester, outerKey).size.width, 200);
    expect(_box(tester, innerKey).size.width, 140);
    expect(_box(tester, innerKey).size.height, 50);
  });

  testWidgets('percentage margins use the parent content width', (
    tester,
  ) async {
    const outerKey = ValueKey('margin-outer');
    const innerKey = ValueKey('margin-inner');
    await tester.pumpWidget(
      _host(
        NativeDocumentBox(
          key: outerKey,
          width: const NativeFlexLength.pixels(200),
          child: const NativeDocumentPercentageMargin(
            fractions: EdgeInsets.fromLTRB(.05, .1, .05, .1),
            child: Align(
              alignment: Alignment.topLeft,
              child: NativeDocumentBox(
                key: innerKey,
                width: NativeFlexLength.percent(50),
                child: SizedBox(width: 10, height: 10),
              ),
            ),
          ),
        ),
      ),
    );

    expect(_box(tester, innerKey).size.width, 100);
    expect(tester.getTopLeft(find.byKey(innerKey)), const Offset(10, 20));
  });

  testWidgets('grid containing-block scope shadows an outer block', (
    tester,
  ) async {
    const innerKey = ValueKey('grid-scoped-inner');
    await tester.pumpWidget(
      _host(
        NativeDocumentBox(
          width: const NativeFlexLength.pixels(200),
          child: NativeDocumentContainingBlock(
            width: 120,
            height: 100,
            child: Align(
              alignment: Alignment.topLeft,
              child: NativeDocumentBox(
                key: innerKey,
                width: const NativeFlexLength.percent(50),
                height: const NativeFlexLength.percent(50),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    );

    expect(_box(tester, innerKey).size, const Size(60, 50));
  });

  testWidgets('percentage height needs a definite height chain', (
    tester,
  ) async {
    const autoParent = ValueKey('auto-parent');
    const autoChild = ValueKey('auto-child');
    const fixedParent = ValueKey('fixed-parent');
    const fixedChild = ValueKey('fixed-child');

    await tester.pumpWidget(
      _host(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            NativeDocumentBox(
              key: autoParent,
              width: const NativeFlexLength.pixels(200),
              lengthsAreContentBox: true,
              child: Align(
                alignment: Alignment.topLeft,
                widthFactor: 1,
                heightFactor: 1,
                child: NativeDocumentBox(
                  key: autoChild,
                  width: const NativeFlexLength.percent(100),
                  height: const NativeFlexLength.percent(50),
                  child: const SizedBox(width: 20, height: 24),
                ),
              ),
            ),
            NativeDocumentBox(
              key: fixedParent,
              width: const NativeFlexLength.pixels(200),
              height: const NativeFlexLength.pixels(200),
              lengthsAreContentBox: true,
              child: Align(
                alignment: Alignment.topLeft,
                child: NativeDocumentBox(
                  key: fixedChild,
                  width: const NativeFlexLength.percent(100),
                  height: const NativeFlexLength.percent(50),
                  child: const SizedBox(width: 20, height: 24),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    expect(_box(tester, autoParent).size.height, 24);
    expect(_box(tester, autoChild).size.height, 24);
    expect(_box(tester, fixedParent).size.height, 200);
    expect(_box(tester, fixedChild).size.height, 100);
  });

  testWidgets('changed containing width relayouts percentage padding', (
    tester,
  ) async {
    const outerKey = ValueKey('changing-outer');
    const innerKey = ValueKey('changing-inner');
    var width = 200.0;

    Widget build() => _host(
      NativeDocumentBox(
        key: outerKey,
        width: NativeFlexLength.pixels(width),
        child: Align(
          alignment: Alignment.topLeft,
          child: NativeDocumentBox(
            key: innerKey,
            width: const NativeFlexLength.pixels(100),
            lengthsAreContentBox: true,
            percentagePadding: const EdgeInsets.all(.1),
            child: const NativeDocumentPercentagePadding(
              fractions: EdgeInsets.all(.1),
              child: SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(build());
    expect(_box(tester, innerKey).size.width, 140);

    width = 300;
    await tester.pumpWidget(build());
    expect(_box(tester, innerKey).size.width, 160);
  });

  testWidgets('tight flex allocation overrides authored dimensions', (
    tester,
  ) async {
    const key = ValueKey('tight-allocation');
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 180,
          height: 80,
          child: NativeDocumentBox(
            key: key,
            width: const NativeFlexLength.pixels(40),
            height: const NativeFlexLength.pixels(30),
            tightAllocationIsAuthoritative: true,
            lengthsAreContentBox: true,
            horizontalEdges: 10,
            verticalEdges: 8,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    expect(_box(tester, key).size, const Size(180, 80));
  });
}
