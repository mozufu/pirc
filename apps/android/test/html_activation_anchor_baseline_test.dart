import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as md;
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';

import 'live_test.dart' show theme;

typedef _ScriptEvent =
    Future<bool> Function(
      String,
      String,
      List<Map<String, dynamic>>, {
      String? submitter,
    });

Widget _page(
  String source, {
  required NativeHtmlViewportController viewport,
  required _ScriptEvent onScriptEvent,
}) => MaterialApp(
  theme: theme.build(Brightness.light),
  home: Scaffold(
    body: SelectionArea(
      child: SingleChildScrollView(
        child: NativeHtmlDocument(
          nodes: [NativeHtmlRaw(source)],
          style: const TextStyle(fontSize: 16),
          styles: md.MarkdownStyleSheet(),
          builders: const {},
          markdownStyles: false,
          viewport: viewport,
          scriptDocument: Object(),
          onScriptEvent: onScriptEvent,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'inline anchors keep button layout, click target, text selection, and scroll keys',
    (tester) async {
      const source = '''
<p><button type="button" data-pirc-script-id="button-action">
  Button <span id="button-label-anchor">Run action</span>
</button></p>
<a name="named-target">Named target</a>
<table><tbody><tr>
  <td><span id="table-cell-anchor">Cell target</span></td>
  <td>Second cell</td>
</tr></tbody></table>
''';
      final events = <String>[];
      final viewport = NativeHtmlViewportController();

      await tester.pumpWidget(
        _page(
          source,
          viewport: viewport,
          onScriptEvent: (id, type, controls, {submitter}) async {
            events.add('$id:$type');
            return false;
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(NativeHtmlButtonWidget), findsOneWidget);
      expect(tester.takeException(), isNull);

      final textFinder = find
          .byWidgetPredicate(
            (widget) =>
                widget is RichText &&
                widget.text.toPlainText().contains('Run action'),
          )
          .first;
      final paragraph = tester.renderObject<RenderParagraph>(textFinder);
      final label = paragraph.text.toPlainText();
      final start = label.indexOf('Run action');
      final selection = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + 1),
      );
      expect(selection, isNotEmpty);
      expect(tester.widget<RichText>(textFinder).selectionRegistrar, isNotNull);

      await tester.tapAt(
        paragraph.localToGlobal(selection.first.toRect().center),
      );
      await tester.pumpAndSettle();
      expect(events, ['button-action:click']);
      expect(tester.takeException(), isNull);

      for (final anchor in [
        'button-label-anchor',
        'named-target',
        'table-cell-anchor',
      ]) {
        final scroll = viewport.scrollToAnchor(anchor);
        await tester.pumpAndSettle();
        expect(await scroll, isTrue, reason: 'anchor $anchor remains attached');
      }

      await tester.pumpWidget(const SizedBox());
    },
  );
}
