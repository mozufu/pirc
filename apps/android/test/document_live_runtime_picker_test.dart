import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'document_navigation_widget_test.dart' show response;
import 'live_test.dart' show theme;
import 'support/document_vm_gateway.dart';

void main() {
  final runtime = File('assets/document-script-runtime.js').readAsStringSync();
  final fixture =
      jsonDecode(
            File(
              'tool/parity/fixtures/document-script-picker-lifetime-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final row in fixture['cases'] as List) {
    testWidgets(
      'real runtime script picker ${row['viewport']['width']} ${row['theme']} dpr${row['dpr']}',
      (t) async {
        final g = (await t.runAsync(DocumentVmGateway.start))!
          ..picker = Completer<dynamic>()
          ..responses.add(response('/picker', fixture['html'] as String));
        final windows = NativeDocumentWindows(g),
            window = windows.target(
              'picker',
              null,
              sourceUrl: 'https://picker.example/',
            );
        await window.load(
          const NativeHtmlFormRequest(
            url: '/picker',
            method: 'GET',
            target: '',
          ),
          baseUrl: window.sourceUrl,
        );
        windows.select(window);
        final document = window.currentDocument!;
        document.scripts = NativeDocumentScripts(
          g,
          loadRuntime: () async => runtime,
        );
        Widget page(int epoch) => MaterialApp(
          theme: theme.build(
            row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
          ),
          home: NativeDocumentWorkspace(key: ValueKey(epoch), windows: windows),
        );
        Finder button(String text) => find.byWidgetPredicate(
          (w) => w is NativeHtmlButtonWidget && w.button.label == text,
        );
        Future<void> compare(Map expected) async {
          var stable = 0;
          await driveDocumentVm(t, () {
            stable = document.scripts?.hasPendingPublication == false
                ? stable + 1
                : 0;
            return stable >= 3;
          }, reason: 'picker publication');
          // This asynchronous probe only reads small inline file bytes; it adds no
          // DOM state and does not synthesize events or geometry.
          await t.runAsync(
            () => g.inspect(
              '(()=>{window.__fixtureRead=null;(async()=>{const upload=document.getElementById("upload");const files=await Promise.all(Array.from(upload.files,async f=>({name:f.name,type:f.type,bytes:Array.from(new Uint8Array(await f.arrayBuffer()))})));return {boots:window.boots,events:window.events,files,formNames:Array.from(new FormData(document.getElementById("form")).values(),f=>f.name)};})().then(value=>window.__fixtureRead=value);return null;})()',
            ),
          );
          final actual = await t.runAsync(
            () => g.inspect('window.__fixtureRead'),
          );
          expect(actual, expected);
          final input = t.widget<NativeHtmlFileInputWidget>(
            find.byType(NativeHtmlFileInputWidget),
          );
          final files = input.state.filesFor(input.control.key);
          expect([
            for (final f in files)
              {'name': f.name, 'type': f.mimeType, 'bytes': f.bytes.toList()},
          ], expected['files']);
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
            reason: 'picker startup',
          );
          await compare(row['initial'] as Map);
          await t.tap(button('Choose files'));
          await driveDocumentVm(
            t,
            () => g.pickerCalls == 1,
            reason: 'script chooser request',
          );
          await t.pumpWidget(const SizedBox.shrink());
          await t.pump();
          g.picker!.complete([
            for (final file in fixture['pickedFiles'] as List)
              {
                'name': file['name'],
                'mimeType': file['type'],
                'bytes': base64Encode(List<int>.from(file['bytes'] as List)),
              },
          ]);
          // Allow the chooser result and its real input/change handlers to run while
          // the same document has no Flutter view, then restore that document.
          for (var i = 0; i < 8; i++) {
            await t.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 3)),
            );
            await t.pump();
          }
          await t.pumpWidget(page(1));
          await compare(row['resumed'] as Map);
          await t.tap(button('Reset'));
          await compare(row['reset'] as Map);
          expect(g.opens, 1);
          expect(g.pickerCalls, 1);
          expect(t.takeException(), isNull);
        } finally {
          await t.pumpWidget(const SizedBox.shrink());
          final scripts = document.scripts;
          windows.dispose();
          var closed = false;
          (scripts?.closed ?? Future<void>.value()).then((_) => closed = true);
          await driveDocumentVm(
            t,
            () => closed && g.closes == g.opens,
            reason: 'picker retirement',
          );
          await t.runAsync(g.close);
          await t.pump();
        }
      },
    );
  }
}
