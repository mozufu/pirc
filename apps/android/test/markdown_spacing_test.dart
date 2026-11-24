import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'live_test.dart' show theme;

Finder text(String value) => find.byWidgetPredicate(
  (widget) => widget is RichText && widget.text.toPlainText() == value,
);

void main() {
  for (final scale in [1.0, 2.0]) {
    for (final streaming in [false, true]) {
      testWidgets('heading margins scale=$scale streaming=$streaming', (
        t,
      ) async {
        Future<void> render(String source, bool active) async {
          await t.pumpWidget(
            MaterialApp(
              theme: theme.build(Brightness.light),
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(390, 844),
                  textScaler: TextScaler.linear(scale),
                ),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: NativeMarkdown(source: source, streaming: active),
                  ),
                ),
              ),
            ),
          );
          await t.pump(const Duration(milliseconds: 100));
        }

        const source = '# Alpha\n\nBravo\n\n## Charlie\n\n### Delta\n\nEcho';
        if (streaming) {
          await render('# Alpha\n\nBravo', true);
          await render('# Alpha\n\nBravo\n\n## Charlie', true);
        }
        await render(source, streaming);
        final rects = [
          'Alpha',
          'Bravo',
          'Charlie',
          'Delta',
        ].map((s) => t.getRect(text(s))).toList();
        expect(rects.first.top, 0);
        expect(
          rects[1].top - rects[0].bottom,
          closeTo(15 * 1.35 * .5 * scale, .01),
        );
        expect(
          rects[2].top - rects[1].bottom,
          closeTo(15 * 1.2 * 1.3 * scale, .01),
        );
        expect(
          rects[3].top - rects[2].bottom,
          closeTo(15 * 1.08 * 1.3 * scale, .01),
        );
        if (streaming) {
          await render(source, false);
          final completed = [
            'Alpha',
            'Bravo',
            'Charlie',
            'Delta',
          ].map((s) => t.getRect(text(s))).toList();
          expect(
            completed,
            rects,
            reason: 'Completing a streamed reply must not move stable blocks',
          );
        }
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      });
    }
  }
}
