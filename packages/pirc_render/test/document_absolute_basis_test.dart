import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_absolute_position.dart';
import 'package:pirc_render/src/html_document_box.dart';
import 'package:pirc_render/src/html_document_flex.dart';

void main() {
  testWidgets(
    'absolute percentage edges relayout when only the flow changes size',
    (tester) async {
      final width = ValueNotifier<double>(200);
      addTearDown(width.dispose);
      final box = GlobalKey();
      final spec = NativeAbsolutePositionSpec.parse(
        {
          'position': 'absolute',
          'left': '0px',
          'top': '0px',
          'width': '100px',
          'box-sizing': 'border-box',
          'padding-top': '10%',
        },
        fontSize: 16,
        viewport: const Size(800, 600),
      )!;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: NativeDocumentAbsoluteLayer(
              flow: ValueListenableBuilder<double>(
                valueListenable: width,
                builder: (_, value, _) => SizedBox(width: value, height: 100),
              ),
              positioned: [
                NativeAbsoluteEntry(
                  spec: spec,
                  child: NativeDocumentBox(
                    key: box,
                    applySizing: false,
                    lengthsAreContentBox: false,
                    width: const NativeFlexLength.pixels(100),
                    percentagePadding: const EdgeInsets.only(top: .1),
                    child: const NativeDocumentPercentagePadding(
                      fractions: EdgeInsets.only(top: .1),
                      child: SizedBox(width: 10, height: 10),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byKey(box)), const Size(100, 30));
      final element = box.currentContext;
      width.value = 300;
      await tester.pump();
      expect(box.currentContext, same(element));
      expect(tester.getSize(find.byKey(box)), const Size(100, 40));
      width.value = 150;
      await tester.pump();
      expect(box.currentContext, same(element));
      expect(tester.getSize(find.byKey(box)), const Size(100, 25));
      expect(tester.takeException(), isNull);
    },
  );
}
