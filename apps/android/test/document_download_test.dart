import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_download.dart';
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_urls.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'live_test.dart' show theme;
import 'native_html_test.dart' show tapText;

class DownloadGateway extends Gateway {
  final saves = <Json>[];
  final external = <Json>[];
  final documents = <Json>[];
  final replies = <Json>[];
  Completer<dynamic>? pendingSave;
  bool cancel = false;
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'documentPrepareRequest') {
      return {
        'nativeCookieRequestKey':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      };
    }
    switch (method) {
      case 'external':
        external.add(args);
        return null;
      case 'boot':
        return {'origin': 'https://gateway.example', 'pairingStamp': 'stamp'};
      case 'resolveDocumentUrl':
        return resolveNativeDocumentUrl(args['reference'], args['baseUrl']);
      case 'document':
        documents.add(args);
        return replies.removeAt(0);
      case 'saveDocument':
        saves.add(args);
        return pendingSave?.future ??
            (cancel
                ? null
                : {
                    'name': args['name'],
                    'bytesWritten': (args['bytes'] as Uint8List).length,
                  });
      default:
        throw StateError('Unexpected call $method');
    }
  }
}

Json reply(
  String path,
  String source, {
  Json headers = const {},
  String method = 'GET',
  String mime = 'text/html',
}) => {
  'status': 200,
  'finalUrl': 'https://gateway.example$path',
  'finalMethod': method,
  'mimeType': mime,
  'charset': 'UTF-8',
  'bytes': Uint8List.fromList(utf8.encode(source)),
  'headersRelevant': headers,
};
NativeHtmlFormRequest request(String url, {String method = 'GET'}) =>
    NativeHtmlFormRequest(
      url: url,
      method: method,
      target: '',
      body: method == 'POST' ? 'exact=body' : null,
    );
void main() {
  test(
    'response headers are case-insensitive and UTF8 filenames take precedence',
    () {
      final headers = {
        'Content-Disposition':
            "attachment; filename=plain.csv; filename*=UTF-8''%E6%B8%AC%E8%A9%A6.csv",
      };
      expect(documentIsAttachment(headers), isTrue);
      expect(
        documentDownloadName('https://site/a', headers, hint: 'hint.csv'),
        '測試.csv',
      );
      expect(
        documentDownloadName('https://site/a', {
          'content-disposition': 'attachment; filename="../../report.csv"',
        }),
        'report.csv',
      );
      expect(documentDownloadName('', const {}, hint: '../\u0000'), 'download');
    },
  );
  test(
    'Blob MIME parameters become a concrete native save MIME without changing bytes',
    () async {
      final gateway = DownloadGateway();
      final bytes = Uint8List.fromList(utf8.encode('雪,export\n'));
      final download = NativeDocumentDownload(
        bytes: bytes,
        name: 'export.csv',
        mimeType: 'TEXT/CSV; charset=utf-8',
      );
      expect(await download.save(gateway, 'stamp'), isTrue);
      expect(gateway.saves.single['mimeType'], 'text/csv');
      expect(gateway.saves.single['bytes'], bytes);
      expect(gateway.saves.single['name'], 'export.csv');
      expect(gateway.saves.single['pairingStamp'], 'stamp');
    },
  );

  test('data URI downloads preserve exact bytes and MIME', () {
    final d = NativeDocumentDownload.dataUri(
      'data:text/csv;base64,YSxiCjEsMgo=',
      hint: 'table.csv',
    );
    expect(d.bytes, utf8.encode('a,b\n1,2\n'));
    expect(d.mimeType, 'text/csv');
    expect(d.name, 'table.csv');
  });
  for (final cancel in [false, true]) {
    test(
      'POST attachment saves exact response once and retains original history (cancel=$cancel)',
      () async {
        final g = DownloadGateway()
          ..cancel = cancel
          ..replies.addAll([
            reply('/form', '<form><input value="kept"></form>'),
            reply(
              '/export',
              'a,b\n1,2\n',
              method: 'POST',
              mime: 'text/csv',
              headers: {
                'Content-Disposition': 'attachment; filename=report.csv',
              },
            ),
          ]);
        final windows = NativeDocumentWindows(g);
        addTearDown(windows.dispose);
        final w = windows.target(
          '',
          null,
          sourceUrl: 'https://gateway.example/source',
        );
        await w.load(request('/form'), baseUrl: 'https://gateway.example/');
        final source = w.current;
        expect(
          await w.load(
            request('/export', method: 'POST'),
            baseUrl: source!.url,
          ),
          NativeDocumentLoadResult.retained,
        );
        expect(w.current, same(source));
        expect(w.history, hasLength(1));
        expect(g.documents, hasLength(2));
        expect(g.saves, hasLength(1));
        expect(g.saves.single['bytes'], utf8.encode('a,b\n1,2\n'));
        expect(g.saves.single['name'], 'report.csv');
        expect(g.saves.single['pairingStamp'], 'stamp');
      },
    );
  }
  testWidgets(
    'relative download link saves and retains source controls without navigating',
    (t) async {
      final g = DownloadGateway()
        ..replies.addAll([
          reply(
            '/source',
            '<input value="kept"><a href="/file" download="local.csv">Download report</a>',
          ),
          reply('/file', 'one,two\n', mime: 'text/csv'),
        ]);
      final windows = NativeDocumentWindows(g);
      final w = windows.target(
        '',
        null,
        sourceUrl: 'https://gateway.example/source',
      );
      await w.load(request('/source'), baseUrl: 'https://gateway.example/');
      final source = w.current;
      windows.select(w);
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: NativeDocumentWorkspace(windows: windows, managed: true),
        ),
      );
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'edited value');
      await tapText(t, 'Download report');
      await t.pumpAndSettle();
      expect(g.saves, hasLength(1));
      expect(g.saves.single['name'], 'local.csv');
      expect(g.saves.single['bytes'], utf8.encode('one,two\n'));
      expect(w.current, same(source));
      expect(w.history, hasLength(1));
      expect(
        t.widget<TextField>(find.byType(TextField)).controller!.text,
        'edited value',
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is RichText && w.text.toPlainText().contains('Download report'),
        ),
        findsOneWidget,
      );
      await t.pumpWidget(const SizedBox());
      windows.dispose();
    },
  );
  for (final inTable in [false, true]) {
    testWidgets(
      'inline HTML download preserves response bytes (table=$inTable)',
      (t) async {
        final g = DownloadGateway()
          ..replies.add(reply('/inline.csv', 'a,b\n1,2\n', mime: 'text/csv'));
        const anchor =
            '<a href="https://gateway.example/inline.csv" download="inline.csv">Save CSV</a>';
        final source = inTable ? '| File |\n| --- |\n| $anchor |' : anchor;
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Scaffold(body: RichTextBody(source, gateway: g)),
          ),
        );
        await t.pumpAndSettle();
        await tapText(t, 'Save CSV');
        await t.pumpAndSettle();
        expect(g.saves, hasLength(1));
        expect(g.documents, hasLength(1));
        expect(g.saves.single['bytes'], utf8.encode('a,b\n1,2\n'));
        expect(g.saves.single['name'], 'inline.csv');
        expect(g.saves.single['mimeType'], 'text/csv');
      },
    );
  }
  testWidgets(
    'cross-origin and mailto download attributes preserve external actions',
    (t) async {
      final g = DownloadGateway();
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: RichTextBody(
              '<a href="https://outside.example/file.csv" download>Outside</a> '
              '<a href="mailto:hello@example.invalid" download>Mail</a>',
              gateway: g,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await tapText(t, 'Outside');
      await tapText(t, 'Mail');
      expect(g.external.map((r) => r['url']), [
        'https://outside.example/file.csv',
        'mailto:hello@example.invalid',
      ]);
      expect(g.saves, isEmpty);
      expect(g.documents, isEmpty);
    },
  );
  test(
    'disposal during pending save cannot commit a downloaded page',
    () async {
      final g = DownloadGateway()
        ..pendingSave = Completer<dynamic>()
        ..replies.add(
          reply(
            '/file',
            'binary',
            headers: {'content-disposition': 'attachment'},
          ),
        );
      final windows = NativeDocumentWindows(g);
      final w = windows.target(
        '',
        null,
        sourceUrl: 'https://gateway.example/source',
      );
      final pending = w.load(
        request('/file'),
        baseUrl: 'https://gateway.example/',
      );
      for (var i = 0; i < 20 && g.saves.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(g.saves, hasLength(1));
      windows.dispose();
      g.pendingSave!.complete(null);
      expect(await pending, NativeDocumentLoadResult.stale);
      expect(w.history, isEmpty);
    },
  );
}
