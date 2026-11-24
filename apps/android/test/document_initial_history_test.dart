import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'document_navigation_widget_test.dart' show DocumentGateway, response;
import 'document_initial_fragment_wait_test.dart' show WaitingScripts;
import 'live_test.dart' show theme;

void main() {
  for (final scenario in [
    'push',
    'replace',
    'append-fragment',
    'remove-fragment',
  ]) {
    testWidgets('History mutation preserves the pending initial reveal: $scenario', (
      tester,
    ) async {
      final initial = scenario == 'append-fragment'
          ? '/initial'
          : '/initial#one';
      final gateway = DocumentGateway()
        ..responses.add(
          response(
            initial,
            '<!doctype html><body style="margin:0"><div style="height:600px"></div><div id="one" style="height:40px">One</div><div style="height:600px"></div><div id="two" style="height:40px">Two</div><div style="height:2000px"></div></body>',
          ),
        );
      final windows = NativeDocumentWindows(gateway),
          window = windows.target(
            'initial',
            null,
            sourceUrl: 'https://gateway.example/',
          );
      addTearDown(windows.dispose);
      await window.load(
        NativeHtmlFormRequest(url: initial, method: 'GET', target: ''),
        baseUrl: window.sourceUrl,
      );
      windows.select(window);
      final document = window.currentDocument!,
          scripts = WaitingScripts(gateway);
      document.scripts = scripts;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: NativeDocumentWorkspace(windows: windows),
        ),
      );
      await tester.pumpAndSettle();
      expect(document.initialFragmentRevealPending, isTrue);
      expect(document.viewport.completedFragmentReveals, 0);
      if (scenario == 'remove-fragment') document.scroll.jumpTo(240);
      window.applyHistoryApiMutation(
        document: document,
        method: scenario == 'replace' || scenario == 'remove-fragment'
            ? 'replace'
            : 'push',
        revision: 1,
        url: scenario == 'remove-fragment'
            ? 'https://gateway.example/initial'
            : 'https://gateway.example/initial#two',
        stateGraph: {'version': 1, 'root': null, 'nodes': []},
      );
      await tester.pumpAndSettle();
      expect(document.initialFragmentRevealPending, isTrue);
      expect(document.viewport.completedFragmentReveals, 0);
      // End the synthetic pending startup through its real error/fallback path.
      // Successful VM selection is checked separately by the real Android gate.
      scripts.finishUnavailable();
      await tester.pumpAndSettle();
      final expected = scenario == 'remove-fragment' ? 240.0 : 1240.0;
      expect(document.scroll.offset, expected);
      expect(document.initialFragmentRevealPending, isFalse);
      final completed = document.viewport.completedFragmentReveals;
      window.applyHistoryApiMutation(
        document: document,
        method: 'replace',
        revision: 2,
        url: 'https://gateway.example/initial#one',
        stateGraph: {'version': 1, 'root': null, 'nodes': []},
      );
      await tester.pumpAndSettle();
      expect(
        document.scroll.offset,
        expected,
        reason: 'later History API writes preserve reading position',
      );
      expect(document.viewport.completedFragmentReveals, completed);
      expect(gateway.calls, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
