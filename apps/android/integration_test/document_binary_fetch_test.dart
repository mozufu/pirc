import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_mobile/theme.dart';
import 'document_binary_fetch_fixture.dart';

class _PickedGateway extends Gateway {
  Uint8List selected = Uint8List(0);
  int picks = 0;
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'pickAttachments') {
      picks++;
      return [
        {
          'name': 'selected.bin',
          'mimeType': 'application/octet-stream',
          'bytes': selected,
        },
      ];
    }
    return super.call(method, args);
  }
}

// Independent parser for this controlled valid multipart corpus; the production
// runtime serializer and parser are not used to compute the expected receipt.
List<Json> _parts(List<int> body, String contentType) {
  final boundary = RegExp(
    r'boundary=(?:"([^"]+)"|([^;\s]+))',
  ).firstMatch(contentType);
  if (boundary == null) throw StateError('Missing multipart boundary');
  final result = <Json>[];
  for (var part
      in latin1.decode(body).split('--${boundary[1] ?? boundary[2]}').skip(1)) {
    if (part.startsWith('--')) break;
    if (!part.startsWith('\r\n') || !part.endsWith('\r\n')) {
      throw StateError('Invalid multipart framing');
    }
    part = part.substring(2, part.length - 2);
    final split = part.indexOf('\r\n\r\n');
    if (split < 0) throw StateError('Missing part headers');
    final headers = part.substring(0, split);
    final bytes = latin1.encode(part.substring(split + 4));
    final name = RegExp(
      r'(?:^|;)\s*name="([^"]*)"',
      caseSensitive: false,
    ).firstMatch(headers)?[1];
    final filename = RegExp(
      r'(?:^|;)\s*filename="([^"]*)"',
      caseSensitive: false,
    ).firstMatch(headers)?[1];
    String unicode(String value) => utf8.decode(latin1.encode(value));
    if (name == null) throw StateError('Missing part name');
    result.add({
      'name': unicode(name),
      if (filename == null) ...{
        'kind': 'text',
        'value': utf8.decode(bytes),
      } else ...{
        'kind': 'file',
        'filename': unicode(filename),
        'mimeType': RegExp(
          r'Content-Type:\s*([^\r\n]+)',
          caseSensitive: false,
        ).firstMatch(headers)?[1],
        'size': bytes.length,
        'base64': base64Encode(bytes),
      },
    });
  }
  return result;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native document Blob and FormData upload matches Chrome and reads selected bytes',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final receipts = <List<Json>>[];
      final rawBodies = <Uint8List>[];
      final failures = <Object>[];
      final listener = server.listen((request) async {
        try {
          if (request.method != 'POST' ||
              request.uri.path != binaryFetchUploadPath) {
            throw StateError(
              'Unexpected fixture request: ${request.method} ${request.uri.path}',
            );
          }
          final body = BytesBuilder();
          await for (final chunk in request) {
            body.add(chunk);
          }
          final bytes = body.takeBytes();
          rawBodies.add(bytes);
          receipts.add(
            _parts(bytes, request.headers.value('content-type') ?? ''),
          );
          request.response.headers.contentType = ContentType.json;
          request.response.write(binaryFetchResponseText);
          await request.response.close();
        } catch (error) {
          failures.add(error);
          request.response.statusCode = 500;
          await request.response.close();
        }
      });
      final gateway = _PickedGateway();
      final windows = NativeDocumentWindows(gateway);
      final documentWindow = windows.target(
        '',
        null,
        sourceUrl: '$origin/index.html',
      );
      final theme = await PircTheme.load();
      NativeFetchedDocument? document;
      Future<void> until(bool Function() condition, String label) async {
        for (var i = 0; i < 300 && !condition(); i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          condition(),
          isTrue,
          reason:
              '$label diagnostics=${document?.scripts?.diagnostics} content=${document?.scripts?.content?.text} failures=$failures',
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      }

      Future<void> mount(
        String source,
        Brightness brightness,
        double width,
        double scale,
      ) async {
        if (document != null) {
          final previous = document!;
          await tester.pumpWidget(const SizedBox());
          documentWindow.history.clear();
          previous.dispose();
          await previous.scripts?.closed;
        }
        final bytes = Uint8List.fromList(utf8.encode(source));
        document = NativeFetchedDocument(
          id: receipts.length + 1,
          url: '$origin/index.html',
          status: 200,
          bytes: bytes,
          mimeType: 'text/html',
          headers: {},
          content: NativeHtmlDocumentContent.fromBytes(
            bytes,
            mimeType: 'text/html',
            charset: 'utf-8',
          ),
        );
        documentWindow.history.add(
          NativeDocumentHistoryItem(document!.url, document!),
        );
        documentWindow.index = 0;
        windows.select(documentWindow);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 844);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme.build(brightness),
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: NativeDocumentScope(
                    windows: windows,
                    window: documentWindow,
                    documentUrl: document!.url,
                    child: NativeFetchedDocumentView(
                      key: ValueKey(document),
                      document: document!,
                      gateway: gateway,
                      onLink: (_) {},
                      onSubmit: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await until(
          () => document?.scripts?.ready == true,
          'Native isolate ready',
        );
      }

      Finder button(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is NativeHtmlButtonWidget && widget.button.label == label,
      );
      Future<void> tap(Finder target) async {
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        expect(target.hitTestable(), findsOneWidget);
        await tester.tap(target);
      }

      try {
        for (final width in [390.0, 860.0]) {
          for (final brightness in Brightness.values) {
            for (final scale in [1.0, 2.0]) {
              final count = receipts.length;
              await mount(binaryFetchHtml, brightness, width, scale);
              await tap(button('Send upload'));
              await until(
                () =>
                    document!.scripts!.content?.text.contains(
                      binaryFetchResponseText,
                    ) ==
                    true,
                'Native multipart/Blob response',
              );
              expect(receipts.length, count + 1);
              expect(receipts.last, binaryFetchExpectedWireEntries);
              expect(
                document!.scripts!.content?.text,
                isNot(contains('afterRequest')),
              );
              expect(
                find.text(binaryFetchResponseText, findRichText: true),
                findsOneWidget,
              );
              debugPrint(
                'BINARY_FETCH:chrome-wire-match:$width:${brightness.name}:$scale',
              );
            }
          }
        }
        // The picker boundary supplies synthetic bytes; all subsequent Flutter
        // control synchronization, native isolate and HTTP transport are real.
        gateway.selected = Uint8List.fromList(
          List.generate(1024 * 1024, (i) => i % 256),
        );
        const selectedHtml =
            r'''<form id="f"><input type="file" name="upload"><button>Upload selected</button></form><p id="result">WAITING</p><script>
        document.querySelector('#f').addEventListener('submit', async event => {
          event.preventDefault();
          try {
            const data = new FormData(event.target);
            const file = data.get('upload');
            const prefix = new Uint8Array(await file.slice(0,4).arrayBuffer());
            if (file.size !== 1048576 || prefix.join(',') !== '0,1,2,3') throw new Error('Selected bytes mismatch');
            const response = await fetch('./upload', {method: 'POST', body: data});
            document.querySelector('#result').textContent = response.ok ? 'SELECTED_BYTES_OK' : 'FAILED';
          } catch (error) { document.querySelector('#result').textContent = 'ERROR: '+error.message; }
        });</script>''';
        final count = receipts.length;
        await mount(selectedHtml, Brightness.light, 390, 1);
        await tap(find.byType(NativeHtmlFileInputWidget));
        await tester.pumpAndSettle();
        await tap(button('Upload selected'));
        await until(
          () =>
              document!.scripts!.content?.text.contains('SELECTED_BYTES_OK') ==
              true,
          'Selected file upload',
        );
        expect(gateway.picks, 1);
        expect(receipts.length, count + 1);
        final sent = receipts.last.single;
        expect(sent['size'], gateway.selected.length);
        expect(sent['filename'], 'selected.bin');
        final received = base64Decode(sent['base64'] as String);
        for (var i = 0; i < received.length; i++) {
          if (received[i] != i % 256) fail('Selected byte differs at $i');
        }
        expect(failures, isEmpty);
        debugPrint('BINARY_FETCH:1MiB-selected-file-exact-bytes-and-slice');
      } finally {
        tester.view.reset();
        await tester.pumpWidget(const SizedBox());
        windows.dispose();
        await document?.scripts?.closed;
        await listener.cancel();
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
