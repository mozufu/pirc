import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_pointer_events.dart';
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'live_test.dart' show theme;

void main() {
  testWidgets(
    'pointer-inert text fields keep keyboard focus but reject pointer focus',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: NativeHtmlDocument(
              nodes: [
                NativeHtmlRaw(
                  '<div style="pointer-events:none"><input id="field" value="start" style="width:120px;height:40px"></div>',
                ),
              ],
              style: const TextStyle(fontSize: 16),
              styles: fm.MarkdownStyleSheet(),
              builders: const {},
              markdownStyles: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byType(EditableText);
      final focus = tester.widget<EditableText>(field).focusNode;
      expect(focus.hasFocus, isFalse);
      await tester.tapAt(tester.getCenter(field));
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);
      focus.requestFocus();
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      await tester.enterText(find.byType(TextField), 'keyboard');
      expect(tester.widget<EditableText>(field).controller.text, 'keyboard');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'restored child respects rounded clipping and leaves none paint inert',
    (tester) async {
      final hits = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 120,
                height: 100,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => hits.add('base'),
                      ),
                    ),
                    NativeDocumentPointerEvents(
                      enabled: false,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(30),
                        child: SizedBox(
                          width: 100,
                          height: 80,
                          child: NativeDocumentPointerEvents(
                            enabled: true,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => hits.add('child'),
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
      await tester.tapAt(const Offset(2, 2));
      await tester.pump();
      expect(hits, ['base']);
      await tester.tapAt(const Offset(50, 40));
      await tester.pump();
      expect(hits, ['base', 'child']);
    },
  );
}
