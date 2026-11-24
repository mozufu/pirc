import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_urls.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

const scriptNavigationOrigin = 'https://example.test';
const scriptNavigationStart = '$scriptNavigationOrigin/script-navigation';

const scriptNavigationHtml =
    '''<!doctype html><html><head><title>Script navigation</title></head><body>
<p id="where">Waiting for script</p>
<button id="href" type="button">Navigate with href</button>
<button id="assign" type="button">Navigate with assign</button>
<button id="replace" type="button">Replace current page</button>
<button id="hash" type="button">Set fragment</button>
<button id="clear-hash" type="button">Clear fragment</button>
<button id="reload" type="button">Reload from script</button>
<button id="popup" type="button">Open new window</button>
<form action="/post-response" method="post">
  <input name="value" value="posted">
  <button type="submit">Submit POST response</button>
</form>
<p id="fragment-target">Fragment target</p>
<script>
// This must stay blocked because it runs without a trusted user activation.
window.open('/startup-popup', '_blank');
const where = document.querySelector('#where');
where.textContent = 'loaded:' + window.location.href;
window.addEventListener('hashchange', () => {
  where.textContent = 'hashchange:' + document.location.href + '|' + location.hash;
});
document.querySelector('#href').onclick = () => {
  document.location.href = '/nav-href';
};
document.querySelector('#assign').onclick = () => {
  window.location.assign('/nav-assigned');
};
document.querySelector('#replace').onclick = () => {
  location.replace('/nav-replaced');
};
document.querySelector('#hash').onclick = () => {
  location.hash = '#fragment';
};
document.querySelector('#clear-hash').onclick = () => {
  location.hash = '';
};
document.querySelector('#reload').onclick = () => {
  window.location.reload();
};
document.querySelector('#popup').onclick = () => {
  window.open('/blank-child', '_blank');
};
</script></body></html>''';

/// Uses the real Android document-script platform methods, while keeping the
/// document routes local and deterministic. No network coverage is claimed.
class ScriptNavigationGateway extends Gateway {
  final List<Json> documentRequests = [];

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    switch (method) {
      case 'boot':
        return {
          'origin': scriptNavigationOrigin,
          'pairingStamp': 'script-navigation-fixture',
        };
      case 'resolveDocumentUrl':
        return resolveNativeDocumentUrl(
          '${args['reference'] ?? ''}',
          '${args['baseUrl'] ?? scriptNavigationStart}',
        );
      case 'document':
        final url = '${args['url']}';
        final requestMethod = '${args['method'] ?? 'GET'}'.toUpperCase();
        documentRequests.add({
          'url': url,
          'method': requestMethod,
          'cacheMode': args['cacheMode'],
        });
        return {
          'status': 200,
          'bytes': Uint8List.fromList(utf8.encode(scriptNavigationHtml)),
          'mimeType': 'text/html',
          'charset': 'utf-8',
          'finalUrl': url,
          'finalMethod': requestMethod,
          'headersRelevant': {
            'cache-control': 'no-store',
            'content-type': 'text/html; charset=utf-8',
          },
        };
      default:
        // This reaches the Android method channel for capabilities, isolate
        // creation, evaluation and disposal of the JavaScript runtime.
        return super.call(method, args);
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'script navigation commits into native history and keeps location in sync',
    (tester) async {
      final gateway = ScriptNavigationGateway();
      final windows = NativeDocumentWindows(gateway);
      final window = windows.target('', null, sourceUrl: scriptNavigationStart);
      final theme = await PircTheme.load();

      Future<void> until(bool Function() ready, String label) async {
        for (var i = 0; i < 240 && !ready(); i++) {
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(
          ready(),
          isTrue,
          reason:
              '$label: ${windows.active?.currentDocument?.scripts?.diagnostics}',
        );
        expect(tester.takeException(), isNull, reason: label);
      }

      Finder button(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is NativeHtmlButtonWidget && widget.button.label == label,
      );

      Future<void> tapButton(String label) async {
        await until(
          () => window.currentDocument?.scripts?.ready == true,
          'script context is ready before $label',
        );
        await tester.pump();
        final finder = button(label);
        expect(finder, findsOneWidget, reason: 'button: $label');
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pump();
      }

      String whereText() => html
          .parse(window.currentDocument!.scripts!.content!.text)
          .querySelector('#where')!
          .text;

      Future<void> tapWorkspaceButton(String label) async {
        await tester.tap(find.byTooltip(label));
        await tester.pump();
      }

      try {
        expect(
          await window.load(
            const NativeHtmlFormRequest(
              url: scriptNavigationStart,
              method: 'GET',
              target: '',
            ),
            baseUrl: scriptNavigationStart,
          ),
          NativeDocumentLoadResult.committed,
        );
        expect(windows.select(window), isTrue);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: NativeDocumentWorkspace(windows: windows),
          ),
        );
        await until(
          () => window.currentDocument?.scripts?.ready == true,
          'initial JavaScript context starts',
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(whereText(), 'loaded:$scriptNavigationStart');
        expect(windows.windows, hasLength(1));
        expect(
          gateway.documentRequests.map((request) => request['url']),
          isNot(contains('$scriptNavigationOrigin/startup-popup')),
          reason: 'startup window.open has no trusted activation',
        );

        await tapButton('Navigate with href');
        await until(
          () =>
              !window.loading &&
              window.current?.url == '$scriptNavigationOrigin/nav-href',
          'document.location.href loads into the current native window',
        );
        expect(window.history, hasLength(2));

        await tapButton('Navigate with assign');
        await until(
          () =>
              !window.loading &&
              window.current?.url == '$scriptNavigationOrigin/nav-assigned',
          'location.assign appends native history',
        );
        expect(window.history, hasLength(3));

        await tapButton('Replace current page');
        await until(
          () =>
              !window.loading &&
              window.current?.url == '$scriptNavigationOrigin/nav-replaced',
          'location.replace commits in place',
        );
        expect(window.history, hasLength(3));
        expect(window.history.map((entry) => entry.url), [
          scriptNavigationStart,
          '$scriptNavigationOrigin/nav-href',
          '$scriptNavigationOrigin/nav-replaced',
        ]);

        final replacedDocument = window.currentDocument;
        await tapButton('Set fragment');
        await until(
          () =>
              window.current?.url ==
              '$scriptNavigationOrigin/nav-replaced#fragment',
          'hash assignment commits a same-document history entry',
        );
        expect(window.currentDocument, same(replacedDocument));
        expect(window.history, hasLength(4));
        await until(
          () =>
              whereText() ==
              'hashchange:$scriptNavigationOrigin/nav-replaced#fragment|#fragment',
          'hashchange reads the acknowledged URL and fragment',
        );

        await tapButton('Set fragment');
        await tester.pump(const Duration(milliseconds: 150));
        expect(window.history, hasLength(4));

        await tapButton('Clear fragment');
        await until(
          () => window.current?.url == '$scriptNavigationOrigin/nav-replaced#',
          'clearing the fragment updates the acknowledged URL',
        );
        expect(window.currentDocument, same(replacedDocument));
        expect(window.history, hasLength(5));
        await until(
          () =>
              whereText() ==
              'hashchange:$scriptNavigationOrigin/nav-replaced#|',
          'clearing the fragment dispatches hashchange with an empty hash',
        );

        await tapWorkspaceButton('返回');
        await until(
          () =>
              window.current?.url ==
              '$scriptNavigationOrigin/nav-replaced#fragment',
          'native back restores the fragment history entry',
        );
        await until(
          () =>
              whereText() ==
              'hashchange:$scriptNavigationOrigin/nav-replaced#fragment|#fragment',
          'back acknowledges the restored fragment before hashchange',
        );
        expect(window.history, hasLength(5));

        await tapWorkspaceButton('返回');
        await until(
          () => window.current?.url == '$scriptNavigationOrigin/nav-replaced',
          'second back restores the fragmentless native history entry',
        );
        await until(
          () =>
              whereText() == 'hashchange:$scriptNavigationOrigin/nav-replaced|',
          'second back synchronizes the empty location hash',
        );
        expect(window.history, hasLength(5));

        final beforeReloadCount = gateway.documentRequests
            .where(
              (request) =>
                  request['url'] == '$scriptNavigationOrigin/nav-replaced',
            )
            .length;
        await tapButton('Reload from script');
        await until(
          () =>
              !window.loading &&
              gateway.documentRequests
                      .where(
                        (request) =>
                            request['url'] ==
                            '$scriptNavigationOrigin/nav-replaced',
                      )
                      .length ==
                  beforeReloadCount + 1,
          'script reload performs one fresh document request',
        );
        expect(window.history, hasLength(5));
        expect(window.current?.url, '$scriptNavigationOrigin/nav-replaced');

        await tapButton('Submit POST response');
        await until(
          () =>
              !window.loading &&
              window.current?.url == '$scriptNavigationOrigin/post-response' &&
              window.currentDocument?.reloadRequest?.method == 'POST',
          'native form creates a POST response that reload must confirm',
        );
        expect(window.history, hasLength(4));
        final postRequestCount = gateway.documentRequests
            .where(
              (request) =>
                  request['url'] == '$scriptNavigationOrigin/post-response' &&
                  request['method'] == 'POST',
            )
            .length;
        expect(postRequestCount, 1);
        await tapButton('Reload from script');
        await until(
          () => find.text('重新送出表單？').evaluate().isNotEmpty,
          'POST reload asks for explicit confirmation',
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('重新送出表單？'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pump(const Duration(milliseconds: 300));
        await until(
          () => find.text('重新送出表單？').evaluate().isEmpty,
          'cancel dismisses the reload confirmation',
        );
        expect(
          gateway.documentRequests
              .where(
                (request) =>
                    request['url'] == '$scriptNavigationOrigin/post-response' &&
                    request['method'] == 'POST',
              )
              .length,
          1,
          reason: 'canceling the reload confirmation sends no second POST',
        );
        expect(window.history, hasLength(4));
        await tapButton('Reload from script');
        await until(
          () => find.text('重新送出表單？').evaluate().isNotEmpty,
          'second POST reload still requires confirmation',
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('重新送出'));
        await tester.pump();
        await until(
          () =>
              !window.loading &&
              gateway.documentRequests
                      .where(
                        (request) =>
                            request['url'] ==
                                '$scriptNavigationOrigin/post-response' &&
                            request['method'] == 'POST',
                      )
                      .length ==
                  2,
          'confirmed POST reload resends the response request',
        );
        expect(window.history, hasLength(4));

        final opener = window;
        await tapButton('Open new window');
        await until(
          () =>
              windows.windows.length == 2 &&
              windows.active != null &&
              windows.active != opener &&
              !windows.active!.loading &&
              windows.active!.current?.url ==
                  '$scriptNavigationOrigin/blank-child',
          'trusted _blank window.open creates its own native browsing context',
        );
        await until(
          () => windows.active!.currentDocument?.scripts?.ready == true,
          'new window remains script-interactive after retained history',
        );
        expect(windows.active!.history, hasLength(1));
        expect(
          gateway.documentRequests.map((request) => request['url']),
          isNot(contains('$scriptNavigationOrigin/startup-popup')),
          reason:
              'script startup popup stays blocked after navigation and reload',
        );
        expect(window.history, hasLength(4));
        expect(window.current?.url, '$scriptNavigationOrigin/post-response');
        final oldest = window.history.first;
        expect(oldest.requiresHistoryRefetch, isTrue);
        expect(
          await window.traverseHistory(0),
          NativeDocumentLoadResult.committed,
        );
        windows.select(window);
        await until(
          () => window.currentDocument?.scripts?.ready == true,
          'evicted history reloads into a working script context',
        );
        expect(window.current?.url, scriptNavigationStart);
        expect(window.currentDocument, isNot(same(oldest.document)));
        await tapButton('Set fragment');
        await until(
          () => window.current?.url == '$scriptNavigationStart#fragment',
          'restored history remains interactive',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        windows.dispose();
      }
    },
  );
}
