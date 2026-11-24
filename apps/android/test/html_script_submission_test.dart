import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as md;
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/html_script_submission.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'live_test.dart' show theme;

void main() {
  test(
    'captured repeated names and native file bytes use existing form encoder',
    () {
      final file = NativeHtmlFile(
        name: 'note.txt',
        mimeType: 'text/plain',
        bytes: [65, 66, 67],
      );
      final request = decodeScriptFormSubmission(
        {
          'action': '/saved',
          'method': 'post',
          'enctype': 'multipart/form-data',
          'target': 'result',
          'targetSpecified': true,
          'submitterId': 'save',
          'entries': [
            {'name': 'tag', 'value': 'one'},
            {'name': 'tag', 'value': 'two'},
            {
              'name': 'file',
              'file': {'controlId': 'upload', 'resetVersion': 0, 'index': 0},
            },
            {'name': 'empty', 'file': null},
          ],
        },
        resolveFile: (id, version, index) {
          expect((id, version, index), ('upload', '0', 0));
          return file;
        },
      );
      expect(request.entries.map((e) => e.name), [
        'tag',
        'tag',
        'file',
        'empty',
      ]);
      expect(request.entries[2].file!.bytes, [65, 66, 67]);
      expect(request.target, 'result');
      expect(request.buildRequest().method, 'POST');
      expect(request.entries.last.isFile, true);
    },
  );

  test(
    'an unresolved selected file fails instead of silently sending empty bytes',
    () {
      expect(
        () => decodeScriptFormSubmission({
          'entries': [
            {
              'name': 'file',
              'file': {'controlId': 'old', 'resetVersion': '1', 'index': 0},
            },
          ],
        }, resolveFile: (_, _, _) => null),
        throwsFormatException,
      );
    },
  );

  testWidgets('a stale painted command is revalidated before submission', (
    t,
  ) async {
    final submitted = <NativeHtmlFormSubmission>[];
    final taken = <List<int>>[];
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: NativeHtmlDocument(
            nodes: [NativeHtmlRaw('<p>Old painted document</p>')],
            style: const TextStyle(fontSize: 16),
            styles: md.MarkdownStyleSheet(),
            builders: const {},
            markdownStyles: false,
            scriptFormActions: [
              {
                'kind': 'submit',
                'sequence': 1,
                'formId': 'form',
                'entries': [],
              },
            ],
            takeScriptFormActions: (ids) {
              taken.add(ids);
              return [];
            },
            onFormSubmit: submitted.add,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(taken, [
      [1],
    ]);
    expect(submitted, isEmpty);
  });

  testWidgets(
    'captured file survives a later script reset in the same snapshot',
    (t) async {
      final submitted = <NativeHtmlFormSubmission>[];
      final owner = Object();
      final file = NativeHtmlFile(
        name: 'upload.txt',
        mimeType: 'text/plain',
        bytes: [65, 66, 67],
      );
      Widget page(
        int version,
        List<Map<String, dynamic>> actions,
      ) => MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: NativeHtmlDocument(
            nodes: [
              NativeHtmlRaw(
                '<input type="file" name="upload" data-pirc-script-id="upload" data-pirc-file-reset-version="$version">',
              ),
            ],
            style: const TextStyle(fontSize: 16),
            styles: md.MarkdownStyleSheet(),
            builders: const {},
            markdownStyles: false,
            scriptDocument: owner,
            scriptSnapshot: version,
            scriptFormActions: actions,
            onScriptFormActionsConsumed: (_) {},
            filePicker: (_) async => [file],
            onFormSubmit: submitted.add,
          ),
        ),
      );
      await t.pumpWidget(page(0, []));
      await t.pumpAndSettle();
      await t.tap(find.byType(NativeHtmlFileInputWidget));
      await t.pumpAndSettle();
      await t.pumpWidget(
        page(1, [
          {
            'sequence': 1,
            'kind': 'submit',
            'formId': 'form',
            'method': 'post',
            'enctype': 'multipart/form-data',
            'entries': [
              {
                'name': 'upload',
                'file': {'controlId': 'upload', 'resetVersion': 0, 'index': 0},
              },
            ],
          },
        ]),
      );
      await t.pumpAndSettle();
      expect(submitted.single.entries.single.file!.bytes, [65, 66, 67]);
      final input = t.widget<NativeHtmlFileInputWidget>(
        find.byType(NativeHtmlFileInputWidget),
      );
      expect(input.state.filesFor(input.control.key), isEmpty);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'implicit Enter delegates validation and submit to the ready runtime',
    (t) async {
      final events = <String>[];
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: NativeHtmlDocument(
              nodes: [
                NativeHtmlRaw(
                  '<form data-pirc-script-id="form"><input required data-pirc-script-id="field"></form>',
                ),
              ],
              style: const TextStyle(fontSize: 16),
              styles: md.MarkdownStyleSheet(),
              builders: const {},
              markdownStyles: false,
              scriptDocument: Object(),
              onScriptControlClick: (_, _) async => false,
              onScriptFormActionsConsumed: (_) {},
              onScriptEvent: (id, type, controls, {submitter}) async {
                events.add('$id:$type:$submitter');
                expect(controls.single, {
                  'id': 'field',
                  'value': '',
                  'userEdited': false,
                  'badInput': false,
                });
                return true;
              },
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byType(EditableText));
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(events, contains('form:requestSubmit:null'));
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'script submission uses captured values and cannot replay on rebuild',
    (t) async {
      final submitted = <NativeHtmlFormSubmission>[];
      final consumed = <int>[];
      final owner = Object();
      final actions = <Map<String, dynamic>>[
        {
          'sequence': 1,
          'kind': 'submit',
          'formId': 'form',
          'action': '/saved',
          'entries': [
            {'name': 'q', 'value': 'captured'},
          ],
        },
      ];
      Widget page(String value) => MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: NativeHtmlDocument(
            nodes: [
              NativeHtmlRaw('<form><input name="q" value="$value"></form>'),
            ],
            style: const TextStyle(fontSize: 16),
            styles: md.MarkdownStyleSheet(),
            builders: const {},
            markdownStyles: false,
            scriptDocument: owner,
            scriptFormActions: actions,
            onScriptFormActionsConsumed: consumed.addAll,
            onFormSubmit: submitted.add,
          ),
        ),
      );
      await t.pumpWidget(page('after call'));
      await t.pumpAndSettle();
      expect(submitted.single.entries.single.value, 'captured');
      await t.pumpWidget(page('another rebuild'));
      await t.pumpAndSettle();
      expect(submitted, hasLength(1));
      expect(consumed, [1]);
      expect(t.takeException(), isNull);
    },
  );

  test('inline files preserve literal names, metadata, and exact bytes', () {
    final payload = <int>[0x00, 0x7f, 0x80, 0xff, 0x41, 0x00, 0x5a];
    final request = decodeScriptFormSubmission({
      'method': 'post',
      'enctype': 'multipart/form-data',
      'entries': [
        {
          'name': 'upload',
          'inlineFile': {
            'name': '資料/報告.bin',
            'type': 'application/x-report',
            'lastModified': 123456789,
            'bytesBase64': base64Encode(payload),
          },
        },
      ],
    }, resolveFile: (_, _, _) => null);

    final file = request.entries.single.file!;
    expect(file.name, '資料/報告.bin');
    expect(file.mimeType, 'application/x-report');
    expect(file.lastModified, 123456789);
    expect(file.bytes, payload);

    final body = request.buildRequest().bodyBytes!;
    expect(
      utf8.decode(body, allowMalformed: true),
      contains('filename="資料/報告.bin"'),
    );
    var hasPayload = false;
    for (var start = 0; start <= body.length - payload.length; start++) {
      var matches = true;
      for (var offset = 0; offset < payload.length; offset++) {
        if (body[start + offset] != payload[offset]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        hasPayload = true;
        break;
      }
    }
    expect(hasPayload, isTrue);
  });

  test('native file metadata overrides preserve the resolved bytes', () {
    final original = NativeHtmlFile(
      name: 'picked.bin',
      mimeType: 'application/octet-stream',
      lastModified: 10,
      bytes: [0x00, 0x80, 0xff, 0x42],
    );
    final request = decodeScriptFormSubmission(
      {
        'entries': [
          {
            'name': 'upload',
            'file': {
              'controlId': 'upload',
              'resetVersion': '4',
              'index': 0,
              'name': r'folder\renamed-資料.bin',
              'type': 'application/x-renamed',
              'lastModified': 987654321,
            },
          },
        ],
      },
      resolveFile: (id, version, index) {
        expect((id, version, index), ('upload', '4', 0));
        return original;
      },
    );

    final renamed = request.entries.single.file!;
    expect(renamed.name, r'folder\renamed-資料.bin');
    expect(renamed.mimeType, 'application/x-renamed');
    expect(renamed.lastModified, 987654321);
    expect(renamed.bytes, [0x00, 0x80, 0xff, 0x42]);
    expect(original.name, 'picked.bin');
    expect(original.mimeType, 'application/octet-stream');
    expect(original.lastModified, 10);
    expect(original.bytes, [0x00, 0x80, 0xff, 0x42]);
  });

  test(
    'large native references stay native and are not subject to inline limit',
    () {
      const inlineLimit = 2 * 1024 * 1024;
      final largeFile = NativeHtmlFile(
        name: 'large.bin',
        mimeType: 'application/octet-stream',
        bytes: List<int>.filled(inlineLimit + 1, 0x42),
        lastModified: 1,
      );
      final request = decodeScriptFormSubmission({
        'entries': [
          {
            'name': 'upload',
            'file': {'controlId': 'upload', 'resetVersion': '1', 'index': 0},
          },
        ],
      }, resolveFile: (_, _, _) => largeFile);

      expect(identical(request.entries.single.file, largeFile), isTrue);
      expect(request.entries.single.file!.length, inlineLimit + 1);
    },
  );

  test('inline file size is bounded per file and across the submission', () {
    const inlineLimit = 2 * 1024 * 1024;
    final tooLargeBase64 = 'A' * (((inlineLimit + 2) ~/ 3) * 4);
    expect(
      () => decodeScriptFormSubmission({
        'entries': [
          {
            'name': 'large',
            'inlineFile': {
              'name': 'large.bin',
              'type': 'application/octet-stream',
              'lastModified': 1,
              'bytesBase64': tooLargeBase64,
            },
          },
        ],
      }, resolveFile: (_, _, _) => null),
      throwsFormatException,
    );

    final atLimitBase64 = base64Encode(List<int>.filled(inlineLimit, 0));
    final accepted = decodeScriptFormSubmission({
      'entries': [
        {
          'name': 'exact-limit',
          'inlineFile': {
            'name': 'exact-limit.bin',
            'type': 'application/octet-stream',
            'lastModified': 1,
            'bytesBase64': atLimitBase64,
          },
        },
      ],
    }, resolveFile: (_, _, _) => null);
    expect(accepted.entries.single.file!.length, inlineLimit);
    expect(
      () => decodeScriptFormSubmission({
        'entries': [
          {
            'name': 'first',
            'inlineFile': {
              'name': 'first.bin',
              'type': 'application/octet-stream',
              'lastModified': 1,
              'bytesBase64': atLimitBase64,
            },
          },
          {
            'name': 'second',
            'inlineFile': {
              'name': 'second.bin',
              'type': 'application/octet-stream',
              'lastModified': 2,
              'bytesBase64': 'AA==',
            },
          },
        ],
      }, resolveFile: (_, _, _) => null),
      throwsFormatException,
    );
  });

  test('inline files reject malformed base64 and invalid metadata types', () {
    for (final inlineFile in [
      {
        'name': 'broken.bin',
        'type': 'application/octet-stream',
        'lastModified': 1,
        'bytesBase64': '%%%!',
      },
      {
        'name': 7,
        'type': 'application/octet-stream',
        'lastModified': 1,
        'bytesBase64': '',
      },
      {'name': 'broken.bin', 'type': 7, 'lastModified': 1, 'bytesBase64': ''},
      {
        'name': 'broken.bin',
        'type': 'application/octet-stream',
        'lastModified': '1',
        'bytesBase64': '',
      },
    ]) {
      expect(
        () => decodeScriptFormSubmission({
          'entries': [
            {'name': 'upload', 'inlineFile': inlineFile},
          ],
        }, resolveFile: (_, _, _) => null),
        throwsFormatException,
      );
    }
  });

  test('form entries cannot mix text, native file, or inline file forms', () {
    for (final entry in [
      {'name': 'mixed', 'value': 'text', 'file': null},
      {'name': 'mixed', 'value': 'text', 'inlineFile': <String, Object>{}},
      {'name': 'mixed', 'file': null, 'inlineFile': <String, Object>{}},
      {'name': 'path-only', 'path': '/private/file.txt'},
    ]) {
      expect(
        () => decodeScriptFormSubmission({
          'entries': [entry],
        }, resolveFile: (_, _, _) => null),
        throwsFormatException,
      );
    }
  });
  test(
    'a script-authored submission cannot select a non-standard encoding',
    () {
      for (final enctype in ['application/json', 'text/html', 'x/y', '']) {
        for (final method in ['put', 'delete', 'post', 'get', 'PATCH']) {
          final request = decodeScriptFormSubmission({
            'action': '/api/x',
            'method': method,
            'enctype': enctype,
            'target': '',
            'entries': [
              {'name': 'a', 'value': '1'},
            ],
          }, resolveFile: (_, _, _) => null).buildRequest();
          expect(['GET', 'POST'], contains(request.method));
          if (request.method == 'POST') {
            expect({
              'application/x-www-form-urlencoded',
              'text/plain',
              'multipart/form-data',
            }, contains(request.contentType!.split(';').first));
          }
        }
      }
    },
  );
}
