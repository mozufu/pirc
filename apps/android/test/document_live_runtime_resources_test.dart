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
  // Read the shipped bundle once as text, then create a fresh async loader in
  // each widget clock. AssetBundle's cached Future belongs to the prior test's
  // FakeAsync zone and is unsuitable for crossing separate widget clocks.
  final runtime = File('assets/document-script-runtime.js').readAsStringSync();
  final fixture =
      jsonDecode(
            File(
              '../../packages/pirc_render/test/fixtures/parity/document-live-resources-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final row in fixture['cases'] as List) {
    for (final sameFrame in [false, true]) {
      testWidgets(
        'real runtime resources ${row['viewport']['width']} ${row['theme']} dpr${row['dpr']} sameFrame=$sameFrame',
        (t) async {
          final gateway = (await t.runAsync(DocumentVmGateway.start))!
            ..responses.add(response('/test', fixture['html'] as String));
          final windows = NativeDocumentWindows(gateway),
              window = windows.target(
                'resource',
                null,
                sourceUrl: 'https://resources.example/',
              );
          await window.load(
            const NativeHtmlFormRequest(
              url: '/test',
              method: 'GET',
              target: '',
            ),
            baseUrl: window.sourceUrl,
          );
          windows.select(window);
          final document = window.currentDocument!;
          document.scripts = NativeDocumentScripts(
            gateway,
            loadRuntime: () async => runtime,
          );
          Widget page(int epoch) => MaterialApp(
            theme: theme.build(
              row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
            ),
            home: NativeDocumentWorkspace(
              key: ValueKey(epoch),
              windows: windows,
            ),
          );
          final panel = find.byWidgetPredicate(
            (w) =>
                w is NativeDocumentBox &&
                w.geometryOwner is dom.Element &&
                (w.geometryOwner as dom.Element).id == 'panel',
          );
          Finder button(String label) => find.byWidgetPredicate(
            (w) => w is NativeHtmlButtonWidget && w.button.label == label,
          );
          Future<void> compare(String phase) async {
            final expected = row[phase] as Map;
            // Require a matching native frame before reading the runtime's live CSSOM.
            var stable = 0;
            await driveDocumentVm(t, () {
              final ready =
                  panel.evaluate().length == 1 &&
                  (t.getSize(panel).height - (expected['rect'][3] as num))
                          .abs() <
                      1 / 32 &&
                  document.scripts?.hasPendingPublication == false;
              stable = ready ? stable + 1 : 0;
              return stable >= 3;
            }, reason: '$phase native publication');
            final actual = await t.runAsync(
              () => gateway.inspect(
                '({probe:window.probe,value:document.getElementById("draft").value,background:getComputedStyle(document.getElementById("panel")).backgroundColor})',
              ),
            );
            expect(actual, {
              'probe': expected['probe'],
              'value': expected['value'],
              'background': expected['background'],
            }, reason: '$phase production runtime');
            expect(
              t.widget<EditableText>(find.byType(EditableText)).controller.text,
              expected['value'],
              reason: '$phase native editor',
            );
            final rect = t.getRect(panel), reference = expected['rect'] as List;
            for (var i = 0; i < 4; i++) {
              expect(
                [rect.left, rect.top - 48, rect.width, rect.height][i],
                closeTo((reference[i] as num).toDouble(), 1 / 32),
                reason: '$phase native rect axis$i',
              );
            }
          }

          Future<void> replaceView(int epoch) async {
            if (!sameFrame) {
              await t.pumpWidget(const SizedBox.shrink());
              await t.pump();
            }
            await t.pumpWidget(page(epoch));
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
            await driveDocumentVm(
              t,
              () => document.scripts?.ready == true,
              reason: 'script startup',
              diagnostic: () =>
                  'opens=${gateway.opens} loading=${document.scripts?.loading} ready=${document.scripts?.ready} issues=${document.scripts?.diagnostics} stderr=${gateway.stderr}',
            );
            await compare('initial');
            await t.tap(button('Load data'));
            await driveDocumentVm(
              t,
              () => gateway.resources.length == 1,
              reason: 'fetch request',
            );
            await compare('loading');
            final requestId = gateway.resources.keys.single;
            if (!sameFrame) {
              await t.pumpWidget(const SizedBox.shrink());
              await t.pump();
            }
            gateway.respond(requestId, jsonEncode(fixture['payload']));
            if (!sameFrame) {
              // Completions are buffered while a document has no view. This
              // differs from CSS-hiding a browser page, which can run callbacks.
              for (var i = 0; i < 3; i++) {
                await t.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 3)),
                );
                await t.pump();
              }
              expect(
                await t.runAsync(() => gateway.inspect('window.probe.phase')),
                'loading',
              );
            }
            await t.pumpWidget(page(1));
            await driveDocumentVm(
              t,
              () =>
                  find.text('Loaded', findRichText: true).evaluate().isNotEmpty,
              reason: 'loaded response after remount',
            );
            await compare('resumed');
            await t.tap(button('Load script'));
            await driveDocumentVm(
              t,
              () => gateway.resources.length == 2,
              reason: 'external script request',
            );
            final scriptId = gateway.resources.keys.last;
            expect(gateway.requests[scriptId]!['kind'], 'script');
            await replaceView(2);
            gateway.respond(scriptId, fixture['extraScript'] as String);
            await driveDocumentVm(
              t,
              () => find
                  .text('Extended', findRichText: true)
                  .evaluate()
                  .isNotEmpty,
              reason: 'external classic script after remount',
            );
            await compare('extended');
            await t.tap(button('Load data'));
            await driveDocumentVm(
              t,
              () => gateway.resources.length == 3,
              reason: 'second fetch request',
            );
            await t.tap(button('Cancel load'));
            await driveDocumentVm(
              t,
              () =>
                  find
                      .text('cancelled', findRichText: true)
                      .evaluate()
                      .isNotEmpty &&
                  gateway.cancellations.length == 1,
              reason: 'abort response',
            );
            await compare('cancelled');
            expect(gateway.opens, 1);
            expect(
              gateway.requests.values.map(
                (r) => Uri.parse(r['url'] as String).path,
              ),
              ['/payload', '/extra.js', '/payload'],
            );
            expect(t.takeException(), isNull);
          } finally {
            await t.pumpWidget(const SizedBox.shrink());
            final scripts = document.scripts;
            windows.dispose();
            var closed = false;
            (scripts?.closed ?? Future<void>.value()).then(
              (_) => closed = true,
            );
            await driveDocumentVm(
              t,
              () => closed && gateway.closes == gateway.opens,
              reason: 'script retirement',
            );
            await t.runAsync(gateway.close);
            await t.pump();
          }
        },
      );
    }
  }
}
