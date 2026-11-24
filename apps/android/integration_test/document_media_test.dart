import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_environment.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_form_submission.dart';

const _page = r'''<!doctype html><html><body>
<pre id="state"></pre>
<script>
window.__queries = {
  wide: matchMedia('(min-width: 600px)'),
  tall: matchMedia('(min-height: 600px)'),
  landscape: matchMedia('(orientation: landscape)'),
  dark: matchMedia('(prefers-color-scheme: dark)'),
  motion: matchMedia('(prefers-reduced-motion: reduce)'),
  dpr2: matchMedia('(resolution: 2dppx)')
};
window.__records = [];
function currentState() {
  const matches = {};
  Object.keys(window.__queries).forEach(key => matches[key] = window.__queries[key].matches);
  return {
    width: window.innerWidth,
    height: window.innerHeight,
    screenWidth: screen.width,
    screenHeight: screen.height,
    devicePixelRatio: window.devicePixelRatio,
    matches: matches
  };
}
function renderState() {
  document.querySelector('#state').textContent = JSON.stringify({
    current: currentState(),
    records: window.__records
  });
}
Object.keys(window.__queries).forEach(key => {
  const query = window.__queries[key];
  query.addEventListener('change', event => {
    window.__records.push({
      kind: 'mql',
      id: key,
      media: event.media,
      matches: event.matches,
      state: currentState()
    });
    renderState();
  });
});
window.onresize = event => {
  window.__records.push({
    kind: 'resize',
    trusted: event.isTrusted,
    state: currentState()
  });
  renderState();
};
renderState();
</script></body></html>''';

Map<String, dynamic> _readState(NativeDocumentScripts scripts) {
  final markup = scripts.content?.text;
  if (markup == null) throw StateError('The native document has no snapshot.');
  final encoded = html.parse(markup).querySelector('#state')?.text;
  if (encoded == null || encoded.isEmpty) {
    throw StateError('The media state has not been rendered yet.');
  }
  return Map<String, dynamic>.from(jsonDecode(encoded) as Map);
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String description,
) async {
  for (var index = 0; index < 250 && !ready(); index++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue, reason: description);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native document media queries publish atomic viewport and preference updates',
    (tester) async {
      await tester.pumpWidget(const SizedBox());
      final pairingServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final documentServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final pairingOrigin = 'http://127.0.0.1:${pairingServer.port}';
      // The separate loopback port gives the document a distinct origin.
      final documentOrigin = 'http://127.0.0.1:${documentServer.port}';
      final token = 'pirc_dev_${'M' * 43}';
      final pairingErrors = <String>[];
      final documentRequests = <Map<String, Object?>>[];
      final pairingListener = pairingServer.listen((request) async {
        if (request.uri.path != '/api/sessions') {
          pairingErrors.add('Unexpected pairing request ${request.uri.path}.');
          request.response.statusCode = HttpStatus.notFound;
        } else if (request.headers.value(HttpHeaders.authorizationHeader) !=
            'Bearer $token') {
          pairingErrors.add(
            'Pairing API did not receive the synthetic bearer.',
          );
          request.response.statusCode = HttpStatus.unauthorized;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"sessions":[]}');
        await request.response.close();
      });
      final documentListener = documentServer.listen((request) async {
        documentRequests.add({
          'method': request.method,
          'path': request.uri.path,
          'authorizationPresent':
              request.headers.value(HttpHeaders.authorizationHeader) != null,
          'cookiePresent':
              request.headers.value(HttpHeaders.cookieHeader) != null,
        });
        request.response.headers.contentType = ContentType.html;
        request.response.headers.set(
          HttpHeaders.cacheControlHeader,
          'no-store',
        );
        if (request.uri.path == '/media') {
          request.response.write(_page);
        } else {
          request.response.statusCode = HttpStatus.notFound;
          request.response.write('not found');
        }
        await request.response.close();
      });

      final gateway = Gateway();
      final windows = NativeDocumentWindows(gateway);
      NativeDocumentWindow? window;
      NativeDocumentScripts? scripts;
      try {
        await gateway.call('pair', {
          'link': Uri(
            scheme: 'pirc',
            host: 'pair',
            queryParameters: {'url': pairingOrigin, 'token': token},
          ).toString(),
        });
        final boot = obj(await gateway.call('boot'));
        expect(boot['documentStylesheets'], true);

        window = windows.target('', null, sourceUrl: '$documentOrigin/source');
        final loaded = await window.load(
          NativeHtmlFormRequest(
            url: '$documentOrigin/media',
            method: 'GET',
            target: '',
          ),
          baseUrl: documentOrigin,
        );
        expect(
          loaded,
          NativeDocumentLoadResult.committed,
          reason: window.error,
        );
        expect(window.currentDocument, isNotNull);
        final document = window.currentDocument!;
        scripts = NativeDocumentScripts(gateway);
        document.scripts = scripts;

        const initialEnvironment = NativeDocumentEnvironment(
          width: 390,
          height: 844,
          devicePixelRatio: 1,
          dark: false,
          reducedMotion: false,
          pointer: 'coarse',
          hover: 'none',
          screenWidth: 390,
          screenHeight: 844,
        );
        // Set the environment before the runtime's first init snapshot.
        await scripts.updateEnvironment(initialEnvironment);
        await windows.startDocumentScripts(document, scripts);
        expect(scripts.ready, isTrue, reason: scripts.diagnostics.join(';'));

        final initial = _readState(scripts);
        expect(initial['current'], {
          'width': 390,
          'height': 844,
          'screenWidth': 390,
          'screenHeight': 844,
          'devicePixelRatio': 1,
          'matches': {
            'wide': false,
            'tall': true,
            'landscape': false,
            'dark': false,
            'motion': false,
            'dpr2': false,
          },
        });
        expect(initial['records'], isEmpty);

        scripts.setActivity(attached: false, visible: false);
        await scripts.updateEnvironment(
          const NativeDocumentEnvironment(
            width: 640,
            height: 700,
            devicePixelRatio: 1.5,
            dark: true,
            reducedMotion: false,
            pointer: 'coarse',
            hover: 'none',
            screenWidth: 640,
            screenHeight: 700,
          ),
        );
        const rotatedEnvironment = NativeDocumentEnvironment(
          width: 768,
          height: 390,
          devicePixelRatio: 2,
          dark: true,
          reducedMotion: true,
          pointer: 'coarse',
          hover: 'none',
          screenWidth: 768,
          screenHeight: 390,
        );
        await scripts.updateEnvironment(rotatedEnvironment);
        // Detached documents retain only the latest environment and have no
        // script-visible events until they resume.
        expect(_readState(scripts), initial);

        scripts.setActivity(attached: true, visible: true);
        await _until(
          tester,
          () =>
              _readState(scripts!)['current']['width'] == 768 &&
              (_readState(scripts)['records'] as List).length == 7,
          'one final environment update after resume',
        );
        final updated = _readState(scripts);
        final finalCurrent = updated['current'] as Map;
        expect(finalCurrent, {
          'width': 768,
          'height': 390,
          'screenWidth': 768,
          'screenHeight': 390,
          'devicePixelRatio': 2,
          'matches': {
            'wide': true,
            'tall': false,
            'landscape': true,
            'dark': true,
            'motion': true,
            'dpr2': true,
          },
        });
        final records = (updated['records'] as List)
            .map((record) => Map<String, dynamic>.from(record as Map))
            .toList();
        final mediaRecords = records
            .where((record) => record['kind'] == 'mql')
            .toList();
        expect(mediaRecords.map((record) => record['id']).toSet(), {
          'wide',
          'tall',
          'landscape',
          'dark',
          'motion',
          'dpr2',
        });
        expect(mediaRecords, hasLength(6));
        for (final record in records) {
          // Every listener sees the same completed environment and all updated
          // match values, even when its own MQL was dispatched first.
          expect(record['state'], finalCurrent);
          if (record['kind'] == 'mql') {
            expect(
              (finalCurrent['matches'] as Map)[record['id']],
              record['matches'],
            );
          }
        }
        final resizeRecords = records
            .where((record) => record['kind'] == 'resize')
            .toList();
        expect(resizeRecords, hasLength(1));
        expect(resizeRecords.single['trusted'], true);
        await scripts.updateEnvironment(rotatedEnvironment);
        expect(_readState(scripts)['records'], hasLength(7));

        expect(pairingErrors, isEmpty);
        expect(documentRequests, hasLength(1));
        expect(documentRequests.single['path'], '/media');
        expect(documentRequests.single['authorizationPresent'], false);
        expect(documentRequests.single['cookiePresent'], false);
        expect(pairingOrigin, isNot(documentOrigin));

        // Begin one more update, then dispose while its native evaluation may
        // still be returning. A late reply must not publish a new snapshot.
        final beforeDispose = _readState(scripts);
        var disposed = false;
        var notificationAfterDispose = false;
        scripts.addListener(() {
          if (disposed && scripts!.ready) notificationAfterDispose = true;
        });
        final lateUpdate = scripts.updateEnvironment(
          const NativeDocumentEnvironment(
            width: 390,
            height: 844,
            devicePixelRatio: 1,
            dark: false,
            reducedMotion: false,
            pointer: 'coarse',
            hover: 'none',
            screenWidth: 390,
            screenHeight: 844,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        disposed = true;
        scripts.dispose();
        await lateUpdate.timeout(const Duration(seconds: 15));
        await scripts.closed;
        await tester.pump(const Duration(milliseconds: 20));
        expect(scripts.ready, isFalse);
        expect(_readState(scripts), beforeDispose);
        expect(notificationAfterDispose, isFalse);
      } finally {
        scripts?.dispose();
        if (scripts != null) await scripts.closed;
        if (window != null) windows.close(window);
        windows.dispose();
        await pairingListener.cancel();
        await documentListener.cancel();
        await pairingServer.close(force: true);
        await documentServer.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
