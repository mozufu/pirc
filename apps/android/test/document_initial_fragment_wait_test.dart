import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'document_navigation_widget_test.dart' show DocumentGateway, response;
import 'live_test.dart' show theme;

// Exercises the host's pending/error lifecycle without fabricating DOM geometry.
// Real successful parser/defer/module completion is covered by the Android gate.
class WaitingScripts extends NativeDocumentScripts {
  WaitingScripts(super.gateway) {
    loading = true;
    fragmentTargetReady = false;
  }
  bool disposed = false;
  bool get observed => hasListeners;
  @override
  bool get initialTargetSelectionPending => loading;
  void finishUnavailable() {
    if (disposed) return;
    loading = false;
    ready = false;
    notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

void main() {
  for (final scenario in [
    'release-error',
    'remount',
    'replace-cancel',
    'window-cancel',
  ]) {
    testWidgets('initial fragment waits without frame spinning: $scenario', (
      tester,
    ) async {
      final gateway = DocumentGateway()
        ..responses.add(
          response(
            '/waiting#target',
            '<!doctype html><body style="margin:0"><div style="height:600px"></div><div id="target" style="height:40px">Target</div><div style="height:2000px"></div></body>',
          ),
        );
      final windows = NativeDocumentWindows(gateway),
          window = windows.target(
            'waiting',
            null,
            sourceUrl: 'https://gateway.example/',
          );
      addTearDown(windows.dispose);
      await window.load(
        const NativeHtmlFormRequest(
          url: '/waiting#target',
          method: 'GET',
          target: '',
        ),
        baseUrl: window.sourceUrl,
      );
      windows.select(window);
      final document = window.currentDocument!,
          scripts = WaitingScripts(gateway);
      document.scripts = scripts;
      Widget workspace() => MaterialApp(
        theme: theme.build(Brightness.light),
        home: NativeDocumentWorkspace(windows: windows),
      );
      await tester.pumpWidget(workspace());
      await tester.pumpAndSettle();
      for (var i = 0; i < 160; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(document.scroll.offset, 0);
      expect(document.initialFragmentRevealPending, isTrue);
      expect(document.viewport.completedFragmentReveals, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      if (scenario == 'remount') {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(scripts.observed, isFalse);
        await tester.pumpWidget(workspace());
        await tester.pumpAndSettle();
        expect(document.initialFragmentRevealPending, isTrue);
        expect(document.scroll.offset, 0);
      }
      if (scenario == 'replace-cancel') {
        gateway.responses.add(
          response(
            '/replacement',
            '<div style="height:3000px">Replacement</div>',
          ),
        );
        await window.load(
          const NativeHtmlFormRequest(
            url: '/replacement',
            method: 'GET',
            target: '',
          ),
          baseUrl: window.current!.url,
          replaceCurrent: true,
        );
        await tester.pumpAndSettle();
        scripts.finishUnavailable();
        await tester.pumpAndSettle();
        expect(window.current!.url, endsWith('/replacement'));
        expect(window.currentDocument!.scroll.offset, 0);
      } else if (scenario == 'window-cancel') {
        document.scroll.jumpTo(240);
        gateway.responses.add(
          response('/other', '<div style="height:3000px">Other</div>'),
        );
        final other = windows.target(
          'other',
          null,
          sourceUrl: 'https://gateway.example/',
        );
        await other.load(
          const NativeHtmlFormRequest(url: '/other', method: 'GET', target: ''),
          baseUrl: other.sourceUrl,
        );
        windows.select(other);
        await tester.pumpAndSettle();
        expect(scripts.observed, isFalse);
        scripts.finishUnavailable();
        await tester.pumpAndSettle();
        windows.select(window);
        await tester.pumpAndSettle();
        expect(document.scroll.offset, 240);
        expect(document.initialFragmentRevealPending, isFalse);
      } else {
        scripts.finishUnavailable();
        await tester.pumpAndSettle();
        expect(document.scroll.offset, 600);
        expect(document.initialFragmentRevealPending, isFalse);
        expect(document.viewport.completedFragmentReveals, 1);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
