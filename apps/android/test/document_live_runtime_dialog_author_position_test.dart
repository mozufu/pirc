import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_render/src/html_document_box.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_form_submission.dart';

import 'document_navigation_widget_test.dart' show response;
import 'live_test.dart' show theme;
import 'support/document_vm_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('sans-serif')..addFont(
          File(
            'tool/parity/vendor/canvas-text-fixture-font/Roboto-Regular.ttf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });
  final fixture =
      jsonDecode(
            File(
              '../../packages/pirc_render/test/fixtures/parity/document-dialog-author-position-chromium153.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final runtime = File('assets/document-script-runtime.js').readAsStringSync();
  for (final entry in fixture['cases'] as List) {
    final row = entry as Map<String, dynamic>;
    final viewport = row['viewport'] as Map<String, dynamic>;
    final expected =
        (row['result'] as Map<String, dynamic>)['rect'] as Map<String, dynamic>;
    final expectedPosition =
        (row['result'] as Map<String, dynamic>)['position'] as String;
    testWidgets('modal author position ${row['name']} ${viewport['width']}', (
      t,
    ) async {
      final body =
          '''<meta name="viewport" content="width=device-width,initial-scale=1">
<div style="${row['parentStyle'] ?? ''}"><dialog id="dialog" style="${row['dialogStyle']}"><button onclick="window.insideClicks=(window.insideClicks||0)+1">Inside</button></dialog></div>
<script>document.getElementById('dialog').showModal()</script>''';
      final html = row['rootless'] == true
          ? '<!doctype html>$body'
          : row['omitBody'] == true
          ? '<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>${body.replaceFirst(RegExp(r'^<meta[^>]*>'), '')}</html>'
          : '<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head><body>${body.replaceFirst(RegExp(r'^<meta[^>]*>'), '')}</body></html>';
      final gateway = (await t.runAsync(DocumentVmGateway.start))!
        ..responses.add({
          ...response('/test', html),
          'finalUrl': 'https://dialog-position.example/test',
        });
      final windows = NativeDocumentWindows(gateway);
      final window = windows.target(
        'position',
        null,
        sourceUrl: 'https://dialog-position.example/',
      );
      await window.load(
        const NativeHtmlFormRequest(url: '/test', method: 'GET', target: ''),
        baseUrl: window.sourceUrl,
      );
      windows.select(window);
      final doc = window.currentDocument!;
      doc.scripts = NativeDocumentScripts(
        gateway,
        loadRuntime: () async => runtime,
      );
      final dialog = find.byWidgetPredicate(
        (widget) =>
            widget is NativeDocumentBox &&
            widget.geometryOwner is dom.Element &&
            (widget.geometryOwner as dom.Element).id == 'dialog',
      );
      t.view.physicalSize = Size(
        (viewport['width'] as num).toDouble(),
        (viewport['height'] as num).toDouble() + 48,
      );
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      try {
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: NativeDocumentWorkspace(windows: windows),
          ),
        );
        var stable = 0;
        await driveDocumentVm(
          t,
          () {
            final settled =
                doc.scripts!.ready &&
                !doc.scripts!.hasPendingPublication &&
                dialog.evaluate().length == 1;
            stable = settled ? stable + 1 : 0;
            return stable >= 4;
          },
          reason: 'modal author position ${row['name']}',
          diagnostic: () => doc.scripts!.diagnostics.toString(),
        );
        final rect = t.getRect(dialog);
        expect(
          await t.runAsync(
            () => gateway.inspect(
              "getComputedStyle(document.getElementById('dialog')).position",
            ),
          ),
          expectedPosition,
          reason: row['name'] as String,
        );
        expect(
          rect.left,
          closeTo((expected['x'] as num).toDouble(), 2),
          reason: row['name'] as String,
        );
        expect(
          rect.top - 48,
          closeTo((expected['y'] as num).toDouble(), 2),
          reason: row['name'] as String,
        );
        expect(
          rect.width,
          closeTo((expected['width'] as num).toDouble(), 2),
          reason: row['name'] as String,
        );
        expect(
          rect.height,
          closeTo((expected['height'] as num).toDouble(), 2),
          reason: row['name'] as String,
        );
        await t.tap(
          find.byWidgetPredicate(
            (widget) =>
                widget is NativeHtmlButtonWidget &&
                widget.button.label == 'Inside',
          ),
        );
        await driveDocumentVm(
          t,
          () => !doc.scripts!.hasPendingPublication,
          reason: 'modal button dispatch ${row['name']}',
        );
        expect(
          await t.runAsync(() => gateway.inspect('window.insideClicks')),
          1,
          reason: 'native hit target follows dialog geometry ${row['name']}',
        );
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        final scripts = doc.scripts;
        windows.dispose();
        var closed = false;
        (scripts?.closed ?? Future<void>.value()).then((_) => closed = true);
        await driveDocumentVm(
          t,
          () => closed && gateway.closes == gateway.opens,
          reason: 'retire',
        );
        await t.runAsync(gateway.close);
        await t.pump();
      }
    });
  }
}
