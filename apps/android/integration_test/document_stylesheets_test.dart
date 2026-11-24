import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/html_form_submission.dart';

const _page = r'''<!doctype html>
<html><head><base id="base" href="/base/one/">
<style id="inline" media="screen">#inlineProbe { color: rgb(1,2,3); width: 10px; height: 12px; }</style>
<style id="readOnly">@import "read.css"; .readOnly {color: red}</style>
<link id="initial" rel="stylesheet" href="theme.css">
</head><body>
<div id="inlineProbe" class="themed">probe</div>
<pre id="events">[]</pre>
<button id="insert">insert CSSOM rule</button><button id="setRule">set CSSOM property</button>
<button id="deleteRule">delete CSSOM rule</button><button id="replaceText">replace style text</button>
<button id="mediaPrint">set print media</button><button id="disableSheet">disable sheet</button>
<button id="enableSheet">enable sheet</button><button id="mediaScreen">set screen media</button>
<button id="addGood">add good link</button><button id="addMissing">add missing link</button>
<button id="addSlow">add slow link</button><button id="swapSlow">replace slow href</button>
<button id="addRemoveSlow">add removable slow link</button><button id="removeSlow">remove slow link</button>
<button id="addDisabled">add disabled link</button><button id="enableDisabled">enable disabled link</button>
<button id="screenDisabled">set disabled link to screen</button>
<button id="changeBase">change base URL</button><button id="addBaseLink">add relative link</button>
<button id="addImport">add imported stylesheet</button><button id="addImport404">add stylesheet with missing import</button>
<script>
window.__sheetEvents = [];
window.__styleLinks = Object.create(null);
window.__readOnlyCount = document.querySelector('#readOnly').sheet.cssRules.length;
document.querySelector('#base').setAttribute('href', '/base/two/');
function recordSheetEvent(id, type) {
  window.__sheetEvents.push({id: id, type: type});
  document.querySelector('#events').textContent = JSON.stringify(window.__sheetEvents);
}
function addLink(id, href, media, disabled) {
  const link = document.createElement('link');
  link.setAttribute('id', id);
  link.setAttribute('rel', 'stylesheet');
  link.setAttribute('href', href);
  if (media) link.setAttribute('media', media);
  if (disabled) link.setAttribute('disabled', '');
  link.addEventListener('load', () => recordSheetEvent(id, 'load'));
  link.addEventListener('error', () => recordSheetEvent(id, 'error'));
  window.__styleLinks[id] = link;
  document.head.appendChild(link);
  return link;
}
document.querySelector('#insert').onclick = () => {
  document.querySelector('#inline').sheet.insertRule(
    '#inlineProbe { color: rgb(9,19,29); width: 31px; height: 17px; }', 1);
};
document.querySelector('#setRule').onclick = () => {
  const rule = document.querySelector('#inline').sheet.cssRules[1];
  rule.style.setProperty('color', 'rgb(4,5,6)');
  rule.style.setProperty('height', '23px');
};
document.querySelector('#deleteRule').onclick = () =>
  document.querySelector('#inline').sheet.deleteRule(1);
document.querySelector('#replaceText').onclick = () => {
  document.querySelector('#inline').textContent =
    '#inlineProbe { color: rgb(17,27,37); width: 41px; height: 19px; }';
};
document.querySelector('#mediaPrint').onclick = () => {
  document.querySelector('#inline').media = 'print';
};
document.querySelector('#disableSheet').onclick = () => {
  document.querySelector('#inline').sheet.disabled = true;
};
document.querySelector('#enableSheet').onclick = () => {
  document.querySelector('#inline').sheet.disabled = false;
};
document.querySelector('#mediaScreen').onclick = () => {
  document.querySelector('#inline').media = 'screen';
};
document.querySelector('#addGood').onclick = () => addLink('good', '/css/good.css');
document.querySelector('#addMissing').onclick = () => addLink('missing', '/css/missing.css');
document.querySelector('#addSlow').onclick = () => addLink('slow', '/css/slow.css');
document.querySelector('#swapSlow').onclick = () =>
  window.__styleLinks.slow.setAttribute('href', '/css/replacement.css');
document.querySelector('#addRemoveSlow').onclick = () =>
  addLink('removed', '/css/remove-slow.css');
document.querySelector('#removeSlow').onclick = () =>
  window.__styleLinks.removed.remove();
document.querySelector('#addDisabled').onclick = () =>
  addLink('disabled', '/css/disabled.css', 'print', true);
document.querySelector('#enableDisabled').onclick = () =>
  window.__styleLinks.disabled.removeAttribute('disabled');
document.querySelector('#screenDisabled').onclick = () =>
  window.__styleLinks.disabled.setAttribute('media', 'screen');
document.querySelector('#changeBase').onclick = () =>
  document.querySelector('#base').setAttribute('href', '/base/two/');
document.querySelector('#addBaseLink').onclick = () => addLink('baseNew', 'new.css');
document.querySelector('#addImport').onclick = () =>
  addLink('importGood', '/css/import-root.css');
document.querySelector('#addImport404').onclick = () =>
  addLink('importMissing', '/css/import-404-root.css');
</script>
</body></html>''';

String _text(NativeDocumentScripts scripts, String selector) =>
    html.parse(scripts.content?.text ?? '').querySelector(selector)?.text ?? '';

Future<void> _click(NativeDocumentScripts scripts, String id) async {
  final element = html.parse(scripts.content!.text).querySelector('#$id');
  expect(element, isNotNull, reason: 'button #$id is in the current document');
  final scriptId = element!.attributes['data-pirc-script-id'];
  expect(scriptId, isNotNull, reason: 'button #$id has a native script id');
  await scripts.click(scriptId!, const []);
}

List<String> _events(NativeDocumentScripts scripts) {
  final encoded = _text(scripts, '#events');
  if (encoded.isEmpty) return const [];
  final values = jsonDecode(encoded) as List;
  return values.map((value) => '${value['id']}:${value['type']}').toList();
}

Map<String, String> _computed(
  NativeDocumentScripts scripts, {
  String selector = '#inlineProbe',
}) {
  final markup = scripts.content?.text;
  final sheets = scripts.stylesheets;
  if (markup == null || sheets == null) {
    throw StateError('The document has no current stylesheet snapshot.');
  }
  final document = html.parse(markup);
  final element = document.querySelector(selector);
  if (element == null) throw StateError('Missing style target $selector.');
  final result = NativeDocumentStyleEngine(
    stylesheets: sheets,
    viewportWidth: 1024,
    dark: false,
    documentBaseUrl: scripts.documentBaseUrl,
  ).apply(document);
  return Map<String, String>.from(
    result.stylesByElement[element] ?? const <String, String>{},
  );
}

String? _normalizedColor(Map<String, String> styles) =>
    styles['color']?.replaceAll(RegExp(r'\s+'), '');

Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String description,
) async {
  for (var n = 0; n < 300 && !ready(); n++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue, reason: description);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native stylesheet bootstrap, live CSSOM, dynamic links and imports stay current',
    (tester) async {
      final apiServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final pairOrigin = 'http://127.0.0.1:${apiServer.port}';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final token = 'pirc_dev_${'T' * 43}';
      final requests = <String>[];
      final requestCounts = <String, int>{};
      final serverErrors = <String>[];
      var pairingSessionRequests = 0;
      final slowStarted = Completer<void>();
      final slowRelease = Completer<void>();
      final removedStarted = Completer<void>();
      final removedRelease = Completer<void>();
      final importStarted = Completer<void>();
      final importRelease = Completer<void>();

      Future<void> respond(
        HttpRequest request, {
        required String body,
        required String mimeType,
        int status = HttpStatus.ok,
      }) async {
        request.response.statusCode = status;
        request.response.headers.set(HttpHeaders.contentTypeHeader, mimeType);
        request.response.write(body);
        await request.response.close();
      }

      final pairListener = apiServer.listen((request) async {
        final path = request.uri.path;
        if (path != '/api/sessions') {
          serverErrors.add('Unexpected pairing API request $path.');
          await respond(
            request,
            body: '{"error":"unexpected pairing API request"}',
            mimeType: ContentType.json.mimeType,
            status: HttpStatus.notFound,
          );
          return;
        }
        pairingSessionRequests++;
        if (request.headers.value(HttpHeaders.authorizationHeader) !=
            'Bearer $token') {
          serverErrors.add(
            'The pairing request did not use its synthetic bearer.',
          );
        }
        await respond(
          request,
          body: '{"sessions":[]}',
          mimeType: ContentType.json.mimeType,
        );
      });

      final listener = server.listen((request) async {
        final path = request.uri.path;
        requests.add(path);
        requestCounts[path] = (requestCounts[path] ?? 0) + 1;
        if (request.headers.value(HttpHeaders.authorizationHeader) != null) {
          serverErrors.add('Authorization leaked to document resource $path.');
        }
        try {
          switch (path) {
            case '/page':
              await respond(
                request,
                body: _page,
                mimeType: 'text/html; charset=utf-8',
              );
            case '/base/one/read.css':
              await respond(
                request,
                body: '#inlineProbe {padding-bottom:6px}',
                mimeType: 'text/css; charset=utf-8',
              );
            case '/base/one/theme.css':
              await respond(
                request,
                body: '.themed { margin-left: 8px; }',
                mimeType: 'text/css; charset=utf-8',
              );
            case '/base/two/new.css':
              await respond(
                request,
                body: '#inlineProbe { word-spacing: 3px; }',
                mimeType: 'text/css; charset=utf-8',
              );
            case '/css/good.css':
              await respond(
                request,
                body: '#inlineProbe { padding-top: 7px; }',
                mimeType: 'text/css; charset=utf-8',
              );
            case '/css/missing.css':
              await respond(
                request,
                body: 'missing stylesheet',
                mimeType: 'text/css; charset=utf-8',
                status: HttpStatus.notFound,
              );
            case '/css/slow.css':
              if (!slowStarted.isCompleted) slowStarted.complete();
              await slowRelease.future;
              await respond(
                request,
                body: '#inlineProbe { bottom: 99px; }',
                mimeType: 'text/css; charset=utf-8',
              );
            case '/css/replacement.css':
              await respond(
                request,
                body: '#inlineProbe { bottom: 44px; }',
                mimeType: 'text/css; charset=utf-8',
              );
            case '/css/remove-slow.css':
              if (!removedStarted.isCompleted) removedStarted.complete();
              await removedRelease.future;
              await respond(
                request,
                body: '#inlineProbe { left: 99px; }',
                mimeType: 'text/css; charset=utf-8',
              );
            case '/css/disabled.css':
              await respond(
                request,
                body: '#inlineProbe { outline-width: 4px; }',
                mimeType: 'text/css; charset=utf-8',
              );
            case '/css/import-root.css':
              await respond(
                request,
                body:
                    "@import url('/css/import-child.css');\n#inlineProbe { right: 42px; }",
                mimeType: 'text/css; charset=utf-8',
              );
            case '/css/import-child.css':
              if (!importStarted.isCompleted) importStarted.complete();
              await importRelease.future;
              await respond(
                request,
                body: '#inlineProbe { top: 41px; }',
                mimeType: 'text/css; charset=utf-8',
              );
            case '/css/import-404-root.css':
              await respond(
                request,
                body:
                    "@import url('/css/missing-import.css');\n#inlineProbe { padding-right: 10px; }",
                mimeType: 'text/css; charset=utf-8',
              );
            case '/css/missing-import.css':
              await respond(
                request,
                body: 'missing imported stylesheet',
                mimeType: 'text/css; charset=utf-8',
                status: HttpStatus.notFound,
              );
            default:
              await respond(
                request,
                body: 'unexpected local stylesheet request: $path',
                mimeType: 'text/plain; charset=utf-8',
                status: HttpStatus.notFound,
              );
          }
        } catch (_) {
          // A native cancellation can close a delayed stylesheet request.
        }
      });

      final gateway = Gateway();
      final windows = NativeDocumentWindows(gateway);
      NativeDocumentWindow? root;
      NativeDocumentScripts? scripts;
      try {
        await tester.pumpWidget(const SizedBox());
        await gateway.call('pair', {
          'link': Uri(
            scheme: 'pirc',
            host: 'pair',
            queryParameters: {'url': pairOrigin, 'token': token},
          ).toString(),
        });
        final boot = obj(await gateway.call('boot'));
        expect(boot['documentStylesheets'], isTrue);

        root = windows.target('', null, sourceUrl: '$origin/source');
        final loaded = await root.load(
          NativeHtmlFormRequest(url: '$origin/page', method: 'GET', target: ''),
          baseUrl: origin,
        );
        expect(loaded, NativeDocumentLoadResult.committed, reason: root.error);
        final document = root.currentDocument!;
        scripts = NativeDocumentScripts(gateway);
        document.scripts = scripts;
        await windows.startDocumentScripts(document, scripts);
        expect(scripts.ready, isTrue, reason: scripts.diagnostics.join(';'));

        // This matches the frozen Chromium 153 inline CSSOM case: initial
        // rgb(1,2,3)/10x12, inserted rgb(9,19,29)/31x17, setProperty
        // rgb(4,5,6)/31x23, deletion to initial, then text replacement
        // rgb(17,27,37)/41x19.
        await tester.pump(const Duration(milliseconds: 250));
        expect(requestCounts['/base/one/theme.css'], 1);
        expect(requestCounts['/base/one/read.css'], 1);
        var style = _computed(scripts);
        expect(_normalizedColor(style), 'rgb(1,2,3)');
        expect(style['width'], '10px');
        expect(style['height'], '12px');
        expect(style['margin-left'], '8px');
        expect(style['padding-bottom'], '6px');

        await _click(scripts, 'insert');
        style = _computed(scripts);
        expect(_normalizedColor(style), 'rgb(9,19,29)');
        expect(style['width'], '31px');
        expect(style['height'], '17px');

        await _click(scripts, 'setRule');
        style = _computed(scripts);
        expect(_normalizedColor(style), 'rgb(4,5,6)');
        expect(style['width'], '31px');
        expect(style['height'], '23px');

        await _click(scripts, 'deleteRule');
        style = _computed(scripts);
        expect(_normalizedColor(style), 'rgb(1,2,3)');
        expect(style['width'], '10px');
        expect(style['height'], '12px');

        await _click(scripts, 'replaceText');
        style = _computed(scripts);
        expect(_normalizedColor(style), 'rgb(17,27,37)');
        expect(style['width'], '41px');
        expect(style['height'], '19px');

        await _click(scripts, 'mediaPrint');
        expect(_computed(scripts)['height'], isNull);
        await _click(scripts, 'mediaScreen');
        await _click(scripts, 'disableSheet');
        expect(_computed(scripts)['height'], isNull);
        await _click(scripts, 'enableSheet');
        expect(_computed(scripts)['height'], '19px');

        // A later base element change leaves the already-selected resource in
        // place. New relative links resolve against the new base URL.
        await _click(scripts, 'changeBase');
        await tester.pump(const Duration(milliseconds: 250));
        expect(requestCounts['/base/one/theme.css'], 1);
        await _click(scripts, 'addBaseLink');
        await _until(
          tester,
          () => _events(scripts!).contains('baseNew:load'),
          'relative link loaded from the changed base URL',
        );
        expect(requestCounts['/base/two/new.css'], 1);
        expect(_computed(scripts)['word-spacing'], '3px');

        await _click(scripts, 'addGood');
        await _until(
          tester,
          () => _events(scripts!).contains('good:load'),
          'dynamic stylesheet load event',
        );
        expect(requestCounts['/css/good.css'], 1);
        expect(_computed(scripts)['padding-top'], '7px');

        await _click(scripts, 'addMissing');
        await _until(
          tester,
          () => _events(scripts!).contains('missing:error'),
          'dynamic stylesheet error event',
        );
        expect(requestCounts['/css/missing.css'], 1);

        await _click(scripts, 'addDisabled');
        await tester.pump(const Duration(milliseconds: 250));
        expect(requestCounts['/css/disabled.css'] ?? 0, 0);
        await _click(scripts, 'enableDisabled');
        await _until(
          tester,
          () => _events(scripts!).contains('disabled:load'),
          'disabled stylesheet fetched after enabling',
        );
        expect(requestCounts['/css/disabled.css'], 1);
        expect(_computed(scripts)['outline-width'], isNull);
        await _click(scripts, 'screenDisabled');
        expect(_computed(scripts)['outline-width'], '4px');

        await _click(scripts, 'addSlow');
        await _until(
          tester,
          () => slowStarted.isCompleted,
          'slow CSS request started',
        );
        await _click(scripts, 'swapSlow');
        await _until(
          tester,
          () => _events(scripts!).contains('slow:load'),
          'replacement CSS request completed for the same link',
        );
        expect(requestCounts['/css/replacement.css'], 1);
        if (!slowRelease.isCompleted) slowRelease.complete();
        await tester.pump(const Duration(milliseconds: 250));
        expect(_computed(scripts)['bottom'], '44px');
        expect(
          _events(scripts).where((event) => event == 'slow:load').length,
          1,
        );

        await _click(scripts, 'addRemoveSlow');
        await _until(
          tester,
          () => removedStarted.isCompleted,
          'removable stylesheet request started',
        );
        await _click(scripts, 'removeSlow');
        if (!removedRelease.isCompleted) removedRelease.complete();
        await tester.pump(const Duration(milliseconds: 250));
        expect(_computed(scripts)['left'], isNull);
        expect(
          _events(scripts).where((event) => event.startsWith('removed:')),
          isEmpty,
        );

        await _click(scripts, 'addImport');
        await _until(
          tester,
          () => importStarted.isCompleted,
          'imported stylesheet request started',
        );
        expect(_events(scripts).contains('importGood:load'), isFalse);
        expect(_computed(scripts)['right'], isNull);
        if (!importRelease.isCompleted) importRelease.complete();
        await _until(
          tester,
          () => _events(scripts!).contains('importGood:load'),
          'link load event waits for its imported stylesheet',
        );
        style = _computed(scripts);
        expect(style['top'], '41px');
        expect(style['right'], '42px');

        await _click(scripts, 'addImport404');
        await _until(
          tester,
          () => _events(scripts!).contains('importMissing:error'),
          'failed import reports an error on its owning link',
        );
        expect(requestCounts['/css/missing-import.css'], 1);
        expect(_computed(scripts)['padding-right'], '10px');

        expect(pairingSessionRequests, greaterThan(0));
        expect(serverErrors, isEmpty);
        expect(
          requests.where((path) => path.startsWith('/css/')).toList(),
          containsAll([
            '/css/good.css',
            '/css/missing.css',
            '/css/slow.css',
            '/css/replacement.css',
            '/css/remove-slow.css',
            '/css/disabled.css',
            '/css/import-root.css',
            '/css/import-child.css',
            '/css/import-404-root.css',
            '/css/missing-import.css',
          ]),
        );
      } finally {
        if (!slowRelease.isCompleted) slowRelease.complete();
        if (!removedRelease.isCompleted) removedRelease.complete();
        if (!importRelease.isCompleted) importRelease.complete();
        if (root != null) windows.close(root);
        windows.dispose();
        scripts?.dispose();
        if (scripts != null) await scripts.closed;
        await gateway.call('unpair');
        await listener.cancel();
        await server.close(force: true);
        await pairListener.cancel();
        await apiServer.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
