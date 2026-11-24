import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/native_math_block.dart';

import 'live_test.dart' show theme;

void main() {
  testWidgets(
    'NativeMarkdown short display block and following paragraph match web geometry',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1800);
      addTearDown(tester.view.reset);

      const source = r'''$$
\mathchoice{\rule{40pt}{5pt}}{\rule{30pt}{5pt}}{\rule{20pt}{5pt}}{\rule{10pt}{5pt}}
$$

Following paragraph''';
      const browserBlockHeights = [32.4375, 60.875];
      const browserLineHeights = [19.4375, 38.875];
      const browserFollowingGaps = [12.75, 25.5];

      for (var index = 0; index < [1.0, 2.0].length; index++) {
        final scale = [1.0, 2.0][index];
        await tester.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                        width: 868,
                        child: NativeMarkdown(
                          source: source,
                          fontSize: 15,
                          lineHeight: 1.65,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'scale=$scale');

        final blockFinder = find.byType(NativeMathDisplayBlock);
        expect(blockFinder, findsOneWidget);
        final lineBoxFinder = find.byType(NativeMathLineBox);
        final paragraphFinder = find.text('Following paragraph');
        expect(paragraphFinder, findsOneWidget);

        final blockRect = tester.getRect(blockFinder);
        final lineBoxRect = tester.getRect(lineBoxFinder);
        final paragraphRect = tester.getRect(paragraphFinder);
        expect(blockRect.left, closeTo(16, .01));
        expect(blockRect.top, closeTo(16, .01));
        expect(blockRect.width, closeTo(868, .01));
        expect(
          blockRect.height,
          closeTo(browserBlockHeights[index], .02),
          reason: 'whole math-block box at scale=$scale',
        );
        expect(
          lineBoxRect.height,
          closeTo(browserLineHeights[index], .02),
          reason: 'display line box at scale=$scale',
        );
        final followingTextGap = paragraphRect.top - blockRect.bottom;
        expect(
          followingTextGap,
          closeTo(browserFollowingGaps[index], .02),
          reason: 'following paragraph top at scale=$scale',
        );
        expect(
          paragraphRect.top - blockRect.top,
          closeTo(
            browserBlockHeights[index] + browserFollowingGaps[index],
            .02,
          ),
          reason: 'following text y relative to the math block at scale=$scale',
        );
      }
    },
  );
}
