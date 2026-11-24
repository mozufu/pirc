import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'live_test.dart' show theme;

void main() {
  testWidgets(
    'only selected bytes enter scripts and oversized content stays explicit',
    (tester) async {
      final firstBytes = Uint8List.fromList([0, 128, 255, 13, 10]);
      final records = <List<Map<String, dynamic>>>[];
      final files = [
        NativeHtmlFile(
          name: '城市.bin',
          mimeType: 'application/octet-stream',
          bytes: firstBytes,
          lastModified: 123,
        ),
        NativeHtmlFile(
          name: 'large.bin',
          mimeType: 'application/octet-stream',
          bytes: Uint8List(2 * 1024 * 1024),
          lastModified: 456,
        ),
        NativeHtmlFile(
          name: 'empty.txt',
          mimeType: 'text/plain',
          bytes: const [],
          lastModified: 789,
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: NativeHtmlDocument(
                nodes: [
                  NativeHtmlRaw(
                    '<input type="file" multiple data-pirc-script-id="upload">',
                  ),
                ],
                style: const TextStyle(fontSize: 16),
                styles: MarkdownStyleSheet(),
                markdownStyles: false,
                builders: const {},
                filePicker: (_) async => files,
                onScriptEvent: (id, type, controls, {submitter}) async {
                  records.add(controls);
                  return false;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(records, isEmpty);
      await tester.tap(find.byType(NativeHtmlFileInputWidget));
      await tester.pumpAndSettle();
      expect(records.length, greaterThanOrEqualTo(2));
      final sent = (records.last.single['files'] as List)
          .cast<Map<String, dynamic>>();
      expect(sent[0]['bytesBase64'], base64Encode(firstBytes));
      expect(sent[0]['lastModified'], 123);
      expect(sent[1]['size'], 2 * 1024 * 1024);
      expect(sent[1].containsKey('bytesBase64'), isFalse);
      expect(sent[1]['contentError'], contains('2 MiB'));
      expect(sent[2]['bytesBase64'], '');
      expect(sent[2]['lastModified'], 789);
      firstBytes[0] = 33;
      expect(files.first.bytes.first, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
