import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_download.dart';
import 'package:pirc_render/src/document_object_urls.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_mobile/live/gateway.dart';

const _largeExport = r'''<!doctype html><html><body>
<button id="export">Export bounded bytes</button>
<script>
document.getElementById('export').onclick = function() {
  const bytes = new Uint8Array(2 * 1024 * 1024);
  for (let i = 0; i < bytes.length; i++) bytes[i] = i % 251;
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([bytes], {type:'application/octet-stream'}));
  a.download = 'bounded-export.bin';
  a.click();
  URL.revokeObjectURL(a.href);
};
</script></body></html>''';

const _asyncExport = r'''<!doctype html><html><body>
<button id="export">Fetch and export</button>
<script>
document.getElementById('export').onclick = async function() {
  const response = await fetch('/export.csv');
  const blob = await response.blob();
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = '非同步.csv';
  a.target = '_blank';
  a.click();
  URL.revokeObjectURL(a.href);
};
</script></body></html>''';

String _exportId(NativeDocumentScripts scripts) => html
    .parse(scripts.content!.text)
    .querySelector('#export')!
    .attributes['data-pirc-script-id']!;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native isolate captures a full 2 MiB Blob export before revoke',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final scripts = NativeDocumentScripts(Gateway());
      try {
        await scripts.start(
          source: _largeExport,
          url: 'https://example.test/budget',
        );
        expect(scripts.ready, isTrue, reason: '${scripts.diagnostics}');
        await scripts.click(_exportId(scripts), const []);
        expect(scripts.ready, isTrue, reason: '${scripts.diagnostics}');
        expect(scripts.diagnostics, isEmpty);
        expect(scripts.navigationActions, hasLength(1));
        final action = scripts.navigationActions.single;
        expect(action['kind'], 'anchor');
        expect(action['download'], 'bounded-export.bin');
        final blob = NativeDocumentBlob.fromBridge(
          action['url'] as String,
          obj(action['capturedBlob']),
        );
        final bytes = blob.bytes;
        expect(bytes.length, 2 * 1024 * 1024);
        for (var i = 0; i < bytes.length; i++) {
          if (bytes[i] != i % 251) fail('Export byte differs at $i');
        }
        expect(
          (await scripts.readObjectURL(action['url'] as String))['ok'],
          false,
        );
        debugPrintSynchronously(
          'NATIVE_ANCHOR_BUDGET ${jsonEncode({'bytes': bytes.length, 'name': action['download'], 'mimeType': blob.mimeType, 'allPatternBytesMatch': true, 'revoked': true, 'diagnostics': scripts.diagnostics})}',
        );
      } finally {
        scripts.dispose();
        await scripts.closed;
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'native HTTP fetch can finish before an async Blob download activation',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bytes = utf8.encode('欄位,數值\n雪,42\n');
      final requests = <Map<String, Object?>>[];
      final failures = <Object>[];
      final listener = server.listen((request) async {
        try {
          requests.add({
            'method': request.method,
            'path': request.uri.path,
            'referer': request.headers.value('referer'),
          });
          if (request.method == 'GET' && request.uri.path == '/export.csv') {
            request.response.headers.contentType = ContentType(
              'text',
              'csv',
              charset: 'utf-8',
            );
            request.response.add(bytes);
          } else {
            failures.add(
              StateError(
                'Unexpected fixture request ${request.method} ${request.uri}',
              ),
            );
            request.response.statusCode = HttpStatus.notFound;
          }
          await request.response.close();
        } catch (error) {
          failures.add(error);
        }
      });
      final scripts = NativeDocumentScripts(Gateway());
      try {
        final origin = 'http://127.0.0.1:${server.port}';
        await scripts.start(source: _asyncExport, url: '$origin/document');
        expect(scripts.ready, isTrue, reason: '${scripts.diagnostics}');
        await scripts.click(_exportId(scripts), const []);
        for (var i = 0; i < 400 && scripts.navigationActions.isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(
          scripts.navigationActions,
          hasLength(1),
          reason: '${scripts.diagnostics}',
        );
        expect(scripts.diagnostics, isEmpty);
        expect(failures, isEmpty);
        final action = scripts.navigationActions.single;
        final blob = NativeDocumentBlob.fromBridge(
          action['url'] as String,
          obj(action['capturedBlob']),
        );
        expect(blob.bytes, bytes);
        expect(action['download'], '非同步.csv');
        expect(action['target'], '_self');
        final download = NativeDocumentDownload(
          bytes: blob.bytes,
          name: action['download'] as String,
          mimeType: blob.mimeType,
        );
        expect(download.mimeType, 'text/csv');
        expect(
          (await scripts.readObjectURL(action['url'] as String))['ok'],
          false,
        );
        expect(requests, [
          {
            'method': 'GET',
            'path': '/export.csv',
            'referer': '$origin/document',
          },
        ]);
        debugPrintSynchronously(
          'NATIVE_ANCHOR_ASYNC ${jsonEncode({'bytes': bytes, 'name': download.name, 'mimeType': download.mimeType, 'target': action['target'], 'requests': requests, 'revoked': true})}',
        );
      } finally {
        scripts.dispose();
        await scripts.closed;
        await listener.cancel();
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
