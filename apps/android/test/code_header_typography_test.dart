import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/code_block.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/markdown_selection.dart';
import 'live_test.dart' show theme;

void main() {
  for (final width in [650.0, 651.0]) {
    for (final compact in [false, true]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'code header follows Markdown width=$width compact=$compact scale=$scale',
          (t) async {
            t.view.physicalSize = Size(width, 1400);
            t.view.devicePixelRatio = 1;
            addTearDown(t.view.reset);
            for (final source in [
              '```text\ncode\n```',
              '<div>\n\n```text\ncode\n```\n\n</div>',
            ]) {
              await t.pumpWidget(
                MaterialApp(
                  theme: theme.build(Brightness.light),
                  home: MediaQuery(
                    data: MediaQueryData(
                      size: Size(width, 1400),
                      textScaler: TextScaler.linear(scale),
                    ),
                    child: Scaffold(
                      body: NativeMarkdown(source: source, compact: compact),
                    ),
                  ),
                ),
              );
              await t.pumpAndSettle();
              final lineHeight = compact
                  ? 1.6
                  : width <= 650
                  ? 1.65
                  : 1.75;
              expect(
                t
                    .widget<SelectionMarkdownBody>(
                      find.byType(SelectionMarkdownBody),
                    )
                    .styleSheet!
                    .p!
                    .height,
                lineHeight,
              );
              final block = t.widget<NativeCodeBlock>(
                find.byType(NativeCodeBlock),
              );
              expect(block.headerLineHeight, lineHeight);
              final label = t.widget<Text>(find.text('text'));
              expect(label.style!.height, lineHeight);
              expect(label.style!.fontSize, 12);
              expect(label.style!.fontWeight, FontWeight.w400);
              final style = DefaultTextStyle.of(
                t.element(find.text('Copy')),
              ).style;
              expect(style.height, lineHeight);
              expect(style.fontSize, 12);
              expect(style.fontWeight, FontWeight.w400);
              final paragraph = t.widget<RichText>(
                find.byWidgetPredicate(
                  (w) => w is RichText && w.text.toPlainText() == 'code',
                ),
              );
              final codeSpan = paragraph.text as TextSpan;
              expect(codeSpan.toPlainText(), 'code');
              expect(t.takeException(), isNull);
            }
          },
        );
      }
    }
  }
  testWidgets('explicit header line height updates without replacing code', (
    t,
  ) async {
    for (final lineHeight in [1.5, 1.8]) {
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.dark),
          home: Scaffold(
            body: NativeMarkdown(
              source: '```text\ncode\n```',
              compact: true,
              streaming: lineHeight == 1.5,
              lineHeight: lineHeight,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        t
            .widget<NativeCodeBlock>(find.byType(NativeCodeBlock))
            .headerLineHeight,
        lineHeight,
      );
      expect(
        DefaultTextStyle.of(t.element(find.text('Copy'))).style.height,
        lineHeight,
      );
    }
  });
}
