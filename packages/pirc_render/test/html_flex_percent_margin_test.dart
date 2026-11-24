import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_document_box.dart';
import 'package:pirc_render/src/html_document_flex.dart';

Widget _host({required double width, double? height, required Widget child}) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox.expand(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: height,
            child: NativeDocumentContainingBlock(width: width, child: child),
          ),
        ),
      ),
    );

RenderBox _flex(WidgetTester tester) =>
    tester.renderObject<RenderBox>(find.byType(NativeDocumentFlex));

RenderBox _box(WidgetTester tester, Key key) =>
    tester.renderObject<RenderBox>(find.byKey(key));

void main() {
  testWidgets('column percentage main margin contributes to item height', (
    tester,
  ) async {
    const childKey = ValueKey('column-percent-margin-child');
    await tester.pumpWidget(
      _host(
        width: 300,
        child: NativeDocumentFlex(
          axis: Axis.vertical,
          items: const [
            NativeFlexItem(
              preferredMain: NativeFlexLength.pixels(10),
              mainMarginPercentage: .05,
            ),
          ],
          children: [
            NativeDocumentPercentageMargin(
              fractions: EdgeInsets.only(top: .05),
              child: SizedBox(key: childKey, width: 30, height: 10),
            ),
          ],
        ),
      ),
    );

    expect(_flex(tester).size.height, 25);
    expect(_box(tester, childKey).size.height, 10);
    expect(tester.getTopLeft(find.byKey(childKey)).dy, 15);
    expect(tester.takeException(), isNull);
  });

  testWidgets('auto-height column counts percentage margins exactly once', (
    tester,
  ) async {
    const first = ValueKey('auto-first');
    const second = ValueKey('auto-second');
    await tester.pumpWidget(
      _host(
        width: 300,
        child: NativeDocumentFlex(
          axis: Axis.vertical,
          items: const [
            NativeFlexItem(mainMarginPercentage: .05),
            NativeFlexItem(),
          ],
          children: const [
            NativeDocumentPercentageMargin(
              fractions: EdgeInsets.only(top: .05),
              child: SizedBox(key: first, width: 30, height: 10),
            ),
            SizedBox(key: second, width: 30, height: 20),
          ],
        ),
      ),
    );
    expect(_flex(tester).size.height, 45);
    expect(tester.getTopLeft(find.byKey(first)).dy, 15);
    expect(_box(tester, first).size.height, 10);
    expect(tester.getTopLeft(find.byKey(second)).dy, 25);
    expect(_box(tester, second).size.height, 20);
    expect(tester.takeException(), isNull);
  });

  testWidgets('row shrink distribution includes percentage main margins', (
    tester,
  ) async {
    const firstKey = ValueKey('row-percent-margin-first');
    const secondKey = ValueKey('row-percent-margin-second');
    await tester.pumpWidget(
      _host(
        width: 200,
        child: NativeDocumentFlex(
          items: const [
            NativeFlexItem(
              basis: NativeFlexLength.pixels(120),
              minimumMain: NativeFlexLength.pixels(0),
              automaticMinimum: false,
              mainMarginPercentage: .05,
            ),
            NativeFlexItem(
              basis: NativeFlexLength.pixels(120),
              minimumMain: NativeFlexLength.pixels(0),
              automaticMinimum: false,
            ),
          ],
          children: [
            NativeDocumentPercentageMargin(
              fractions: EdgeInsets.only(left: .05),
              child: SizedBox(key: firstKey, width: 120, height: 10),
            ),
            SizedBox(key: secondKey, width: 120, height: 10),
          ],
        ),
      ),
    );

    expect(_box(tester, firstKey).size.width, 95);
    expect(_box(tester, secondKey).size.width, 95);
    expect(tester.getTopLeft(find.byKey(firstKey)).dx, 10);
    expect(tester.getTopLeft(find.byKey(secondKey)).dx, 105);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cross percentage margins size the aligned margin box', (
    tester,
  ) async {
    const childKey = ValueKey('cross-percent-margin-child');
    await tester.pumpWidget(
      _host(
        width: 200,
        height: 60,
        child: NativeDocumentFlex(
          items: const [
            NativeFlexItem(
              basis: NativeFlexLength.pixels(30),
              preferredCross: NativeFlexLength.pixels(10),
              crossMarginPercentage: .1,
              stretchCross: false,
              align: CrossAxisAlignment.center,
            ),
          ],
          children: [
            NativeDocumentPercentageMargin(
              fractions: EdgeInsets.symmetric(vertical: .05),
              child: SizedBox(key: childKey, width: 30, height: 10),
            ),
          ],
        ),
      ),
    );

    expect(_flex(tester).size.height, 60);
    expect(_box(tester, childKey).size.height, 10);
    expect(tester.getTopLeft(find.byKey(childKey)).dy, 25);
    expect(tester.takeException(), isNull);
  });
}
