import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'live_test.dart' show theme;

void main() {
  final fixture =
      jsonDecode(
            File(
              'tool/parity/fixtures/document-script-picker-lifetime-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final row in fixture['cases'] as List) {
    for (final sameFrame in [false, true]) {
      testWidgets(
        'script picker resumes ${row['viewport']['width']} ${row['theme']} dpr${row['dpr']} sameFrame=$sameFrame',
        (t) async {
          final dpr = (row['dpr'] as num).toDouble();
          t.view.devicePixelRatio = dpr;
          t.view.physicalSize =
              Size(
                (row['viewport']['width'] as num).toDouble(),
                (row['viewport']['height'] as num).toDouble(),
              ) *
              dpr;
          addTearDown(t.view.reset);
          final owner = Object(),
              selections = NativeHtmlScriptFileSelections(),
              pending = Completer<List<NativeHtmlFile>?>();
          final completions = <Map<String, dynamic>>[];
          var taken = false, picks = 0;
          final action = <String, dynamic>{
            'id': 1,
            'sequence': 1,
            'controlId': 'pirc-upload',
            'resetVersion': '0',
            'accept': '',
            'multiple': true,
          };
          Widget page(int epoch) => MaterialApp(
            theme: theme.build(
              row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
            ),
            home: Scaffold(
              body: NativeHtmlDocument(
                key: ValueKey(epoch),
                nodes: [
                  NativeHtmlRaw(
                    '<input type="file" name="upload" data-pirc-script-id="pirc-upload" data-pirc-file-reset-version="0" multiple>',
                  ),
                ],
                style: const TextStyle(fontSize: 16),
                styles: MarkdownStyleSheet(),
                builders: const {},
                markdownStyles: false,
                scriptDocument: owner,
                scriptFilePickerIsCurrent: () => true,
                scriptFileSelections: selections,
                scriptFilePickerActions: taken ? [] : [action],
                takeScriptFilePickerActions: (seq) {
                  if (taken) return [];
                  taken = true;
                  return [action];
                },
                onScriptFilePickerResult:
                    (id, {files, cancelled = false, error}) async {
                      completions.add({
                        'id': id,
                        'files': files,
                        'cancelled': cancelled,
                        'error': error,
                      });
                    },
                filePicker: (request) {
                  picks++;
                  return pending.future;
                },
                onScriptEvent: (id, type, controls, {submitter}) async => false,
              ),
            ),
          );
          await t.pumpWidget(page(0));
          await t.pumpAndSettle();
          expect(picks, 1);
          if (!sameFrame) {
            await t.pumpWidget(const SizedBox.shrink());
            await t.pumpAndSettle();
          }
          await t.pumpWidget(page(1));
          await t.pumpAndSettle();
          pending.complete([
            for (final f in fixture['pickedFiles'] as List)
              NativeHtmlFile(
                name: f['name'] as String,
                mimeType: f['type'] as String,
                bytes: List<int>.from(f['bytes'] as List),
              ),
          ]);
          await t.pumpAndSettle();
          expect(completions, hasLength(1));
          expect(picks, 1);
          final wire = completions.single['files'] as List;
          expect([
            for (final f in wire)
              {
                'name': f['name'],
                'type': f['type'],
                'bytes': base64Decode(f['bytesBase64'] as String).toList(),
              },
          ], row['resumed']['files']);
          // Re-entering the document projects the document-owned selected bytes.
          await t.pumpWidget(page(2));
          await t.pumpAndSettle();
          final upload = t.widget<NativeHtmlFileInputWidget>(
            find.byType(NativeHtmlFileInputWidget),
          );
          expect([
            for (final f in upload.state.filesFor(upload.control.key)) f.name,
          ], row['resumed']['formNames']);
          await t.pumpWidget(const SizedBox.shrink());
          selections.clear();
          expect(t.takeException(), isNull);
        },
      );
    }
  }
}
