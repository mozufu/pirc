import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/code_block.dart';
import 'live_test.dart' show theme;

void main() {
  for (final scale in [1.0, 2.0]) {
    for (final source in [
      'abc\n',
      '\n',
      'abc\n\n',
      'abc\t\n',
      'abc\u2028def\n',
      'abc\n ',
    ]) {
      testWidgets(
        'terminal LF layout and selection ${source.codeUnits} scale=$scale',
        (t) async {
          String? copied;
          t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String;
              }
              return null;
            },
          );
          addTearDown(
            () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              SystemChannels.platform,
              null,
            ),
          );
          await t.pumpWidget(
            MaterialApp(
              theme: theme.build(Brightness.light),
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: NativeCodeBlock(source: source, language: 'text'),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          final finder = find.byWidgetPredicate(
            (w) => w is RichText && w.text.toPlainText() == source,
          );
          expect(finder, findsOneWidget);
          final rich = t.widget<RichText>(finder);
          final paragraph = t.renderObject<RenderParagraph>(finder);
          final control = TextPainter(
            text: rich.text,
            textDirection: TextDirection.ltr,
            textScaler: rich.textScaler,
            strutStyle: rich.strutStyle,
          )..layout();
          final lines = control.computeLineMetrics();
          final expectedHeight = source.endsWith('\n')
              ? control.height - lines.last.height
              : control.height;
          expect(paragraph.size.height, closeTo(expectedHeight, .001));
          final caret = paragraph.getOffsetForCaret(
            TextPosition(offset: source.length),
            Rect.zero,
          );
          expect(caret.dy, greaterThanOrEqualTo(0));
          expect(caret.dy, lessThan(paragraph.size.height));
          final region = t.state<SelectableRegionState>(
            find.byType(SelectableRegion),
          );
          region.selectAll(SelectionChangedCause.keyboard);
          await t.pump();
          region.contextMenuButtonItems
              .firstWhere((item) => item.type == ContextMenuButtonType.copy)
              .onPressed!();
          await t.pump();
          expect(copied, 'text\nCopy\n$source');
          await t.tap(find.text('Copy'));
          await t.pump();
          expect(copied, source);
          await t.pump(const Duration(milliseconds: 1400));
          if (source == 'abc\n') {
            final start = paragraph.localToGlobal(
              paragraph.getOffsetForCaret(
                    const TextPosition(offset: 2),
                    Rect.zero,
                  ) +
                  Offset(0, paragraph.size.height / 2),
            );
            final end = paragraph.localToGlobal(
              Offset(paragraph.size.width + 10, paragraph.size.height + 4),
            );
            final drag = await t.startGesture(
              start,
              kind: PointerDeviceKind.mouse,
            );
            await drag.moveTo(end);
            await drag.up();
            await t.pumpAndSettle();
            region.contextMenuButtonItems
                .firstWhere((item) => item.type == ContextMenuButtonType.copy)
                .onPressed!();
            await t.pump();
            // The pinned Chrome oracle selects only c at this drag endpoint.
            expect(copied, 'c');
          }
          control.dispose();
          expect(t.takeException(), isNull);
        },
      );
    }
  }
}
