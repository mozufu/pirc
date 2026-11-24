import 'dart:async';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_form_submission.dart';

import 'document_navigation_widget_test.dart' show DocumentGateway, response;
import 'live_test.dart' show theme;

class _DelayedGateway extends DocumentGateway {
  Completer<Json>? pending;
  @override
  Future<dynamic> call(String method, [Json args = const {}]) {
    if (method == 'documentPrepareRequest') {
      return Future.value({
        'nativeCookieRequestKey':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      });
    }
    if (method == 'document' && pending != null) return pending!.future;
    return super.call(method, args);
  }
}

const _shell =
    '<!doctype html><html><head>'
    '<meta name="description" content="A calm command surface for persistent coding-agent sessions.">'
    '<meta name="apple-mobile-web-app-title" content="pirc"><title>pirc</title>'
    '</head><body><div id="app"></div><script type="module" src="/src/main.ts"></script></body></html>';

void main() {
  testWidgets(
    'late document response commits in background without stealing selection',
    (t) async {
      final gateway = _DelayedGateway()
        ..responses.add(
          response('/existing', '<title>Existing document</title>'),
        );
      final windows = NativeDocumentWindows(gateway);
      final host = GlobalKey<NativeDocumentHostState>();
      final existing = windows.target(
        'existing',
        null,
        sourceUrl: 'https://gateway.example/',
      );
      await existing.load(
        const NativeHtmlFormRequest(
          url: '/existing',
          method: 'GET',
          target: '',
        ),
        baseUrl: 'https://gateway.example/',
      );
      late BuildContext sourceContext;
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: NativeDocumentScope(
            windows: windows,
            documentUrl: 'https://gateway.example/',
            sourceIdentity: windows.accountIdentity,
            child: NativeDocumentHost(
              key: host,
              windows: windows,
              child: Builder(
                builder: (context) {
                  sourceContext = context;
                  return const Scaffold(body: Text('Source'));
                },
              ),
            ),
          ),
        ),
      );
      gateway.pending = Completer<Json>();
      NativeDocumentWindow? requested;
      final loading = openNativeDocument(
        sourceContext,
        NativeDocumentScope.maybeOf(sourceContext)!,
        const NativeHtmlFormRequest(
          url: '/late',
          method: 'GET',
          target: '_blank',
        ),
        onStarted: (window) => requested = window,
      );
      await t.pump();
      await host.currentState!.selectWindow(existing);
      await t.pumpAndSettle();
      gateway.pending!.complete(
        response('/late', '<title>Late document</title>'),
      );
      await loading;
      await t.pumpAndSettle();
      expect(requested!.currentDocument!.url, 'https://gateway.example/late');
      expect(windows.active, same(existing));
      expect(find.text('Existing document'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      windows.dispose();
    },
  );
  for (final retry in [false, true]) {
    testWidgets(
      'late ${retry ? 'retry' : 'reload'} App response cannot steal selection',
      (t) async {
        final gateway = _DelayedGateway()
          ..responses.addAll([
            response('/primary', '<title>Primary</title>'),
            response('/other', '<title>Other</title>'),
          ]);
        var appRoutes = 0;
        final windows = NativeDocumentWindows(
          gateway,
          onAppRoute: (_) async {
            appRoutes++;
          },
        );
        final primary = windows.target(
          '',
          null,
          sourceUrl: 'https://gateway.example/',
        );
        await primary.load(
          const NativeHtmlFormRequest(
            url: '/primary',
            method: 'GET',
            target: '',
          ),
          baseUrl: 'https://gateway.example/',
        );
        final other = windows.target(
          'other',
          primary,
          sourceUrl: primary.current!.url,
        );
        await other.load(
          const NativeHtmlFormRequest(url: '/other', method: 'GET', target: ''),
          baseUrl: 'https://gateway.example/',
        );
        final host = GlobalKey<NativeDocumentHostState>();
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: NativeDocumentHost(
              key: host,
              windows: windows,
              child: const Scaffold(body: Text('App')),
            ),
          ),
        );
        await host.currentState!.selectWindow(primary);
        await t.pumpAndSettle();
        if (retry) {
          gateway.pending = Completer<Json>();
          final failed = primary.load(
            const NativeHtmlFormRequest(
              url: '/failed',
              method: 'GET',
              target: '',
            ),
            baseUrl: 'https://gateway.example/',
          );
          await t.pump();
          gateway.pending!.completeError(
            PlatformException(code: 'offline', message: 'Disconnected'),
          );
          await failed;
          await t.pumpAndSettle();
        }
        gateway.pending = Completer<Json>();
        await t.tap(retry ? find.text("Retry") : find.byTooltip("Reload"));
        await t.pump();
        await host.currentState!.selectWindow(other);
        await t.pumpAndSettle();
        gateway.pending!.complete(response('/?session=late', _shell));
        for (var i = 0; i < 10 && primary.loading; i++) {
          await t.pump();
        }
        await t.pumpAndSettle();
        expect(primary.currentAppRoute, isNotNull);
        expect(windows.active, same(other));
        expect(appRoutes, 0);
        expect(find.text('Other'), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        windows.dispose();
      },
    );
  }
}
