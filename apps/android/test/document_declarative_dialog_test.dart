import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'document_navigation_widget_test.dart' show response;
import 'live_test.dart' show theme;
import 'support/document_vm_gateway.dart';

void main() {
  final runtime = File('assets/document-script-runtime.js').readAsStringSync();
  for (final width in [390.0, 768.0]) {
    testWidgets('declarative dialog closes without authored scripts at $width', (
      t,
    ) async {
      final g = (await t.runAsync(DocumentVmGateway.start))!
        ..responses.add({
          ...response(
            '/test',
            '<!doctype html><html><body><dialog id="dialog" open><form method="dialog"><button value="done">Close</button></form></dialog><p>Outside</p></body></html>',
          ),
          'finalUrl': 'https://dialog.example/test',
        });
      final windows = NativeDocumentWindows(g),
          window = windows.target(
            'declarative',
            null,
            sourceUrl: 'https://dialog.example/',
          );
      await window.load(
        const NativeHtmlFormRequest(url: '/test', method: 'GET', target: ''),
        baseUrl: window.sourceUrl,
      );
      windows.select(window);
      final doc = window.currentDocument!;
      expect(doc.content.hasScripts, isFalse);
      doc.scripts = NativeDocumentScripts(g, loadRuntime: () async => runtime);
      Finder close() => find.byWidgetPredicate(
        (w) => w is NativeHtmlButtonWidget && w.button.label == 'Close',
      );
      try {
        t.view.physicalSize = Size(width, 844);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: NativeDocumentWorkspace(windows: windows),
          ),
        );
        await driveDocumentVm(
          t,
          () => doc.scripts!.ready,
          reason: 'runtime for declarative dialog',
        );
        expect(close(), findsOneWidget);
        await t.tap(close());
        await driveDocumentVm(
          t,
          () =>
              close().evaluate().isEmpty && !doc.scripts!.hasPendingPublication,
          reason: 'declarative close',
        );
        expect(
          await t.runAsync(
            () => g.inspect(
              '({open:document.getElementById("dialog").open,value:document.getElementById("dialog").returnValue})',
            ),
          ),
          {'open': false, 'value': 'done'},
        );
        expect(identical(window.currentDocument, doc), isTrue);
        expect(g.opens, 1);
        expect(g.requests, isEmpty);
        expect(g.responses, isEmpty);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        final scripts = doc.scripts;
        windows.dispose();
        var closed = false;
        (scripts?.closed ?? Future<void>.value()).then((_) => closed = true);
        await driveDocumentVm(
          t,
          () => closed && g.closes == g.opens,
          reason: 'retirement',
        );
        await t.runAsync(g.close);
        await t.pump();
      }
    });
  }
}
