import 'dart:ui' show SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as md;
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'live_test.dart' show theme;

void main() {
  for (final width in [390.0, 768.0]) {
    for (final brightness in Brightness.values) {
      for (final dpr in [1.0, 3.0]) {
        testWidgets('scripted details $width $brightness dpr$dpr', (
          tester,
        ) async {
          tester.view.devicePixelRatio = dpr;
          tester.view.physicalSize = Size(width, 1024) * dpr;
          addTearDown(tester.view.reset);
          final owner = Object(), clicks = <String>[];
          var first = false, second = false, revision = 0;
          var draft = 'server';
          var focusActions = <Map<String, dynamic>>[];
          late StateSetter update;
          final links = <String>[];
          String source() =>
              '''
<details data-pirc-script-id="first" name="group" ${first ? 'open' : ''}>
<summary data-pirc-script-id="first-summary" data-pirc-script-click style="padding:12px">First section</summary>
<p>First body</p><input data-pirc-script-id="draft" value="$draft"></details>
<details data-pirc-script-id="second" name="group" ${second ? 'open' : ''}>
<summary data-pirc-script-id="second-summary" data-pirc-script-click>Second section</summary><p>Second body</p></details>
<details data-pirc-script-id="cancelled"><summary data-pirc-script-id="cancel-summary" data-pirc-script-click>Cancelled section</summary><p>Cancelled body</p></details>
<p data-pirc-script-id="revision">Revision $revision</p>''';
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(brightness),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      update = setState;
                      return NativeHtmlDocument(
                        nodes: [NativeHtmlRaw(source())],
                        style: const TextStyle(fontSize: 16),
                        styles: md.MarkdownStyleSheet(),
                        builders: const {},
                        markdownStyles: false,
                        scriptDocument: owner,
                        scriptFocusActions: focusActions,
                        onLink: links.add,
                        onScriptEvent: (id, type, controls, {submitter}) async {
                          for (final control in controls) {
                            if (control['id'] == 'draft' &&
                                control['value'] is String) {
                              draft = control['value'] as String;
                            }
                          }
                          if (type != 'click') return false;
                          clicks.add(id);
                          if (id == 'cancel-summary') return true;
                          update(() {
                            if (id == 'first-summary') {
                              first = !first;
                              if (first) second = false;
                            }
                            if (id == 'second-summary') {
                              second = !second;
                              if (second) first = false;
                            }
                          });
                          return false;
                        },
                      );
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('First body', findRichText: true), findsNothing);
          // Activate the summary's padded box, away from its text recognizer.
          final title = _summary('First section');
          await tester.tapAt(tester.getTopLeft(title) + const Offset(-4, 4));
          await tester.pumpAndSettle();
          expect(clicks, ['first-summary']);
          expect(find.text('First body', findRichText: true), findsOneWidget);
          await tester.enterText(find.byType(EditableText), 'retained draft');
          await tester.pumpAndSettle();
          await tester.tap(title);
          await tester.pumpAndSettle();
          expect(clicks, ['first-summary', 'first-summary']);
          expect(find.text('First body', findRichText: true), findsNothing);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(clicks, ['first-summary', 'first-summary', 'first-summary']);
          expect(
            tester
                .widget<EditableText>(find.byType(EditableText))
                .controller
                .text,
            'retained draft',
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.pumpAndSettle();
          expect(clicks, hasLength(4));
          expect(find.text('First body', findRichText: true), findsNothing);
          update(() {
            first = true;
            revision++;
          });
          await tester.pumpAndSettle();
          expect(find.text('First body', findRichText: true), findsOneWidget);
          update(() {
            second = true;
            first = false;
            revision++;
          });
          await tester.pumpAndSettle();
          expect(find.text('First body', findRichText: true), findsNothing);
          expect(find.text('Second body', findRichText: true), findsOneWidget);
          await tester.tap(_summary('Cancelled section'));
          await tester.pumpAndSettle();
          expect(clicks.last, 'cancel-summary');
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(clicks.where((id) => id == 'cancel-summary'), hasLength(2));
          final semantics = tester.ensureSemantics();
          await tester.pumpAndSettle();
          final node = tester.getSemantics(_summary('Cancelled section'));
          node.owner!.performAction(node.id, SemanticsAction.tap);
          await tester.pumpAndSettle();
          expect(clicks.where((id) => id == 'cancel-summary'), hasLength(3));
          semantics.dispose();
          update(() {
            focusActions = [
              {
                'kind': 'focus',
                'controlId': 'first-summary',
                'preventScroll': true,
                'actionOrder': 1,
                'sequence': 1,
              },
            ];
          });
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(clicks.last, 'first-summary');
          expect(find.text('First body', findRichText: true), findsOneWidget);
          expect(find.text('Second body', findRichText: true), findsNothing);

          expect(find.text('Cancelled body', findRichText: true), findsNothing);
          expect(links, isEmpty);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}

Finder _summary(String label) => find.byWidgetPredicate(
  (widget) => widget is RichText && widget.text.toPlainText().contains(label),
);
