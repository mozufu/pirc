import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_mobile/theme.dart';
import 'live_test.dart' show theme;

TextStyle leafStyle(WidgetTester t, String text) {
  final widget = t.widget<RichText>(
    find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText() == text,
    ),
  );
  TextStyle? result;
  void visit(InlineSpan span, TextStyle inherited) {
    final style = inherited.merge(span.style);
    if (span is TextSpan) {
      if (span.text?.isNotEmpty == true) result = style;
      for (final child in span.children ?? <InlineSpan>[]) {
        visit(child, style);
      }
    }
  }

  visit(widget.text, const TextStyle());
  return result!;
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'quote preserves inline styles and link interaction ${brightness.name}',
      (t) async {
        final data = theme.build(brightness), links = <String>[];
        final colors = data.extension<PircColors>()!;
        await t.pumpWidget(
          MaterialApp(
            theme: data,
            home: Scaffold(
              body: SingleChildScrollView(
                child: NativeMarkdown(
                  source:
                      '> # `code`\n>\n> **Strong**\n>\n> [Link](https://example.com/)\n>\n> - Item',
                  onLink: links.add,
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(leafStyle(t, 'code').fontSize, closeTo(20.25 * .87, .001));
        expect(leafStyle(t, 'code').fontWeight, FontWeight.w700);
        expect(leafStyle(t, 'Strong').color, colors['text.primary']);
        expect(leafStyle(t, 'Link').color, colors['accent.default']);
        expect(leafStyle(t, 'Item').color, colors['text.muted']);
        expect(leafStyle(t, '•').color, colors['text.muted']);
        await t.tap(
          find.byWidgetPredicate(
            (w) => w is RichText && w.text.toPlainText() == 'Link',
          ),
        );
        expect(links, ['https://example.com/']);
        expect(t.takeException(), isNull);
      },
    );
    testWidgets('quote heading and nested scope ${brightness.name}', (t) async {
      final data = theme.build(brightness);
      final colors = data.extension<PircColors>()!;
      await t.pumpWidget(
        MaterialApp(
          theme: data,
          home: const Scaffold(
            body: SingleChildScrollView(
              child: NativeMarkdown(
                source:
                    '> # Heading\n>\n> Before\n>\n> > Nested\n>\n> After\n\nOutside',
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final heading = leafStyle(t, 'Heading');
      expect(heading.fontSize, 20.25);
      expect(heading.height, 1.35);
      expect(heading.fontWeight, FontWeight.w700);
      expect(heading.color, colors['text.primary']);
      for (final label in ['Before', 'Nested', 'After']) {
        expect(leafStyle(t, label).color, colors['text.muted']);
      }
      expect(leafStyle(t, 'Outside').color, colors['text.primary']);
      expect(t.takeException(), isNull);
    });
  }
}
