import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_control_intrinsic.dart';

void main() {
  testWidgets(
    'intrinsic adapter protects an inline control with pointer and layout listeners',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IntrinsicWidth(
              child: RichText(
                text: TextSpan(
                  text: 'Date: ',
                  style: const TextStyle(fontSize: 14),
                  children: [
                    WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: NativeHtmlControlIntrinsic(
                        intrinsicSize: const Size(156, 36),
                        baselineFromTop: 25,
                        child: GestureDetector(
                          onTap: () {},
                          child: Focus(
                            child: LayoutBuilder(
                              builder: (context, constraints) => Container(
                                width: constraints.hasBoundedWidth
                                    ? constraints.maxWidth
                                    : 156,
                                height: 36,
                                color: Colors.white,
                              ),
                            ),
                          ),
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
      await tester.pump();

      final inlineControl = find.byType(NativeHtmlControlIntrinsic);
      expect(inlineControl, findsOneWidget);
      expect(tester.getSize(inlineControl).width, greaterThanOrEqualTo(156));
      expect(tester.getSize(inlineControl).height, 36);
      final renderBox = tester.renderObject<RenderBox>(inlineControl);
      expect(
        renderBox.getDryBaseline(
          const BoxConstraints(),
          TextBaseline.alphabetic,
        ),
        25,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
