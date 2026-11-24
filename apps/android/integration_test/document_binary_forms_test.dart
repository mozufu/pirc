import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_mobile/theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real Android multipart form preserves binary files through 307', (
    tester,
  ) async {
    expect(const bool.fromEnvironment('PIRC_REAL_GATEWAY'), isTrue);
    expect(const bool.fromEnvironment('PIRC_DOCUMENTS'), isTrue);
    final gateway = Gateway();
    await gateway.call('pair', {
      'link': const String.fromEnvironment('PIRC_PAIR_LINK'),
    });
    await gateway.call('completeOnboarding');
    final boot = obj(await gateway.call('boot'));
    final origin = boot['origin'] as String;
    final windows = NativeDocumentWindows(gateway);
    final window = windows.target('', null, sourceUrl: '$origin/source');
    final theme = (await PircTheme.load()).build(Brightness.light);
    NativeHtmlFormRequest? submitted;
    Future<NativeDocumentLoadResult>? pending;
    Future<List<Json>> receipts() async {
      final response = obj(
        await gateway.call('document', {
          'url': '$origin/parity-documents/receipt',
          'method': 'GET',
          'pairingStamp': boot['pairingStamp'],
        }),
      );
      expect(response['status'], 200);
      return rows(
        obj(
          jsonDecode(utf8.decode(response['bytes'] as Uint8List)),
        )['requests'],
      );
    }

    try {
      expect(
        await window.load(
          const NativeHtmlFormRequest(
            url: '/parity-documents/binary-echo',
            method: 'GET',
            target: '',
          ),
          baseUrl: '$origin/source',
        ),
        NativeDocumentLoadResult.committed,
      );
      final firstReceipt = (await receipts()).length;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: NativeHtmlDocument(
                nodes: [
                  NativeHtmlRaw(
                    '<form action="/parity-documents/binary-redirect307" method="post" enctype="multipart/form-data"><input name="before" value="城市\n台北"><input type="file" name="upload" required multiple><button name="go" value="send">Send</button><input name="after" value="A"></form>',
                  ),
                ],
                style: const TextStyle(fontSize: 15),
                styles: MarkdownStyleSheet.fromTheme(theme),
                builders: const {},
                filePicker: (request) async {
                  expect(request.multiple, isTrue);
                  return [
                    NativeHtmlFile(
                      name: '城市.bin',
                      mimeType: 'application/octet-stream',
                      bytes: [0, 127, 128, 255, 13, 10],
                    ),
                    NativeHtmlFile(
                      name: 'two.txt',
                      mimeType: 'text/plain',
                      bytes: [65, 0, 255, 66],
                    ),
                  ];
                },
                onFormSubmit: (form) {
                  submitted = form.buildRequest();
                  pending = window.load(submitted!, baseUrl: '$origin/source');
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(NativeHtmlFileInputWidget));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(NativeHtmlButtonWidget));
      await tester.pump();
      expect(pending, isNotNull);
      expect(await pending!, NativeDocumentLoadResult.committed);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(window.currentDocument!.content.title, 'Binary upload');
      final sent = submitted!;
      expect(sent.body, isNull);
      final received = (await receipts()).skip(firstReceipt).toList();
      expect(received, hasLength(2));
      expect(received.map((row) => row['path']), [
        '/parity-documents/binary-redirect307',
        '/parity-documents/binary-echo',
      ]);
      for (final row in received) {
        expect(row['method'], 'POST');
        expect(row['contentType'], sent.contentType);
        expect(
          base64Decode(row['bodyBase64'] as String),
          orderedEquals(sent.bodyBytes!),
        );
      }
      expect(
        window.currentDocument!.reloadRequest!.bodyBytes,
        orderedEquals(sent.bodyBytes!),
      );
      final countBeforeHistory = (await receipts())
          .where((row) => row['method'] == 'POST')
          .length;
      window.back();
      for (var i = 0; i < 100 && window.loading; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(window.loading, isFalse);
      expect(
        (await receipts()).where((row) => row['method'] == 'POST').length,
        countBeforeHistory,
        reason: 'History must never auto replay an upload',
      );

      for (final path in [
        '/api/devices',
        '/api/providers',
        '/api/provider-auth',
      ]) {
        final denied = obj(
          await gateway.call('document', {
            'method': 'GET',
            'url': '$origin$path',
            'pairingStamp': boot['pairingStamp'],
          }),
        );
        expect(denied['status'], 403, reason: path);
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      windows.dispose();
      await gateway.call('unpair');
    }
  });
}
