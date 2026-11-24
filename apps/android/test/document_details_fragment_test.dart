import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'document_navigation_widget_test.dart' show DocumentGateway, response;
import 'live_test.dart' show theme;

void main() {
  final fixture =
      jsonDecode(
            File(
              'tool/parity/fixtures/document-details-fragment-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final row in fixture['cases'] as List) {
    testWidgets(
      'details fragment ${row['spec']['id']} initial=${row['initial']} ${row['screen']['width']} dpr${row['dpr']} ${row['theme']}',
      (tester) async {
        final dpr = (row['dpr'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize =
            Size(
              (row['screen']['width'] as num).toDouble(),
              (row['screen']['height'] as num).toDouble(),
            ) *
            dpr;
        addTearDown(tester.view.reset);
        final initial = row['initial'] == true,
            target = row['spec']['target'] as String;
        final path = '/details-fragment${initial ? '#$target' : ''}';
        final source = (row['html'] as String).replaceAll(
          RegExp(r'<script>[\s\S]*?</script>'),
          '',
        );
        final gateway = DocumentGateway()
          ..responses.add(response(path, source));
        final windows = NativeDocumentWindows(gateway),
            window = windowsTarget(windows);
        await window.load(
          NativeHtmlFormRequest(url: path, method: 'GET', target: ''),
          baseUrl: window.sourceUrl,
        );
        windows.select(window);
        final document = window.currentDocument!;
        Future<void> settle() async {
          var stable = 0;
          String? previous;
          for (var i = 0; i < 180; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            final stamp =
                '${document.scroll.lastKnownOffset}:${document.viewport.completedFragmentReveals}:${document.viewport.focusedNativeElementId}';
            final ready =
                !window.hasPendingFragmentReveal &&
                document.elementScroll.anchoringSettled &&
                document.scroll.hasClients &&
                !document.scroll.position.isScrollingNotifier.value;
            stable = ready && stamp == previous ? stable + 1 : 0;
            previous = stamp;
            if (stable >= 3) return;
          }
          fail(
            'Unsettled fragment ${row['spec']['id']}: ${document.viewport.lastFragmentDifference}',
          );
        }

        NativeHtmlDocument rendered() =>
            tester.widget<NativeHtmlDocument>(find.byType(NativeHtmlDocument));
        String nativeId(String id) {
          final index = rendered().fragmentIndex!;
          return index.nativeIdFor(index.select(id)!.anchor!)!;
        }

        Map<String, bool> opened() {
          final parsed = html.parse(
            (rendered().nodes.single as NativeHtmlRaw).html,
          );
          return {
            for (final id in ['peer', 'outer', 'inner'])
              id: parsed.getElementById(id)!.attributes.containsKey('open'),
          };
        }

        void compare(Map state) {
          final result = state['result'] as Map;
          expect(
            opened(),
            result['open'],
            reason: '${state['name']} disclosure DOM',
          );
          if (state['name'] == 'closed' || result['rect'] == null) return;
          expect(document.viewport.lastFragmentDifference, isNull);
          expect(
            document.scroll.offset,
            closeTo((result['scrollY'] as num).toDouble(), 1 / 32),
            reason: '${state['name']} root',
          );
          final viewport = Size(
            (row['viewport']['width'] as num).toDouble(),
            (row['viewport']['height'] as num).toDouble(),
          );
          final packet = rendered().layoutController!.capture(
            revision: rendered().layoutRevision,
            generation: 1,
            viewport: viewport,
            requestedIds: {nativeId(target)},
            scrollOffset: Offset(0, document.scroll.offset),
          );
          expect(packet, isNotNull);
          final box = (packet!['boxes'] as List).single as Map;
          final actual = [
            box['x'],
            (box['y'] as num) - document.scroll.offset,
            box['width'],
            box['height'],
          ];
          for (var i = 0; i < 4; i++) {
            expect(
              actual[i],
              closeTo((result['rect'][i] as num).toDouble(), 1 / 32),
              reason: '${state['name']} rect[$i]',
            );
          }
          if (row['spec']['scrollports'] == true) {
            for (final id in ['outerBody', 'innerBody']) {
              final metrics = document.elementScroll.metricsFor(nativeId(id));
              expect(
                metrics?['top'],
                closeTo((result['ports'][id]['top'] as num).toDouble(), 1 / 32),
                reason: '${state['name']} $id',
              );
            }
          }
          final focused = document.viewport.focusedNativeElementId;
          final expected = result['focus'] as String;
          expect(
            focused,
            expected.isEmpty ? isNull : nativeId(expected),
            reason: '${state['name']} focus',
          );
        }

        Future<void> closeOuter() async {
          if (opened()['outer'] == true) {
            final summary = find.byWidgetPredicate(
              (w) => w is RichText && w.text.toPlainText().contains('Outer'),
            );
            await tester.ensureVisible(summary);
            await tester.tap(summary);
            await settle();
          }
          document.scroll.jumpTo(0);
          await settle();
        }

        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(
                row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
              ),
              home: NativeDocumentWorkspace(windows: windows),
            ),
          );
          await settle();
          var states = (row['states'] as List).iterator;
          states.moveNext();
          compare(states.current as Map);
          if (!initial) {
            await tester.tap(find.text('Jump', findRichText: true));
            await settle();
            states.moveNext();
            compare(states.current as Map);
          }
          if (row['spec']['input'] == true) {
            await tester.enterText(find.byType(EditableText), 'retained edit');
            await tester.pumpAndSettle();
          }
          await closeOuter();
          states.moveNext();
          compare(states.current as Map);
          // Resizing and remounting the same browsing context must not run
          // initial fragment selection or reopen the user's closed disclosure.
          final originalSize = tester.view.physicalSize;
          tester.view.physicalSize = Size(
            originalSize.width - 40 * dpr,
            originalSize.height - 80 * dpr,
          );
          await settle();
          expect(opened()['outer'], isFalse);
          tester.view.physicalSize = originalSize;
          await settle();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(
                row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
              ),
              home: NativeDocumentWorkspace(windows: windows),
            ),
          );
          await settle();
          expect(opened()['outer'], isFalse);
          await tester.tap(find.text('Jump', findRichText: true));
          await settle();
          states.moveNext();
          compare(states.current as Map);
          if (row['spec']['input'] == true) {
            expect(
              tester
                  .widget<EditableText>(find.byType(EditableText))
                  .controller
                  .text,
              'retained edit',
            );
          }
          await closeOuter();
          window.applyHistoryApiMutation(
            document: document,
            method: 'push',
            revision: 1,
            url: 'https://gateway.example/details-fragment#other-route',
            stateGraph: {'version': 1, 'root': null, 'nodes': []},
          );
          await settle();
          expect(
            opened()['outer'],
            isFalse,
            reason: 'pushState does not reveal',
          );
          window.back();
          await settle();
          states.moveNext();
          compare(states.current as Map);
          // A completed traversal is not a new fragment request on remount.
          document.scroll.jumpTo(160);
          await settle();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(
                row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
              ),
              home: NativeDocumentWorkspace(windows: windows),
            ),
          );
          await settle();
          expect(
            document.scroll.offset,
            closeTo(160, 1 / 32),
            reason: 'keep subsequent reading position',
          );
          expect(gateway.calls, hasLength(1));
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          windows.dispose();
        }
      },
    );
  }
}

NativeDocumentWindow windowsTarget(NativeDocumentWindows windows) =>
    windows.target('report', null, sourceUrl: 'https://gateway.example/');
