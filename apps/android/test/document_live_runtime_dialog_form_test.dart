import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
              'tool/parity/fixtures/document-dialog-form-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  final runtime = File('assets/document-script-runtime.js').readAsStringSync();
  for (final row in fixture['cases'] as List) {
    testWidgets(
      'native dialog form ${row['viewport']} ${row['theme']} dpr${row['dpr']}',
      (t) async {
        final g = (await t.runAsync(DocumentVmGateway.start))!
          ..responses.add({
            ...response('/test', fixture['html'] as String),
            'finalUrl': 'https://dialog.example/test',
          });
        final windows = NativeDocumentWindows(g),
            window = windows.target(
              'dialog',
              null,
              sourceUrl: 'https://dialog.example/',
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
        Widget page(int epoch) => RepaintBoundary(
          key: paintKey,
          child: MaterialApp(
            theme: theme.build(
              row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
            ),
            home: NativeDocumentWorkspace(
              key: ValueKey(epoch),
              windows: windows,
            ),
          ),
        );
        Finder button(String label) => find.byWidgetPredicate(
          (w) => w is NativeHtmlButtonWidget && w.button.label == label,
        );
        Finder dialog() => find.byWidgetPredicate(
          (w) =>
              w is NativeDocumentBox &&
              w.geometryOwner is dom.Element &&
              (w.geometryOwner as dom.Element).id == 'dialog',
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
                  doc.scripts!.hasPendingPublication == false &&
                  (expected['open'] == true
                      ? dialog().evaluate().length == 1
                      : dialog().evaluate().isEmpty);
              stable = ready ? stable + 1 : 0;
              return stable >= 3;
            },
            reason: name,
            diagnostic: () => doc.scripts!.diagnostics.toString(),
          );
          final result = await t.runAsync(
            () => g.inspect(
              "(()=>{const d=document.getElementById('dialog'),css=getComputedStyle(d);return {open:d.open,attribute:d.hasAttribute('open'),value:d.returnValue,draft:document.getElementById('required').value,events:events.splice(0),handler:window.handler||null,instance:d instanceof HTMLDialogElement,display:css.display,background:css.backgroundColor};})()",
            ),
          );
          final actual = Map<String, dynamic>.from(result as Map);
          final expectedEvents = expected['events'] as List;
          final actualEvents = actual.remove('events') as List;
          if (const {'accepted', 'skip', 'external'}.contains(name)) {
            expect(
              actualEvents.take(2).toList(),
              expectedEvents.take(2).toList(),
              reason: '$name synchronous events',
            );
            // Explicit scheduling difference: host timers emit toggle before
            // close; the captured Chromium pointer path emits close first.
            expect(actualEvents.skip(2).map((e) => e['type']).toList(), [
              'toggle',
              'close',
            ]);
            expect(expectedEvents.skip(2).map((e) => e['type']).toList(), [
              'close',
              'toggle',
            ]);
            expect(
              actualEvents.skip(2).toList(),
              unorderedEquals(expectedEvents.skip(2).toList()),
            );
          } else {
            expect(actualEvents, expectedEvents, reason: '$name events');
          }
          expect(actual, {
            for (final k in [
              'open',
              'attribute',
              'value',
              'draft',
              'handler',
              'instance',
              'display',
              'background',
            ])
              k: expected[k],
          }, reason: name);
          if (expected['rect'] != null) {
            final rect = t.getRect(dialog());
            for (var i = 0; i < 4; i++) {
              expect(
                [rect.left, rect.top - 48, rect.width, rect.height][i],
                closeTo((expected['rect'][i] as num).toDouble(), 1 / 32),
                reason: '$name rect$i',
              );
            }
            // Validation feedback has its own browser/native popup paint and
            // can cover this point. Its appearance is a listed visual boundary.
            if (name == 'invalid') return;
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
              final point = expected['point'] as List;
              final x = ((point[0] as num) * t.view.devicePixelRatio).floor(),
                  y = (((point[1] as num) + 48) * t.view.devicePixelRatio)
                      .floor(),
                  offset = (y * image.width + x) * 4;
              expect(
                [for (var c = 0; c < 4; c++) bytes.getUint8(offset + c)],
                expected['pixel'],
                reason: '$name dialog background',
              );
            } finally {
              image.dispose();
            }
          }
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
          await t.pumpWidget(page(0));
          await driveDocumentVm(t, () => doc.scripts!.ready, reason: 'ready');
          await compare('initial');
          await t.tap(button('Open'));
          await compare('open');
          await t.enterText(find.byType(EditableText), '草稿🙂');
          await t.tap(button('Accept'));
          // The real script/document survives complete removal while close tasks
          // and control publication are in flight.
          await t.pumpWidget(const SizedBox.shrink());
          await t.pump();
          await t.pumpWidget(page(1));
          await driveDocumentVm(
            t,
            () => find
                .text('Closed: yes', findRichText: true)
                .evaluate()
                .isNotEmpty,
            reason: 'accept close',
          );
          await compare('accepted');
          await t.tap(button('Open'));
          await driveDocumentVm(
            t,
            () => find.byType(EditableText).evaluate().length == 1,
            reason: 'reopen input',
          );
          await t.enterText(find.byType(EditableText), '');
          await t.tap(button('Accept'));
          await compare('invalid');
          await t.tap(button('Skip'));
          await driveDocumentVm(
            t,
            () => find
                .text('Closed: skip', findRichText: true)
                .evaluate()
                .isNotEmpty,
            reason: 'skip close',
          );
          await compare('skip');
          await t.tap(button('Open'));
          await driveDocumentVm(
            t,
            () => find.byType(EditableText).evaluate().length == 1,
            reason: 'reopen input',
          );
          await t.enterText(find.byType(EditableText), 'final');
          await t.tap(button('External'));
          await driveDocumentVm(
            t,
            () => find
                .text('Closed: external', findRichText: true)
                .evaluate()
                .isNotEmpty,
            reason: 'external close',
          );
          await compare('external');
          expect(
            g.requests,
            isEmpty,
            reason: 'dialog must not issue HTTP resources',
          );
          expect(g.opens, 1);
          expect(identical(window.currentDocument, doc), isTrue);
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
