import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'live_test.dart' show theme;

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('list descendant margins at document edges scale=$scale', (
      t,
    ) async {
      await render(t, '- # Alpha\n\n  Bravo', scale);
      expect(rect(t, 'Alpha').top, closeTo(15 * 1.35 * 1.3 * scale, .01));
      expect(
        t.getRect(find.byType(NativeMarkdown)).bottom,
        rect(t, 'Bravo').bottom,
      );
      await render(t, '- Alpha\n\n  ## Bravo', scale);
      expect(rect(t, 'Alpha').top, 0);
      expect(
        t.getRect(find.byType(NativeMarkdown)).bottom - rect(t, 'Bravo').bottom,
        closeTo(9 * scale, .01),
      );
    });
    testWidgets('streamed list edges do not duplicate margins scale=$scale', (
      t,
    ) async {
      const list = '- # Alpha\n\n  Bravo';
      await render(t, list, scale, streaming: true);
      await render(t, '$list\n\nAfter', scale, streaming: true);
      final before = [rect(t, 'Alpha'), rect(t, 'Bravo')];
      await render(t, '$list\n\nAfter', scale);
      expect([rect(t, 'Alpha'), rect(t, 'Bravo')], before);
      expect(
        rect(t, 'After').top - rect(t, 'Bravo').bottom,
        closeTo(12.75 * scale, .01),
      );
    });
    for (final loose in [false, true]) {
      testWidgets('list spacing loose=$loose scale=$scale', (t) async {
        await render(
          t,
          loose
              ? '- Alpha\n\n- Bravo\n\n- Charlie'
              : '- Alpha\n- Bravo\n- Charlie',
          scale,
        );
        final a = rect(t, 'Alpha'),
            b = rect(t, 'Bravo'),
            c = rect(t, 'Charlie');
        expect(b.top - a.bottom, closeTo((loose ? 6 : 3) * scale, .01));
        expect(c.top - b.bottom, closeTo((loose ? 6 : 3) * scale, .01));
        expect(a.left, 22.5 * scale);
        expect(
          t.getRect(find.byType(NativeMarkdown)).bottom - c.bottom,
          closeTo((loose ? 6 : 0) * scale, .01),
          reason:
              'A final loose-list paragraph margin collapses through its list',
        );
      });
    }
    testWidgets('inline emphasis and loose item paragraphs scale=$scale', (
      t,
    ) async {
      await render(t, '1. **Alpha**\n2. Bravo', scale);
      expect(
        rect(t, 'Bravo').top - rect(t, 'Alpha').bottom,
        closeTo(3 * scale, .01),
      );
      await render(t, '- Alpha\n\n  Bravo\n\n- Charlie', scale);
      expect(
        rect(t, 'Bravo').top - rect(t, 'Alpha').bottom,
        closeTo(6 * scale, .01),
      );
      expect(
        rect(t, 'Charlie').top - rect(t, 'Bravo').bottom,
        closeTo(6 * scale, .01),
      );
    });
    testWidgets('nested list spacing scale=$scale', (t) async {
      await render(t, '- Alpha\n  - Bravo\n  - Charlie\n- Delta', scale);
      final values = [
        'Alpha',
        'Bravo',
        'Charlie',
        'Delta',
      ].map((s) => rect(t, s)).toList();
      for (var i = 1; i < values.length; i++) {
        expect(values[i].top - values[i - 1].bottom, closeTo(3 * scale, .01));
      }
      expect(values[1].left, 45 * scale);
    });
    testWidgets('quote inner trailing margin scale=$scale', (t) async {
      await render(t, 'Before\n\n> Alpha\n>\n> Bravo\n\nAfter', scale);
      final a = rect(t, 'Alpha'),
          b = rect(t, 'Bravo'),
          after = rect(t, 'After');
      expect(b.top - a.bottom, closeTo(12.75 * scale, .01));
      expect(after.top - b.bottom, closeTo((12.75 + 1.5 + 12.75) * scale, .01));
      expect(a.left, closeTo(3 + 14.25 * scale, .01));
    });
  }
}

Rect rect(WidgetTester t, String text) => t.getRect(
  find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == text),
);
Future<void> render(
  WidgetTester t,
  String source,
  double scale, {
  bool streaming = false,
}) async {
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
            child: NativeMarkdown(
              source: source,
              lineHeight: 1.65,
              streaming: streaming,
            ),
          ),
        ),
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 100));
  expect(t.takeException(), isNull);
}
