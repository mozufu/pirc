import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_box.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'document_navigation_widget_test.dart' show response;
import 'live_test.dart' show theme;
import 'support/document_vm_gateway.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../packages/pirc_render/test/fixtures/parity/document-dialog-layout-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  final runtime = File('assets/document-script-runtime.js').readAsStringSync();
  for (final row in fixture['cases'] as List) {
    testWidgets(
      'native default dialog ${row['viewport']} ${row['theme']} dpr${row['dpr']}',
      (t) async {
        final g = (await t.runAsync(DocumentVmGateway.start))!
          ..responses.add({
            ...response('/test', fixture['html'] as String),
            'finalUrl': 'https://dialog-layout.example/test',
          });
        final windows = NativeDocumentWindows(g),
            window = windows.target(
              'layout',
              null,
              sourceUrl: 'https://dialog-layout.example/',
            );
        await window.load(
          const NativeHtmlFormRequest(url: '/test', method: 'GET', target: ''),
          baseUrl: window.sourceUrl,
        );
        windows.select(window);
        final doc = window.currentDocument!;
        doc.scripts = NativeDocumentScripts(
          g,
          loadRuntime: () async => runtime,
        );
        final paintKey = GlobalKey();
        Finder box(String id) => find.byWidgetPredicate(
          (w) =>
              w is NativeDocumentBox &&
              w.geometryOwner is dom.Element &&
              (w.geometryOwner as dom.Element).id == id,
        );
        Finder button(String label) => find.byWidgetPredicate(
          (w) => w is NativeHtmlButtonWidget && w.button.label == label,
        );
        Future<void> compare(String name) async {
          final expected =
              (row['steps'] as List).singleWhere(
                    (s) => s['name'] == name,
                  )['value']
                  as Map;
          var stable = 0;
          await driveDocumentVm(
            t,
            () {
              final ready =
                  !doc.scripts!.hasPendingPublication &&
                  (expected['open'] == true
                      ? box('dialog').evaluate().length == 1
                      : box('dialog').evaluate().isEmpty);
              stable = ready ? stable + 1 : 0;
              return stable >= 4;
            },
            reason: name,
            diagnostic: () => doc.scripts!.diagnostics.toString(),
          );
          final actual = await t.runAsync(
            () => g.inspect(
              "(()=>{const d=document.getElementById('dialog'),s=getComputedStyle(d);return {open:d.open,css:Object.fromEntries(['display','position','left','right','top','bottom','padding-top','border-top-width','border-top-style','border-top-color','color','background-color','box-sizing'].map(k=>[k,s.getPropertyValue(k)]))}})()",
            ),
          );
          expect((actual as Map)['open'], expected['open']);
          expect(
            actual['css'],
            expected['css'],
            reason: '$name computed style',
          );
          if (expected['rect'] != null) {
            final r = t.getRect(box('dialog'));
            for (var i = 0; i < 4; i++) {
              expect(
                [r.left, r.top - 48, r.width, r.height][i],
                closeTo((expected['rect'][i] as num).toDouble(), 1 / 32),
                reason: '$name rect$i',
              );
            }
          }
          if (expected['points'] != null) {
            final image = (await t.runAsync(
              () => t
                  .renderObject<RenderRepaintBoundary>(find.byKey(paintKey))
                  .toImage(pixelRatio: t.view.devicePixelRatio),
            ))!;
            try {
              final bytes = (await t.runAsync(
                () => image.toByteData(
                  format: ui.ImageByteFormat.rawStraightRgba,
                ),
              ))!;
              final points = expected['points'] as List;
              for (var i = 0; i < points.length; i++) {
                final p = points[i] as List;
                final x = ((p[0] as num) * t.view.devicePixelRatio).floor(),
                    y = (((p[1] as num) + 48) * t.view.devicePixelRatio)
                        .floor(),
                    offset = (y * image.width + x) * 4;
                expect(
                  [for (var c = 0; c < 4; c++) bytes.getUint8(offset + c)],
                  expected['pixels'][i],
                  reason: '$name border/padding/content pixel$i',
                );
              }
            } finally {
              image.dispose();
            }
          }
          expect(
            t.getTopLeft(box('after')).dy - 48,
            expected['after'][0],
            reason: '$name flow after',
          );
          expect(
            t.getTopLeft(button('Close')).dy - 48,
            expected['after'][1],
            reason: '$name flow close',
          );
        }

        try {
          t.view.devicePixelRatio = (row['dpr'] as num).toDouble();
          t.view.physicalSize =
              Size(
                (row['viewport']['width'] as num).toDouble(),
                (row['viewport']['height'] as num).toDouble() + 48,
              ) *
              t.view.devicePixelRatio;
          addTearDown(t.view.reset);
          await t.pumpWidget(
            RepaintBoundary(
              key: paintKey,
              child: MaterialApp(
                theme: theme.build(
                  row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
                ),
                home: NativeDocumentWorkspace(windows: windows),
              ),
            ),
          );
          await driveDocumentVm(t, () => doc.scripts!.ready, reason: 'ready');
          await compare('closed');
          await t.tap(button('Open'));
          await compare('open');
          await t.tap(button('Close'));
          await compare('close');
          await t.tap(button('Open'));
          await compare('reopen');
          await t.tap(button('Tint'));
          await compare('author-color');
          expect(g.requests, isEmpty);
          expect(g.opens, 1);
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
            reason: 'retire',
          );
          await t.runAsync(g.close);
          await t.pump();
        }
      },
    );
  }
}
