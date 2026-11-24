import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/code_block.dart';
import 'live_test.dart' show theme;

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('tab stops retain source and native selection scale=$scale', (
      t,
    ) async {
      const source = ' \tA\n  \tB\n\t\tC';
      String? clipboard;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
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
            child: const Scaffold(
              body: SingleChildScrollView(
                child: NativeCodeBlock(source: source, language: 'text'),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final finder = find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText() == source,
      );
      expect(finder, findsOneWidget);
      final paragraph = t.renderObject<RenderParagraph>(finder);
      final richText = t.widget<RichText>(finder);
      final control = TextPainter(
        text: TextSpan(
          text: source.replaceAll('\t', '  '),
          style: richText.text.style,
        ),
        textDirection: TextDirection.ltr,
        textScaler: richText.textScaler,
      )..layout();
      expect(paragraph.size.height, lessThanOrEqualTo(control.height + .001));
      control.dispose();
      double advance(int offset) {
        final box = paragraph
            .getBoxesForSelection(
              TextSelection(baseOffset: offset, extentOffset: offset + 1),
            )
            .single;
        return box.right - box.left;
      }

      final space = advance(0);
      expect(advance(1), closeTo(space, .001));
      for (final offset in [6, 9, 10]) {
        expect(advance(offset), closeTo(2 * space, .001));
      }
      final selection = t.state<SelectableRegionState>(
        find.byType(SelectableRegion),
      );
      selection.selectAll(SelectionChangedCause.keyboard);
      await t.pump();
      selection.contextMenuButtonItems
          .firstWhere((item) => item.type == ContextMenuButtonType.copy)
          .onPressed!();
      await t.pump();
      expect(clipboard, 'text\nCopy\n$source');
      await t.tap(find.text('Copy'));
      await t.pump();
      expect(clipboard, source);
      await t.pump(const Duration(milliseconds: 1400));
      expect(t.takeException(), isNull);
    });
  }
}
