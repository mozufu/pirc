import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_mobile/theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('XHR deadline remains authoritative across app suspension', (
    t,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requested = false, responded = false;
    final serving = server.listen((req) {
      unawaited(() async {
        requested = true;
        await Future<void>.delayed(const Duration(milliseconds: 1700));
        req.response.headers.contentType = ContentType.text;
        req.response.write('too late');
        await req.response.close();
        responded = true;
      }());
    });
    const source =
        '''<!doctype html><html><body><pre id="result">pending</pre><script>
 const xhr=new XMLHttpRequest();xhr.open('GET','/slow');xhr.timeout=1500;
 xhr.onload=()=>document.querySelector('#result').textContent='load';
 xhr.ontimeout=()=>document.querySelector('#result').textContent='timeout';xhr.send();
 </script></body></html>''';
    final bytes = Uint8List.fromList(utf8.encode(source));
    final document = NativeFetchedDocument(
      id: 1,
      url: 'http://127.0.0.1:${server.port}/fixture',
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
    String value() =>
        html
            .parse(document.scripts?.content?.text ?? '')
            .querySelector('#result')
            ?.text ??
        '';
    try {
      final theme = await PircTheme.load();
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: NativeFetchedDocumentView(
              document: document,
              gateway: Gateway(),
              onLink: (_) {},
              onSubmit: (_) {},
            ),
          ),
        ),
      );
      for (var i = 0; i < 300 && !requested; i++) {
        await t.pump(const Duration(milliseconds: 1));
      }
      expect(requested, true);
      expect(value(), 'pending');
      final scripts = document.scripts!;
      scripts.didChangeAppLifecycleState(AppLifecycleState.paused);
      await t.pump(const Duration(milliseconds: 2000));
      expect(responded, true);
      expect(value(), 'pending');
      scripts.didChangeAppLifecycleState(AppLifecycleState.resumed);
      for (var i = 0; i < 100 && value() == 'pending'; i++) {
        await t.pump(const Duration(milliseconds: 10));
      }
      expect(value(), 'timeout', reason: '${scripts.diagnostics}');
      expect(scripts.ready, true);
      expect(scripts.diagnostics, isEmpty);
      expect(t.takeException(), isNull);
      debugPrint('NATIVE_XHR_SUSPEND timeout PASS');
    } finally {
      await t.pumpWidget(const SizedBox());
      document.dispose();
      await t.pump();
      await serving.cancel();
      await server.close(force: true);
    }
  });
  testWidgets(
    'XHR completed within deadline remains successful after suspension',
    (t) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requested = false, responded = false;
      final serving = server.listen((req) {
        unawaited(() async {
          requested = true;
          await Future<void>.delayed(const Duration(milliseconds: 100));
          req.response.headers.contentType = ContentType.text;
          req.response.write('too late');
          await req.response.close();
          responded = true;
        }());
      });
      const source =
          '''<!doctype html><html><body><pre id="result">pending</pre><script>
 const xhr=new XMLHttpRequest();xhr.open('GET','/slow');xhr.timeout=1500;
 xhr.onload=()=>document.querySelector('#result').textContent='load';
 xhr.ontimeout=()=>document.querySelector('#result').textContent='timeout';xhr.send();
 </script></body></html>''';
      final bytes = Uint8List.fromList(utf8.encode(source));
      final document = NativeFetchedDocument(
        id: 1,
        url: 'http://127.0.0.1:${server.port}/fixture',
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
      String value() =>
          html
              .parse(document.scripts?.content?.text ?? '')
              .querySelector('#result')
              ?.text ??
          '';
      try {
        final theme = await PircTheme.load();
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Scaffold(
              body: NativeFetchedDocumentView(
                document: document,
                gateway: Gateway(),
                onLink: (_) {},
                onSubmit: (_) {},
              ),
            ),
          ),
        );
        for (var i = 0; i < 300 && !requested; i++) {
          await t.pump(const Duration(milliseconds: 1));
        }
        expect(requested, true);
        expect(value(), 'pending');
        final scripts = document.scripts!;
        scripts.didChangeAppLifecycleState(AppLifecycleState.paused);
        await t.pump(const Duration(milliseconds: 2000));
        expect(responded, true);
        expect(value(), 'pending');
        scripts.didChangeAppLifecycleState(AppLifecycleState.resumed);
        for (var i = 0; i < 100 && value() == 'pending'; i++) {
          await t.pump(const Duration(milliseconds: 10));
        }
        expect(value(), 'load', reason: '${scripts.diagnostics}');
        expect(scripts.ready, true);
        expect(scripts.diagnostics, isEmpty);
        expect(t.takeException(), isNull);
        debugPrint('NATIVE_XHR_SUSPEND early-load PASS');
      } finally {
        await t.pumpWidget(const SizedBox());
        document.dispose();
        await t.pump();
        await serving.cancel();
        await server.close(force: true);
      }
    },
  );
}
