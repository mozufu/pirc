import 'dart:convert';
import 'dart:io';
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
              '../../packages/pirc_render/test/fixtures/parity/document-dialog-request-close-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  final runtime = File('assets/document-script-runtime.js').readAsStringSync();
  for (final row in fixture['profiles'] as List) {
    testWidgets(
      'native dialog requestClose ${row['viewport']} ${row['theme']} dpr${row['dpr']}',
      (t) async {
        final g = (await t.runAsync(DocumentVmGateway.start))!
          ..responses.add({
            ...response('/test', fixture['html'] as String),
            'finalUrl': 'https://dialog-request.example/test',
          });
        final windows = NativeDocumentWindows(g),
            window = windows.target(
              'dialog-request',
              null,
              sourceUrl: 'https://dialog-request.example/',
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
                  !doc.scripts!.hasPendingPublication &&
                  (expected['open'] == true
                      ? dialog().evaluate().length == 1
                      : dialog().evaluate().isEmpty);
              stable = ready ? stable + 1 : 0;
              return stable >= 4;
            },
            reason: name,
            diagnostic: () => doc.scripts!.diagnostics.toString(),
          );
          final actual = Map<String, dynamic>.from(
            (await t.runAsync(
                  () => g.inspect(
                    "(()=>{const d=document.getElementById('dialog');return {open:d.open,value:d.returnValue,draft:document.getElementById('draft').value,active:document.activeElement?.id||document.activeElement?.localName||null,notes:notes.splice(0),events:events.splice(0)}})()",
                  ),
                ))
                as Map,
          );
          final events = actual.remove('events') as List,
              expectedEvents = expected['events'] as List;
          if (const {'closed', 'forced'}.contains(name)) {
            // Existing task-source difference is explicit, not normalized away:
            // pointer-driven Chromium close precedes toggle; native timers do not.
            final prefix = name == 'closed'
                ? ['cancel', 'beforetoggle']
                : ['beforetoggle'];
            expect(events.map((e) => e['type']).toList(), [
              ...prefix,
              'toggle',
              'close',
            ]);
            expect(expectedEvents.map((e) => e['type']).toList(), [
              ...prefix,
              'close',
              'toggle',
            ]);
            expect(
              events,
              unorderedEquals(expectedEvents),
              reason: '$name event payloads',
            );
          } else {
            expect(
              events,
              expectedEvents,
              reason: '$name event order and payload',
            );
          }
          expect(actual, {
            for (final k in ['open', 'value', 'draft', 'active', 'notes'])
              k: expected[k],
          }, reason: name);
          final active = expected['active'];
          if (active == 'draft') {
            expect(
              t
                  .widget<EditableText>(find.byType(EditableText))
                  .focusNode
                  .hasPrimaryFocus,
              isTrue,
              reason: '$name native input focus',
            );
          } else if (active != 'body') {
            final label = {
              'open': 'Open',
              'request': 'Request close',
              'allow': 'Allow close',
              'force': 'Force close',
            }[active]!;
            final w = t.widget<NativeHtmlButtonWidget>(button(label));
            expect(
              w.state.focusNodeFor(w.button.key).hasPrimaryFocus,
              isTrue,
              reason: '$name native button focus',
            );
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
          await t.pumpWidget(
            MaterialApp(
              theme: theme.build(
                row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
              ),
              home: NativeDocumentWorkspace(windows: windows),
            ),
          );
          await driveDocumentVm(t, () => doc.scripts!.ready, reason: 'ready');
          await compare('initial');
          await t.tap(button('Open'));
          await compare('open');
          await t.enterText(find.byType(EditableText), '草稿🙂');
          await t.pump(const Duration(milliseconds: 500));
          await t.tap(button('Request close'));
          await compare('blocked');
          await t.tap(button('Allow close'));
          await compare('allowed');
          await t.tap(button('Request close'));
          await compare('closed');
          await t.tap(button('Open'));
          await compare('reopen');
          await t.tap(button('Force close'));
          await compare('forced');
          expect(g.requests, isEmpty);
          expect(g.opens, 1);
          expect(identical(window.currentDocument, doc), isTrue);
          expect(
            doc.scripts!.diagnostics.where((d) => d.contains('error')),
            isEmpty,
          );
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
